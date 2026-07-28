//! spatial-sound-gen — synthetise une salle d'ecoute virtuelle au format HeSuVi.
//!
//! Le fichier produit se depose dans ~/.local/share/pipewire/hrir_hesuvi/ et
//! devient un profil comme les autres.
//!
//! Ecrit d'apres les algorithmes publies (methode des sources images d'Allen &
//! Berkley, 1979 ; formule de Sabine pour la duree de reverberation), sans
//! reprendre de code existant.

mod hesuvi;
mod lecture;
mod salle;
mod sofa;

use salle::Salle;

const FREQUENCE: u32 = 48_000;

/// Raccourcit la queue de reverberation d'un profil existant, sans toucher au
/// fichier d'origine.
///
/// On ne peut que RACCOURCIR : allonger demanderait de fabriquer de la
/// reverberation absente du materiau, ce qui est le travail du mode synthese.
///
/// La decroissance supplementaire demarre a la crete du son direct, reperee
/// canal par canal : l'appliquer depuis l'echantillon zero attenuerait aussi
/// le son direct, donc le niveau general, sans rien changer au rapport
/// direct/reverbere qui est justement ce qu'on veut regler.
fn appliquer_enveloppe(source: &str, sortie: &str, tau_ms: f32) -> Result<(), String> {
    let w = lecture::lire(source)?;
    let fe = w.frequence as f32;
    let tau = (tau_ms / 1000.0).max(0.001);

    let canaux: Vec<Vec<f32>> = w
        .canaux
        .iter()
        .map(|c| {
            let crete = c
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.abs().partial_cmp(&b.1.abs()).unwrap())
                .map(|(i, _)| i)
                .unwrap_or(0);
            c.iter()
                .enumerate()
                .map(|(i, v)| {
                    if i <= crete {
                        *v
                    } else {
                        *v * (-((i - crete) as f32) / fe / tau).exp()
                    }
                })
                .collect()
        })
        .collect();

    // Pas de renormalisation : le son direct doit garder son niveau, seule la
    // queue est raccourcie.
    hesuvi::ecrire(sortie, &canaux, w.frequence, false).map_err(|e| format!("ecriture : {e}"))
}

