"""Strict, local-only request oracle shared by helper and native UI fixtures.

This describes the application wire contract, not a complete LiteLLM emulator.
It deliberately rejects malformed requests instead of returning canned success.
No real credentials, provider calls, or price estimates belong in this fixture.
"""
import json
import re


class FixtureContractError(ValueError):
    pass


def require(condition, description):
    if not condition:
        raise FixtureContractError(description)


def validate_schema(schema, name="tool parameters"):
    require(isinstance(schema, dict) and schema.get("type") == "object", name + " must be an object schema")
    properties, required = schema.get("properties"), schema.get("required", [])
    require(isinstance(properties, dict), name + " must describe properties")
    require(isinstance(required, list) and all(isinstance(key, str) for key in required), name + " required must contain names")
    require(len(set(required)) == len(required) and set(required) <= set(properties), name + " required fields must exist")
    for key, value in properties.items():
        require(isinstance(key, str) and isinstance(value, dict), name + " property schema is malformed")
        require(value.get("type") in ("string", "integer", "number", "boolean", "object", "array") or "anyOf" in value, name + " property type is missing")
        if value.get("type") == "array":
            require(isinstance(value.get("items"), dict), name + " array item schema is missing")


def validate_arguments(arguments, schema):
    """Check the subset used by the native tools, independently of the host."""
    require(isinstance(arguments, dict), "tool call arguments must be an object")
    require(set(schema.get("required", [])) <= set(arguments), "tool call is missing a required argument")
    if schema.get("additionalProperties") is False:
        require(set(arguments) <= set(schema["properties"]), "tool call contains an unknown argument")
    for name, value in arguments.items():
        spec = schema["properties"].get(name, {})
        kind = spec.get("type")
        types = {"string": str, "object": dict, "array": list, "boolean": bool}
        if kind in types:
            require(isinstance(value, types[kind]), "tool argument has the wrong type: " + name)
        elif kind in ("integer", "number"):
            require(type(value) in ((int,) if kind == "integer" else (int, float)), "tool argument has the wrong numeric type: " + name)
        if "enum" in spec:
            require(value in spec["enum"], "tool argument is outside its enum: " + name)


CORRELATION_ID = re.compile(r"[A-Za-z0-9._:-]{1,128}")


def validate_correlation(headers, body, responses, *, session_id=None, turn_id=None):
    """Every gateway request names its native session and turn.

    ``x-session-id``/``x-turn-id`` carry bounded identity text; a Responses
    body repeats the session identity as ``metadata.session_id`` so LiteLLM
    can correlate spend without inspecting headers. Messages bodies must not
    grow a metadata field the host never sends.
    """
    session = headers.get("x-session-id")
    turn = headers.get("x-turn-id")
    require(isinstance(session, str) and CORRELATION_ID.fullmatch(session) is not None, "x-session-id header is missing or invalid")
    require(isinstance(turn, str) and CORRELATION_ID.fullmatch(turn) is not None, "x-turn-id header is missing or invalid")
    require(session_id is None or session == session_id, "x-session-id does not name the expected session")
    require(turn_id is None or turn == turn_id, "x-turn-id does not name the expected turn")
    if responses:
        metadata = body.get("metadata")
        require(isinstance(metadata, dict) and metadata.get("session_id") == session, "Responses metadata.session_id must equal x-session-id")
    else:
        require("metadata" not in body, "Messages requests must not carry Responses correlation metadata")
    return session, turn


