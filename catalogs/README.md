# Bello Agent model catalog

Research date: **2026-09-16**. App contract reviewed on `BelloWare/pi-app` **master**, commit `8716a1c4bb34b69517a373008e8c08df64677a61`. The branch was rechecked at `34603906e6a38ab02244ee799deb6b65cc467d0c` before publication; the catalog contract/parser and provider request builder were unchanged in that comparison.

`bello-agent.models.json` is an **application model catalog**, not a LiteLLM routing configuration or a Codex `models.json`. It preserves all six requested LiteLLM aliases. The research/publication below did not change gateway routes or credentials. Starting with **Bello Agent 0.1.10**, the app bundles this exact file and uses it by default for every connection without a custom catalog URL. Existing selected aliases/efforts remain unchanged. The earlier source-only publication did not connect it to the default picker, which still used gateway discovery through 0.1.9.

## Configured values

All token figures below are exact integers; “1M” here is **1,048,576**, not 1,000,000. Output caps are *not* additional input capacity, and the maximum input and maximum output are not promises that both can be consumed simultaneously.

| LiteLLM alias | App context capacity | Configured output cap | Explicit effort choices |
| --- | ---: | ---: | --- |
| `deepseek-v4.1-flash` | 1,048,576 | 393,216 | off, low, high, max |
| `glm-5.3-flash` | 1,048,576 | 131,072 | low, high, max |
| `glm-5.3` | 1,048,576 | 131,072 | low, high, max |
| `kimi-k3` | 1,048,576 | 131,072 | low, high, max |
| `gemini-3.8-flash` | 1,048,576 | 65,536 | low, medium, high |
| `auto-router` | 1,048,576 | 128,000 | off, low, high, max |

The model's serving route can impose lower limits. In particular, the GLM output limits use a **documented serving-provider reference**, not a verified Z.ai-direct or user-deployed LiteLLM contract. Apply lower deployment caps when appropriate.

### Per-model evidence and decisions

**DeepSeek V4.1 Flash.** The official September 10 release identifies `deepseek-flash` as the provider API model name. The requested `deepseek-v4.1-flash` is intentionally retained as the user's LiteLLM alias; the gateway must map it correctly. DeepSeek's current Codex integration uses `1048576` for context. Its API reference allows `393216` generated tokens and the native effort set `none`, `low`, `high`, `max`. In this app's Responses adapter, `off` maps to `none` unless a connection-specific mapping overrides it. Sources: [release](https://api-docs.deepseek.com/news/news260910/), [context configuration](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/), [API limits and effort](https://api-docs.deepseek.com/api/create-chat-completion/).

