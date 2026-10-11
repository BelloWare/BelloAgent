//! Swift 0.1.122's reply file links (`Files/ReplyFileResolver.swift`,
//! `MarkdownTextView.resolveFileLinks`): a code span in a reply that names a
//! file of the chat's project — `src/main.rs`, `src/main.rs:42`, an absolute
//! path inside the project — reads as a link, and a click opens the file in
//! a tab at that line. Only a regular file inside the project resolves, its
//! symbolic links followed first: nothing outside the project ever opens.
//! Each name is checked once per reply, off the main thread; a click checks
//! it again before opening.
use crate::AgentView;
use bello_agent_core::Controller;
use gpui::{App, Window};
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    rc::Rc,
    sync::Weak,
};

/// What a click opens: the file, and the line (from 1) a `:N` suffix named.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ReplyFileLocation {
    pub path: PathBuf,
    pub line: Option<usize>,
}

/// `ReplyFileResolver.resolve` for a project with one root, `root`.
pub(crate) fn resolve(text: &str, root: &Path) -> Option<ReplyFileLocation> {
    if text.is_empty()
        || text.len() > 4_096
        || text.contains('\n')
        || text.contains('\r')
        || text.contains("://")
    {
        return None;
    }
    let mut path = text;
    let mut line = None;
    if let Some((before, after)) = text.rsplit_once(':')
        && let Ok(number) = after.parse::<usize>()
        && number > 0
    {
        line = Some(number);
        path = before;
    }
    let expanded: PathBuf = match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => std::env::var_os("HOME")
            .map(PathBuf::from)?
            .join(rest.trim_start_matches('/')),
        _ => PathBuf::from(path),
    };
    let candidate = if expanded.is_absolute() {
        expanded
    } else {
        root.join(expanded)
    };
    let root = std::fs::canonicalize(root).ok()?;
    let resolved = std::fs::canonicalize(&candidate).ok()?;
    // Inside the project, never the project itself or past it.
    if resolved == root || !resolved.starts_with(&root) {
        return None;
    }
    std::fs::metadata(&resolved)
        .ok()
        .filter(|metadata| metadata.is_file())?;
    Some(ReplyFileLocation {
        path: resolved,
        line,
    })
}

/// A transcript's file links: which of each reply's code spans name a file,
/// and the ones still being checked.
#[derive(Default)]
pub(super) struct FileLinks {
    known: HashMap<(String, String), bool>,
    pending: HashSet<(String, String)>,
    /// Spans a frame drew that have not been checked yet.
    wanted: Vec<(String, String)>,
}

const LIMIT: usize = 4_096;

impl FileLinks {
    /// Whether `text`, a code span in `message`, names a project file;
    /// asks for it to be checked when it is not known yet.
    pub fn link(&mut self, message: &str, text: &str) -> bool {
        let key = (message.to_owned(), text.to_owned());
        match self.known.get(&key) {
            Some(known) => *known,
            None => {
                if !self.pending.contains(&key) && !self.wanted.contains(&key) {
                    self.wanted.push(key);
                }
                false
            }
        }
    }
}

/// The URL a file link carries; never opened as a web address.
pub(super) const SCHEME: &str = "bello-file:";

/// Checks what the last frame wanted checked, off the main thread, and
/// draws again once any of it names a file.
pub(super) fn check(
    links: &Rc<RefCell<FileLinks>>,
    parent: &gpui::WeakEntity<AgentView>,
    transcript: &gpui::WeakEntity<super::TranscriptView>,
    chat_id: &str,
    controller: &Weak<Controller>,
    cx: &mut App,
) {
    let wanted = {
        let mut links = links.borrow_mut();
        let wanted = std::mem::take(&mut links.wanted);
        if links.known.len() + wanted.len() > LIMIT {
            links.known.clear();
        }
        links.pending.extend(wanted.iter().cloned());
        wanted
    };
    if wanted.is_empty() {
        return;
    }
    let (links, parent, transcript) = (links.clone(), parent.clone(), transcript.clone());
    let (chat_id, controller) = (chat_id.to_owned(), controller.clone());
    cx.spawn(async move |cx| {
        let root = parent
            .read_with(cx, |view, _| {
                view.active_transcript_matches(&chat_id, &controller)
                    .then(|| view.project.clone())
            })
            .ok()
            .flatten();
        let names: Vec<String> = wanted.iter().map(|(_, text)| text.clone()).collect();
        let found = match root {
            Some(root) => {
                cx.background_executor()
                    .spawn(async move {
                        names
                            .iter()
                            .map(|text| resolve(text, &root).is_some())
                            .collect::<Vec<_>>()
                    })
                    .await
            }
            None => vec![false; wanted.len()],
        };
        let any = found.iter().any(|found| *found);
        {
            let mut links = links.borrow_mut();
            for (key, found) in wanted.into_iter().zip(found) {
                links.pending.remove(&key);
                links.known.insert(key, found);
            }
        }
        if any {
            let _ = transcript.update(cx, |_, cx| cx.notify());
        }
    })
    .detach();
}