fn aide() {
    eprintln!(
        r#"Usage : spatial-sound-gen --sofa <fichier.sofa> --sortie <fichier.wav> [options]
        spatial-sound-gen --source <profil.wav> --enveloppe <ms> --sortie <f.wav>

Mode enveloppe : raccourcit la queue d'un profil existant sans le modifier.
  --source <f>        profil HeSuVi 14 canaux a retravailler
  --enveloppe <ms>    constante de decroissance ; plus c'est petit, plus c'est sec

  --sofa <f>          jeu HRTF au format SOFA (obligatoire)
  --sortie <f>        WAV HeSuVi 14 canaux a produire (obligatoire)
  --preset <nom>      cabine | studio | regie | salon   (defaut studio)
                      Les options ci-dessous priment sur le preset.

Geometrie de la piece
  --largeur <m>       defaut 4.2
  --profondeur <m>    defaut 5.0
  --hauteur <m>       defaut 2.6
  --rayon <m>         distance auditeur-enceinte, defaut 1.8

Acoustique
  --absorption <0-1>  absorption moyenne des parois, defaut 0.60
                      0.30 = piece vivante, 0.72 = fortement traitee
  --amortissement <0-1>  perte d'aigus a chaque reflexion, defaut 0.35
  --gain-direct <dB>  rapproche (+) ou eloigne (-) la scene, defaut 0
  --ordre <n>         ordre des reflexions calculees, defaut 3

Divers
  --duree <s>         longueur de la reponse, defaut 0.35
  --graine <n>        rend la queue reproductible, defaut 1

Mesure le resultat avant de l'adopter :
  python3 tools/analyse_hrir.py"#
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        aide();
        std::process::exit(if args.is_empty() { 1 } else { 0 });
    }

    let mut chemin_sofa = String::new();
    let mut source = String::new();
    let mut enveloppe = 0.0f32;
    let mut sortie = String::new();
    let mut s = Salle::default();
    let mut duree = 0.35f32;
    let mut graine = 1u64;

    // Le preset est lu d'abord : les options explicites doivent pouvoir l'ajuster.
    if let Some(k) = args.iter().position(|a| a == "--preset") {
        match args.get(k + 1).and_then(|n| Salle::preset(n)) {
            Some(p) => s = p,
            None => {
                eprintln!("preset inconnu : cabine | studio | regie | salon");
                std::process::exit(1);
            }
        }
    }

    let mut i = 0;
    while i < args.len() {
        let val = |i: usize| -> String {
            args.get(i + 1).cloned().unwrap_or_else(|| {
                eprintln!("valeur manquante apres {}", args[i]);
                std::process::exit(1);
            })
        };
        let nombre = |i: usize| -> f32 {
            val(i).parse().unwrap_or_else(|_| {
                eprintln!("valeur numerique attendue apres {}", args[i]);
                std::process::exit(1);
            })
        };
        match args[i].as_str() {
            "--sofa" => chemin_sofa = val(i),
            "--source" => source = val(i),
            "--enveloppe" => enveloppe = nombre(i),
            "--sortie" => sortie = val(i),
            "--largeur" => s.largeur = nombre(i),
            "--profondeur" => s.profondeur = nombre(i),
            "--hauteur" => s.hauteur = nombre(i),
            "--rayon" => s.rayon = nombre(i),
            "--absorption" => s.absorption = nombre(i),
            "--amortissement" => s.amortissement = nombre(i),
            "--gain-direct" => s.gain_direct = nombre(i),
            "--ordre" => s.ordre = nombre(i) as i32,
            "--duree" => duree = nombre(i),
            "--graine" => graine = nombre(i) as u64,
            "--preset" => {} // deja traite
            autre => {
                eprintln!("option inconnue : {autre}");
                std::process::exit(1);
            }
        }
        i += 2;
    }

    // Mode enveloppe : independant de la synthese, il ne demande pas de SOFA.
    if !source.is_empty() {
        if sortie.is_empty() || enveloppe <= 0.0 {
            eprintln!("--source exige --sortie et --enveloppe <ms>.");
            std::process::exit(1);
        }
        match appliquer_enveloppe(&source, &sortie, enveloppe) {
            Ok(()) => {
                eprintln!("Enveloppe {enveloppe:.0} ms appliquee : {sortie}");
                return;
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
    }

    if chemin_sofa.is_empty() || sortie.is_empty() {
        eprintln!("--sofa et --sortie sont obligatoires.\n");
        aide();
        std::process::exit(1);
    }

    let jeu = match sofa::JeuSofa::ouvrir(&chemin_sofa, FREQUENCE) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };

    eprintln!(
        "HRTF : {} points par reponse, {} Hz",
        jeu.longueur, jeu.frequence
    );
    eprintln!(
        "Salle : {:.1} x {:.1} x {:.1} m, absorption {:.2}, RT60 {:.2} s",
        s.largeur,
        s.profondeur,
        s.hauteur,
        s.absorption,
        s.rt60()
    );

    // Une BRIR par enceinte, puis repartition dans les 14 canaux HeSuVi.
    let brirs: Vec<salle::Brir> = hesuvi::ENCEINTES
        .iter()
        .map(|(nom, azimut)| {
            eprintln!("  {nom:<3} azimut {azimut:>7.1} deg");
            salle::synthetiser(&jeu, &s, *azimut, 0.0, duree, graine)
        })
        .collect();

    let canaux: Vec<Vec<f32>> = hesuvi::PLAN
        .iter()
        .map(|(enceinte, oreille)| {
            let b = &brirs[*enceinte];
            if *oreille == 0 {
                b.gauche.clone()
            } else {
                b.droite.clone()
            }
        })
        .collect();

    match hesuvi::ecrire(&sortie, &canaux, FREQUENCE, true) {
        Ok(()) => eprintln!(
            "\nEcrit : {sortie}\n{} canaux, {:.0} ms",
            canaux.len(),
            duree * 1000.0
        ),
        Err(e) => {
            eprintln!("ecriture impossible : {e}");
            std::process::exit(1);
        }
    }
}