**GLM 5.3 and GLM 5.3 Flash.** [AIHubMix's serving comparison](https://aihubmix.com/compare/glm-5.3/glm-5.3-flash) lists `1048576` context and `131072` output for both. [NVIDIA's GLM 5.3 reference](https://docs.api.nvidia.com/nim/reference/z-ai-glm-5-3) independently identifies the 1,048,576 context and low/high/max effort choices. The [Z.ai-authored Flash model card, reproduced on Hugging Face's Dell hub](https://dell.huggingface.co/models/zai-org/GLM-5.3-Flash), specifies low/high/max effort and max as its default. The Z.ai-direct 5.3 API pages were not successfully retrievable during this pass; the serving-provider caps therefore remain explicitly qualified. Do not replace them with benchmark generation settings or a different host's larger advertised capacity.

**Kimi K3.** [Kimi's Codex integration](https://platform.kimi.ai/docs/guide/codex-kimi) specifies context `1048576`. Its [K3 guide, Important limits](https://platform.kimi.ai/docs/guide/kimi-k3-quickstart) states that `max_completion_tokens` defaults to **131072** and can be set as high as **1048576**. The catalog deliberately uses the **documented default**, not that larger ceiling: the app rejects output limits above 1,000,000 and output >= context, and it treats the configured output as reserved context space. K3 always thinks; supported effort choices are low/high/max, default max. No off or fabricated medium setting is advertised.

**Gemini 3.8 Flash.** [Google's model page](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash) lists input limit **1048576**, output limit **65536**, and thinking levels **low/medium/high**; minimal is not supported. We conservatively use Google's input limit as the app's context capacity, without adding the separate output ceiling. This leaves additional margin because the app also subtracts its output reserve. [Google's thinking guide](https://ai.google.dev/gemini-api/docs/generate-content/thinking) documents thinking controls. No off, minimal, xhigh, or max choice is advertised.

**GPT-5.6 Sol, router constituent only.** [OpenAI's model page](https://developers.openai.com/api/docs/models/gpt-5.6-sol) lists context **1050000**, output **128000**, and efforts **none/low/medium/high/xhigh/max**. This model is not added as a seventh selectable alias.

## Auto-router calculation and boundaries

The membership supplied by the owner is GPT-5.6 Sol plus DeepSeek V4.1 Flash. Assuming either can receive any request:

```text
contextWindow   = min(1050000, 1048576) = 1048576
maxOutputTokens = min(128000, 393216)   = 128000
native efforts  = intersection(
                    {none, low, medium, high, xhigh, max},
                    {none, low, high, max})
                = {none, low, high, max}
app labels      = {off, low, high, max}
```

This is an intersection, not an average or sum. In particular, **128000 is not 131072**. DeepSeek also accepts compatibility aliases such as medium/xhigh mapped to high, but these are not native common effort semantics, so they are not advertised for the router. Equal effort labels do not imply equal reasoning compute across models.

With the current reserve calculation, this router leaves approximately `1048576 - 128000 = 920576` tokens for the estimated input, including instructions and tools. This is arithmetic on configured budgets, not a measured or provider-guaranteed optimal compaction threshold.

The catalog does **not** create `auto-router`, select an upstream provider, ensure compatible continuation, or configure reported-model headers. The gateway must already expose that exact alias and honor these limits on both selected backends and any fallback. Recompute the intersection if its membership changes. Keep the requested alias separate from the model reported for each response; do not overwrite the selection with the previous response's model. Provider-specific reasoning replay remains a separate app/gateway policy, particularly when the router changes models during a tool loop.

## Important current-app behavior

Reviewed files:
- [Catalog contract](../docs/Model-Catalog.md).
- [Parser and selection](../apps/macos/PiApp/Workspaces/ModelCatalogEndpoint.swift).
- [Request serialization](../packages/swift-host/Sources/PiAgentCore/Providers.swift).

The catalog's `reasoning` array controls the offered explicit effort choices. It is not the provider's `reasoning` JSON object and does not choose a default. “Model default” remains available; use that choice to omit an explicit effort. “Profile default” can inherit connection settings and should be reviewed when reusing an existing connection.

For this mixed-model catalog, use the app's **Responses API connection to LiteLLM**. The current Responses serializer sends named effort values (off becomes none). The Messages serializer can instead use fixed thinking budgets or adaptive-thinking options based on connection settings; the same labels must not be assumed to request identical native effort through that path. The installed gateway's adapters still need to support each selected model and parameter.

`maxOutputTokens` currently serves both as the outgoing maximum and as the output reserve. The DeepSeek entry uses its published 384K maximum, which reserves **393216** tokens, leaving **655360** tokens of its configured window before input is too large. For normal interactive work, lowering that entry to **131072** is a reasonable application policy, not a different model specification. The other entries retain the output values shown above; Kimi's default-based exception is deliberate. A future schema could separate published output ceiling, default request budget, and compaction reserve.

The current catalog cannot set input modalities, sampling parameters, routing policy, credentials, pricing, or thinking-level translations. Do not add unsupported fields and assume they take effect. For Kimi in particular, its official guide specifies fixed sampling values and recommends omitting those fields; clear incompatible inherited sampling overrides in connection settings. This catalog does not mutate those settings.

## Serve and use

No URL is needed for the included catalog in 0.1.10 and later. To replace it, serve your catalog at a **direct HTTPS URL** returning its JSON body, then set that URL as the connection's optional model-catalog endpoint. Alternatively, for local development only:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory catalogs
# Catalog URL: http://127.0.0.1:8765/bello-agent.models.json
```

The app supports HTTPS or loopback HTTP, refuses redirects, and bounds the response to 2 MiB. It only sends the gateway credential when the catalog shares the gateway's origin. A raw URL in this private GitHub repository is **not** a working anonymous catalog endpoint. Do not publish secrets or assume the app forwards GitHub authentication.

Catalogs are cached; refresh or reopen as described in the app's catalog contract. Existing chats keep their saved overrides until the user selects a catalog model again. Source files alone do not deploy the catalog or rewrite existing configuration.

## Verification and deployment acceptance

The generated file passes JSON syntax, exact alias/order, field/range, uniqueness, supported-effort and router-intersection checks against the reviewed schema. No complete macOS build or live gateway call was run for this metadata change.

Before treating the deployment as verified, inspect a small request for each alias at Model default and each intended explicit effort. Confirm the outgoing model ID, output cap, effort and endpoint in the app's debugger, plus a complete tool-call/result round trip. For auto-router, exercise both backend routes and model changes, verifying reported identity and continuation policy. Long-context capacity also depends on the actual serving route; advertising a limit in a catalog is not a successful boundary test.
