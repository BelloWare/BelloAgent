use super::*;
fn offered() -> NativeTools {
    let mut tools = NativeTools::new("/fixture".into(), [], "/fixture-home".into(), []).unwrap();
    tools
        .capabilities
        .extend([Capability::Write, Capability::Edit]);
    tools
}
fn call(name: &str, arguments: Value) -> ToolCall {
    ToolCall {
        id: "mutation".into(),
        name: name.into(),
        arguments,
    }
}
#[test]
fn source_schemas_and_required_string_preparation_are_exact() {
    let tools = offered();
    assert_eq!(tools.capability_ids(), ["write", "edit"]);
    assert_eq!(
        tools.definitions()[0].schema,
        json!({"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false})
    );
    assert_eq!(
        tools.definitions()[1].schema["required"],
        json!(["path", "oldText", "newText"])
    );
    for (name, raw, prepared) in [
        (
            "write",
            json!({"path":true,"content":null}),
            json!({"path":"true","content":""}),
        ),
        (
            "edit",
            json!({"path":1,"oldText":false,"newText":2.5}),
            json!({"path":"1","oldText":"false","newText":"2.5"}),
        ),
        (
            "edit",
            json!({"path":null,"oldText":null,"newText":null}),
            json!({"path":"","oldText":"","newText":""}),
        ),
        (
            "write",
            json!({"path":"a","content":[],"limit":null}),
            json!({"path":"a","content":[],"limit":null}),
        ),
    ] {
        let input = call(name, raw.clone());
        assert_eq!(tools.prepare_call(&input).arguments, prepared);
        assert_eq!(input.arguments, raw);
    }
}
#[tokio::test]
async fn unsupported_keys_and_missing_required_members_are_rejected_before_io() {
    let tools = offered();
    for input in [
        call("write", json!({"path":"x"})),
        call("write", json!({"path":"x","content":"","limit":1})),
        call("edit", json!({"path":"x","oldText":"x"})),
        call("edit", json!([])),
    ] {
        assert_eq!(
            tools
                .invoke(&input, CancellationToken::new())
                .await
                .unwrap_err()
                .code(),
            Some("tool_arguments")
        );
    }
}
#[tokio::test]
async fn gate_wait_cancellation_and_late_admission_refusal_never_enter_native_tool() {
    let tools = offered();
    let held = tools.editing_gate.lock().await;
    let token = CancellationToken::new();
    let input = call("write", json!({"path":"x","content":"new"}));
    let mut waiting = Box::pin(tools.invoke(&input, token.clone()));
    assert!(matches!(
        futures_util::poll!(&mut waiting),
        std::task::Poll::Pending
    ));
    token.cancel();
    assert!(matches!(waiting.await, Err(ToolError::NotExecuted(_))));
    drop(held);
    let failure = tools
        .invoke_mapped_with_admission(&input, CancellationToken::new(), Ok, async {
            Err(ToolError::NotExecuted("stale fixture trust".into()))
        })
        .await;
    assert!(
        matches!(failure,Err(ToolError::NotExecuted(message)) if message=="stale fixture trust")
    );
}
