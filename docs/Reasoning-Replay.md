# Reasoning sent back, and the question when a provider refuses it

Since 0.1.138. Owner, 2026-11-11: "encrypted reasoning should be not ignored… unless it got rejected by litellm due to model switch, which then we need user confirmation to proceed with previous encrypted reasoning removed or something like that, while keep new encrypted reasoning". And: "It has to be backward compatible."

Design reviewed by Astra, 2026-11-12. The boundary rule is the same as Bello Hub's.

## What was wrong

Every request asks the provider for encrypted reasoning and every reply is stored with it, but until 0.1.137 it was hardly ever sent back:

- A connection's "Reasoning continuation" policy was `portable` for every new connection (onboarding and Settings both wrote it). Under it no reasoning went back at all, not even to the same model between two tool rounds of one turn. Nobody chose it.
- A connection with no policy (`ask`) did not ask: once a chat held reasoning it refused to build the next request (`opaque_replay_policy`).
- A reply written before a connection move, or under a per-turn model override, went as text and tool calls.
- `pinned` did send, but stopped after the first tool call on every route except direct OpenAI: LiteLLM's `x-litellm-model-name` header names the model with its provider prefix (`gemini/gemini-3.5-flash-lite`) and the response body names it bare, which was read as two models.

Live, a Gemini 3 model whose signature travels in a reasoning item failed mid-task without replay, three runs of three, and finished with it.

## The rule

A connection behaves in one of three ways (`Profile.reasoning`):

| Choice in Settings | Meaning |
|---|---|
| **Send reasoning back** (default) | Reasoning a reply was stored with goes back with every later request, whatever model, alias or connection the request goes to. A provider that refuses it is the owner's question. |
| **Never send reasoning back** | Text and tool calls only, and no thought signature inside a call id. The owner's explicit choice. |
| **Preserve native state on a fixed route** | 0.1.137's pinned route, with its strict checks. Replies from outside the route go as text and calls, as before. |

**Only replies stored from 0.1.138 on are sent back with their reasoning.** The helper marks a reply when the request that produced it ran on a sending connection (`ChatMessage.reasoningReplay`, saved as `nativeReasoningReplay`). A reply without the mark is sent exactly as 0.1.137 sent it. So for an existing chat nothing about its existing rows changes: no rewritten prefix, no cache miss, no sudden growth by months of stored blobs. Its new replies carry their reasoning.

What goes back for a marked reply (`ProviderClient.replay(of:profile:)`):

