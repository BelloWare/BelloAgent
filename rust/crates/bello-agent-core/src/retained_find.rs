//! Process-local identity of the exact retained text searched by conversation Find.
//! This is presentation evidence, never durability or permission to mutate a chat.
use crate::{Message, Session};
use std::sync::Arc;

/// A streaming active row is omitted; every other row (including empty rows) is retained.
pub fn is_retained(session: &Session, message: &Message) -> bool {
    !(session.active_reply.as_deref() == Some(message.id.as_str()) && message.state == "streaming")
}

#[derive(Clone, Debug)]
pub(crate) struct ContentToken(Arc<()>);
impl ContentToken {
    pub(crate) fn fresh() -> Self {
        Self(Arc::new(()))
    }
    fn same(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

/// One indivisible snapshot and retained-content identity. Consumers cannot forge
/// a pairing or hold a publication lock. Equal content does NOT prove equal raw
/// message indices: an excluded streaming row can move. Locate hits by message ID
/// and revalidate query/chat/window generations before using byte offsets.
#[derive(Clone, Debug)]
pub struct FindSnapshot {
    session: Arc<Session>,
    token: ContentToken,
}
impl FindSnapshot {
    pub(crate) fn new(session: Arc<Session>, token: ContentToken) -> Self {
        Self { session, token }
    }
    pub fn session(&self) -> &Session {
        &self.session
    }
    pub fn session_shared(&self) -> Arc<Session> {
        self.session.clone()
    }
    pub fn same_content(&self, other: &Self) -> bool {
        self.token.same(&other.token)
    }
}

pub(crate) fn same_projection(left: &Session, right: &Session) -> bool {
    #[cfg(test)]
    COMPARISONS.with(|count| count.set(count.get() + 1));
    left.id == right.id
        && left
            .messages
            .iter()
            .filter(|m| is_retained(left, m))
            .map(|m| (&m.id, &m.text))
            .eq(right
                .messages
                .iter()
                .filter(|m| is_retained(right, m))
                .map(|m| (&m.id, &m.text)))
}

#[cfg(test)]
thread_local! {
    pub(crate) static COMPARISONS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}
#[cfg(test)]
#[path = "retained_find_tests.rs"]
mod tests;
