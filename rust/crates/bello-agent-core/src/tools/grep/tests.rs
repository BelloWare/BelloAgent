use super::*;
use crate::tools::{
    ToolError,
    find::source::{CANDIDATE_LIMIT, COMPLETE_FOOTER, LIMITED_FOOTER, OUTPUT_BYTES, ScanControl},
};
use std::{cell::RefCell, rc::Rc};

#[derive(Debug, PartialEq)]
enum Event {
    Candidate(usize),
    Compiled(String, bool, bool),
    Read(usize),
    Matched(String),
}

type Events = Rc<RefCell<Vec<Event>>>;

struct FixtureScanner {
    root: Candidate<usize>,
    directory: bool,
    entries: Vec<Candidate<usize>>,
    events: Events,
    stop_before: Option<usize>,
    cancel_before: Option<(usize, CancellationToken)>,
    cancel_after_scan: Option<CancellationToken>,
}

fn candidate(path: &str, resource: usize) -> Candidate<usize> {
    Candidate {
        path: path.to_owned(),
        basename: path.rsplit('/').next().unwrap_or("").to_owned(),
        is_symbolic_link: false,
        resource,
    }
}

impl FixtureScanner {
    fn directory(paths: &[&str], events: &Events) -> Self {
        Self {
            root: candidate("/fixture", usize::MAX),
            directory: true,
            entries: paths
                .iter()
                .enumerate()
                .map(|(index, path)| candidate(path, index))
                .collect(),
            events: events.clone(),
            stop_before: None,
            cancel_before: None,
            cancel_after_scan: None,
        }
    }

    fn file(path: &str, events: &Events) -> Self {
        Self {
            root: candidate(path, 0),
            directory: false,
            ..Self::directory(&[], events)
        }
    }
}

impl Scanner for FixtureScanner {
    type Resource = usize;

    fn root(&self) -> &Candidate<usize> {
        &self.root
    }

    fn is_directory(&self) -> bool {
        self.directory
    }

    fn scan(
        &mut self,
        visit: &mut dyn FnMut(Candidate<usize>) -> ToolResult<ScanControl>,
    ) -> ToolResult<()> {
        let mut skipped_prefix: Option<String> = None;
        for (index, entry) in self.entries.iter().enumerate() {
            if self.stop_before == Some(index) {
                break;
            }
            if let Some((cancel_at, cancellation)) = &self.cancel_before
                && index == *cancel_at
            {
                cancellation.cancel();
            }
            if skipped_prefix
                .as_ref()
                .is_some_and(|prefix| entry.path.starts_with(prefix))
            {
                continue;
            }
            skipped_prefix = None;
            self.events.borrow_mut().push(Event::Candidate(entry.resource));
            match visit(entry.clone())? {
                ScanControl::Continue => {}
                ScanControl::SkipDescendants => {
                    skipped_prefix = Some(format!("{}/", entry.path));
                }
                ScanControl::Stop => break,
            }
        }
        if let Some(cancellation) = &self.cancel_after_scan {
            cancellation.cancel();
        }
        Ok(())
    }
}

struct FixtureReader {
    contents: Vec<ReadResult>,
    events: Events,
    cancel_on_read: Option<(usize, CancellationToken)>,
}

impl FixtureReader {
    fn new(contents: Vec<ReadResult>, events: &Events) -> Self {
        Self { contents, events: events.clone(), cancel_on_read: None }
    }
}

impl Reader<usize> for FixtureReader {
    fn read(&mut self, candidate: &Candidate<usize>) -> ReadResult {
        self.events.borrow_mut().push(Event::Read(candidate.resource));
        if let Some((resource, cancellation)) = &self.cancel_on_read
            && candidate.resource == *resource
        {
            cancellation.cancel();
        }
        match &self.contents[candidate.resource] {
            ReadResult::Directory => ReadResult::Directory,
            ReadResult::Text(text) => ReadResult::Text(text.clone()),
            ReadResult::Skipped => ReadResult::Skipped,
        }
    }
}

