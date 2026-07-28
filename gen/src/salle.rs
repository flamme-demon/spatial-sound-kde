//! Synthese d'une reponse impulsionnelle binaurale de salle (BRIR).
//!
//! Trois etages, dans l'ordre ou l'oreille les percoit :
//!
//! 1. le son direct, filtre par la HRTF de la direction de l'enceinte ;
//! 2. les premieres reflexions, obtenues par la methode des sources images
//!    (Allen & Berkley, 1979) : chaque mur est un miroir, chaque image est une
//!    source virtuelle avec sa direction, son retard et son attenuation ;
//! 3. la queue de reverberation, trop dense pour etre calculee image par image,
//!    synthetisee comme un bruit decorrele entre les oreilles et amorti.
//!
//! Le passage de 2 a 3 se fait au temps de melange, au-dela duquel les
//! reflexions deviennent statistiquement indiscernables les unes des autres.

use crate::sofa::JeuSofa;

pub const CELERITE: f32 = 343.0; // m/s, air a 20 degres

pub struct Salle {
    /// Dimensions interieures en metres.
    pub largeur: f32,
    pub profondeur: f32,
    pub hauteur: f32,
    /// Coefficient d'absorption moyen des parois, entre 0 et 1.
    pub absorption: f32,
    /// Amortissement des aigus a chaque reflexion, entre 0 et 1.
    /// Sans lui la queue sonne blanche et artificielle.
    pub amortissement: f32,
    /// Distance auditeur-enceinte en metres.
    pub rayon: f32,
    /// Gain du son direct en dB, pour rapprocher ou eloigner la scene.
    pub gain_direct: f32,
    /// Ordre maximal des reflexions calculees explicitement.
    pub ordre: i32,
}

impl Default for Salle {
    fn default() -> Self {
        Self::preset("studio").unwrap()
    }
}

impl Salle {
    /// Salles types, mesurees puis retenues pour leur compromis
    /// reverberation / lateralisation (voir le tableau du README).
    pub fn preset(nom: &str) -> Option<Self> {
        let base = |largeur, profondeur, hauteur, absorption, rayon| Salle {
            largeur,
            profondeur,
            hauteur,
            absorption,
            amortissement: 0.35,
            rayon,
            gain_direct: 0.0,
            ordre: 3,
        };
        Some(match nom {
            // Tres amortie : le plus proche d'un profil de jeu.
            "cabine" => base(3.5, 4.0, 2.4, 0.72, 1.5),
            // Compromis par defaut.
            "studio" => base(4.2, 5.0, 2.6, 0.60, 1.8),
            // Regie plus vivante.
            "regie" => base(4.5, 5.5, 2.7, 0.50, 2.0),
            // Piece domestique : ample, nettement plus lointaine.
            "salon" => base(5.0, 6.5, 2.8, 0.30, 2.5),
            _ => return None,
        })
    }
}

impl Salle {
    /// Duree de reverberation par la formule de Sabine.
    pub fn rt60(&self) -> f32 {
        let v = self.largeur * self.profondeur * self.hauteur;
        let s = 2.0
            * (self.largeur * self.profondeur
                + self.largeur * self.hauteur
                + self.profondeur * self.hauteur);
        let a = (self.absorption.clamp(0.01, 0.99)) * s;
        (0.161 * v / a).clamp(0.05, 3.0)
    }

    /// Temps de melange : au-dela, on cesse de calculer les images une a une.
    fn temps_melange(&self) -> f32 {
        let v = self.largeur * self.profondeur * self.hauteur;
        (0.002 * v.sqrt()).clamp(0.015, 0.08)
    }
}

/// Generateur pseudo-aleatoire deterministe (xorshift64*).
/// Deterministe pour que deux generations aux memes parametres donnent le meme
/// fichier — indispensable pour comparer deux salles a l'ecoute.
struct Alea(u64);

impl Alea {
    fn new(graine: u64) -> Self {
        Self(graine | 1)
    }
    fn suivant(&mut self) -> f32 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        let v = x.wrapping_mul(0x2545_F491_4F6C_DD1D);
        // Bruit centre dans [-1, 1[
        ((v >> 11) as f64 / (1u64 << 52) as f64) as f32 * 2.0 - 1.0
    }
}

pub struct Brir {
    pub gauche: Vec<f32>,
    pub droite: Vec<f32>,
}

/// Ajoute une impulsion a retard fractionnaire par interpolation lineaire.
fn deposer(sortie: &mut [f32], position: f32, gain: f32) {
    if gain == 0.0 || position < 0.0 {
        return;
    }
    let i = position.floor() as usize;
    if i + 1 >= sortie.len() {
        return;
    }
    let f = position - i as f32;
    sortie[i] += gain * (1.0 - f);
    sortie[i + 1] += gain * f;
}

/// Convolue un train d'impulsions clairseme par une HRTF, en accumulant.
/// La convolution directe suffit : le train compte quelques centaines
/// d'impulsions non nulles, pas des dizaines de milliers.
fn convoluer_accumuler(sortie: &mut [f32], train: &[f32], hrtf: &[f32]) {
    for (i, &v) in train.iter().enumerate() {
        if v == 0.0 {
            continue;
        }
        for (j, &h) in hrtf.iter().enumerate() {
            let k = i + j;
            if k >= sortie.len() {
                break;
            }
            sortie[k] += v * h;
        }
    }
}

/// Filtre passe-bas a un pole, applique aux reflexions tardives pour simuler
/// l'absorption progressive des aigus par les parois et par l'air.
fn amortir(signal: &mut [f32], coefficient: f32) {
    let mut etat = 0.0f32;
    for e in signal.iter_mut() {
        etat += coefficient * (*e - etat);
        *e = etat;
    }
}

