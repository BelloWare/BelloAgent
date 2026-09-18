# Issue: chat model picker lists a stale catalog after a custom catalog URL is saved

Reported: 2026-09-16. Observed at `f9f0593` (Bello Agent 0.1.16). Found by read-only review; no code was changed.

## Resolution in 0.1.18

Review of the complete save path found that `inheritCatalog` already handles the
new same-gateway, same-credential alias/catalog save described below. Its
integration test saves that change and verifies the original chat refreshes the
new URL. The original diagnosis omitted that call. Existing records without a
catalog binding still have the reported symptom, and Refresh cannot infer which
independently saved list they should follow.

The chat picker now detects a different custom catalog in a later saved
connection for the same gateway and makes the difference visible beside the
current source. **Use this catalog** immediately saves the binding and loads its
models; multiple alternatives get an explicit chooser. Detection does not rely
on `profileChoice`, since opening a chat resets that value to the original route.
It does not silently merge independent connections. Explicitly linked lists are
respected, and unrelated gateways are excluded from the suggestion.

The action preserves the chat's request connection, credentials, selected model,
effort, output budget, and history. It persists across restart, and subsequent
Refresh uses the selected source. The existing **Catalog source…** menu remains
available for deliberate selections outside the suggested matches. Tests cover
the original save flow, legacy repair/restart, multiple/duplicate sources and
the actual mounted picker's text and replacement model rows.

The original investigation follows for context.

## Symptom

A user sets a custom model catalog URL on their connection.

- The **Settings** model picker lists the new catalog correctly.
- The **chat composer** model picker keeps listing the old models.
- Pressing **Refresh** in the chat picker does not help.

## Cause

The two pickers resolve **different saved connection records**, so the chat picker is refreshing a different catalog URL.

1. `apps/macos/PiApp/Workspaces/WorkspaceConfiguration.swift:81-84` — `saveProfile` treats a change to `api`, `baseUrl` or `modelId` as a route change and assigns a **new connection id**. Adding a catalog URL alone does not trigger this, but selecting a model from the new catalog changes `modelId`, which is the usual next step.
2. `WorkspaceConfiguration.swift:88-89` — the save appends when no id matches, so the **old connection record stays in the vault** with its old `catalogUrl` or none.
3. `WorkspaceConfiguration.swift:103` — only `profileChoice` is updated, which affects **new** chats. Nothing repoints existing chats.
4. `apps/macos/PiApp/Workspaces/ModelSwitchControls.swift:14` — the chat picker resolves its connection by `chat.profileID`, which still points at the **old** record.
5. `ModelSwitchControls.swift:152-153` and `apps/macos/PiApp/Workspaces/WorkspaceCatalogSources.swift:59` — the picker then reads that old record's catalog URL.
6. `ModelSwitchControls.swift:168` and `apps/macos/PiApp/Workspaces/ModelCatalog.swift:242` — Refresh calls `refreshModels(profileID:)` with the old id. It correctly reloads the vault and forces a fetch past the one hour cache, but it fetches the **old URL**. The button works; the input is wrong.

## Reproduce

1. Create a connection and start a chat on it.
2. In Settings, set a custom catalog URL on that connection **and** pick a model from the new catalog, so the alias changes. Save.
3. Open the Settings picker. New models appear.
4. Open the chat's model picker. Old models appear. Press Refresh. Still old.

## Confirm quickly

The chat picker header shows the connection name and the catalog host and path actually in use, built by `ModelSwitchControls.swift:290`. If it shows a different host, or "Included with Bello Agent", while Settings shows the custom URL, this is the issue.

## Existing workaround

The chat picker has a **"Catalog source…"** menu that rebinds that connection's model list to another connection's catalog, without changing the request route, credentials or selected model. See `WorkspaceCatalogSources.swift:68`, whose comment describes it as the explicit repair for older chats whose connection predates a custom catalog. It only appears when more than one Responses connection exists.

## Already ruled out

- **Not HTTP caching.** `ModelCatalogEndpoint.swift:119-129` uses an ephemeral `URLSessionConfiguration` with a fresh session per fetch.
- **Not the TTL.** Refresh passes `force: true`, which skips the freshness check in `ModelCatalog.load`.
- **Not a cache key mismatch.** When `cachedProfiles[id]` does not equal the profile, `ModelCatalog.entry(for:)` returns an empty entry, which renders as "No models are listed by this connection". That is a different symptom from stale rows.

## Suggested directions

Not prescriptive; the tradeoffs are the implementer's call.

- **Make it visible.** When a chat's connection is not the current `profileChoice`, or its catalog differs from the newest record for the same route, say so in the picker and offer a one-click rebind. Lowest risk.
- **Repoint on save.** When `saveProfile` mints a new id, offer to move existing chats on the old record to the new one. Changes history semantics, so it needs a decision about what a chat's recorded connection means.
- **Stop minting new ids.** Version connections instead of duplicating them, so a chat references a stable connection with a revision history. Largest change, removes the whole class of problem.
- **Whatever is chosen**, a regression test should cover: save a connection with a changed alias plus a new catalog URL, then assert the existing chat's picker either follows the new catalog or surfaces that it is not.