def validate_request(method, path, headers, body, *, api_key, model=None,
                     max_output_tokens=None, custom_headers=None,
                     expected_tool_names=None, native_items=None, historical_tool_schemas=None,
                     session_id=None, turn_id=None):
    """Validate both API formats and return semantic history for response choice.

    native_items='portable' rejects opaque reasoning on the wire. 'pinned'
    permits it; the response fixture additionally checks the exact issued bytes.
    Request authentication is compared in memory and never included in errors.
    session_id/turn_id pin the expected correlation identities when known.
    """
    require(method == "POST", "model requests must use POST")
    require(path in ("/v1/responses", "/v1/messages"), "unexpected model route")
    responses = path == "/v1/responses"
    headers = {name.lower(): value for name, value in headers.items()}
    require(headers.get("authorization") == "Bearer " + api_key, "Authorization does not match the configured fixture key")
    require(headers.get("content-type", "").split(";", 1)[0].strip() == "application/json", "request content type must be JSON")
    require(headers.get("accept") == "text/event-stream", "request must accept SSE")
    require(isinstance(body, dict), "request body must be an object")
    session, turn = validate_correlation(headers, body, responses, session_id=session_id, turn_id=turn_id)
    if responses:
        require("x-api-key" not in headers and "anthropic-version" not in headers, "Messages headers leaked into Responses")
    else:
        require(headers.get("x-api-key") == api_key, "Messages x-api-key does not match the configured fixture key")
        require(headers.get("anthropic-version") == "2023-06-01", "Messages protocol version is missing")
    for name, value in (custom_headers or {}).items():
        require(headers.get(name.lower()) == value, "configured custom header did not reach the gateway: " + name)
    require(isinstance(body, dict), "request body must be an object")
    require(isinstance(body.get("model"), str) and body["model"], "model alias must be nonempty")
    require(model is None or body["model"] == model, "model alias changed on the wire")
    require(body.get("stream") is True, "stream must be true")
    limit_name = "max_output_tokens" if responses else "max_tokens"
    # A conversation request carries the model's catalog ceiling when one is known and nothing otherwise;
    # the app's output budget is a local reserve that never reaches the wire.
    require(limit_name not in body or (type(body.get(limit_name)) is int and body[limit_name] > 0), "output token limit must be positive when present")
    require(max_output_tokens is None or body.get(limit_name) == max_output_tokens, "output token limit differs from the model ceiling")
    instructions = body.get("instructions" if responses else "system")
    require(isinstance(instructions, str), "native instructions must use the correct API field")
    require(not set(body).intersection({"messages", "system", "max_tokens"} if responses else {"input", "instructions", "max_output_tokens", "store", "parallel_tool_calls"}), "request mixes the two provider formats")
    if responses:
        require(body.get("store") is False, "Responses requests must explicitly disable provider storage")
    tools = body.get("tools", [])
    require(isinstance(tools, list), "tools must be an array")
    schemas = {}
    for tool in tools:
        require(isinstance(tool, dict) and isinstance(tool.get("name"), str) and tool["name"], "tool name is missing")
        require(tool["name"] not in schemas, "tool names must be unique")
        require(isinstance(tool.get("description"), str) and tool["description"], "tool description is missing")
        if responses:
            require(tool.get("type") == "function" and tool.get("strict") is False, "Responses tool must use non-strict function format")
            require("input_schema" not in tool, "Messages schema leaked into Responses")
        else:
            require("parameters" not in tool and "strict" not in tool, "Responses schema leaked into Messages")
        schema = tool.get("parameters" if responses else "input_schema")
        validate_schema(schema, tool["name"])
        schemas[tool["name"]] = schema
    if responses and tools:
        require(body.get("parallel_tool_calls") is False, "Responses tool execution must stay serial")
    if expected_tool_names is not None:
        require(set(schemas) == set(expected_tool_names), "request tool set differs from the expected capabilities")
    history = body.get("input" if responses else "messages")
    require(isinstance(history, list) and history, "request history must be nonempty")
    calls, results, opaque, user_texts = {}, {}, [], []
    historical_schemas = dict(historical_tool_schemas or {})
    for name, schema in historical_schemas.items():
        validate_schema(schema, name)
    historical_schemas.update(schemas)

    def call(ident, name, arguments):
        require(isinstance(ident, str) and ident and ident not in calls, "tool call ID is missing or duplicated")
        require(isinstance(name, str) and name, "historical tool name must be nonempty text")
        # A read-only side can inherit completed editing-tool history. The
        # fixture supplies those known schemas separately; this does not grant
        # the current request permission to invoke an unavailable tool.
        require(name in historical_schemas, "history contains a tool call with no known fixture schema")
        validate_arguments(arguments, historical_schemas[name])
        calls[ident] = {"name": name, "arguments": arguments}

    def result(ident, content):
        require(ident in calls and ident not in results, "tool result has no matching preceding call or duplicates a result")
        require(isinstance(content, str) and content, "tool result content must be nonempty text")
        results[ident] = content

    for item in history:
        require(isinstance(item, dict), "history entries must be objects")
        kind = item.get("type", "message")
        if responses and kind == "function_call":
            require(isinstance(item.get("arguments"), str), "Responses tool arguments must be serialized JSON")
            try:
                arguments = json.loads(item["arguments"])
            except (ValueError, TypeError):
                raise FixtureContractError("Responses tool arguments are not valid JSON")
            call(item.get("call_id"), item.get("name"), arguments)
        elif responses and kind == "function_call_output":
            result(item.get("call_id"), item.get("output"))
        elif responses and kind == "reasoning":
            require(isinstance(item.get("encrypted_content"), str) and item["encrypted_content"], "opaque Responses item has no native payload")
            opaque.append(item)
        else:
            require(kind == "message", "unsupported Responses history item")
            role, content = item.get("role"), item.get("content")
            require(role in ("user", "assistant"), "history role is invalid")
            require(isinstance(content, list) and content, "history content must be nonempty blocks")
            texts = []
            for block in content:
                require(isinstance(block, dict), "history block must be an object")
                block_type = block.get("type")
                is_text = block_type in ("input_text", "output_text") if responses else block_type == "text"
                if is_text:
                    require(isinstance(block.get("text"), str), "text content must be a string")
                    if responses:
                        require(block_type == ("input_text" if role == "user" else "output_text"), "Responses text block does not match its role")
                    texts.append(block["text"])
                elif not responses and block_type == "tool_use":
                    require(role == "assistant", "Messages tool_use must be in an assistant message")
                    call(block.get("id"), block.get("name"), block.get("input"))
                elif not responses and block_type == "tool_result":
                    require(role == "user" and type(block.get("is_error")) is bool, "Messages tool result role/is_error is invalid")
                    result(block.get("tool_use_id"), block.get("content"))
                elif not responses and block_type in ("thinking", "redacted_thinking"):
                    require(role == "assistant", "Messages thinking must remain an assistant block")
                    if block_type == "thinking":
                        require(isinstance(block.get("signature"), str) and block["signature"], "Messages native thinking signature is missing")
                    else:
                        require(isinstance(block.get("data"), str) and block["data"], "Messages redacted thinking payload is missing")
                    opaque.append(block)
                else:
                    raise FixtureContractError("unexpected history content block")
            if role == "user" and texts:
                user_texts.append("\n".join(texts))
    require(set(calls) == set(results), "request contains a tool call without its completed result")
    if native_items == "portable":
        require(not opaque, "portable history leaked opaque provider items")
    is_compaction = instructions == "Produce a factual, concise continuation summary. Do not claim unfinished actions succeeded."
    if is_compaction:
        require(not tools and len(history) == 1 and len(user_texts) == 1, "compaction must be a single no-tools summary request")
        require(user_texts[0].startswith("Summarize this conversation for continuation.") and "[user]\n" in user_texts[0], "compaction omitted source history or summary instructions")
    return {"api": "openai-responses" if responses else "anthropic-messages", "instructions": instructions,
            "latest_text": user_texts[-1] if user_texts else "", "user_texts": user_texts,
            "calls": calls, "results": results, "opaque": opaque, "tool_names": set(schemas),
            "is_compaction": is_compaction, "session_id": session, "turn_id": turn}
