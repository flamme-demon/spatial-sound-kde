//! Liage minimal vers libmysofa, en C, pour lire un jeu HRTF au format SOFA.
//!
//! Seules quatre fonctions sont necessaires ; ecrire les declarations a la main
//! evite d'imposer bindgen et son lot de dependances de compilation.

use std::ffi::CString;
use std::os::raw::{c_char, c_float, c_int};

#[repr(C)]
struct MysofaEasy {
    _private: [u8; 0],
}

#[link(name = "mysofa")]
extern "C" {
    fn mysofa_open_cached(
        filename: *const c_char,
        samplerate: c_float,
        filterlength: *mut c_int,
        err: *mut c_int,
    ) -> *mut MysofaEasy;

    fn mysofa_getfilter_float(
        easy: *mut MysofaEasy,
        x: c_float,
        y: c_float,
        z: c_float,
        ir_left: *mut c_float,
        ir_right: *mut c_float,
        delay_left: *mut c_float,
        delay_right: *mut c_float,
    );

    fn mysofa_close_cached(easy: *mut MysofaEasy);
}

/// Une paire de reponses impulsionnelles pour une direction donnee, avec les
/// retards interauraux que libmysofa exprime separement de l'impulsion.
// Les retards sont exposes par completude : la geometrie de la salle porte deja
// la difference de temps interaurale, les reappliquer la doublerait.
#[allow(dead_code)]
pub struct Hrtf {
    pub left: Vec<f32>,
    pub right: Vec<f32>,
    /// Retards en echantillons, fractionnaires.
    pub delay_left: f32,
    pub delay_right: f32,
}

pub struct SofaSet {
    handle: *mut MysofaEasy,
    pub length: usize,
    pub sample_rate: u32,
}

impl SofaSet {
    pub fn open(path: &str, sample_rate: u32) -> Result<Self, String> {
        let c = CString::new(path).map_err(|_| "chemin invalide".to_string())?;
        let mut length: c_int = 0;
        let mut err: c_int = 0;
        // libmysofa reechantillonne lui-meme le jeu vers la frequence demandee :
        // un fichier en 44,1 kHz est donc utilisable tel quel.
        let handle = unsafe {
            mysofa_open_cached(c.as_ptr(), sample_rate as c_float, &mut length, &mut err)
        };
        if handle.is_null() {
            return Err(format!("lecture SOFA impossible (code {err}) : {path}"));
        }
        Ok(Self {
            handle,
            length: length as usize,
            sample_rate,
        })
    }

    /// Direction en coordonnees spheriques : azimut en degres (0 devant, 90 a
    /// gauche), elevation en degres, distance en metres.
    pub fn filter(&self, azimuth_deg: f32, elevation_deg: f32, distance_m: f32) -> Hrtf {
        let az = azimuth_deg.to_radians();
        let el = elevation_deg.to_radians();
        // Convention libmysofa : x devant, y a gauche, z en haut.
        let x = distance_m * el.cos() * az.cos();
        let y = distance_m * el.cos() * az.sin();
        let z = distance_m * el.sin();

        let mut l = vec![0.0f32; self.length];
        let mut r = vec![0.0f32; self.length];
        let (mut dl, mut dr) = (0.0f32, 0.0f32);
        unsafe {
            mysofa_getfilter_float(
                self.handle,
                x,
                y,
                z,
                l.as_mut_ptr(),
                r.as_mut_ptr(),
                &mut dl,
                &mut dr,
            );
        }
        Hrtf {
            left: l,
            right: r,
            delay_left: dl,
            delay_right: dr,
        }
    }
}

impl Drop for SofaSet {
    fn drop(&mut self) {
        unsafe { mysofa_close_cached(self.handle) }
    }
}
