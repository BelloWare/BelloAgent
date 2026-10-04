//! Byte-incremental port of Transport.swift SSEParser. EOF never fabricates a
//! final blank line, and UTF-8 is decoded only after a full line is assembled.
use crate::{Result, invalid};
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub event: String,
    pub data: String,
}
#[derive(Default)]
pub struct Parser {
    line: Vec<u8>,
    fields: Vec<String>,
    kind: String,
    skip_lf: bool,
    seen_line: bool,
    event_bytes: usize,
}
impl Parser {
    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<Event>> {
        let mut events = Vec::new();
        for &byte in bytes {
            if self.skip_lf {
                self.skip_lf = false;
                if byte == b'\n' {
                    continue;
                }
            }
            if byte == b'\r' || byte == b'\n' {
                let mut value = String::from_utf8(std::mem::take(&mut self.line))
                    .map_err(|_| invalid("Stream contains invalid UTF-8"))?;
                if !self.seen_line {
                    self.seen_line = true;
                    value = value.trim_start_matches('\u{feff}').into();
                }
                if value.is_empty() {
                    if !self.fields.is_empty() {
                        events.push(Event {
                            event: if self.kind.is_empty() {
                                "message".into()
                            } else {
                                self.kind.clone()
                            },
                            data: self.fields.join("\n"),
                        });
                    }
                    self.fields.clear();
                    self.kind.clear();
                    self.event_bytes = 0;
                } else if !value.starts_with(':') {
                    let (key, data) = value.split_once(':').unwrap_or((&value, ""));
                    let data = data.strip_prefix(' ').unwrap_or(data);
                    match key {
                        "data" => {
                            self.event_bytes += data.len() + 1;
                            self.fields.push(data.into());
                        }
                        "event" => self.kind = data.into(),
                        _ => {}
                    }
                }
                self.skip_lf = byte == b'\r';
            } else {
                self.line.push(byte);
            }
            if self.line.len() > 4 * 1024 * 1024
                || self.event_bytes + self.line.len() > 8 * 1024 * 1024
            {
                return Err(invalid("SSE line or event exceeded its safety limit"));
            }
        }
        Ok(events)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_byte_splits_match() {
        let source =
            "\u{feff}: comment\r\nevent: custom\rdata: héllo\ndata: world\r\n\r\n".as_bytes();
        for split in 0..=source.len() {
            let mut p = Parser::default();
            let mut out = p.feed(&source[..split]).unwrap();
            out.extend(p.feed(&source[split..]).unwrap());
            assert_eq!(
                out,
                vec![Event {
                    event: "custom".into(),
                    data: "héllo\nworld".into()
                }]
            );
        }
        let mut p = Parser::default();
        let out: Vec<_> = source.iter().flat_map(|b| p.feed(&[*b]).unwrap()).collect();
        assert_eq!(out.len(), 1);
    }
    #[test]
    fn eof_is_not_terminal() {
        assert!(
            Parser::default()
                .feed(b"data: incomplete\n")
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn invalid_utf8_is_rejected() {
        assert!(
            Parser::default()
                .feed(&[b'd', b'a', b't', b'a', b':', 0xff, b'\n'])
                .is_err()
        );
    }
}
