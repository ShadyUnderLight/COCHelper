# Issue #226 自动化验收门禁

- commit: `c31f7ced133324705027a732ae7b239ea730db68`
- date: 2026-08-24
- working tree: clean（已验证 git diff / diff --cached / untracked，不含 results）
- macOS: 26.6.2 (arm64)
- swift: Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)

## AppModelSnapshotHistoryTests

```text
Test Suite 'COCHelperPackageTests.xctest' passed at 2026-08-24 11:37:31.698.
	 Executed 14 tests, with 0 failures (0 unexpected) in 25.377 (25.378) seconds
Test Suite 'Selected tests' passed at 2026-08-24 11:37:31.698.
	 Executed 14 tests, with 0 failures (0 unexpected) in 25.377 (25.379) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

结果: **通过**

## 全量单 worker 测试

```text
[1824/1827] Testing COCHelperCoreTests.WarLogTimeFormatterTests/testTrailingWhitespaceAndFourDigitMillisecondsRejected
[1825/1827] Testing COCHelperCoreTests.WarLogTimeFormatterTests/testUnparsableRawValuesDegrade
[1826/1827] Testing COCHelperCoreTests.WarLogTimeFormatterTests/testYear1992Boundary
[1827/1827] Testing COCHelperCoreTests.WarLogTimeFormatterTests/testYear9999Extreme
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

结果: **通过**

## Release build

```text
[0/1] Planning build
Building for production...
[0/4] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.31s)
```

结果: **通过**

## App bundle 组装

```text
[0/1] Planning build
Building for production...
[0/4] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.23s)
Built /Users/lmz/Documents/Vibe Coding/COC助手/.worktrees/issue-226-acceptance/scripts/../.build/COCHelper.app
```

结果: **通过**

## git diff --check

```text
```

结果: **通过**

## 真实村庄验收（本地数据）

跳过：`Tools/acceptance/local/village-a-1.json` 不存在。
将真实 JSON 放入 `Tools/acceptance/local/` 后重新运行本脚本。
