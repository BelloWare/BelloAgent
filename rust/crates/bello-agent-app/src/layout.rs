//! Geometry copied from WindowPresentation.swift and WorkspaceView.SplitPane.
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Write,
    path::PathBuf,
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

/// TranscriptRows.swift: 840pt page, 48pt gutter, 40pt leading user space,
/// and a 640pt prose cap. Plain user text fills that proposed width; leaving
/// it intrinsic lets GPUI's percentage child collapse to a single glyph.
pub(crate) fn user_bubble_width(pane: f32) -> f32 {
    let pane = if pane.is_finite() { pane } else { 0. };
    ((pane - 48.).clamp(0., 840.) - 40.).clamp(1., 640.)
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct Layout {
    pub sidebar: f32,
    pub fraction: f32,
}
impl Default for Layout {
    fn default() -> Self {
        Self {
            sidebar: 300.,
            fraction: 0.5,
        }
    }
}
impl Layout {
    pub fn clamped(mut self) -> Self {
        self.sidebar = if self.sidebar.is_finite() {
            self.sidebar.clamp(200., 420.)
        } else {
            300.
        };
        self.fraction = if self.fraction.is_finite() {
            self.fraction.clamp(0.30, 0.70)
        } else {
            0.5
        };
        self
    }
    pub fn panes(self, width: f32) -> (f32, f32) {
        let usable = (width - self.clamped().sidebar - 1.).max(0.);
        let main = (usable * self.clamped().fraction).floor();
        (main, usable - main)
    }
}
pub struct LayoutStore {
    path: PathBuf,
    latest: AtomicU64,
    write: Mutex<()>,
}
impl LayoutStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            latest: AtomicU64::new(0),
            write: Mutex::new(()),
        }
    }
    pub fn load(&self) -> Layout {
        fs::read(&self.path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Layout>(&bytes).ok())
            .unwrap_or_default()
            .clamped()
    }
    pub fn reserve(&self) -> u64 {
        self.latest.fetch_add(1, Ordering::AcqRel) + 1
    }
    pub fn save(&self, revision: u64, layout: Layout) -> std::io::Result<bool> {
        let _guard = self
            .write
            .lock()
            .map_err(|_| std::io::Error::other("Layout storage lock failed"))?;
        if self.latest.load(Ordering::Acquire) != revision {
            return Ok(false);
        }
        let parent = self
            .path
            .parent()
            .ok_or_else(|| std::io::Error::other("Layout storage has no parent"))?;
        fs::create_dir_all(parent)?;
        let tmp = parent.join(format!(".layout-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&tmp)?;
            file.write_all(&serde_json::to_vec(&layout.clamped())?)?;
            file.sync_all()?;
            fs::rename(&tmp, &self.path)?;
            Ok(true)
        })();
        if result.is_err() {
            let _ = fs::remove_file(tmp);
        }
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn user_bubble_has_a_finite_source_width_at_normal_and_minimum_sizes() {
        assert_eq!(user_bubble_width(979.), 640.);
        assert_eq!(user_bubble_width(619.), 531.);
        // Minimum-size half pane and supported 30% split retain usable width.
        assert_eq!(user_bubble_width(309.), 221.);
        assert_eq!(user_bubble_width(185.), 97.);
        let narrowest = Layout {
            sidebar: 420.,
            fraction: 0.3,
        }
        .panes(920.)
        .0;
        assert_eq!(user_bubble_width(narrowest), 61.);
        assert_eq!(user_bubble_width(0.), 1.);
        assert_eq!(user_bubble_width(f32::NAN), 1.);
        // Short and multiline text use the same source width, not min-content.
        for pane in [979., 619., 309., 185.] {
            let width = user_bubble_width(pane);
            assert!(width > 28.); // Source horizontal padding cannot consume it.
            assert!(width <= 640.);
            assert!(width + 40. <= (pane - 48.).min(840.));
        }
    }
    #[test]
    fn source_geometry_and_bounds() {
        assert_eq!(Layout::default().panes(1280.), (489., 490.));
        assert_eq!(
            Layout {
                sidebar: 100.,
                fraction: 0.9
            }
            .clamped()
            .sidebar,
            200.
        );
        assert_eq!(
            Layout {
                sidebar: 500.,
                fraction: 0.1
            }
            .clamped()
            .fraction,
            0.3
        );
        assert_eq!(Layout::default().panes(920.), (309., 310.));
    }
    #[test]
    fn stale_drag_save_cannot_overwrite_newer() {
        let path = std::env::temp_dir().join(format!("bello-layout-{}.json", uuid::Uuid::new_v4()));
        let store = LayoutStore::new(path.clone());
        let old = store.reserve();
        let new = store.reserve();
        assert!(
            store
                .save(
                    new,
                    Layout {
                        sidebar: 360.,
                        fraction: 0.6
                    }
                )
                .unwrap()
        );
        assert!(!store.save(old, Layout::default()).unwrap());
        assert_eq!(store.load().sidebar, 360.);
        fs::remove_file(path).unwrap();
    }
}
