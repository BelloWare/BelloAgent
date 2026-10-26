# Local model catalog hotfix — validation

2026-10-27. Branch: `dev/a132-local-catalog`, based on released 0.1.131
(`df38fe1f`). Owner request: accept a local version of a connection's custom
model catalog. This record follows the workstream's `r131/rules.md`; the owner's
hotfix overrides exclude full native lanes, mutation runs and measurements.

## Cause and change

`ModelCatalogEndpoint.url` accepted only HTTPS and loopback HTTP, and its loader
always used URLSession. It now accepts `file://` URLs, absolute paths and expanded
`~/` paths; relative paths remain malformed. Local file URLs have no credentials,
query, fragment, port or remote host.

A detached task reads at most the catalog byte limit plus one byte and runs the
existing parser. This preserves the 2 MiB, 2048-model and field validation limits.
File errors use the existing failure reporting. The shared `ModelCatalog` cache
already retains the last good list beside errors, uses the five-minute refresh
and thirty-second failure backoff, supports forced refresh and invalidates on
field edits; no cache changes were needed. File sources bypass credential lookup
and key validation entirely. Settings, setup and error copy mention local files,
and `docs/Model-Catalog.md` documents the accepted locations and behavior.

## Tests

Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a132-catalog`.
All evidence below is in its `logs/` directory. Fixtures use generated files,
memory vaults and loopback services in the isolated test host.

Five new cases failed before the fix (21 assertions/errors), including rejected
file locations, empty model lists and the Settings field flow. The final runs
pass **94 unique cases, zero failures, zero skips**:

| Suite | Passed | Log |
| --- | ---: | --- |
| ModelCatalogEndpointTests | 23 | `local-catalog-endpoint.log` |
| ModelCatalogTimeoutTests | 1 | `local-catalog-timeout.log` |
| ModelSwitchTests | 24 | `local-catalog-loading-settings.log` |
| OnboardingTests | 22 | `local-catalog-loading-settings.log` |
| SettingsSaveTests | 15 | `local-catalog-loading-settings.log` |
| ConnectionSettingsFlowTests | 7 | `local-catalog-settings-final.log` |
| MiniModelSettingsTests | 1 | `local-catalog-mini-settings.log` |
| SettingsCloseNativeTests/testSnapshotOfUnsavedSettings | 1 | `local-catalog-settings-snapshot.log` |

The initial post-fix loading/Settings run passed 67 of 68 cases. The new Settings
fixture entered a key before looking up its selected descriptor; entering a key
changes the draft cache identity. Selecting the descriptor first corrected the
fixture, and all seven connection-flow tests then passed. No product change was
needed for that failure. Baseline evidence: `local-catalog-before.log`.

Commands (with `PI_BUILD_ROOT` set to the build root above):

```sh
# Failing-before run, before changing production code:
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ModelCatalogEndpointTests/testLocalCatalogLocationsAcceptFileURLsAndExpandedPathsButRejectRelativePaths \
  -only-testing:PiAppTests/ModelCatalogEndpointTests/testLocalCatalogListsModelsAndRefreshesWithoutRequestingCredentials \
  -only-testing:PiAppTests/ModelCatalogEndpointTests/testMissingAndInvalidLocalCatalogKeepTheLastGoodListBesideTheError \
  -only-testing:PiAppTests/ModelCatalogEndpointTests/testLocalCatalogReadUsesTheSameBodyLimitAndIgnoresTheGatewayKey \
  -only-testing:PiAppTests/ConnectionSettingsFlowTests/testEditingTheCatalogFieldListsLocalFilesBeforeSaving

# Loading/Settings classes:
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ModelSwitchTests \
  -only-testing:PiAppTests/SettingsSaveTests \
  -only-testing:PiAppTests/ConnectionSettingsFlowTests \
  -only-testing:PiAppTests/OnboardingTests

# After the fixture correction, rebuilding the test target:
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ModelCatalogEndpointTests

catalog_xcode=(xcodebuild test-without-building -project PiApp.xcodeproj \
  -scheme PiApp -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO -parallel-testing-enabled NO)
"${catalog_xcode[@]}" -only-testing:PiAppTests/ModelCatalogTimeoutTests
"${catalog_xcode[@]}" -only-testing:PiAppTests/MiniModelSettingsTests
TEST_RUNNER_PI_APP_SETTINGS_SNAPSHOT="$PI_BUILD_ROOT/settings-snapshot" \
  "${catalog_xcode[@]}" -only-testing:PiAppTests/SettingsCloseNativeTests/testSnapshotOfUnsavedSettings
"${catalog_xcode[@]}" -only-testing:PiAppTests/ConnectionSettingsFlowTests
```

The focus-dependent runs held the shared lock and ran individually. Builds
waited while the lead's lock was marked perf-sensitive. The existing Settings
snapshot generated light and dark images; the requested single visual review
used `settings-snapshot/settings-unsaved-light.png`. The catalog label, local-file
help and placeholder are readable and fit without clipping.

No full lanes, mutations, performance measurements, installed-app launch,
Keychain access or real user data were used. `NEXT-RELEASE.md`, `project.yml` and
release notes remain untouched. No unresolved test failures.
