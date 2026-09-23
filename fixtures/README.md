# Electron-owned fixtures

`fixtures/account/` contains the anonymous account and official API fixtures used by
the Electron/TypeScript testkit, packaged performance runner, and offline acceptance
tools.

`fixtures/golden/` contains the golden contract fixtures used by the
Electron/TypeScript wire, domain, and parity tests.

The copies currently under `Tests/COCHelperCoreTests/Fixtures/` and
`Tests/Golden/Fixtures/` are migration-era Swift oracle snapshots. They remain
byte-for-byte separate until the Swift package, oracle, and XCTest targets are
removed in the later E6-01 cutover slice. Electron code must read the corresponding
directory under `fixtures/`, not the Swift test target's resource directory.
