use super::*;

fn offered_find() -> NativeTools {
    // Preparation is platform-independent; this private fixture never invokes
    // Find and does not bypass the public unsupported-platform admission gate.
    let mut native = NativeTools::new("/fixture".into(), [], "/home-fixture".into(), []).unwrap();
    native
        .capabilities
        .extend([Capability::Find, Capability::Ls]);
    native
}

fn call(arguments: Value) -> ToolCall {
    ToolCall {
        id: "find-fixture".into(),
        name: "find".into(),
        arguments,
    }
}

#[test]
fn find_definition_and_order_match_source() {
    let native = offered_find();
    assert_eq!(native.capability_ids(), ["ls", "find"]);
    let definitions = native.definitions();
    assert_eq!(definitions[0].name, "ls");
    assert_eq!(definitions[1].name, "find");
    assert_eq!(
        definitions[1].description,
        "Find paths matching a shell-style glob, relative to path (default workspace). No shell execution."
    );
    assert_eq!(
        definitions[1].schema,
        json!({"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"limit":{"type":"integer","minimum":1}},"required":["pattern"],"additionalProperties":false})
    );
}

#[test]
fn find_preparation_keeps_required_null_and_original_call_semantics() {
    let native = offered_find();
    for (raw, expected) in [
        (
            json!({"pattern":null,"path":null,"limit":null}),
            json!({"pattern":""}),
        ),
        (
            json!({"pattern":true,"path":42,"limit":"0"}),
            json!({"pattern":"true","path":"42","limit":0}),
        ),
        (
            json!({"pattern":12.5,"limit":false}),
            json!({"pattern":"12.5","limit":0}),
        ),
        (
            json!({"pattern":"a*","limit":"1.5","unknown":true}),
            json!({"pattern":"a*","limit":"1.5","unknown":true}),
        ),
        (json!({"path":"x"}), json!({"path":"x"})),
        (json!(null), json!(null)),
    ] {
        let original = call(raw.clone());
        let prepared = native.prepare_call(&original);
        assert_eq!(prepared.arguments, expected);
        assert_eq!(original.arguments, raw);
        assert_eq!(prepared.id, original.id);
    }
    let unoffered = NativeTools::new(
        "/fixture".into(),
        [],
        "/home-fixture".into(),
        [Capability::Ls],
    )
    .unwrap();
    let raw = call(json!({"pattern":null,"limit":true}));
    assert_eq!(unoffered.prepare_call(&raw).arguments, raw.arguments);
}

#[tokio::test]
async fn find_missing_and_unknown_fields_fail_before_dispatch() {
    let native = offered_find();
    for arguments in [json!({}), json!({"pattern":"*","other":true})] {
        let error = native
            .invoke(&call(arguments), CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(error.code(), Some("tool_arguments"));
        assert_eq!(error.to_string(), "Missing or unsupported tool arguments");
    }
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    assert!(matches!(
        native.invoke(&call(json!({})), cancelled).await,
        Err(ToolError::Cancelled)
    ));
}