- its reasoning items, as received, each before the text or calls it led to;
- its message and call items, rebuilt as the native path always rebuilt them;
- to **another model**, a call id over 64 bytes goes as a short derived name (OpenAI's limit, since 0.1.136) and a `function_call` item id over 64 bytes is not sent. Not to another **Gemini** model: it reads the signature LiteLLM keeps in a Gemini call's id (3.5 and 3.1 took each other's), so it gets the id whole. A request goes to a Gemini model when its name contains "gemini" (Bello Hub's only test), or, for an alias that says nothing, when the gateway reported a Gemini model for that alias's own replies in the chat or one of them made such an id. A target wrongly taken for Gemini refuses the long id, which is then the owner's question (`signedCallID`).

A model switch A → B → A therefore looks like this on the wire: B's request carries A's reasoning items; B's reply is stored with B's; back on A the request carries A's own and B's. Most gateways drop what the target cannot use (50 of 50 ordered pairs through OpenRouter were accepted); a provider that refuses is asked about, below.

"Never" also names the calls of its own model by a signature-free id, old rows included: a signature in an id is reasoning.

## What changes for an existing connection and chat

- A connection saved with `portable` or `ask`, or with nothing, **sends reasoning back from its next reply on**. Settings shows it as "Send reasoning back". Nothing is rewritten on disk until the owner saves the connection.
- A connection the owner had deliberately set to "Portable text and tool history" reads the same way, because the stored value cannot tell a choice from the default. "Never send reasoning back" has to be chosen once more.
- A pinned connection is unchanged, except that it now works where the gateway's header and body name the model differently.
- A chat that could not go on under `ask` goes on: its old replies from text and calls, its new ones with reasoning.
- Requests grow by the reasoning of the replies made from now on (a few hundred to a few thousand characters each), which the context count already includes (0.1.137).

## What an older build reads

0.1.137 accepts three `routing.replayPolicy` values, a closed set of routing keys, and no advanced field it does not know. So:

- "Send" and "Never" are both saved as `routing.replayPolicy: "portable"`. "Never" adds the connection record's own field, `ProfileRecord.reasoningReplay = "never"`, outside the advanced settings; the helper gets it as the profile's top-level `reasoningReplay`.
- 0.1.137 opens such a connection as portable history: it sends no reasoning, as it always did. If it **saves** the connection it drops the field; back on 0.1.138 a "Never" then reads as "Send".
- The reply mark, the `pi-app.reasoning-withheld.v1` journal record, the `reasoningRejection` and `reasoningRetry` state fields and the checkpoint's `reasoningWithheld` are unknown to 0.1.137, which skips them. A held refusal shows there as an ordinary failed run with Retry.
- If 0.1.137 rewrites a checkpoint and the chat returns to 0.1.138, the journal records are read again only on a full replay; a chat resumed from that checkpoint may ask its question once more.

## Recognising a refusal

`ReasoningRejection`. LiteLLM never refuses reasoning itself: it passes the provider's text on inside `error.message`, with `error.code` "400" and escaping that varies by route (pretty JSON, compact JSON, escaped twice inside OpenRouter's `raw`, a Python `b'…'`). A streamed request fails as HTTP 400 JSON before any event, or as HTTP 200 with a `response.failed` event (LiteLLM's Gemini bridge), an `error` event or a bare `{"error":…}` frame. The rules read substrings of the message, case-insensitively, on a 400 or a failure frame; never a parsed structure, and never a server error.

| Rule | In the message | Provider |
|---|---|---|
| encryptedContent | `invalid_encrypted_content` (also as a failure frame's code), or `could not be verified` with `encrypted content` | OpenAI, Azure |
| organization | `organization_id did not match the target organization` | OpenAI, Azure: another key, organization or region; the route changed |
| undecryptable | `could not be decrypted or parsed` | OpenAI: foreign or damaged |
| thinkingSignature | `invalid .?signature.? in .?thinking.? block` | Anthropic, on every host |
| thoughtSignature | `Corrupted thought signature`, `Invalid thought signature` | Gemini (AI Studio, Vertex) |
| affinity | `encrypted_content_affinity`, or "This error occurs when load balancing Responses API across deployments with different API keys" | LiteLLM's help, appended on `openai/` and `azure/` routes |
| signedCallID | `string too long` with `call_id` and `maximum length 64` | OpenAI, only when the request named a call by an id with `__thought__` in it |

Not a refusal of reasoning: "Function call is missing a thought_signature", "Base64 decoding failed", a 5xx internal error, "was provided without its required 'reasoning' item", and anything else.

It counts only when the refused request did carry earlier reasoning, read from the request's own projected input (`ProviderClient.carriesReasoning`): an encrypted or signed reasoning item, or a call named by an id with `__thought__` in it. A refusal is never retried as a transient error and is not an overflow.

## The notice and its one button

Owner, 2026-11-13: "try to make the UX even more intuitive and better". One step, the same design as Bello Hub's.

The run ends as a failed run with the code `reasoning_rejected` and the question kept with it (`reasoningRejection` in the saved state and the snapshot: an identity, the notice's words, the rule, the provider's own sentence, the model that refused, whose reasoning it is). Nothing is retried. Being a failed run it survives a relaunch: the notice is there again with its button, and nothing comes up by itself, at launch or when the refusal arrives. The chat is marked as any stopped run is.

The notice in the transcript answers what happened, what is lost and what to press:

- **Title:** "{model} can't use the earlier reasoning"
- **Body**, when other models wrote it: "Its provider refused the hidden reasoning saved from earlier replies by {origin model(s)}. Your messages, the replies and the tool results are all still sent."
- **Body**, when it is its own (nobody else's was in the request: its key or route changed): "Its provider refused the hidden reasoning saved from its own earlier replies; its key or route has probably changed. Your messages, the replies and the tool results are all still sent."
- **Under the body, quietly** (the notice's detail line): "Switching back to {origin model} keeps its reasoning.", only when another model of this connection wrote it; and "Provider's message: {the provider's own sentence}".
- **One button: Continue without earlier reasoning.** It acts at once; pressing the clearly named button is the confirmation. There is no sheet and no Stop button: the turn is already stopped, and stays so until the button is pressed or a new message is sent.
- Model names are the aliases the model picker lists.

The helper's failure message carries the same words (title on the first line, then the body, then "Provider's message: …"), so a notice read from the journal before the helper has the chat reads the same; pressing its button fetches the question from the helper first, and the answer goes with the question's identity.

**Continue** (`turn.retry` with `withoutEarlierReasoning: {rejection: <id>}`) means "{model} goes on without whatever earlier reasoning its provider refuses":

- The answer must be for the question that stands; otherwise `reasoning_confirmation_stale` and nothing changes.
- **It is saved for the model that refused**, on that connection. A journal record (`pi-app.reasoning-withheld.v1`: the route, the replies, whether they are the model's own, the rule) is written and synchronized before anything is sent. The replies it names go to that model without their reasoning from then on: no reasoning item, no `fc_` item id (OpenAI refuses a call "without its required reasoning item"), a signature-free call id on the call and on its output alike, and no reasoning summary as text. That holds whatever the connection's policy: a pinned route's own state can be refused too.
- **First without the reasoning other models wrote** (or the same alias on another connection). The model keeps what it wrote itself, unless the request carried no one else's.
- **If that request is refused too, once more without the model's own**, without asking again: a second record says what was added. If that is refused as well, it is the provider's ordinary error. One question per refusal, never a second.
- **A model that never refused gets everything**, so switching back to the model that made the reasoning recovers the chat, with its cached prefix.
- **Everything made after** is sent to the refusing model whoever wrote it. If it refuses that, it is a new notice; nothing is left out unasked.
- **A model chosen while the notice waits** gets a notice of its own if it refuses: the answer and its retries belong to the model that refused.
- No tool runs again, and no refusal is retried as a transient error. A reply of the model, or a new task, ends the count.
- Stored history is never rewritten.

**After Continue** the notice is gone and one quiet line stays in the transcript: "Continued without earlier reasoning · {model}", or "Continued without earlier reasoning, including its own · {model}" when the answer was about its own. When the second step happens, a line of this app's transcript cannot be rewritten, so a second one is added: "Continued without its own earlier reasoning too · {model}". Sending a new message instead leaves the refusal as a past failure without a button; a refusal of the new request brings a new notice, so a chat never has two live buttons.

The connection-switch question ("Earlier reasoning from X can't be sent to Y. Switch anyway?") stays, and is asked only when the new connection would not send what the old one sends: the new one is set to "Never send reasoning back", or the chat leaves a pinned route. It is a sheet at the moment of switching and is not kept across a relaunch; nothing was switched if the app quit while it was up.

## Compaction, forks, agents

- The summary request is built by the same projection, so what is withheld from a model is withheld there. A summary request refused for its reasoning is the same question, not "a summary paid for and not adopted": the task's automatic compaction is not written off and no failed-compaction record is kept. After Continue, whether a summary is still needed is worked out again before the request goes, and one may be paid for.
- A manual compaction of an idle chat that is refused shows as that compaction's failure: there is no request to send again, so nothing is offered. The question comes with the next turn's request.
- The context preview and the meter of an idle chat read the same projection as a request.
- Checkpoints, `continuationText` and kept rows are untouched.
- A fork, a side chat and a Codex-style sub-agent started from a chat inherit what its models are no longer sent, as it stood then, with their origin (`reasoningWithheld` in the fork's or side's origin record and in `SubagentOrigin`). A fork cut before the answer was given has it all the same. An answer given in a side chat that has no journal yet is written into the journal it gets when it is kept.
- A sub-agent has no one to ask: a refusal inside it is its turn's failure, with the same title and body ("{model} can't use the earlier reasoning…") and the provider's sentence, so the parent's view of the failed sub-agent says what it was. Its notice has no button.
- The Codex runtime owns its requests; none of this applies there.

## Known limits

- A connection's "Never" does not survive a save by 0.1.137 (above).
- A sub-agent cannot be continued without its inherited reasoning; the parent's Continue has to come first.
- A crash between the journal record and the request leaves the chat stopped as an interrupted run; going on from there sends the request without the withheld reasoning.
- What OpenAI, Google and Anthropic do with another model's or account's reasoning on direct routes is not determined; the rules above are what was observed through OpenRouter and against a stand-in.
