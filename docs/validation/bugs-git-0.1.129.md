# Git review findings — 0.1.129 (bugs-git workstream)

Branch `dev/a129-bugs-git` from `dev/next` a2691e9c. Build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-bugs-git`; logs named below are in
its `logs/` folder. Source: the external review of 2026-10-16 (reviewed commit
9d4123f6), findings BUG-001, BUG-006, BUG-007 and BUG-008. All four reproduced on
this branch and are agreed to be bugs. Fixtures are generated temporary
repositories (fixture identity, signing off, empty hooks); no network, no real
preferences, no installed app.

## Findings and fixes

| Finding | Reproduced (failing-first, `red-all-five.log`) | Fix | Mutation (`mutation-*.log`) |
| --- | --- | --- | --- |
| BUG-001 Drop/Pop can remove a different stash | A stash pushed after the final `rev-parse` check (new `afterVerification` test hook) was the one Git dropped; the reviewed one stayed and the newcomer's entry was gone (2 entries left of 3). | After native `git stash drop`, `confirmDropped` compares Git's "Dropped … (<oid>)" with the reviewed OID and the reflog after the drop with the reviewed reflog (entries compared without the old-value field that `--rewrite` changes). Success needs the reviewed entry gone and the reported OID to be the reviewed one. A different reported OID is stored back with native `git stash store -m <its subject>` and the drop is refused ("…stored again as the newest stash, and the stash you chose was kept"); if storing fails the message names the OID and the terminal command. A reported reviewed OID whose entry is still listed is refused as unconfirmed. Pop shares this path, so it reports "Stash applied, but it was kept: …". | `confirmDropped` check replaced by `return`: 4 failures (`mutation-bug001.log`). |
| BUG-006 Discard fails before the first commit | `fatal: could not resolve HEAD`; nothing changed. | Before the first commit `discard` first proves the branch is genuinely unborn (`isUnbornBranch`): HEAD is a symbolic ref to `refs/heads/…`, `rev-parse --verify --quiet HEAD` answers "missing" (1), and `for-each-ref` lists nothing with no diagnostics. Then only the chosen tracked rows go through native `git rm -f -q --ignore-unmatch -- :(literal)…` (index and working tree, as `restore` does against HEAD for a path HEAD lacks), and chosen untracked rows through `clean` as before. Anything else refuses with "HEAD could not be read. Nothing was discarded." Unstage now uses the same check; before, `show-ref --verify --quiet` answered 1 for both a missing and a damaged loose ref. | Unborn branch disabled: the original error (`mutation-bug006-unborn.log`). Guard replaced by `true`: 6 failures, the chosen file's index entry removed under a broken ref (`mutation-bug006-guard.log`). |
| BUG-007 `XDG_CONFIG_HOME` dropped | Commit with the only identity under a custom XDG folder: "Author identity unknown". | `GitService.gitEnvironment(from:home:)` builds the child environment from the app's: the fixed five values plus a nonempty `XDG_CONFIG_HOME` (FileFinder's rule). Nothing else is inherited, so `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_CONFIG_*` never reach git. The service keeps the built environment per instance (`init()` uses the process environment; an internal `init(environment:)` serves the test). | XDG line removed: 2 failures (`mutation-bug007.log`). |
| BUG-008 Recreated file shows an empty unstaged diff | Staged deletion + untracked recreation: the unstaged row's diff stayed empty (`git diff` routed as tracked). | The diff load picks the row in the selected section (`staged` for a staged selection, `unstaged` for an unstaged one), falling back to the path. | Path-only lookup restored: 2 failures (`mutation-bug008.log`). |

## Tests

New, in `packages/bello-views/Tests/GitViewTests`:

- `GitStashTests.testStashSavedAfterFinalCheckIsNeverTheOneDropped`: reviewed stash at
  `stash@{0}` and at `stash@{1}`; a concurrent `stash push` after the last check. The
  drop refuses, all three stashes remain with their messages, the newcomer's bytes
  are intact.
- `GitReviewFindingsTests.testDiscardBeforeTheFirstCommitRemovesOnlyTheChosenAddition`:
  two staged new files (the chosen one also edited after staging) and one untracked;
  only the chosen file leaves index and disk.
- `GitReviewFindingsTests.testDiscardRefusesWhenTheBranchIsBrokenRatherThanUnborn`:
  a damaged loose ref, a loose ref naming a missing commit and unreadable packed refs;
  nothing is removed.
- `GitReviewFindingsTests.testGitKeepsTheAppsXDGConfigurationButNotRepositoryOverrides`:
  builder keeps XDG, drops every repository/config override, ignores an empty XDG;
  a commit through `GitService` with a scratch `HOME` gets the XDG-only identity.
- `GitReviewFindingsTests.testRecreatedFileShowsItsOwnPatchBesideTheStagedDeletion`:
  through `GitController`, the unstaged row shows `+new unstaged contents` and the
  staged row `-committed contents`.

## Decisions and limits

- BUG-001: Git's stash drop cannot be run under a lock this app holds, so the
  approval check still is not atomic with external writers. The guarantee is now
  after the fact: a wrongly dropped entry is detected and stored back, and the
  reviewed stash is kept. A stored-back entry becomes the newest stash with a new
  reflog date; its commit, message and contents are unchanged. One window is left
  inside Git itself: `git stash drop` resolves the selector, then counts the reflog,
  then locks it, all unlocked; a push in those microseconds inside one Git process
  can make Git report the reviewed OID while removing the newcomer. That case is
  detected (the reviewed entry is still listed) and refused, but the newcomer's OID
  is not known to restore it; its commit stays in the object store until garbage
  collection. No custom ref or reflog writing was added.
- BUG-006: the discard question's text ("Tracked files revert to HEAD…") is unchanged:
  a staged addition reverts to "no file" both before and after the first commit, so
  no UI changed and no gallery was needed.

## Validation

| Check | Result | Log |
| --- | --- | --- |
| Failing-first, the five new tests before the fixes | 5 of 5 failed | `red-all-five.log` |
| New tests + all stash tests after the fixes | 22 passed | `green.log` |
| Complete views package | 312 tests, 3 skipped, 0 failures | `package-all.log` |
| `scripts/verify-release.sh` (shared lock) | GATE_RESULT | `verify.log` |
