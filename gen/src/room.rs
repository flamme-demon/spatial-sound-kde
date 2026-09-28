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

use crate::sofa::SofaSet;

pub const SPEED_OF_SOUND: f32 = 343.0; // m/s, air a 20 degres

pub struct Room {
    /// Dimensions interieures en metres.
    pub width: f32,
    pub depth: f32,
    pub height: f32,
    /// Coefficient d'absorption moyen des parois, entre 0 et 1.
    pub absorption: f32,
    /// Amortissement des aigus a chaque reflexion, entre 0 et 1.
    /// Sans lui la queue sonne blanche et artificielle.
    pub damping: f32,
    /// Distance auditeur-enceinte en metres.
    pub radius: f32,
    /// Gain du son direct en dB, pour rapprocher ou eloigner la scene.
    pub direct_gain: f32,
    /// Ordre maximal des reflexions calculees explicitement.
    pub order: i32,
}

impl Default for Room {
    fn default() -> Self {
        Self::preset("studio").unwrap()
    }
}

impl Room {
    /// Salles types, mesurees puis retenues pour leur compromis
    /// reverberation / lateralisation (voir le tableau du README).
    /// Les noms francais d'avant la 1.1 restent acceptes.
    pub fn preset(name: &str) -> Option<Self> {
        let base = |width, depth, height, absorption, radius| Room {
            width,
            depth,
            height,
            absorption,
            damping: 0.35,
            radius,
            direct_gain: 0.0,
            order: 3,
        };
        Some(match name {
            // Tres amortie : le plus proche d'un profil de jeu.
            "booth" | "cabine" => base(3.5, 4.0, 2.4, 0.72, 1.5),
            // Compromis par defaut.
            "studio" => base(4.2, 5.0, 2.6, 0.60, 1.8),
            // Regie plus vivante.
            "control-room" | "regie" => base(4.5, 5.5, 2.7, 0.50, 2.0),
            // Piece domestique : ample, nettement plus lointaine.
            "living-room" | "salon" => base(5.0, 6.5, 2.8, 0.30, 2.5),
            _ => return None,
        })
    }
}

impl Room {
    /// Duree de reverberation par la formule de Sabine.
    pub fn rt60(&self) -> f32 {
        let v = self.width * self.depth * self.height;
        let s = 2.0
            * (self.width * self.depth
                + self.width * self.height
                + self.depth * self.height);
        let a = (self.absorption.clamp(0.01, 0.99)) * s;
        (0.161 * v / a).clamp(0.05, 3.0)
    }

    /// Temps de melange : au-dela, on cesse de calculer les images une a une.
    fn mixing_time(&self) -> f32 {
        let v = self.width * self.depth * self.height;
        (0.002 * v.sqrt()).clamp(0.015, 0.08)
    }
}

/// Generateur pseudo-aleatoire deterministe (xorshift64*).
/// Deterministe pour que deux generations aux memes parametres donnent le meme
/// fichier — indispensable pour comparer deux salles a l'ecoute.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed | 1)
    }
    fn next(&mut self) -> f32 {
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
    pub left: Vec<f32>,
    pub right: Vec<f32>,
}

/// Ajoute une impulsion a retard fractionnaire par interpolation lineaire.
fn deposit(output: &mut [f32], position: f32, gain: f32) {
    if gain == 0.0 || position < 0.0 {
        return;
    }
    let i = position.floor() as usize;
    if i + 1 >= output.len() {
        return;
    }
    let f = position - i as f32;
    output[i] += gain * (1.0 - f);
    output[i + 1] += gain * f;
}

/// Convolue un train d'impulsions clairseme par une HRTF, en accumulant.
/// La convolution directe suffit : le train compte quelques centaines
/// d'impulsions non nulles, pas des dizaines de milliers.
fn convolve_accumulate(output: &mut [f32], train: &[f32], hrtf: &[f32]) {
    for (i, &v) in train.iter().enumerate() {
        if v == 0.0 {
            continue;
        }
        for (j, &h) in hrtf.iter().enumerate() {
            let k = i + j;
            if k >= output.len() {
                break;
            }
            output[k] += v * h;
        }
    }
}

/// Filtre passe-bas a un pole, applique aux reflexions tardives pour simuler
/// l'absorption progressive des aigus par les parois et par l'air.
fn damp(signal: &mut [f32], coefficient: f32) {
    let mut state = 0.0f32;
    for e in signal.iter_mut() {
        state += coefficient * (*e - state);
        *e = state;
    }
}

