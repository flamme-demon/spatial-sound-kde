//! Liage minimal vers libmysofa, en C, pour lire un jeu HRTF au format SOFA.
//!
//! Seules quatre fonctions sont necessaires ; ecrire les declarations a la main
//! evite d'imposer bindgen et son lot de dependances de compilation.

use std::ffi::CString;
use std::os::raw::{c_char, c_float, c_int};

#[repr(C)]
struct MysofaEasy {
    _prive: [u8; 0],
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
        ir_gauche: *mut c_float,
        ir_droite: *mut c_float,
        retard_gauche: *mut c_float,
        retard_droite: *mut c_float,
    );

    fn mysofa_close_cached(easy: *mut MysofaEasy);
}

/// Une paire de reponses impulsionnelles pour une direction donnee, avec les
/// retards interauraux que libmysofa exprime separement de l'impulsion.
// Les retards sont exposes par completude : la geometrie de la salle porte deja
// la difference de temps interaurale, les reappliquer la doublerait.
#[allow(dead_code)]
pub struct Hrtf {
    pub gauche: Vec<f32>,
    pub droite: Vec<f32>,
    /// Retards en echantillons, fractionnaires.
    pub retard_gauche: f32,
    pub retard_droite: f32,
}

pub struct JeuSofa {
    poignee: *mut MysofaEasy,
    pub longueur: usize,
    pub frequence: u32,
}

impl JeuSofa {
    pub fn ouvrir(chemin: &str, frequence: u32) -> Result<Self, String> {
        let c = CString::new(chemin).map_err(|_| "chemin invalide".to_string())?;
        let mut longueur: c_int = 0;
        let mut err: c_int = 0;
        // libmysofa reechantillonne lui-meme le jeu vers la frequence demandee :
        // un fichier en 44,1 kHz est donc utilisable tel quel.
        let poignee = unsafe {
            mysofa_open_cached(c.as_ptr(), frequence as c_float, &mut longueur, &mut err)
        };
        if poignee.is_null() {
            return Err(format!("lecture SOFA impossible (code {err}) : {chemin}"));
        }
        Ok(Self {
            poignee,
            longueur: longueur as usize,
            frequence,
        })
    }

    /// Direction en coordonnees spheriques : azimut en degres (0 devant, 90 a
    /// gauche), elevation en degres, distance en metres.
    pub fn filtre(&self, azimut_deg: f32, elevation_deg: f32, distance_m: f32) -> Hrtf {
        let az = azimut_deg.to_radians();
        let el = elevation_deg.to_radians();
        // Convention libmysofa : x devant, y a gauche, z en haut.
        let x = distance_m * el.cos() * az.cos();
        let y = distance_m * el.cos() * az.sin();
        let z = distance_m * el.sin();

        let mut g = vec![0.0f32; self.longueur];
        let mut d = vec![0.0f32; self.longueur];
        let (mut rg, mut rd) = (0.0f32, 0.0f32);
        unsafe {
            mysofa_getfilter_float(
                self.poignee,
                x,
                y,
                z,
                g.as_mut_ptr(),
                d.as_mut_ptr(),
                &mut rg,
                &mut rd,
            );
        }
        Hrtf {
            gauche: g,
            droite: d,
            retard_gauche: rg,
            retard_droite: rd,
        }
    }
}

impl Drop for JeuSofa {
    fn drop(&mut self) {
        unsafe { mysofa_close_cached(self.poignee) }
    }
}
