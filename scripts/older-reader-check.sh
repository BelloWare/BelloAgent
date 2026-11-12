#!/usr/bin/env bash
# An earlier release's helper opens a chat and a connection this checkout
# wrote (owner, 2026-11-11: "It has to be backward compatible").
#
#   PI_BUILD_ROOT=/scratch scripts/older-reader-check.sh [v0.1.137]
#
# 1. This checkout's ReasoningQuestionTests leave a chat (journal, checkpoint,
#    connection) in $PI_BUILD_ROOT/older-reader/export, and its OverWindowTests
#    one with an over-window notice in $PI_BUILD_ROOT/older-reader/export-window.
# 2. The named release is checked out beside it, given
#    fixtures/native/older-reader/OlderReaderTests.swift, and its helper's
#    tests read that chat. The checkout and its build are removed afterwards.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PI_BUILD_ROOT:?Set PI_BUILD_ROOT to a scratch directory outside the repository}"
RELEASE="${1:-v0.1.137}"
WORK="$PI_BUILD_ROOT/older-reader"
export PI_REASONING_COMPAT_OUT="$WORK/export"
export PI_OVERWINDOW_COMPAT_OUT="$WORK/export-window"
rm -rf "$WORK/export" "$WORK/export-window"; mkdir -p "$WORK"
cd "$ROOT"
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --filter 'ReasoningQuestionTests/testARefusalAfterAModelSwitchIsAskedAboutAndContinueLeavesTheEarlierReasoningOut'
test -f "$PI_REASONING_COMPAT_OUT/export.json"
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --skip-build \
  --filter 'OverWindowTests/testAReopenedChatDoesNotRepeatTheTasksNotice'
test -f "$PI_OVERWINDOW_COMPAT_OUT/export.json"
TREE="$WORK/tree"
cleanup() { git -C "$ROOT" worktree remove --force "$TREE" >/dev/null 2>&1 || true; rm -rf "$WORK/build"; }
trap cleanup EXIT
git -C "$ROOT" worktree remove --force "$TREE" >/dev/null 2>&1 || true
git -C "$ROOT" worktree add --detach "$TREE" "$RELEASE" >/dev/null
cp "$ROOT/fixtures/native/older-reader/OlderReaderTests.swift" "$TREE/packages/swift-host/Tests/PiAgentCoreTests/"
swift test --package-path "$TREE/packages/swift-host" --scratch-path "$WORK/build" --filter OlderReaderTests
echo "$RELEASE reads what this checkout writes."
