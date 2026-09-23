# Electron-owned fixtures

`fixtures/account/` contains the anonymous account and official API fixtures used by
the Electron/TypeScript testkit, packaged performance runner, and offline acceptance
tools.

`fixtures/golden/` contains the golden contract fixtures used by the
Electron/TypeScript wire, domain, and contract tests.

The copies currently under `Tests/COCHelperCoreTests/Fixtures/` are migration-era
Swift test snapshots. They remain until the later E6-01 cutover slice removes the
remaining Swift package and XCTest targets. Electron code must read the corresponding
directory under `fixtures/`, not the Swift test target's resource directory.