// Fixture matching rules are explicit answers, not a replacement regex dialect.
#[derive(Clone, Copy)]
enum MatchRule {
    EveryLine,
    Contains(&'static str),
    Exactly(&'static str),
}

struct FixtureFactory {
    rule: MatchRule,
    events: Events,
    fail: bool,
    cancel_after_match: Option<(usize, CancellationToken)>,
}

impl FixtureFactory {
    fn new(rule: MatchRule, events: &Events) -> Self {
        Self { rule, events: events.clone(), fail: false, cancel_after_match: None }
    }
}

struct FixtureMatcher {
    rule: MatchRule,
    events: Events,
    calls: usize,
    cancel_after_match: Option<(usize, CancellationToken)>,
}

impl RegexFactory for FixtureFactory {
    type Matcher = FixtureMatcher;

    fn compile(&mut self, pattern: &str, literal: bool, ignore_case: bool) -> ToolResult<Self::Matcher> {
        self.events.borrow_mut().push(Event::Compiled(pattern.to_owned(), literal, ignore_case));
        if self.fail {
            return Err(ToolError::failure("fixture_regex_error", "Fixture compiler rejected pattern"));
        }
        Ok(FixtureMatcher {
            rule: self.rule,
            events: self.events.clone(),
            calls: 0,
            cancel_after_match: self.cancel_after_match.clone(),
        })
    }
}

impl Matcher for FixtureMatcher {
    fn is_match(&mut self, line: &str) -> bool {
        self.calls += 1;
        self.events.borrow_mut().push(Event::Matched(line.to_owned()));
        if let Some((calls, cancellation)) = &self.cancel_after_match
            && self.calls == *calls
        {
            cancellation.cancel();
        }
        match self.rule {
            MatchRule::EveryLine => true,
            MatchRule::Contains(needle) => line.contains(needle),
            MatchRule::Exactly(expected) => line == expected,
        }
    }
}

fn options(limit: usize) -> Options<'static> {
    Options { pattern: "fixture-pattern", literal: false, ignore_case: false, limit }
}

fn text(value: &Value) -> &str {
    value["content"][0]["text"].as_str().unwrap()
}

fn run_file(contents: &str, rule: MatchRule, limit: usize) -> (Value, Events) {
    let events = Events::default();
    let mut scanner = FixtureScanner::file("/fixture/file", &events);
    let mut reader = FixtureReader::new(vec![ReadResult::Text(contents.to_owned())], &events);
    let mut factory = FixtureFactory::new(rule, &events);
    let result = execute(&mut scanner, &mut reader, &mut factory, options(limit), &CancellationToken::new()).unwrap();
    (result, events)
}

#[test]
fn empty_scan_still_compiles_and_preserves_result_envelope() {
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&[], &events);
    let mut reader = FixtureReader::new(vec![], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    let options = Options { pattern: "[literal]", literal: true, ignore_case: true, limit: 100 };
    let result = execute(&mut scanner, &mut reader, &mut factory, options, &CancellationToken::new()).unwrap();
    assert_eq!(result, serde_json::json!({"content":[{"type":"text","text":COMPLETE_FOOTER}],"isError":false}));
    assert_eq!(*events.borrow(), [Event::Compiled("[literal]".into(), true, true)]);
    assert!(result.get("stats").is_none());
}

#[test]
fn regex_error_is_reported_only_after_the_candidate_cap() {
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&[], &events);
    scanner.entries = (0..=CANDIDATE_LIMIT)
        .map(|index| candidate(&format!("/fixture/{index:05}"), index))
        .collect();
    let mut reader = FixtureReader::new(vec![], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    factory.fail = true;
    let error = execute(&mut scanner, &mut reader, &mut factory, options(100), &CancellationToken::new()).unwrap_err();
    assert_eq!(error.code(), Some("fixture_regex_error"));
    let events = events.borrow();
    assert_eq!(events.len(), CANDIDATE_LIMIT + 1);
    assert_eq!(events[CANDIDATE_LIMIT - 1], Event::Candidate(CANDIDATE_LIMIT - 1));
    assert_eq!(events.last(), Some(&Event::Compiled("fixture-pattern".into(), false, false)));
}

#[test]
fn cap_is_applied_before_sorting_and_exact_cap_is_limited() {
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&[], &events);
    scanner.entries = (0..CANDIDATE_LIMIT)
        .map(|index| candidate(&format!("/fixture/z-{index:05}"), index))
        .collect();
    scanner.entries.push(candidate("/fixture/a-outside-cap", CANDIDATE_LIMIT));
    let mut contents: Vec<_> = (0..CANDIDATE_LIMIT).map(|_| ReadResult::Skipped).collect();
    contents.push(ReadResult::Text("hit".into()));
    let mut reader = FixtureReader::new(contents, &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    let result = execute(&mut scanner, &mut reader, &mut factory, options(100), &CancellationToken::new()).unwrap();
    assert_eq!(text(&result), LIMITED_FOOTER);
    assert!(!events.borrow().contains(&Event::Read(CANDIDATE_LIMIT)));
    scanner.entries.pop();
    events.borrow_mut().clear();
    let result = execute(&mut scanner, &mut reader, &mut factory, options(100), &CancellationToken::new()).unwrap();
    assert_eq!(text(&result), LIMITED_FOOTER);
}

#[test]
fn sorted_candidates_retain_original_spelling_and_resource_identity() {
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&["/fixture/e\u{301}", "/fixture/é", "/fixture/z"], &events);
    let mut reader = FixtureReader::new(vec![ReadResult::Text("decomposed".into()), ReadResult::Text("composed".into()), ReadResult::Text("ascii".into())], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    let result = execute(&mut scanner, &mut reader, &mut factory, options(100), &CancellationToken::new()).unwrap();
    assert_eq!(text(&result), format!("z:1: ascii\ne\u{301}:1: decomposed\né:1: composed{COMPLETE_FOOTER}"));
    let reads: Vec<_> = events.borrow().iter().filter_map(|event| if let Event::Read(id) = event { Some(*id) } else { None }).collect();
    assert_eq!(reads, [2, 0, 1]);
}

#[test]
fn selected_file_uses_basename_and_bypasses_traversal_exclusions() {
    for path in ["/fixture/.git", "/fixture/node_modules", "/fixture/.build"] {
        let events = Events::default();
        let mut scanner = FixtureScanner::file(path, &events);
        scanner.root.is_symbolic_link = true;
        let mut reader = FixtureReader::new(vec![ReadResult::Text("hit".into())], &events);
        let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
        let result = execute(&mut scanner, &mut reader, &mut factory, options(100), &CancellationToken::new()).unwrap();
        assert_eq!(text(&result), format!("{}:1: hit{COMPLETE_FOOTER}", path.rsplit('/').next().unwrap()));
        assert!(!events.borrow().iter().any(|event| matches!(event, Event::Candidate(_))));
    }
}

#[test]
fn directories_and_failed_reads_are_not_sent_to_the_matcher() {
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&["/fixture/a-dir", "/fixture/b-unreadable", "/fixture/c-non-utf8", "/fixture/d-file"], &events);
    let mut reader = FixtureReader::new(vec![ReadResult::Directory, ReadResult::Skipped, ReadResult::Skipped, ReadResult::Text("hit".into())], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    let result = execute(&mut scanner, &mut reader, &mut factory, options(100), &CancellationToken::new()).unwrap();
    assert_eq!(text(&result), format!("d-file:1: hit{COMPLETE_FOOTER}"));
    assert_eq!(events.borrow().iter().filter(|event| matches!(event, Event::Matched(_))).count(), 1);
}

#[test]
fn zero_limit_skips_failed_reads_but_stops_after_first_readable_line() {
    for first_line in ["hit", "miss"] {
        let events = Events::default();
        let mut scanner = FixtureScanner::directory(&["/fixture/a-unreadable", "/fixture/b-non-utf8", "/fixture/c-file", "/fixture/d-later"], &events);
        let mut reader = FixtureReader::new(vec![ReadResult::Skipped, ReadResult::Skipped, ReadResult::Text(format!("{first_line}\nhit")), ReadResult::Text("hit".into())], &events);
        let mut factory = FixtureFactory::new(MatchRule::Exactly("hit"), &events);
        let result = execute(&mut scanner, &mut reader, &mut factory, options(0), &CancellationToken::new()).unwrap();
        assert_eq!(text(&result), if first_line == "hit" { format!("c-file:1: hit{LIMITED_FOOTER}") } else { LIMITED_FOOTER.into() });
        assert!(!events.borrow().contains(&Event::Read(3)));
        assert_eq!(events.borrow().iter().filter(|event| matches!(event, Event::Matched(_))).count(), 1);
    }
}

#[test]
fn zero_limit_directory_reaches_outer_check_without_reading_later_candidates() {
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&["/fixture/a-dir", "/fixture/b-file"], &events);
    let mut reader = FixtureReader::new(vec![ReadResult::Directory, ReadResult::Text("hit".into())], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    let result = execute(&mut scanner, &mut reader, &mut factory, options(0), &CancellationToken::new()).unwrap();
    assert_eq!(text(&result), LIMITED_FOOTER);
    assert!(!events.borrow().contains(&Event::Read(1)));
    assert!(!events.borrow().iter().any(|event| matches!(event, Event::Matched(_))));
}

#[test]
fn line_splitting_preserves_cr_and_trailing_empty_lines() {
    let (result, events) = run_file("first\r\nsecond\rthird\n", MatchRule::EveryLine, 100);
    assert_eq!(text(&result), format!("file:1: first\r\nfile:2: second\rthird\nfile:3: {COMPLETE_FOOTER}"));
    let lines: Vec<_> = events.borrow().iter().filter_map(|event| if let Event::Matched(line) = event { Some(line.clone()) } else { None }).collect();
    assert_eq!(lines, ["first\r", "second\rthird", ""]);
    let (result, _) = run_file("", MatchRule::Exactly(""), 100);
    assert_eq!(text(&result), format!("file:1: {COMPLETE_FOOTER}"));
}

#[test]
fn one_match_per_line_and_one_global_limit_across_files() {
    let (result, _) = run_file("hit hit hit\nmiss\nhit", MatchRule::Contains("hit"), 100);
    assert_eq!(text(&result), format!("file:1: hit hit hit\nfile:3: hit{COMPLETE_FOOTER}"));
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&["/fixture/a", "/fixture/b", "/fixture/c"], &events);
    let mut reader = FixtureReader::new(vec![ReadResult::Text("hit\nmiss".into()), ReadResult::Text("hit\nhit".into()), ReadResult::Text("hit".into())], &events);
    let mut factory = FixtureFactory::new(MatchRule::Contains("hit"), &events);
    let result = execute(&mut scanner, &mut reader, &mut factory, options(2), &CancellationToken::new()).unwrap();
    assert_eq!(text(&result), format!("a:1: hit\nb:1: hit{LIMITED_FOOTER}"));
    assert!(!events.borrow().contains(&Event::Read(2)));
}

