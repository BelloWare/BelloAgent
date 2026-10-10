// Reads a JSON array of Markdown strings (argv[1]) and prints, per string, the
// paragraph/heading/cell spans flattened as [text, flags] for comparison.
use bello_agent_core::markdown::{Block, Span, Style, parse};
fn flags(span: &Span) -> String {
    [(span.bold, 'b'), (span.italic, 'i'), (span.strike, 's'), (span.code, 'c')]
        .iter().filter(|(on, _)| *on).map(|(_, c)| *c).collect::<String>()
        + if span.link.is_some() { "l" } else { "" }
}
fn walk(blocks: &[Block], out: &mut Vec<serde_json::Value>) {
    for block in blocks {
        match block {
            Block::Paragraph(spans) | Block::Heading { spans, .. } => {
                out.push(serde_json::json!(spans.iter().map(|s| (s.text.clone(), flags(s))).collect::<Vec<_>>()))
            }
            Block::List { items, .. } => items.iter().for_each(|item| walk(item, out)),
            Block::Quote(blocks) => walk(blocks, out),
            Block::Table { header, rows, .. } => {
                for cell in header.iter().chain(rows.iter().flatten()) {
                    out.push(serde_json::json!(cell.iter().map(|s| (s.text.clone(), flags(s))).collect::<Vec<_>>()))
                }
            }
            Block::Code { code, .. } => out.push(serde_json::json!([[code, "code"]])),
        }
    }
}
fn main() {
    let corpus: Vec<String> = serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
    let all: Vec<_> = corpus.iter().map(|source| { let mut out = Vec::new(); walk(&parse(source, Style::PROSE), &mut out); out }).collect();
    println!("{}", serde_json::to_string(&all).unwrap());
}
