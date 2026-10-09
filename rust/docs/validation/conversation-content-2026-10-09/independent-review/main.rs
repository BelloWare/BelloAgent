extern crate self as bello_agent_core;
#[derive(Clone)] pub struct Message { pub id:String, pub text:String, pub state:String, pub reasoning:String }
#[derive(Clone)] pub struct Session { pub id:String, pub messages:Vec<Message>, pub active_reply:Option<String> }
mod conversation_content;
