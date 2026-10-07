//! Bounded, conservative port of PiAgentCore/MetadataYAML.swift, not general YAML.
use crate::{Result, invalid};
use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Number, Value};
use std::fmt;
pub const MAX_METADATA_BYTES: usize = 65_536;
struct Line<'a> {
    indent: usize,
    text: &'a str,
}
struct Parser<'a> {
    lines: Vec<Line<'a>>,
    index: usize,
}
pub fn parse(text: &str) -> Result<Value> {
    if text.len() > MAX_METADATA_BYTES || text.contains('\t') {
        return Err(invalid("Metadata exceeds 64 KiB or contains tabs"));
    }
    let mut p = Parser {
        lines: text
            .split([
                '\n', '\r', '\u{000b}', '\u{000c}', '\u{0085}', '\u{2028}', '\u{2029}',
            ])
            .map(|raw| Line {
                indent: raw.bytes().take_while(|b| *b == b' ').count(),
                text: trim(raw),
            })
            .collect(),
        index: 0,
    };
    p.skip();
    if p.index == p.lines.len() {
        return Ok(Value::Object(Map::new()));
    }
    let result = p.node(p.lines[p.index].indent, 0)?;
    p.skip();
    if p.index != p.lines.len() {
        return Err(invalid("Unexpected YAML indentation"));
    }
    check_depth(&result, 0)?;
    Ok(result)
}
fn trim(s: &str) -> &str {
    s.trim_matches(|c| {
        matches!(
            c,
            '\t' | ' ' | '\u{00a0}' | '\u{1680}' | '\u{2000}'
                ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
        )
    })
}
pub(crate) fn without_comment(s: &str) -> &str {
    let mut quote = None;
    let mut escaped = false;
    let mut previous = None;
    for (i, c) in s.char_indices() {
        if escaped {
            escaped = false;
            previous = Some(c);
            continue;
        }
        if c == '\\' && quote == Some('"') {
            escaped = true;
            previous = Some(c);
            continue;
        }
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
        } else if c == '"' || c == '\'' {
            quote = Some(c);
        } else if c == '#' && previous.is_none_or(char::is_whitespace) {
            return trim(&s[..i]);
        }
        previous = Some(c);
    }
    trim(s)
}
fn scalar(raw: &str) -> Result<Value> {
    let s = without_comment(raw);
    if s.starts_with('"') {
        return serde_json::from_str::<String>(s)
            .map(Value::String)
            .map_err(|_| invalid("Invalid quoted string"));
    }
    if s.starts_with('\'') {
        if s.len() < 2 || !s.ends_with('\'') {
            return Err(invalid("Unclosed string"));
        }
        return Ok(Value::String(s[1..s.len() - 1].replace("''", "'")));
    }
    match s {
        "true" => return Ok(Value::Bool(true)),
        "false" => return Ok(Value::Bool(false)),
        "null" | "~" => return Ok(Value::Null),
        _ => {}
    }
    if s.starts_with('[') || s.starts_with('{') {
        let value = serde_json::from_str::<UniqueValue>(s)
            .map_err(|_| invalid("Invalid metadata collection"))?
            .0;
        check_depth(&value, 0)?;
        return Ok(value);
    }
    if s.starts_with(['&', '*', '!', '%']) || s.contains(": ") {
        return Err(invalid("Unsupported YAML construct; quote literal values"));
    }
    if let Ok(n) = s.parse::<f64>()
        && let Some(n) = Number::from_f64(n)
    {
        return Ok(Value::Number(n));
    }
    Ok(Value::String(s.into()))
}
fn check_depth(v: &Value, depth: usize) -> Result<()> {
    if depth >= 16 && (v.is_array() || v.is_object()) {
        return Err(invalid("Metadata nesting exceeds limit"));
    }
    match v {
        Value::Array(v) => {
            for v in v {
                check_depth(v, depth + 1)?;
            }
        }
        Value::Object(v) => {
            for v in v.values() {
                check_depth(v, depth + 1)?;
            }
        }
        _ => {}
    }
    Ok(())
}
impl Parser<'_> {
    fn skip(&mut self) {
        while self.index < self.lines.len()
            && (self.lines[self.index].text.is_empty()
                || self.lines[self.index].text.starts_with('#'))
        {
            self.index += 1;
        }
    }
    fn value(&mut self, rest: &str, parent: usize, depth: usize) -> Result<Value> {
        let s = without_comment(rest);
        if ["|", "|-", "|+", ">", ">-", ">+"].contains(&s) {
            let mut parts = Vec::new();
            let mut block_indent = None;
            while self.index < self.lines.len() {
                let line = &self.lines[self.index];
                if !line.text.is_empty() && line.indent <= parent {
                    break;
                }
                if !line.text.is_empty() && block_indent.is_none() {
                    block_indent = Some(line.indent);
                }
                parts.push(format!(
                    "{}{}",
                    " ".repeat(
                        line.indent
                            .saturating_sub(block_indent.unwrap_or(line.indent))
                    ),
                    line.text
                ));
                self.index += 1;
            }
            return Ok(Value::String(
                parts.join(if s.starts_with('>') { " " } else { "\n" })
                    + if s.ends_with('-') { "" } else { "\n" },
            ));
        }
        if !s.is_empty() {
            return scalar(s);
        }
        self.skip();
        if self.index < self.lines.len() && self.lines[self.index].indent > parent {
            return self.node(self.lines[self.index].indent, depth + 1);
        }
        Ok(Value::Object(Map::new()))
    }
    fn pair(s: &str) -> Result<(&str, &str)> {
        let (key, rest) = s
            .split_once(':')
            .ok_or_else(|| invalid("Expected metadata key"))?;
        let key = trim(key);
        if !key
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
            || !key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err(invalid("Unsupported metadata key"));
        }
        Ok((key, trim(rest)))
    }
    fn node(&mut self, indent: usize, depth: usize) -> Result<Value> {
        if depth >= 16 {
            return Err(invalid("Metadata nesting exceeds limit"));
        }
        self.skip();
        let sequence =
            self.index < self.lines.len() && self.lines[self.index].text.starts_with("- ");
        let mut array = Vec::new();
        let mut object = Map::new();
        loop {
            self.skip();
            if self.index == self.lines.len() || self.lines[self.index].indent < indent {
                break;
            }
            if self.lines[self.index].indent != indent {
                return Err(invalid("Unexpected metadata indentation"));
            }
            let line = self.lines[self.index].text;
            self.index += 1;
            if sequence {
                let item = line
                    .strip_prefix("- ")
                    .ok_or_else(|| invalid("Mixed metadata collection"))?;
                if item.contains(": ") || item.ends_with(':') {
                    let (key, rest) = Self::pair(item)?;
                    let mut v = Map::new();
                    v.insert(key.into(), self.value(rest, indent + 2, depth)?);
                    self.skip();
                    if self.index < self.lines.len() && self.lines[self.index].indent > indent {
                        let more = self.node(self.lines[self.index].indent, depth + 1)?;
                        let more = more
                            .as_object()
                            .ok_or_else(|| invalid("Expected mapping continuation"))?;
                        for (key, value) in more {
                            if v.insert(key.clone(), value.clone()).is_some() {
                                return Err(invalid("Duplicate metadata key"));
                            }
                        }
                    }
                    array.push(Value::Object(v));
                } else {
                    array.push(scalar(item)?);
                }
            } else {
                let (key, rest) = Self::pair(line)?;
                if object.contains_key(key) {
                    return Err(invalid("Duplicate metadata key"));
                }
                object.insert(key.into(), self.value(rest, indent, depth)?);
            }
        }
        Ok(if sequence {
            Value::Array(array)
        } else {
            Value::Object(object)
        })
    }
}
// Value itself silently accepts duplicate inline keys. Fail closed instead.
struct UniqueValue(Value);
impl<'de> Deserialize<'de> for UniqueValue {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = UniqueValue;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("metadata value")
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Bool(v)))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Number(v.into())))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Number(v.into())))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> std::result::Result<Self::Value, E> {
                Number::from_f64(v)
                    .map(|n| UniqueValue(Value::Number(n)))
                    .ok_or_else(|| E::custom("Nonfinite metadata number"))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::String(v.into())))
            }
            fn visit_string<E: de::Error>(self, v: String) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::String(v)))
            }
            fn visit_none<E: de::Error>(self) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Null))
            }
            fn visit_unit<E: de::Error>(self) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut v = Vec::new();
                while let Some(UniqueValue(item)) = seq.next_element()? {
                    v.push(item);
                }
                Ok(UniqueValue(Value::Array(v)))
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut map: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut v = Map::new();
                while let Some((key, UniqueValue(value))) =
                    map.next_entry::<String, UniqueValue>()?
                {
                    if v.insert(key, value).is_some() {
                        return Err(de::Error::custom("Duplicate metadata key"));
                    }
                }
                Ok(UniqueValue(Value::Object(v)))
            }
        }
        d.deserialize_any(V)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn quoted_blocks_and_dependencies() {
        let v=parse("name: 'review'\ndescription: >-\n  Review the code\n  carefully\ndependencies:\n  tools:\n    - type: mcp\n      value: docs").unwrap();
        assert_eq!(v["description"], "Review the code carefully");
        assert_eq!(v["dependencies"]["tools"][0]["value"], "docs");
        assert_eq!(
            parse("description: \"literal # hash\" # comment").unwrap()["description"],
            "literal # hash"
        );
    }
    #[test]
    fn ambiguous_metadata_fails_closed() {
        for text in [
            "x: a\nx: b",
            "x:\n\ta: false",
            "x: &anchor",
            "x: !tag",
            "x: *alias",
            "x: %directive",
            "x: {\"p\":true,\"p\":false}",
            "x: [unquoted]",
            "x:\n  y: a\n z: b",
        ] {
            assert!(parse(text).is_err(), "{text}");
        }
        let text = (0..17)
            .map(|n| format!("{}x:\n", " ".repeat(n)))
            .collect::<String>();
        assert!(parse(&text).is_err());
    }
    #[test]
    fn metadata_bounds_are_exact() {
        let text = format!("x: {}", "a".repeat(MAX_METADATA_BYTES - 3));
        assert!(parse(&text).is_ok());
        assert!(parse(&(text + "a")).is_err());
    }
}