#[test]
fn exact_hit_limit_is_limited_even_at_end_of_input() {
    let (result, _) = run_file("hit", MatchRule::EveryLine, 1);
    assert_eq!(text(&result), format!("file:1: hit{LIMITED_FOOTER}"));
    let (result, _) = run_file("hit", MatchRule::EveryLine, 2);
    assert_eq!(text(&result), format!("file:1: hit{COMPLETE_FOOTER}"));
}

#[test]
fn line_preview_is_lossy_bytes_and_does_not_itself_mark_output_limited() {
    let line = format!("{}é-tail", "a".repeat(LINE_BYTES - 1));
    let (result, _) = run_file(&line, MatchRule::EveryLine, 100);
    assert_eq!(text(&result), format!("file:1: {}{COMPLETE_FOOTER}", "a".repeat(LINE_BYTES - 1)));
    let (result, _) = run_file("\u{fffd}x\u{fffd}y\u{fffd}", MatchRule::EveryLine, 100);
    assert_eq!(text(&result), format!("file:1: x\u{fffd}y{COMPLETE_FOOTER}"));
}

#[test]
fn overall_output_uses_utf8_byte_boundary_and_source_footer() {
    let line = "é".repeat(500);
    let contents = std::iter::repeat_n(line, 40).collect::<Vec<_>>().join("\n");
    let (result, _) = run_file(&contents, MatchRule::EveryLine, 100);
    let expected = (1..=40).map(|index| format!("file:{index}: {}", "é".repeat(500))).collect::<Vec<_>>().join("\n");
    assert!(expected.len() > OUTPUT_BYTES);
    let bounded = String::from_utf8_lossy(&expected.as_bytes()[..OUTPUT_BYTES]).trim_matches('\u{fffd}').to_owned();
    assert_eq!(text(&result), format!("{bounded}{LIMITED_FOOTER}"));
}

