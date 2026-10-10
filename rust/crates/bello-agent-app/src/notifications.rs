//! Swift WorkspaceReadState.swift / CompletionSound.swift policy. Native effects
//! stay on GPUI's foreground thread; tests never touch AppKit or an audio device.
use bello_agent_core::{
    Controller, read_observation::AcceptedReadObservation, workspace::ChatRecord,
    workspace_read_state::ChatReadState,
};
use gpui::{Context, Global, Task};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

pub(crate) fn dock_badge<'a>(
    chats: impl IntoIterator<Item = (&'a ChatRecord, Option<ChatReadState>)>,
) -> Option<String> {
    let count = chats
        .into_iter()
        .filter(|(record, state)| {
            state
                .as_ref()
                .is_some_and(|s| s.dock_chat(record.archived_at.is_some()))
        })
        .count();
    (count > 0).then(|| count.to_string())
}

#[derive(Default)]
struct CompletionTracker {
    last: Option<(String, u64)>,
}
impl CompletionTracker {
    fn observe(&mut self, observation: &AcceptedReadObservation, baseline: bool) -> bool {
        let completed = !baseline
            && self.last.as_ref().is_some_and(|(generation, sequence)| {
                generation == &observation.generation
                    && observation.completed_task_sequence > *sequence
            });
        // Consume even while muted/archived: enabling sound must never replay it.
        self.last = Some((
            observation.generation.clone(),
            observation.completed_task_sequence,
        ));
        completed
    }
}
#[derive(Default)]
struct SoundExclusions {
    archived: bool,
    background_task: bool,
    connection_test: bool,
    imported: bool,
    shut_down: bool,
}
fn completion_cue(completed: bool, enabled: bool, exclusions: SoundExclusions) -> bool {
    completed
        && enabled
        && !exclusions.archived
        && !exclusions.background_task
        && !exclusions.connection_test
        && !exclusions.imported
        && !exclusions.shut_down
}
fn playback_allowed(now: Duration, last: Option<Duration>, playing: bool, testing: bool) -> bool {
    !testing
        && !playing
        && last.is_none_or(|last| {
            now.checked_sub(last)
                .is_some_and(|d| d >= Duration::from_secs(1))
        })
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Preferences {
    completion_sound_enabled: Option<bool>,
}
impl Preferences {
    fn enabled(&self) -> bool {
        self.completion_sound_enabled.unwrap_or(true)
    }
}

pub(crate) struct Notifications {
    preferences: Preferences,
    path: Option<PathBuf>,
    badge: Option<Option<String>>,
    clock: Instant,
    last_played: Option<Duration>,
    #[cfg(all(target_os = "macos", not(test)))]
    sound: native::Sound,
}
impl Global for Notifications {}
impl Notifications {
    pub(crate) fn new(path: Option<PathBuf>) -> Self {
        let preferences = path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            preferences,
            path,
            badge: None,
            clock: Instant::now(),
            last_played: None,
            #[cfg(all(target_os = "macos", not(test)))]
            sound: native::Sound::default(),
        }
    }
    pub(crate) fn enabled(&self) -> bool {
        self.preferences.enabled()
    }
    pub(crate) fn set_enabled(&mut self, enabled: bool) -> std::io::Result<()> {
        let next = Preferences {
            completion_sound_enabled: Some(enabled),
        };
        // Only an explicit Settings action writes the Rust-owned file. A failed
        // write leaves the effective preference unchanged and is shown in UI.
        if let Some(path) = &self.path {
            let parent = path
                .parent()
                .ok_or_else(|| std::io::Error::other("Settings have no parent"))?;
            std::fs::create_dir_all(parent)?;
            let temp = parent.join(format!(".notifications-{}.tmp", uuid::Uuid::new_v4()));
            let result = (|| {
                use std::io::Write;
                let mut file = std::fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&temp)?;
                file.write_all(&serde_json::to_vec(&next)?)?;
                file.sync_all()?;
                std::fs::rename(&temp, path)
            })();
            if result.is_err() {
                let _ = std::fs::remove_file(&temp);
            }
            result?;
        }
        self.preferences = next;
        Ok(())
    }
    pub(crate) fn badge(&mut self, label: Option<String>) {
        if self.badge.as_ref() == Some(&label) {
            return;
        }
        #[cfg(all(target_os = "macos", not(test)))]
        native::badge(label.as_deref());
        self.badge = Some(label);
    }
    pub(crate) fn play(&mut self) -> bool {
        let now = self.clock.elapsed();
        #[cfg(all(target_os = "macos", not(test)))]
        let (playing, testing) = (self.sound.playing(), native::testing());
        #[cfg(any(not(target_os = "macos"), test))]
        let (playing, testing) = (false, true);
        if !playback_allowed(now, self.last_played, playing, testing) {
            return false;
        }
        #[cfg(all(target_os = "macos", not(test)))]
        let played = self.sound.play();
        #[cfg(any(not(target_os = "macos"), test))]
        let played = false;
        if played {
            self.last_played = Some(now);
        }
        played
    }
}

