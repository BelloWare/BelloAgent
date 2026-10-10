//! Seed a Rust Bello Agent session snapshot from conversation.json (see
//! longchat_fixture.py), using the same Session/Message construction as
//! bello-agent-core/examples/session_streaming_bench.rs.
use bello_agent_core::{Message, Session};
use serde_json::Value;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(args.len(), 3, "usage: longchat-seeder conversation.json session.json");
    let conversation: Vec<Value> = serde_json::from_slice(&std::fs::read(&args[1]).unwrap()).unwrap();
    let target = std::path::PathBuf::from(&args[2]);
    assert!(!target.exists(), "refusing to replace an existing session file");
    let mut session = Session::new();
    session.title = "Long chat".into();
    session.messages = conversation
        .iter()
        .enumerate()
        .map(|(i, m)| Message {
            task_root_id: None,
            user_content: None,
            id: format!("history-{i:06}"),
            role: m["role"].as_str().unwrap().into(),
            text: m["text"].as_str().unwrap().into(),
            reasoning: String::new(),
            replay_eligible: true,
            state: "completed".into(),
            usage: Value::Null,
            model: Some("bench-model".into()),
            tool_record: None,
            compaction: None,
        })
        .collect();
    std::fs::create_dir_all(target.parent().unwrap()).unwrap();
    let mut encoded = serde_json::to_vec(&session).unwrap();
    encoded.push(b'\n');
    std::fs::write(&target, &encoded).unwrap();
    println!("{{\"messages\":{},\"bytes\":{}}}", session.messages.len(), encoded.len());
}
