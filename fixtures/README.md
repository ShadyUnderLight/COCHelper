# Electron-owned fixtures

`fixtures/account/` contains the anonymous account and official API fixtures used by
the Electron/TypeScript domain, testkit, and packaged performance runner.

`fixtures/golden/` contains the golden contract fixtures used by the
Electron/TypeScript wire, domain, and contract tests.

These directories are authoritative Electron inputs. There is no second Swift fixture
copy or synchronization gate on the pure Electron main branch.