pub(crate) fn subscribe(
    controller: &Arc<Controller>,
    record: &ChatRecord,
    workspace: Arc<Mutex<bello_agent_core::workspace::WorkspaceStore>>,
    cx: &mut Context<crate::AgentView>,
) -> Task<()> {
    let mut updates = controller.subscribe_read_observation();
    let mut tracker = CompletionTracker::default();
    tracker.observe(&updates.borrow_and_update(), true);
    let source = Arc::downgrade(controller);
    let id = record.id.clone();
    let path = record.snapshot.clone();
    cx.spawn(async move |owner, cx| {
        while updates.changed().await.is_ok() {
            let completed = tracker.observe(&updates.borrow_and_update(), false);
            if owner
                .update(cx, |view, cx| {
                    if !Arc::ptr_eq(&view.workspace, &workspace) {
                        return;
                    }
                    let Some(chat) = view.chat_ref(&id).filter(|chat| {
                        chat.record.snapshot == path
                            && source.ptr_eq(&Arc::downgrade(&chat.controller))
                    }) else {
                        return;
                    };
                    let archived = view
                        .records
                        .iter()
                        .find(|r| r.id == id)
                        .unwrap_or(&chat.record)
                        .archived_at
                        .is_some();
                    let enabled = cx.global::<Notifications>().enabled();
                    // Rust catalogs currently contain regular chats only: utility chat
                    // types and Pi-import flags have no representation/workflow.
                    if completion_cue(
                        completed,
                        enabled,
                        SoundExclusions {
                            archived,
                            shut_down: view.shutting_down,
                            ..Default::default()
                        },
                    ) {
                        cx.global_mut::<Notifications>().play();
                    }
                })
                .is_err()
            {
                break;
            }
        }
    })
}

#[cfg(all(target_os = "macos", not(test)))]
mod native {
    use cocoa::{
        base::{BOOL, NO, id, nil},
        foundation::NSString,
    };
    use objc::{class, msg_send, runtime::Class, sel, sel_impl};
    pub(super) fn testing() -> bool {
        std::env::var("PI_APP_TESTING").as_deref() == Ok("1")
            || Class::get("XCTestCase").is_some()
            || std::env::var("BELLO_APP_TESTING").as_deref() == Ok("1")
    }
    pub(super) fn badge(label: Option<&str>) {
        unsafe {
            let app: id = msg_send![class!(NSApplication), sharedApplication];
            let dock: id = msg_send![app, dockTile];
            let value = label.map(|s| NSString::alloc(nil).init_str(s));
            let label = value.unwrap_or(nil);
            let current: id = msg_send![dock, badgeLabel];
            let same = current == label
                || (current != nil && label != nil && {
                    let equal: BOOL = msg_send![current, isEqualToString: label];
                    equal != NO
                });
            if !same {
                let _: () = msg_send![dock, setBadgeLabel: label];
            }
            if let Some(value) = value {
                let _: () = msg_send![value, release];
            }
        }
    }
    pub(super) struct Sound {
        sound: id,
    }
    impl Default for Sound {
        fn default() -> Self {
            Self { sound: nil }
        }
    }
    impl Sound {
        pub(super) fn playing(&self) -> bool {
            self.sound != nil
                && unsafe {
                    let playing: BOOL = msg_send![self.sound, isPlaying];
                    playing != NO
                }
        }
        pub(super) fn play(&mut self) -> bool {
            unsafe {
                if self.sound == nil {
                    let name = NSString::alloc(nil).init_str("Tink");
                    let sound: id = msg_send![class!(NSSound), soundNamed: name];
                    let _: () = msg_send![name, release];
                    if sound == nil {
                        return false;
                    }
                    self.sound = msg_send![sound, retain];
                    let _: () = msg_send![self.sound, setVolume: 0.8_f32];
                }
                if self.playing() {
                    return false;
                }
                let played: BOOL = msg_send![self.sound, play];
                played != NO
            }
        }
    }
    impl Drop for Sound {
        fn drop(&mut self) {
            if self.sound != nil {
                unsafe {
                    let _: () = msg_send![self.sound, release];
                }
            }
        }
    }
}
#[cfg(test)]
#[path = "notifications_tests.rs"]
mod tests;
