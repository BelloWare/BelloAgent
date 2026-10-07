use super::*;
fn offered() -> NativeTools {
    let mut tools = NativeTools::new("/fixture".into(), [], "/fixture-home".into(), []).unwrap();
    tools.capabilities.extend([
        Capability::Read,
        Capability::Ls,
        Capability::Find,
        Capability::Grep,
    ]);
    tools
}
fn call(arguments: Value) -> ToolCall {
    ToolCall {
        id: "read-fixture".into(),
        name: "read".into(),
        arguments,
    }
}
#[test]
fn read_schema_and_preparation_keep_original_arguments_and_source_order() {
    let tools = offered();
    assert_eq!(tools.capability_ids(), ["read", "ls", "find", "grep"]);
    let definition = &tools.definitions()[0];
    assert_eq!(definition.name, "read");
    assert_eq!(
        definition.schema,
        json!({"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false})
    );
    for (raw, expected) in [
        (
            json!({"path":null,"offset":null,"limit":null}),
            json!({"path":""}),
        ),
        (
            json!({"path":12,"offset":"2","limit":"0x10"}),
            json!({"path":"12","offset":2,"limit":16}),
        ),
        (
            json!({"path":true,"offset":true,"limit":false}),
            json!({"path":"true","offset":1,"limit":0}),
        ),
        (
            json!({"path":"x","offset":"2.5","limit":" "}),
            json!({"path":"x","offset":"2.5","limit":" "}),
        ),
    ] {
        let original = call(raw.clone());
        let prepared = tools.prepare_call(&original);
        assert_eq!(prepared.arguments, expected);
        assert_eq!(original.arguments, raw);
    }
}
#[tokio::test]
async fn read_key_validation_and_cancellation_precede_any_file_io() {
    let tools = offered();
    for args in [json!({}), json!({"path":"x","unsupported":true})] {
        assert_eq!(
            tools
                .invoke(&call(args), CancellationToken::new())
                .await
                .unwrap_err()
                .code(),
            Some("tool_arguments")
        );
    }
    let token = CancellationToken::new();
    token.cancel();
    assert!(matches!(
        tools.invoke(&call(json!({})), token).await,
        Err(ToolError::Cancelled)
    ));
}
#[test]
fn unsupported_platform_does_not_offer_partial_read_under_full_name() {
    let constructed = NativeTools::new(
        "/fixture".into(),
        [],
        "/fixture-home".into(),
        [Capability::Read],
    );
    #[cfg(not(target_os = "macos"))]
    assert!(constructed.is_err());
    #[cfg(target_os = "macos")]
    assert_eq!(constructed.unwrap().capability_ids(), ["read"]);
}