/// Opens a file link's file by its name.
pub(super) type OpenFile = Rc<dyn Fn(&str, &mut Window, &mut App)>;

/// A click on a file link: the name is checked again, against the chat's
/// project as it is now, and the file opens in a tab at its line.
pub(super) fn opener(
    parent: &gpui::WeakEntity<AgentView>,
    chat_id: &str,
    controller: &Weak<Controller>,
) -> OpenFile {
    let (parent, chat_id, controller) = (parent.clone(), chat_id.to_owned(), controller.clone());
    Rc::new(move |text, window, cx| {
        let Some(root) = parent
            .read_with(cx, |view, _| {
                view.active_transcript_matches(&chat_id, &controller)
                    .then(|| view.project.clone())
            })
            .ok()
            .flatten()
        else {
            return;
        };
        let text = text.to_owned();
        let (parent, chat_id, controller) = (parent.clone(), chat_id.clone(), controller.clone());
        let handle = window.window_handle();
        cx.spawn(async move |cx| {
            let Some(target) = cx
                .background_executor()
                .spawn(async move { resolve(&text, &root) })
                .await
            else {
                return;
            };
            let _ = handle.update(cx, |_, window, cx| {
                let _ = parent.update(cx, |view, cx| {
                    if view.active_transcript_matches(&chat_id, &controller) {
                        view.open_file(target.path, target.line, window, cx);
                    }
                });
            });
        })
        .detach();
    })
}

#[cfg(test)]
mod tests {
    use super::{ReplyFileLocation, resolve};

    #[test]
    fn only_a_regular_file_inside_the_project_resolves() {
        let outside = tempfile::tempdir().unwrap();
        let project = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(project.path()).unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
        std::fs::write(root.join("name:with:colons"), "").unwrap();
        let secret = std::fs::canonicalize(outside.path())
            .unwrap()
            .join("secret.txt");
        std::fs::write(&secret, "x").unwrap();
        let file = |line| {
            Some(ReplyFileLocation {
                path: root.join("src/main.rs"),
                line,
            })
        };
        assert_eq!(resolve("src/main.rs", &root), file(None));
        assert_eq!(resolve("src/main.rs:42", &root), file(Some(42)));
        assert_eq!(resolve("./src/../src/main.rs", &root), file(None));
        assert_eq!(
            resolve(root.join("src/main.rs").to_str().unwrap(), &root),
            file(None)
        );
        // A colon that is no line number stays part of the name.
        assert_eq!(
            resolve("name:with:colons", &root).map(|found| found.line),
            Some(None)
        );
        assert_eq!(resolve("src/main.rs:0", &root), None);
        // Not files, not the project's, not paths at all.
        for text in [
            "src",
            ".",
            "",
            "missing.rs",
            "../outside.rs",
            "https://example.com/src/main.rs",
            "src/main.rs\nmore",
            secret.to_str().unwrap(),
        ] {
            assert_eq!(resolve(text, &root), None, "{text:?}");
        }
        assert_eq!(resolve(&"a".repeat(4_097), &root), None);
        // A link inside the project that leads out of it does not resolve.
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&secret, root.join("escape.txt")).unwrap();
            assert_eq!(resolve("escape.txt", &root), None);
            std::os::unix::fs::symlink(root.join("src/main.rs"), root.join("alias.rs")).unwrap();
            assert_eq!(resolve("alias.rs", &root), file(None));
        }
    }
}
