# Bello Agent 0.1.87 validation

Date: 2026-09-23. Version 0.1.87, build 91, arm64 macOS 14+.

## Changes

- **Instant sends.**
  - Return empties the composer and draws the message in the same frame, as the app's own row. Its id is the `clientTurnId`, so the helper's row takes over in place.
  - Typing into a chat whose helper stopped starts the helper. Draft and intent commit in one transaction, and nothing is dispatched before it is on disk.
  - Release medians, time to the message on screen: short chat 178 → 40 ms; 468 rows 346 → 65 ms; after the idle stop 1,154 → 62 ms.
- **Inline skills.**
  - Tokens lead the composer text, and pills show on sent messages. Display rows carry `skills` (additive).
  - A hover card after 450 ms, and a click opens a popover: source (Open, Reveal), scope, policy, version, and whether the skill changed since the message.
- **History and focus.**
  - The reader's own edit adopts its new branch instead of being reported as an outside change.
  - History pages load without strips: a spinner after 300 ms, and Retry only on a failure. Stuck loading states are cleared.
  - Tool rows draw their own focus over the whole row. "Ask in side chat" is a compact bar on the app's surface.
- **Context counted as pi counts it.**
  - The count follows pi 0.85.1 `estimateContextTokens`: the last valid reply's reported total, plus ceil(chars/4) (UTF-16) for the messages since, with images at 4,800 characters.
  - It is pending after a compaction until the next reply. Compaction triggers at window − 16,384, pi's `reserveTokens` (capped at half the window).
  - Requests no reply has measured keep the conservative request sizing.
- **Nothing lost across quit and relaunch.**
  - Quit never erases a saved draft it never loaded, and a side's unsent text moves to its parent.
  - Stop and Quit waits for the helpers, so the partial reply and the stopped run are journaled. After stdin EOF the helper stops writing instead of exiting 70.
  - Reading positions older than the newest window are kept, and the landing no longer drifts.
  - Interrupted runs and paused follow-ups come back as they were left.
  - A cut-off journal opens read-only with Recover Copy (`session.recover`).
  - A moved project folder is named, with Locate Folder…
  - Also kept: the zoom, the report section, Session info's frame, queue rewrites, the background-tasks toggle and the report page. Interrupted titles resume, and a never-sent chat's connection switch writes nothing.
- **Tests:** a bounded arrival-jitter tolerance in one helper timing test; a stale incomplete-tail assertion restated; the gallery clears the follow-up an earlier scene paused.

## Evidence

- **Debug whole suite** (Xcode 16.1, Swift 6): 1,506 tests, 22 skipped, 1 failure. The failure was a stale assertion that a cut-off journal cannot be read. It was restated to the new read-only behaviour, and its class reran green (19/19).
- **Gallery:** `UIScreenshotTests` passed with 76 screenshots in light and dark, after the scene-order fix.
- **Helper:** `swift test` 357/357; wire tests 27/27; concurrent wire and acceptance OK; Python script tests 53/53.

## Release provenance

- **Source:** tag `v0.1.87`, one release commit on GitHub. The DMG was built from the local candidate `e6de350`, with native tree `c4e99e50b810c3d553c6c17b84481fe7b5b82d7f` and helper tree `dff07aa6a6f739e897a347a98ad33d37c422f81d`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `e3bb95647152ba875db831e8903786bcdc6013f5`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `5bfece05-90f3-4e00-9249-d967ccb1e3f2`; DMG `fb1eb88c-b963-4694-8c32-948245b9296e`.
- **Public verification** at **2026-09-23 12:07:06 UTC**: the product page advertises 0.1.87, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,246,118 bytes (9.77 MiB)**; SHA-256 `b52be05e7987ac6bf5ff6639021240c5edaf49a12441e62d719ab13e47b77a8b`.
- **Download:** [Bello Agent 0.1.87](https://belloware.com/assets/BelloAgent-0.1.87.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