#[test]
fn source_root_slash_relative_path_quirk_is_shared_with_find() {
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&["/alpha"], &events);
    scanner.root = candidate("/", usize::MAX);
    let mut reader = FixtureReader::new(vec![ReadResult::Text("hit".into())], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    let result = execute(&mut scanner, &mut reader, &mut factory, options(100), &CancellationToken::new()).unwrap();
    assert_eq!(text(&result), format!("lpha:1: hit{COMPLETE_FOOTER}"));
}

#[test]
fn enumeration_error_keeps_partial_candidates_without_scan_limited_footer() {
    let events = Events::default();
    let mut scanner = FixtureScanner::directory(&["/fixture/a", "/fixture/b"], &events);
    scanner.stop_before = Some(1);
    let mut reader = FixtureReader::new(vec![ReadResult::Text("hit".into())], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    let result = execute(&mut scanner, &mut reader, &mut factory, options(100), &CancellationToken::new()).unwrap();
    assert_eq!(text(&result), format!("a:1: hit{COMPLETE_FOOTER}"));
}

#[test]
fn cancellation_during_scan_precedes_regex_compile() {
    let events = Events::default();
    let token = CancellationToken::new();
    let mut scanner = FixtureScanner::directory(&["/fixture/a", "/fixture/.git"], &events);
    scanner.cancel_before = Some((1, token.clone()));
    let mut reader = FixtureReader::new(vec![], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    factory.fail = true;
    assert!(matches!(execute(&mut scanner, &mut reader, &mut factory, options(100), &token), Err(ToolError::Cancelled)));
    assert!(!events.borrow().iter().any(|event| matches!(event, Event::Compiled(..))));
}

#[test]
fn cancellation_after_scan_is_checked_before_first_candidate_but_after_compile() {
    let events = Events::default();
    let token = CancellationToken::new();
    let mut scanner = FixtureScanner::directory(&["/fixture/a"], &events);
    scanner.cancel_after_scan = Some(token.clone());
    let mut reader = FixtureReader::new(vec![], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    assert!(matches!(execute(&mut scanner, &mut reader, &mut factory, options(100), &token), Err(ToolError::Cancelled)));
    assert_eq!(*events.borrow(), [Event::Candidate(0), Event::Compiled("fixture-pattern".into(), false, false)]);
}

#[test]
fn cancellation_is_cooperative_between_lines_and_before_first_line() {
    for during_match in [false, true] {
        let events = Events::default();
        let token = CancellationToken::new();
        let mut scanner = FixtureScanner::file("/fixture/file", &events);
        let mut reader = FixtureReader::new(vec![ReadResult::Text("first\nsecond".into())], &events);
        let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
        if during_match {
            factory.cancel_after_match = Some((1, token.clone()));
        } else {
            reader.cancel_on_read = Some((0, token.clone()));
        }
        assert!(matches!(execute(&mut scanner, &mut reader, &mut factory, options(100), &token), Err(ToolError::Cancelled)));
        assert_eq!(events.borrow().iter().filter(|event| matches!(event, Event::Matched(_))).count(), usize::from(during_match));
    }
}

#[test]
fn cancellation_is_checked_between_candidates_after_a_skipped_read() {
    let events = Events::default();
    let token = CancellationToken::new();
    let mut scanner = FixtureScanner::directory(&["/fixture/a", "/fixture/b"], &events);
    let mut reader = FixtureReader::new(vec![ReadResult::Skipped], &events);
    reader.cancel_on_read = Some((0, token.clone()));
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    assert!(matches!(execute(&mut scanner, &mut reader, &mut factory, options(100), &token), Err(ToolError::Cancelled)));
    assert!(!events.borrow().contains(&Event::Read(1)));
}

#[test]
fn cancellation_during_last_match_is_not_a_thread_kill_or_an_extra_final_check() {
    let events = Events::default();
    let token = CancellationToken::new();
    let mut scanner = FixtureScanner::file("/fixture/file", &events);
    let mut reader = FixtureReader::new(vec![ReadResult::Text("hit\nlater".into())], &events);
    let mut factory = FixtureFactory::new(MatchRule::EveryLine, &events);
    factory.cancel_after_match = Some((1, token.clone()));
    let result = execute(&mut scanner, &mut reader, &mut factory, options(1), &token).unwrap();
    assert!(token.is_cancelled());
    assert_eq!(text(&result), format!("file:1: hit{LIMITED_FOOTER}"));
    assert!(!events.borrow().contains(&Event::Matched("later".into())));
}
