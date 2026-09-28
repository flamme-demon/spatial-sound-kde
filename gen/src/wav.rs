//! Lecture d'un WAV multicanal.
//!
//! Les profils HeSuVi livres sont en float32, ceux que ce programme ecrit en
//! PCM 16 bits : les deux doivent etre acceptes, sans quoi l'enveloppe ne
//! s'appliquerait qu'a nos propres fichiers.

use std::fs;

pub struct Wav {
    pub channels: Vec<Vec<f32>>,
    pub sample_rate: u32,
}

fn u16le(o: &[u8], i: usize) -> u16 {
    u16::from_le_bytes([o[i], o[i + 1]])
}
fn u32le(o: &[u8], i: usize) -> u32 {
    u32::from_le_bytes([o[i], o[i + 1], o[i + 2], o[i + 3]])
}

pub fn read(path: &str) -> Result<Wav, String> {
    let o = fs::read(path).map_err(|e| format!("lecture impossible : {e}"))?;
    if o.len() < 12 || &o[0..4] != b"RIFF" || &o[8..12] != b"WAVE" {
        return Err(format!("{path} n'est pas un WAV"));
    }

    let (mut format, mut nb, mut sample_rate, mut bits) = (0u16, 0u16, 0u32, 0u16);
    let mut data: Option<(usize, usize)> = None;

    // Parcours des blocs : un WAV peut contenir des blocs annexes (LIST, fact)
    // qu'il faut enjamber plutot que supposer data juste apres fmt.
    let mut p = 12usize;
    while p + 8 <= o.len() {
        let id = &o[p..p + 4];
        let size = u32le(&o, p + 4) as usize;
        let body = p + 8;
        if body + size > o.len() {
            break;
        }
        match id {
            b"fmt " if size >= 16 => {
                format = u16le(&o, body);
                nb = u16le(&o, body + 2);
                sample_rate = u32le(&o, body + 4);
                bits = u16le(&o, body + 14);
                // WAVE_FORMAT_EXTENSIBLE : le vrai format est dans le sous-type.
                if format == 0xFFFE && size >= 40 {
                    format = u16le(&o, body + 24);
                }
            }
            b"data" => data = Some((body, size)),
            _ => {}
        }
        p = body + size + (size & 1); // les blocs sont alignes sur 2 octets
    }

    let (start, size) = data.ok_or_else(|| format!("{path} : bloc data absent"))?;
    if nb == 0 {
        return Err(format!("{path} : nombre de canaux nul"));
    }

    let bytes = (bits / 8) as usize;
    let frames = size / (bytes * nb as usize);
    let mut channels = vec![vec![0.0f32; frames]; nb as usize];

    for t in 0..frames {
        for c in 0..nb as usize {
            let i = start + (t * nb as usize + c) * bytes;
            channels[c][t] = match (format, bits) {
                (1, 16) => i16::from_le_bytes([o[i], o[i + 1]]) as f32 / 32768.0,
                (1, 24) => {
                    let v = ((o[i + 2] as i32) << 24 | (o[i + 1] as i32) << 16 | (o[i] as i32) << 8)
                        >> 8;
                    v as f32 / 8_388_608.0
                }
                (1, 32) => i32::from_le_bytes([o[i], o[i + 1], o[i + 2], o[i + 3]]) as f32
                    / 2_147_483_648.0,
                (3, 32) => f32::from_le_bytes([o[i], o[i + 1], o[i + 2], o[i + 3]]),
                _ => {
                    return Err(format!(
                        "{path} : format non gere (code {format}, {bits} bits)"
                    ))
                }
            };
        }
    }

    Ok(Wav {
        channels,
        sample_rate,
    })
}
