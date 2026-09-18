# Model catalog endpoint

Bello Agent includes the reviewed [six-model catalog](../catalogs/bello-agent.models.json)
in its signed application bundle. It is the default for every connection without
a custom catalog URL, including saved connections from earlier releases. Loading
it is local and does not read the gateway key or call `/v1/models`.

A connection can name an optional **custom model catalog URL**, which replaces
the bundled list. The endpoint is yours: an HTTPS URL (or explicit loopback HTTP)
that returns the JSON below. A catalog on the gateway's same origin (scheme, host and port) receives
`Authorization: Bearer <key>`. External catalogs are fetched anonymously and do
not read the saved gateway key. Separate catalog credentials are not supported.
URLs cannot contain embedded credentials or fragments. Redirects are refused,
requests time out after eight seconds, and responses are capped at 2 MiB and
2048 models. Cookies and shared credential storage are disabled.

## Response

```json
{
  "version": 1,
  "models": [
    {
      "id": "gpt-5.1",
      "name": "GPT-5.1",
      "description": "Default coding model behind the team router.",
      "contextWindow": 400000,
      "maxOutputTokens": 128000,
      "reasoning": ["minimal", "low", "medium", "high"],
      "deprecated": false,
      "order": 1
    },
    {
      "id": "claude-sonnet-4.5",
      "name": "Claude Sonnet 4.5",
      "contextWindow": 200000,
      "maxOutputTokens": 64000,
      "reasoning": ["off", "low", "medium", "high", "max"]
    },
    { "id": "gpt-4.1", "name": "GPT-4.1", "deprecated": true },
    { "id": "utility-small", "name": "Fast utility model", "mini": true }
  ]
}
```

A bare array of model objects is accepted too. An object may omit `version`;
when present, only version `1` is supported.

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | The alias sent to the gateway as `model`. Unique, ≤200 UTF-8 bytes, no control characters. |
| `name` | no | Display name; defaults to the id (≤2 KiB kept). |
| `description` | no | Shown under the name in pickers (≤2 KiB kept). |
| `contextWindow` | no | Context capacity in tokens, an integer from 2 through 10,000,000. Aliases `context_window`, `context`. |
| `maxOutputTokens` | no | Supported model output ceiling, an integer from 1 through 1,000,000. Stored as `modelOutputLimit` on profiles/chats; it does not become the requested output budget. The budget is separately clamped below context capacity and within this ceiling. Aliases `max_output_tokens`, `maxOutput`. |
| `reasoning` | no | Accepted efforts: any of `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`. An object with an `efforts` array is also accepted. Omission means unknown support; `[]` means no explicit effort. Unknown entries are ignored and duplicates collapse. |
| `deprecated` | no | Hidden from pickers unless a chat already uses it; shown with a badge then. |
| `order` | no | Integer sort key; lower first. Equal keys preserve array order; entries without it follow all ordered entries. |

The optional boolean **mini** marks a recommendation for inexpensive auxiliary
work, initially automatic session titles. The first active recommended entry
is the catalog default; omission means no recommendation.

## Ordering and defaults

Version 0.1.9 and earlier shipped the catalog source file only in the repository;
connections without a custom URL still used gateway discovery. Version 0.1.10
fixes that missing default path. No vault migration or URL entry is needed.
Existing connection aliases, session choices and remembered reasoning efforts
stay unchanged; an unlisted selected alias remains explicit until changed.
The bundled catalog updates with app releases. Its presence does not establish
that a particular gateway deploys those aliases; onboarding still verifies the
selected alias with a small Responses request.

The first non-deprecated model is selected during first-run setup when no alias
has been entered. Existing aliases are preserved. A chat with no override uses
its saved connection's model; refreshing a catalog never changes that default.

New ordinary chats remember the last model and reasoning effort deliberately
chosen in a session using the same connection, across projects and app restarts.
The chosen model's catalog limits travel with it. A different connection keeps
its own choices; opening an older chat does not reset them. Explicit Profile
default and Model default choices remain distinct. The current chat and remembered
choice save together, and New Chat waits for a pending picker save. For existing
installations without a remembered choice, the current session supplies the
initial defaults when it uses the same connection. Other existing chats are
unchanged. First-run setup and connection tests use the connection being tested;
sides and forks continue to inherit their parent.

