//! spatial-sound-gen — synthetise une salle d'ecoute virtuelle au format HeSuVi.
//!
//! Le fichier produit se depose dans ~/.local/share/pipewire/hrir_hesuvi/ et
//! devient un profil comme les autres.
//!
//! Ecrit d'apres les algorithmes publies (methode des sources images d'Allen &
//! Berkley, 1979 ; formule de Sabine pour la duree de reverberation), sans
//! reprendre de code existant.

mod hesuvi;
mod room;
mod sofa;
mod wav;

use room::Room;

const SAMPLE_RATE: u32 = 48_000;

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
fn apply_envelope(source: &str, output: &str, tau_ms: f32) -> Result<(), String> {
    let w = wav::read(source)?;
    let fs = w.sample_rate as f32;
    let tau = (tau_ms / 1000.0).max(0.001);

    let channels: Vec<Vec<f32>> = w
        .channels
        .iter()
        .map(|c| {
            let peak = c
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.abs().partial_cmp(&b.1.abs()).unwrap())
                .map(|(i, _)| i)
                .unwrap_or(0);
            c.iter()
                .enumerate()
                .map(|(i, v)| {
                    if i <= peak {
                        *v
                    } else {
                        *v * (-((i - peak) as f32) / fs / tau).exp()
                    }
                })
                .collect()
        })
        .collect();

    // Pas de renormalisation : le son direct doit garder son niveau, seule la
    // queue est raccourcie.
    hesuvi::write(output, &channels, w.sample_rate, false).map_err(|e| format!("ecriture : {e}"))
}

fn help() {
    eprintln!(
        r#"Usage : spatial-sound-gen --sofa <fichier.sofa> --output <fichier.wav> [options]
        spatial-sound-gen --source <profil.wav> --envelope <ms> --output <f.wav>

Mode enveloppe : raccourcit la queue d'un profil existant sans le modifier.
  --source <f>        profil HeSuVi 14 canaux a retravailler
  --envelope <ms>     constante de decroissance ; plus c'est petit, plus c'est sec

  --sofa <f>          jeu HRTF au format SOFA (obligatoire)
  --output <f>        WAV HeSuVi 14 canaux a produire (obligatoire)
  --preset <nom>      booth | studio | control-room | living-room   (defaut studio)
                      Les options ci-dessous priment sur le preset.

Geometrie de la piece
  --width <m>         defaut 4.2
  --depth <m>         defaut 5.0
  --height <m>        defaut 2.6
  --radius <m>        distance auditeur-enceinte, defaut 1.8

Acoustique
  --absorption <0-1>  absorption moyenne des parois, defaut 0.60
                      0.30 = piece vivante, 0.72 = fortement traitee
  --damping <0-1>     perte d'aigus a chaque reflexion, defaut 0.35
  --direct-gain <dB>  rapproche (+) ou eloigne (-) la scene, defaut 0
  --order <n>         ordre des reflexions calculees, defaut 3

Divers
  --duration <s>      longueur de la reponse, defaut 0.35
  --seed <n>          rend la queue reproductible, defaut 1

Les noms francais d'avant la 1.1 (--sortie, --largeur, cabine...) restent acceptes.

Mesure le resultat avant de l'adopter :
  python3 tools/analyse_hrir.py"#
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        help();
        std::process::exit(if args.is_empty() { 1 } else { 0 });
    }

    let mut sofa_path = String::new();
    let mut source = String::new();
    let mut envelope = 0.0f32;
    let mut output = String::new();
    let mut r = Room::default();
    let mut duration = 0.35f32;
    let mut seed = 1u64;

    // Le preset est lu d'abord : les options explicites doivent pouvoir l'ajuster.
    if let Some(k) = args.iter().position(|a| a == "--preset") {
        match args.get(k + 1).and_then(|n| Room::preset(n)) {
            Some(p) => r = p,
            None => {
                eprintln!("preset inconnu : booth | studio | control-room | living-room");
                std::process::exit(1);
            }
        }
    }

    // Chaque option garde son ancien nom francais en alias.
    let mut i = 0;
    while i < args.len() {
        let val = |i: usize| -> String {
            args.get(i + 1).cloned().unwrap_or_else(|| {
                eprintln!("valeur manquante apres {}", args[i]);
                std::process::exit(1);
            })
        };
        let number = |i: usize| -> f32 {
            val(i).parse().unwrap_or_else(|_| {
                eprintln!("valeur numerique attendue apres {}", args[i]);
                std::process::exit(1);
            })
        };
        match args[i].as_str() {
            "--sofa" => sofa_path = val(i),
            "--source" => source = val(i),
            "--envelope" | "--enveloppe" => envelope = number(i),
            "--output" | "--sortie" => output = val(i),
            "--width" | "--largeur" => r.width = number(i),
            "--depth" | "--profondeur" => r.depth = number(i),
            "--height" | "--hauteur" => r.height = number(i),
            "--radius" | "--rayon" => r.radius = number(i),
            "--absorption" => r.absorption = number(i),
            "--damping" | "--amortissement" => r.damping = number(i),
            "--direct-gain" | "--gain-direct" => r.direct_gain = number(i),
            "--order" | "--ordre" => r.order = number(i) as i32,
            "--duration" | "--duree" => duration = number(i),
            "--seed" | "--graine" => seed = number(i) as u64,
            "--preset" => {} // deja traite
            other => {
                eprintln!("option inconnue : {other}");
                std::process::exit(1);
            }
        }
        i += 2;
    }

    // Mode enveloppe : independant de la synthese, il ne demande pas de SOFA.
    if !source.is_empty() {
        if output.is_empty() || envelope <= 0.0 {
            eprintln!("--source exige --output et --envelope <ms>.");
            std::process::exit(1);
        }
        match apply_envelope(&source, &output, envelope) {
            Ok(()) => {
                eprintln!("Enveloppe {envelope:.0} ms appliquee : {output}");
                return;
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
    }

    if sofa_path.is_empty() || output.is_empty() {
        eprintln!("--sofa et --output sont obligatoires.\n");
        help();
        std::process::exit(1);
    }

    let set = match sofa::SofaSet::open(&sofa_path, SAMPLE_RATE) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };

    eprintln!(
        "HRTF : {} points par reponse, {} Hz",
        set.length, set.sample_rate
    );
    eprintln!(
        "Salle : {:.1} x {:.1} x {:.1} m, absorption {:.2}, RT60 {:.2} s",
        r.width,
        r.depth,
        r.height,
        r.absorption,
        r.rt60()
    );

    // Une BRIR par enceinte, puis repartition dans les 14 canaux HeSuVi.
    let brirs: Vec<room::Brir> = hesuvi::SPEAKERS
        .iter()
        .map(|(name, azimuth)| {
            eprintln!("  {name:<3} azimut {azimuth:>7.1} deg");
            room::synthesize(&set, &r, *azimuth, 0.0, duration, seed)
        })
        .collect();

    let channels: Vec<Vec<f32>> = hesuvi::LAYOUT
        .iter()
        .map(|(speaker, ear)| {
            let b = &brirs[*speaker];
            if *ear == 0 {
                b.left.clone()
            } else {
                b.right.clone()
            }
        })
        .collect();

    match hesuvi::write(&output, &channels, SAMPLE_RATE, true) {
        Ok(()) => eprintln!(
            "\nEcrit : {output}\n{} canaux, {:.0} ms",
            channels.len(),
            duration * 1000.0
        ),
        Err(e) => {
            eprintln!("ecriture impossible : {e}");
            std::process::exit(1);
        }
    }
}
