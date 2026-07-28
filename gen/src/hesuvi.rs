//! Assemblage et ecriture au format HeSuVi : un WAV de 14 canaux, chacun portant
//! la reponse d'une enceinte virtuelle vers une oreille.
//!
//! L'ordre des canaux n'est pas symetrique et ne doit pas etre « corrige » : pour
//! les enceintes de gauche l'oreille gauche vient en premier, pour celles de droite
//! c'est l'oreille droite. C'est la convention du format, et c'est elle que lit la
//! configuration PipeWire du projet.

use std::fs::File;
use std::io::{BufWriter, Write};

/// Enceintes d'un 7.1, avec leur azimut en degres.
/// Convention : 0 devant, positif vers la gauche.
pub const ENCEINTES: [(&str, f32); 7] = [
    ("FL", 30.0),
    ("SL", 90.0),
    ("RL", 135.0),
    ("FC", 0.0),
    ("FR", -30.0),
    ("SR", -90.0),
    ("RR", -135.0),
];

/// Canal HeSuVi -> (indice d'enceinte, oreille) ; 0 = gauche, 1 = droite.
pub const PLAN: [(usize, usize); 14] = [
    (0, 0), // 0  FL -> G
    (0, 1), // 1  FL -> D
    (1, 0), // 2  SL -> G
    (1, 1), // 3  SL -> D
    (2, 0), // 4  RL -> G
    (2, 1), // 5  RL -> D
    (3, 0), // 6  FC -> G
    (4, 1), // 7  FR -> D
    (4, 0), // 8  FR -> G
    (5, 1), // 9  SR -> D
    (5, 0), // 10 SR -> G
    (6, 1), // 11 RR -> D
    (6, 0), // 12 RR -> G
    (3, 1), // 13 FC -> D
];

/// Ecrit un WAV PCM 16 bits entrelace.
pub fn ecrire(
    chemin: &str,
    canaux: &[Vec<f32>],
    frequence: u32,
) -> std::io::Result<()> {
    let nb = canaux.len() as u16;
    let n = canaux.iter().map(|c| c.len()).max().unwrap_or(0);

    // Normalisation par l'ENERGIE, pas par la crete.
    //
    // Une reponse de salle porte une longue queue : a crete egale, son energie
    // totale depasse largement celle d'une capture seche. Or c'est l'energie qui
    // fixe le gain applique par la convolution. Normaliser sur la crete produisait
    // un fichier saturant la chaine en sortie — mesure a 0,00 dBFS — et la
    // saturation ecrasait les differences entre oreilles, donc la localisation.
    //
    // On vise donc le gain de convolution des profils de reference (environ -2 dB),
    // puis on borne la crete par securite.
    const GAIN_VISE: f32 = 0.80; // -1,9 dB en puissance
    let energie_max = canaux
        .iter()
        .map(|c| c.iter().map(|v| v * v).sum::<f32>())
        .fold(0.0f32, f32::max);
    let mut gain = if energie_max > 0.0 {
        GAIN_VISE / energie_max.sqrt()
    } else {
        1.0
    };
    let crete = canaux
        .iter()
        .flat_map(|c| c.iter())
        .fold(0.0f32, |m, v| m.max(v.abs()));
    if crete * gain > 0.95 {
        gain = 0.95 / crete;
    }

    let octets_donnees = (n * nb as usize * 2) as u32;
    let mut f = BufWriter::new(File::create(chemin)?);

    f.write_all(b"RIFF")?;
    f.write_all(&(36 + octets_donnees).to_le_bytes())?;
    f.write_all(b"WAVEfmt ")?;
    f.write_all(&16u32.to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?; // PCM
    f.write_all(&nb.to_le_bytes())?;
    f.write_all(&frequence.to_le_bytes())?;
    f.write_all(&(frequence * nb as u32 * 2).to_le_bytes())?;
    f.write_all(&(nb * 2).to_le_bytes())?;
    f.write_all(&16u16.to_le_bytes())?;
    f.write_all(b"data")?;
    f.write_all(&octets_donnees.to_le_bytes())?;

    for i in 0..n {
        for c in canaux {
            let v = c.get(i).copied().unwrap_or(0.0) * gain;
            let e = (v.clamp(-1.0, 1.0) * 32767.0).round() as i16;
            f.write_all(&e.to_le_bytes())?;
        }
    }
    f.flush()
}