Selecting a catalog model in setup or Settings fills the connection's published
context and output limits. Selecting one in a chat stores limits with that chat's
model override and sends them with each turn, including compaction. Side chats
inherit those overrides. The shared connection is unchanged. An omitted limit
uses the connection's value; with partial metadata, the output limit is capped
below the effective context. Manual aliases without catalog metadata use
the connection limits. Choose the model again after a catalog refresh to adopt
updated metadata; saved chats do not silently change.

The effort menu offers the model's known efforts, **Profile default** (inherit
the connection, when compatible) and **Model default** (send no explicit reasoning/effort). A
catalog model selection resets an incompatible inherited or previous effort to
Model default. A model declaring `reasoning: []` always selects Model default.
In Settings, selecting a model also updates its reasoning capability and clears
incompatible effort defaults and mappings from the previous model.

## Mini model

The connection's **Mini model** picker is separate from its conversation model.
Choose any listed model explicitly, or **Use catalog Mini default** to use the
first non-deprecated entry marked Mini. Without an explicit choice or a catalog
recommendation, no automatic title request is sent. There is no fallback to the
conversation model.

The explicit choice is saved as the optional connection field **miniModelId**.
Selecting or clearing it does not alter the main model, context/output limits,
reasoning preferences, or remembered new-chat choices. Auxiliary title requests
use the chosen descriptor's limits and a bounded output budget; their requests,
accounting, and results are retained in a separate title-generation session.
Existing connections and catalogs without either new field continue to load.

## Failure behaviour

A configured catalog is the only model source: the gateway's `/v1/models` list
is never consulted for that connection. If the catalog cannot be fetched or
parsed, the picker shows the error, keeps the last list it loaded (if any) and
lets you type an alias; a malformed catalog URL is reported the same way. A
failed fetch is not retried for thirty seconds unless you choose Refresh.

Catalogs are cached for five minutes per connection and loaded lazily when that
session's picker appears, without requiring a hover. Saved connection changes
reload its picker; other connections are not prefetched. Opening the live native
picker checks that cache again, including keyboard opening after five minutes.
Explicit Refresh reloads saved configuration and the connection’s catalog binding,
then forces a fetch with HTTP cache revalidation. It displays the successful
refresh time; the bundled source explains that its models change with app updates. It shows progress through configuration reload and network
fetch, updates the open list, and reports configuration failures inline. It
never retargets a chat to a different connection. Passive catalog loading keeps
its existing credential rules. The composer and Settings use the same searchable list;
all catalog entries are accessible by scrolling or searching, without an
80-model cutoff. Results update while the picker is open. The source shows the
saved connection name and catalog host/path, omitting URL query values.
An existing/manual alias missing from the catalog remains selected, but is not
inserted into the catalog results.
Connections without a custom URL load the bundled catalog once per saved
connection revision, with explicit Refresh available. A missing/corrupt bundled
resource shows an error rather than querying the gateway. Cache identity includes the saved connection revision and catalog
URL; obsolete requests cannot replace newer results. Settings requires changed
endpoint/catalog URLs to be saved before browsing.

Existing chats retain their own saved connection. Changing a connection's API,
gateway URL or default model creates a new connection to preserve those chats'
route and credentials; it does not repoint old sessions to the new catalog.
Editing only the catalog URL on the chat's connection refreshes its list.

## Catalog selection and preserved connections

Version 0.1.14 separates the offered list from the request connection. In the
chat model picker, **Catalog source…** can select another saved connection's
catalog. This is useful for older chats left on a preserved connection when
Settings created a new default-model connection. Selection is saved for chats
using that connection, survives restart and updates open pickers. Requests keep
their connection ID, endpoint, credentials, selected alias, effort and limits.
Choosing a model remains the deliberate action that adopts its metadata.

The optional vault `catalogSources` dictionary contains flat references between
saved profiles, without chains or cycles. Lists and model metadata use the chosen
source's own origin/credential rules; an external catalog never receives either
connection's key. Settings and mini-model recommendations use the same source.
Editing a linked connection's own catalog URL detaches it from that source.

New default-model forks created with unchanged API, gateway, key and headers
keep their catalog linkage, including URL edits made in the same save. Gateway,
API or credential differences do not establish that linkage. Credential-only
edits retain the existing same-connection behavior. Older records have no reliable
lineage: neither array order nor the current Settings selection is treated as
proof that two catalogs belong together. Those chats can choose the intended
saved catalog explicitly. Saving a source selection never sends a model request.