/// Synthetise la BRIR d'une enceinte placee a l'azimut donne.
pub fn synthesize(
    sofa: &SofaSet,
    room: &Room,
    azimuth_deg: f32,
    elevation_deg: f32,
    duration_s: f32,
    seed: u64,
) -> Brir {
    let fs = sofa.sample_rate as f32;
    let n = (duration_s * fs) as usize;
    let lh = sofa.length;

    // L'auditeur est au centre de la piece, legerement en retrait du fond.
    let (lx, ly, lz) = (room.width, room.depth, room.height);
    let listener = [lx * 0.5, ly * 0.38, 1.2];

    // L'enceinte est placee sur le cercle d'ecoute, a l'azimut demande.
    let az = azimuth_deg.to_radians();
    let el = elevation_deg.to_radians();
    let source = [
        listener[0] - room.radius * el.cos() * az.sin(),
        listener[1] + room.radius * el.cos() * az.cos(),
        listener[2] + room.radius * el.sin(),
    ];

    let beta = (1.0 - room.absorption.clamp(0.0, 0.99)).sqrt();
    let mixing = room.mixing_time();

    // Les images sont regroupees par direction : convoluer une HRTF par image
    // couterait des milliers de convolutions pour un resultat identique, les
    // directions voisines partageant la meme reponse a l'oreille pres.
    const AZ_STEP: f32 = 15.0;
    const EL_STEP: f32 = 30.0;
    let mut buckets: std::collections::HashMap<(i32, i32), Vec<f32>> =
        std::collections::HashMap::new();

    let order = room.order.max(0);
    let mut late_energy = 0.0f32;

    for mx in -order..=order {
        for my in -order..=order {
            for mz in -order..=order {
                for px in 0..2 {
                    for py in 0..2 {
                        for pz in 0..2 {
                            // Comptage des reflexions par axe (Allen & Berkley).
                            let rx = (mx - px).abs() + mx.abs();
                            let ry = (my - py).abs() + my.abs();
                            let rz = (mz - pz).abs() + mz.abs();
                            let total = rx + ry + rz;
                            if total > order {
                                continue;
                            }

                            let ix = (1 - 2 * px) as f32 * source[0] + 2.0 * mx as f32 * lx;
                            let iy = (1 - 2 * py) as f32 * source[1] + 2.0 * my as f32 * ly;
                            let iz = (1 - 2 * pz) as f32 * source[2] + 2.0 * mz as f32 * lz;

                            let dx = ix - listener[0];
                            let dy = iy - listener[1];
                            let dz = iz - listener[2];
                            let dist = (dx * dx + dy * dy + dz * dz).sqrt().max(0.1);

                            let delay = dist / SPEED_OF_SOUND * fs;
                            if delay as usize + lh >= n {
                                continue;
                            }

                            // Attenuation : divergence spherique et absorption.
                            let mut gain = beta.powi(total) / dist;
                            if total == 0 {
                                gain *= 10f32.powf(room.direct_gain / 20.0);
                            }

                            // Au-dela du temps de melange, l'energie part dans la
                            // queue de synthese plutot que dans une image isolee.
                            if total > 0 && dist / SPEED_OF_SOUND > mixing {
                                late_energy += gain * gain;
                                continue;
                            }

                            // Direction vue de l'auditeur. Convention : x devant
                            // (+y de la piece), y a gauche (-x de la piece).
                            let az_i = (-dx).atan2(dy).to_degrees();
                            let el_i = (dz / dist).asin().to_degrees();
                            let key = (
                                (az_i / AZ_STEP).round() as i32,
                                (el_i / EL_STEP).round() as i32,
                            );
                            let train = buckets.entry(key).or_insert_with(|| vec![0.0; n]);
                            deposit(train, delay, gain);
                        }
                    }
                }
            }
        }
    }

    let mut l = vec![0.0f32; n];
    let mut r = vec![0.0f32; n];
    for ((kaz, kel), train) in &buckets {
        let hrtf = sofa.filter(*kaz as f32 * AZ_STEP, *kel as f32 * EL_STEP, room.radius);
        // Les retards renvoyes par libmysofa sont deja inclus dans la geometrie :
        // les reappliquer doublerait la difference interaurale.
        convolve_accumulate(&mut l, train, &hrtf.left);
        convolve_accumulate(&mut r, train, &hrtf.right);
    }

    // --- queue de reverberation ---------------------------------------------
    let rt60 = room.rt60();
    let tau = rt60 / 6.908; // decroissance de 60 dB
    let start = (mixing * fs) as usize;
    let mut rng = Rng::new(seed ^ ((azimuth_deg as i64 as u64) << 8));
    let mut tail_l = vec![0.0f32; n];
    let mut tail_r = vec![0.0f32; n];
    for i in start..n {
        let t = (i - start) as f32 / fs;
        let envelope = (-t / tau).exp();
        tail_l[i] = rng.next() * envelope;
        tail_r[i] = rng.next() * envelope;
    }
    damp(&mut tail_l, room.damping.clamp(0.02, 1.0));
    damp(&mut tail_r, room.damping.clamp(0.02, 1.0));

    // Calage du niveau de la queue sur l'energie que les images tardives
    // auraient portee : la transition doit etre inaudible.
    let tail_energy: f32 = tail_l.iter().map(|v| v * v).sum::<f32>().max(1e-20);
    let factor = (late_energy / tail_energy).sqrt();
    for i in 0..n {
        l[i] += tail_l[i] * factor;
        r[i] += tail_r[i] * factor;
    }

    Brir { left: l, right: r }
}
