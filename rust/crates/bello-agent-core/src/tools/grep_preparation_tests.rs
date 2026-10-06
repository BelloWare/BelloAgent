use super::*;

fn offered() -> NativeTools {
    let mut native = NativeTools::new("/fixture".into(), [], "/home-fixture".into(), []).unwrap();
    native
        .capabilities
        .extend([Capability::Grep, Capability::Find, Capability::Ls]);
    native
}
fn call(arguments: Value) -> ToolCall {
    ToolCall {
        id: "grep-fixture".into(),
        name: "grep".into(),
        arguments,
    }
}

#[test]
fn grep_definition_order_and_immutable_boolean_preparation_match_source() {
    let native = offered();
    assert_eq!(native.capability_ids(), ["ls", "find", "grep"]);
    let definitions = native.definitions();
    assert_eq!(definitions[2].name, "grep");
    assert_eq!(
        definitions[2].description,
        "Search UTF-8 files for a literal string or regular expression. Results include path and line number."
    );
    assert_eq!(
        definitions[2].schema,
        json!({"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"literal":{"type":"boolean"},"ignoreCase":{"type":"boolean"},"limit":{"type":"integer","minimum":1}},"required":["pattern"],"additionalProperties":false})
    );
    for (raw, expected) in [
        (
            json!({"pattern":null,"path":null,"limit":null,"literal":null,"ignoreCase":null}),
            json!({"pattern":""}),
        ),
        (
            json!({"pattern":true,"literal":"true","ignoreCase":0,"limit":"0"}),
            json!({"pattern":"true","literal":true,"ignoreCase":false,"limit":0}),
        ),
        (
            json!({"pattern":"x","literal":"false","ignoreCase":1.0}),
            json!({"pattern":"x","literal":false,"ignoreCase":true}),
        ),
        (
            json!({"pattern":"x","literal":"TRUE","ignoreCase":2}),
            json!({"pattern":"x","literal":"TRUE","ignoreCase":2}),
        ),
        (
            json!({"pattern":"x","literal":"1","ignoreCase":{}}),
            json!({"pattern":"x","literal":"1","ignoreCase":{}}),
        ),
    ] {
        let original = call(raw.clone());
        let prepared = native.prepare_call(&original);
        assert_eq!(prepared.arguments, expected);
        assert_eq!(original.arguments, raw);
        assert_eq!(prepared.id, original.id);
    }
    let disabled = NativeTools::new(
        "/fixture".into(),
        [],
        "/home-fixture".into(),
        [Capability::Ls],
    )
    .unwrap();
    let original = call(json!({"pattern":null,"literal":"true"}));
    assert_eq!(
        disabled.prepare_call(&original).arguments,
        original.arguments
    );
}

#[tokio::test]
async fn grep_rejects_missing_unknown_fields_and_checks_cancellation_first() {
    let native = offered();
    for arguments in [
        json!({}),
        json!({"pattern":"x","unknown":true}),
        json!({"literal":true}),
    ] {
        let error = native
            .invoke(&call(arguments), CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(error.code(), Some("tool_arguments"));
        assert_eq!(error.to_string(), "Missing or unsupported tool arguments");
    }
    let token = CancellationToken::new();
    token.cancel();
    assert!(matches!(
        native.invoke(&call(json!({})), token).await,
        Err(ToolError::Cancelled)
    ));
}