/// Synthetise la BRIR d'une enceinte placee a l'azimut donne.
pub fn synthetiser(
    sofa: &JeuSofa,
    salle: &Salle,
    azimut_deg: f32,
    elevation_deg: f32,
    duree_s: f32,
    graine: u64,
) -> Brir {
    let fe = sofa.frequence as f32;
    let n = (duree_s * fe) as usize;
    let lh = sofa.longueur;

    // L'auditeur est au centre de la piece, legerement en retrait du fond.
    let (lx, ly, lz) = (salle.largeur, salle.profondeur, salle.hauteur);
    let auditeur = [lx * 0.5, ly * 0.38, 1.2];

    // L'enceinte est placee sur le cercle d'ecoute, a l'azimut demande.
    let az = azimut_deg.to_radians();
    let el = elevation_deg.to_radians();
    let source = [
        auditeur[0] - salle.rayon * el.cos() * az.sin(),
        auditeur[1] + salle.rayon * el.cos() * az.cos(),
        auditeur[2] + salle.rayon * el.sin(),
    ];

    let beta = (1.0 - salle.absorption.clamp(0.0, 0.99)).sqrt();
    let melange = salle.temps_melange();

    // Les images sont regroupees par direction : convoluer une HRTF par image
    // couterait des milliers de convolutions pour un resultat identique, les
    // directions voisines partageant la meme reponse a l'oreille pres.
    const PAS_AZ: f32 = 15.0;
    const PAS_EL: f32 = 30.0;
    let mut paquets: std::collections::HashMap<(i32, i32), Vec<f32>> =
        std::collections::HashMap::new();

    let ordre = salle.ordre.max(0);
    let mut energie_tardive = 0.0f32;

    for mx in -ordre..=ordre {
        for my in -ordre..=ordre {
            for mz in -ordre..=ordre {
                for px in 0..2 {
                    for py in 0..2 {
                        for pz in 0..2 {
                            // Comptage des reflexions par axe (Allen & Berkley).
                            let rx = (mx - px).abs() + mx.abs();
                            let ry = (my - py).abs() + my.abs();
                            let rz = (mz - pz).abs() + mz.abs();
                            let total = rx + ry + rz;
                            if total > ordre {
                                continue;
                            }

                            let ix = (1 - 2 * px) as f32 * source[0] + 2.0 * mx as f32 * lx;
                            let iy = (1 - 2 * py) as f32 * source[1] + 2.0 * my as f32 * ly;
                            let iz = (1 - 2 * pz) as f32 * source[2] + 2.0 * mz as f32 * lz;

                            let dx = ix - auditeur[0];
                            let dy = iy - auditeur[1];
                            let dz = iz - auditeur[2];
                            let dist = (dx * dx + dy * dy + dz * dz).sqrt().max(0.1);

                            let retard = dist / CELERITE * fe;
                            if retard as usize + lh >= n {
                                continue;
                            }

                            // Attenuation : divergence spherique et absorption.
                            let mut gain = beta.powi(total) / dist;
                            if total == 0 {
                                gain *= 10f32.powf(salle.gain_direct / 20.0);
                            }

                            // Au-dela du temps de melange, l'energie part dans la
                            // queue de synthese plutot que dans une image isolee.
                            if total > 0 && dist / CELERITE > melange {
                                energie_tardive += gain * gain;
                                continue;
                            }

                            // Direction vue de l'auditeur. Convention : x devant
                            // (+y de la piece), y a gauche (-x de la piece).
                            let az_i = (-dx).atan2(dy).to_degrees();
                            let el_i = (dz / dist).asin().to_degrees();
                            let cle = (
                                (az_i / PAS_AZ).round() as i32,
                                (el_i / PAS_EL).round() as i32,
                            );
                            let train = paquets.entry(cle).or_insert_with(|| vec![0.0; n]);
                            deposer(train, retard, gain);
                        }
                    }
                }
            }
        }
    }

    let mut g = vec![0.0f32; n];
    let mut d = vec![0.0f32; n];
    for ((kaz, kel), train) in &paquets {
        let hrtf = sofa.filtre(*kaz as f32 * PAS_AZ, *kel as f32 * PAS_EL, salle.rayon);
        // Les retards renvoyes par libmysofa sont deja inclus dans la geometrie :
        // les reappliquer doublerait la difference interaurale.
        convoluer_accumuler(&mut g, train, &hrtf.gauche);
        convoluer_accumuler(&mut d, train, &hrtf.droite);
    }

    // --- queue de reverberation ---------------------------------------------
    let rt60 = salle.rt60();
    let tau = rt60 / 6.908; // decroissance de 60 dB
    let debut = (melange * fe) as usize;
    let mut alea = Alea::new(graine ^ ((azimut_deg as i64 as u64) << 8));
    let mut qg = vec![0.0f32; n];
    let mut qd = vec![0.0f32; n];
    for i in debut..n {
        let t = (i - debut) as f32 / fe;
        let enveloppe = (-t / tau).exp();
        qg[i] = alea.suivant() * enveloppe;
        qd[i] = alea.suivant() * enveloppe;
    }
    amortir(&mut qg, salle.amortissement.clamp(0.02, 1.0));
    amortir(&mut qd, salle.amortissement.clamp(0.02, 1.0));

    // Calage du niveau de la queue sur l'energie que les images tardives
    // auraient portee : la transition doit etre inaudible.
    let e_queue: f32 = qg.iter().map(|v| v * v).sum::<f32>().max(1e-20);
    let facteur = (energie_tardive / e_queue).sqrt();
    for i in 0..n {
        g[i] += qg[i] * facteur;
        d[i] += qd[i] * facteur;
    }

    Brir {
        gauche: g,
        droite: d,
    }
}
