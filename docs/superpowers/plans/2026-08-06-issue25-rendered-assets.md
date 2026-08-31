# Issue #25 逐级图标 rendered asset 接入实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全量渲染 catalog 引用的图标资产为 PNG 进 Bundle，并在 `UpgradeDisplayRow` / `LevelDetailSheet` 接入 renderedPath 渲染，替换 SF Symbol 兜底。

**Architecture:** ① Python 侧扩展 `Tools/render_generator.py` 收集 catalog 全部 (container, exportName) 引用（item 级 + level 级，R2.4 去重）并全量渲染回写 catalog.json/icons//manifest；② Swift Core 层新增 `CatalogAssetRef.bundledURL()`（Bundle.module 在 Core 模块内解析，契约 R1.1）；③ UI 层两处接入：`UpgradeDisplayRow` 图标列（icon 可渲染 → PNG，否则 SF Symbol + 角标）、`LevelDetailSheet` 逐级行（levelVisual 优先 → icon 兜底 → SF Symbol）。

**Tech Stack:** Python 3 stdlib + ctypes/libzstd（既有例外）、pytest + hypothesis、SwiftPM（SwiftUI macOS）、XCTest。

---

## 背景（implementer 必须阅读）

### 现状证据（已确认）
- `render_generator.py` main() 硬编码 `SAMPLES`（4 成功 + 2 失败固定样本）；`render_samples(apk, samples)` 已支持自定义样本列表 + sc/sctx 缓存（`sc_cache: dict[str, ScFile]`）；`--samples-only` 控制是否回写 catalog.json。**全量渲染只需：收集全部引用 → 传给 render_samples → 走既有 write_rendered_outputs 事务写盘。**
- bundled catalog（18.400.13）：683 items、5479 levels；当前 29 个 ref 有 renderedPath（4 个 PNG 被多 level 引用）、484 个 ref `icons_not_rendered`；item 级唯一引用键 381、level 级（含 item 级？）契约口径：level 级唯一键 1269。
- `Package.swift` 已 `.copy("GameCatalog")` → PNG 自动进 Core bundle。
- `CatalogAssetRef.isRenderable`（renderedPath != nil && missingReason == nil）已有真值表测试。
- `Tools/game_catalog/__init__.py` `ASSET_MISSING_REASONS` 已含全部稳定枚举（container_not_found/export_not_found/astc_unsupported/texture_missing/render_failed 等）。
- **锁定测试会被全量渲染打破**（必须随 Task 更新）：
  - `testBundledRenderableRefCountIsNonZero`（GameCatalogTests.swift:240）断言 `uniquePaths == Set(known 4 PNG)` → 全量后失败
  - `testMissingRefIsNotRenderableAndHasNoPath`（:268）锚点 barracks lv2 levelVisual `missingReason == "icons_not_rendered"` → 全量渲染后该引用可能变为可渲染或新枚举值
  - `testSharedRenderedPathAcrossLevels`（:287）去重语义不变，应仍通过
- **Bundle.module 归属**：`Bundle.module` 在 COCHelperCore 模块内编译 → 解析到 Core 资源 bundle（现有 `loadBundled()` 即用此模式成功）；UI 层（COCHelper）无法访问 Core 的 Bundle.module，**URL resolver 必须放 Core 层**。
- 测试 target 中 `Bundle.module` 指向测试 bundle；Core 层代码内的 `Bundle.module` 仍是 Core bundle（编译期生成），Core 层方法在测试中直接可用（`loadBundled()` 测试即证据）。
- UI 层（COCHelper）无单测 target，改动靠 `swift build` + 手工验收。
- README.md:78-84 已记录 render_generator 样本用法；全量渲染后补充一行全量命令。

### 渲染耗时实测
`--samples-only` 6 键（含 2 失败）总 3.3s（含首次解析 ui.sc/buildings.sc）。全量键数（item 级 381 + level 级去重新增）估算 400-1300，单键 ~100-900ms（sc 缓存命中后），预计 3-10 分钟。可接受一次性全量。

### 决策记录（3 候选投票，已定）
1. **全量渲染策略**：A 一次性全量（选）vs B 分批 vs C 仅 UI 子集——实测速度快，选 A；若真实运行 >30 分钟则暂停重评估。
2. **Bundle resolver 归属**：A COCHelperCore（选，可测试）vs B COCHelper UI（Bundle.module 不可达，否决）vs C 新 target（过度设计）。
3. **LevelDetailSheet 图标优先级**：A levelVisual 优先、icon 兜底（选，等级外观是逐级语义）vs B icon 优先（每级同图，丢等级外观）vs C 仅 levelVisual（无兜底）。

### 契约要点（docs/rendered-path-contract.md）
- R1.1 renderedPath 相对版本目录；完整 Bundle 路径 = Core bundle 下 `GameCatalog/<version>/icons/<path>`。
- R2.4 跨 item/level 复用同一 (container, exportName) 只渲染一份，多引用共享同一 renderedPath。
- R5 失败 → 稳定 missingReason 枚举，无空 PNG/伪路径。
- R12.3 渲染 PNG 可提交入库（private 仓库、个人学习用途）。

### 明确不做（scope 边界）
- 不实现嵌套 MovieClip 递归渲染（契约已知限制，跳过记录 skippedElements）
- 不改多帧 MovieClip 取帧 0 行为
- 不改投影层 join 规则、升级计时、账号解码
- 不接 ClashKing CDN
- 不引入任何新第三方依赖
- 不重构 UpgradeDisplayRow / LevelDetailSheet 布局（只动图标部分）
- 不写 UI 自动化测试（项目无此基建）

---

## Task 1: render_generator 全量引用收集 + 全量渲染

**Files:**
- Modify: `Tools/render_generator.py`
- Test: `Tools/tests/test_render_generator.py`

- [ ] **Step 1: 写失败测试**（追加到 `Tools/tests/test_render_generator.py`）

```python
def test_collect_catalog_refs_dedupes_and_skips_empty(tmp_path):
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({"items": [
        {"icon": {"container": "sc/ui.sc", "exportName": "icon_a"}},
        # 跨 item 重复（R2.4：只保留一份）
        {"levelVisual": {"container": "sc/ui.sc", "exportName": "icon_a"}},
        # level 级引用
        {"levels": [{"icon": {"container": "sc/buildings.sc", "exportName": "lvl1"}}]},
        # 无引用（container/exportName 为 nil）→ 跳过
        {"icon": {"container": None, "exportName": None},
         "levels": [{"levelVisual": {"container": None, "exportName": "x"}}]},
        # 部分缺失 → 跳过
        {"icon": {"container": "sc/ui.sc", "exportName": None}},
    ]}), encoding="utf-8")
    refs = collect_catalog_refs(cat)
    keys = {(r["container"], r["exportName"]) for r in refs}
    assert keys == {("sc/ui.sc", "icon_a"), ("sc/buildings.sc", "lvl1")}
    # 顺序确定性：输出与输入顺序一致（便于稳定报告）
    assert refs[0] == {"container": "sc/ui.sc", "exportName": "icon_a"}
```

property-based 测试（同文件）：

```python
from hypothesis import given, settings, strategies as st

@given(st.lists(st.tuples(
    st.one_of(st.none(), st.text(min_size=1)),
    st.one_of(st.none(), st.text(min_size=1)),
), max_size=50))
@settings(max_examples=100)
def test_collect_catalog_refs_deterministic_deduped(pairs, tmp_path):
    cat = tmp_path / "catalog.json"
    items = [{"icon": {"container": c, "exportName": e}} for c, e in pairs]
    cat.write_text(json.dumps({"items": items}), encoding="utf-8")
    refs = collect_catalog_refs(cat)
    keys = [(r["container"], r["exportName"]) for r in refs]
    # 无 None 组件
    assert all(c and e for c, e in keys)
    # 去重
    assert len(keys) == len(set(keys))
    # 集合与输入有效对一致
    valid = {(c, e) for c, e in pairs if c and e}
    assert set(keys) == valid
    # 两次调用结果一致（确定性）
    assert refs == collect_catalog_refs(cat)
```

- [ ] **Step 2: 运行验证失败**

```bash
python3 -m pytest Tools/tests/test_render_generator.py -q
```
Expected: FAIL（`collect_catalog_refs` 未定义，ModuleNotFoundError/NameError）

- [ ] **Step 3: 实现**（`Tools/render_generator.py`，放在 `SAMPLES` 定义之后）

```python
def collect_catalog_refs(catalog_path: Path) -> list[dict]:
    """收集 catalog.json 全部 icon/levelVisual 引用（item 级 + level 级），
    按 (container, exportName) 去重（契约 R2.4），返回 render_samples 样本
    列表格式。container 或 exportName 为 nil 的引用跳过（无资产可渲染）。
    顺序 = catalog 中出现顺序（确定性报告）。"""
    data = json.loads(catalog_path.read_text(encoding="utf-8"))
    seen: set[tuple[str, str]] = set()
    refs: list[dict] = []

    def add(container: str | None, export: str | None) -> None:
        if container and export:
            key = (container, export)
            if key not in seen:
                seen.add(key)
                refs.append({"container": container, "exportName": export})

    for item in data.get("items", []):
        for ref in (item.get("icon"), item.get("levelVisual")):
            if isinstance(ref, dict):
                add(ref.get("container"), ref.get("exportName"))
        for level in item.get("levels", []):
            if not isinstance(level, dict):
                continue
            for ref in (level.get("icon"), level.get("levelVisual")):
                if isinstance(ref, dict):
                    add(ref.get("container"), ref.get("exportName"))
    return refs
```

`main()` 修改（render_samples 调用处，~line 895）：

```python
    # Issue #25：全量模式收集 catalog 全部引用（R2.4 去重）；--samples-only
    # 保持固定样本语义（回归基线）。
    samples = SAMPLES if args.samples_only else collect_catalog_refs(args.catalog)
    meta, verdicts = render_samples(args.apk, samples)
```

- [ ] **Step 4: 运行验证通过**

```bash
python3 -m pytest Tools/tests/test_render_generator.py -q
```
Expected: PASS

- [ ] **Step 5: 统计键数（决策依据）**

```bash
python3 -c "
import sys; sys.path.insert(0, 'Tools')
from pathlib import Path
from render_generator import collect_catalog_refs
refs = collect_catalog_refs(Path('Sources/COCHelperCore/GameCatalog/18.400.13/catalog.json'))
from collections import Counter
print('唯一键总数:', len(refs))
print('container 分布:', dict(Counter(r['container'] for r in refs)))
"
```
记录输出数字到 task 完成报告（预计 400-1300）。

- [ ] **Step 6: 全量渲染**（可能 3-30 分钟，用较长 timeout）

```bash
python3 Tools/render_generator.py --apk /path/to/base.apk \
  --catalog Sources/COCHelperCore/GameCatalog/18.400.13 \
  --report /tmp/issue25-full-render.json
```
Expected: 退出码 0；汇总行显示成功/失败计数。若运行 >30 分钟未完成，暂停并汇报（回到计划决策点 1）。

- [ ] **Step 7: 验证产物**

```bash
python3 Tools/validate_game_catalog.py --catalog Sources/COCHelperCore/GameCatalog/18.400.13
python3 -m pytest Tools/tests -q
```
Expected: validate verdict OK；pytest 全绿（既有 527 全量测试中渲染相关测试若因数据变化失败，先记录，Task 5 统一修——**除了 test_render_generator.py 自身**）。

- [ ] **Step 8: 记录实际渲染统计**：从 `/tmp/issue25-full-render.json` 提取 successCount/failedCount/updatedRefs、PNG 总数、总耗时；missingReason 分布（新枚举值必须 ∈ ASSET_MISSING_REASONS，若出现域外值 → 阻塞上报）。记录到 task 完成报告。

- [ ] **Step 9: 提交**

```bash
git add Tools/render_generator.py Tools/tests/test_render_generator.py
git commit -m "feat: render_generator 全量引用收集与全量渲染模式 (Issue #25)"
```

**注意**：Step 6 的全量渲染会修改 catalog.json/manifest.json/icons/（大量新 PNG），这些产物**不随本 task 提交**，Task 5 统一提交。

---

## Task 2: Swift Core 层 Bundle URL resolver（TDD）

**Files:**
- Modify: `Sources/COCHelperCore/GameCatalog.swift`
- Test: `Tests/COCHelperCoreTests/GameCatalogTests.swift`

- [ ] **Step 1: 写失败测试**（追加到 `Tests/COCHelperCoreTests/GameCatalogTests.swift`，放在「RenderedPath bundle」MARK 区）

```swift
// MARK: - bundledURL resolver（Issue #25）

/// R1.1/R5.3：isRenderable 的引用必须解析出 Bundle 内 URL，且文件真实存在。
func testBundledURLResolvesRenderableRefsToExistingFiles() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let renderable = allAssetRefs(in: catalog).filter { $0.ref.isRenderable }
    XCTAssertGreaterThan(renderable.count, 0)
    for entry in renderable {
        let url = try XCTUnwrap(entry.ref.bundledURL(),
                                "\(entry.item.section) \(entry.item.dataID) \(entry.slot) 应解析出 URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(entry.item.section) \(entry.item.dataID) \(entry.slot) → \(url.path) 不存在")
    }
}

/// 缺失引用（missingReason != nil）不得解析出 URL（UI 回退 SF Symbol）。
func testBundledURLIsNilForMissingRefs() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let missing = allAssetRefs(in: catalog).filter { $0.ref.missingReason != nil }
    XCTAssertGreaterThan(missing.count, 0)
    for entry in missing {
        XCTAssertNil(entry.ref.bundledURL(),
                     "\(entry.item.section) \(entry.item.dataID) \(entry.slot) 有 missingReason 不应解析出 URL")
    }
}
```

- [ ] **Step 2: 运行验证失败**

```bash
swift test --filter GameCatalogTests
```
Expected: FAIL（`bundledURL` 不存在：`type 'CatalogAssetRef' has no member 'bundledURL'`）

- [ ] **Step 3: 实现**（`Sources/COCHelperCore/GameCatalog.swift`，`CatalogAssetRef` struct 之后追加）

```swift
extension CatalogAssetRef {
    /// renderedPath 在 Core 资源 Bundle 内的 URL（契约 R1.1/R5.3）。
    ///
    /// - 仅当 `isRenderable` 时解析（renderedPath 非空且无缺失原因）；
    ///   否则返回 nil，UI 回退 SF Symbol。
    /// - `Bundle.module` 在本模块（COCHelperCore）内编译 → 解析到 Core
    ///   资源 bundle（与 `loadBundled()` 同一机制）。
    /// - 文件不存在时 Bundle 解析返回 nil，不抛错。
    public func bundledURL(version: String = GameCatalog.defaultBundledVersion) -> URL? {
        guard isRenderable, let renderedPath else { return nil }
        let nsPath = renderedPath as NSString
        let subdirectory = "GameCatalog/" + version + "/" + nsPath.deletingLastPathComponent
        return Bundle.module.url(
            forResource: nsPath.deletingPathExtension,
            withExtension: nsPath.pathExtension,
            subdirectory: subdirectory
        )
    }
}
```

- [ ] **Step 4: 运行验证通过**

```bash
swift test --filter GameCatalogTests
```
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperCore/GameCatalog.swift Tests/COCHelperCoreTests/GameCatalogTests.swift
git commit -m "feat: CatalogAssetRef.bundledURL Bundle 资源解析 (Issue #25)"
```

---

## Task 3: UpgradeDisplayRow 图标列接入 PNG

**Files:**
- Modify: `Sources/COCHelper/UpgradeDisplayRow.swift`

- [ ] **Step 1: 实现图标列分支**。当前 body 图标列（第 131-147 行）是 `Image(systemName:)` + 角标 overlay。改为：

```swift
    // MARK: - 图标

    /// 目录渲染 PNG（icon 可渲染时）；否则 nil → SF Symbol 兜底。
    /// Issue #25：renderedPath 资产进 Bundle 后，`item.icon?.isRenderable`
    /// 为 true 时优先渲染真实图标（`bundledURL()` 解析 + NSImage 加载）；
    /// 加载失败（Bundle 文件缺失等）同样回退 SF Symbol，不崩溃。
    private var iconView: some View {
        if let url = item.icon?.bundledURL(), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .help(iconHelp)
        } else {
            Image(systemName: iconImageName)
                .font(.body)
                .foregroundStyle(item.category?.tint ?? Color.secondary)
                .frame(width: 24)
                .help(iconHelp)
        }
    }
```

body 图标列替换为：

```swift
            iconView
                .overlay(alignment: .bottomTrailing) {
                    if iconMissingReason != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .offset(x: 4, y: 4)
                    }
                }
```

角标条件不变（`iconMissingReason != nil`：icon 可渲染但 levelVisual 缺失时角标保留——缺失状态仍成立）。

- [ ] **Step 2: 更新 doc comment**（文件头第 7-11 行与 `iconHelp` 上方注释：将「当前全目录 icons_not_rendered / 应在此接入」改为「icon 可渲染时渲染 PNG，缺失时 SF Symbol + 角标」——按实际实现描述，不要留「应接入」未完成语义）。

- [ ] **Step 3: 文件头部加 `import AppKit`**（NSImage 需要；若已有则跳过）。

- [ ] **Step 4: 编译验证**

```bash
swift build
```
Expected: 成功。同时确认 `COCHelperApp`（若引用该组件）一并编译通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelper/UpgradeDisplayRow.swift
git commit -m "feat: UpgradeDisplayRow 图标列渲染 renderedPath PNG (Issue #25)"
```

---

## Task 4: LevelDetailSheet 逐级行接入 levelVisual/icon

**Files:**
- Modify: `Sources/COCHelper/LevelDetailSheet.swift`

- [ ] **Step 1: 新增逐级图标解析辅助**（决策点 3：levelVisual 优先 → icon 兜底 → SF Symbol）：

```swift
    /// 逐级图标：levelVisual 优先（等级外观是逐级语义核心），icon 兜底；
    /// 两者均不可渲染/加载失败 → nil（SF Symbol 兜底，不崩溃）。
    private func levelAssetImage(_ level: CatalogLevel) -> Image? {
        let ref = (level.levelVisual?.isRenderable == true) ? level.levelVisual
            : ((level.icon?.isRenderable == true) ? level.icon : nil)
        guard let url = ref?.bundledURL(), let nsImage = NSImage(contentsOf: url) else {
            return nil
        }
        return Image(nsImage: nsImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
```

- [ ] **Step 2: `levelRow` HStack 头部加图标列**（现有第一项是 `VStack(alignment: .leading)`，在其前插入）：

```swift
        return HStack(spacing: 12) {
            Group {
                if let img = levelAssetImage(level) {
                    img.frame(width: 28, height: 28)
                } else {
                    Image(systemName: item.category?.systemImage ?? "hammer.fill")
                        .font(.body)
                        .foregroundStyle(item.category?.tint ?? Color.secondary)
                        .frame(width: 28, height: 28)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
```

- [ ] **Step 3: sheet 头部大图标**（第 70 行 `Image(systemName:)`）：icon 可渲染时渲染 PNG（与逐级行同一 resolver 语义，复用 `item.icon?.bundledURL()`）：

```swift
                    Group {
                        if let url = item.icon?.bundledURL(), let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                        } else {
                            Image(systemName: item.category?.systemImage ?? "hammer.fill")
                                .font(.title2)
                                .foregroundStyle(item.category?.tint ?? Color.secondary)
                                .frame(width: 36)
                        }
                    }
```

- [ ] **Step 4: 文件头部加 `import AppKit`**（若已有则跳过）；更新文件头 doc comment 提及逐级图标渲染。

- [ ] **Step 5: 编译验证**

```bash
swift build
```
Expected: 成功。

- [ ] **Step 6: 提交**

```bash
git add Sources/COCHelper/LevelDetailSheet.swift
git commit -m "feat: LevelDetailSheet 逐级行渲染 levelVisual/icon PNG (Issue #25)"
```

---

## Task 5: 锁定测试更新 + 产物提交 + 契约回写

**Files:**
- Modify: `Tests/COCHelperCoreTests/GameCatalogTests.swift`
- Modify: `docs/rendered-path-contract.md`
- Modify: `README.md`
- 产物：`Sources/COCHelperCore/GameCatalog/18.400.13/{catalog.json, manifest.json, icons/**}`（Task 1 已生成）

- [ ] **Step 1: 检查 Task 1 全量渲染后的实际状态**（以下数字以实际为准）：

```bash
python3 -c "
import json
d = json.load(open('Sources/COCHelperCore/GameCatalog/18.400.13/catalog.json'))
refs = []
def walk(item):
    for k in ('icon','levelVisual'):
        r = item.get(k)
        if r: refs.append(r)
    for lv in item.get('levels', []):
        for k in ('icon','levelVisual'):
            r = lv.get(k)
            if r: refs.append(r)
for i in d['items']: walk(i)
from collections import Counter
print('总 refs:', len(refs))
print('isRenderable:', sum(1 for r in refs if r.get('renderedPath') and not r.get('missingReason')))
print('missingReason:', dict(Counter(r.get('missingReason') for r in refs if r.get('missingReason'))))
print('唯一 renderedPath:', len({r['renderedPath'] for r in refs if r.get('renderedPath')}))
"
```

- [ ] **Step 2: 更新 `testBundledRenderableRefCountIsNonZero`**（GameCatalogTests.swift:240）：已知 4 个样本仍是子集 + 唯一路径数显著增长（用 Step 1 实测数字，如 `XCTAssertGreaterThan(uniquePaths.count, 100)`，数字必须 <= 实测唯一路径数）：

```swift
    func testBundledRenderableRefCountIsNonZero() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let renderable = allAssetRefs(in: catalog).filter { $0.ref.isRenderable }
        XCTAssertGreaterThan(renderable.count, 0, "bundled 目录应含真实渲染 PNG 引用")
        // Issue #25 全量渲染后：4 个固定样本仍是子集，唯一路径数大幅增长。
        let known = [
            "icons/buildings/blacksmith_lvl1.png",
            "icons/buildings/fireplace_lvl1.png",
            "icons/ui/icon_spell_rage.png",
            "icons/ui/icon_unit_barbarian.png",
        ]
        let uniquePaths = Set(renderable.map(\.ref.renderedPath).compactMap { $0 })
        for path in known {
            XCTAssertTrue(uniquePaths.contains(path), "\(path) 应仍被引用（跨等级/跨 item 复用）")
        }
        XCTAssertGreaterThan(uniquePaths.count, <实测唯一路径数 - 100 的安全下限>, "全量渲染后唯一路径数应显著增长")
    }
```

- [ ] **Step 3: 更新 `testMissingRefIsNotRenderableAndHasNoPath`**（:268）锚点：Step 1 实测 barracks（dataID 1_000_000）lv2 levelVisual 的实际状态——
  - 若仍 `missingReason == "icons_not_rendered"`：断言不变，仅确认即可；
  - 若已渲染/变为其他枚举：改用 Step 1 统计中仍存在 `icons_not_rendered` 或具体枚举的锚点（从实测输出中挑一个稳定的未渲染引用），并把断言从「= icons_not_rendered」放宽为「= 实测枚举值」，注释注明实测值来源。
  - `XCTAssertGreaterThan(missing.count, 0)` 保留（全量渲染必然有失败键：缺失 container/export 等）。

- [ ] **Step 4: 契约文档回写**（`docs/rendered-path-contract.md` §12.1 末尾追加）：

```markdown
**#25 全量渲染与 UI 接入完成（<YYYY-MM-DD> 回写）**：
- 全量渲染 <N> 个唯一键 → 成功 <S> / 失败 <F>；唯一 renderedPath <P> 个，
  全部 PNG 在 Bundle 内可解析（`testBundledURLResolvesRenderableRefsToExistingFiles` 锁定）
- missingReason 分布：<dict>（全部 ∈ ASSET_MISSING_REASONS）
- `UpgradeDisplayRow` 图标列 / `LevelDetailSheet` 逐级行已接入
  （levelVisual 优先、icon 兜底、SF Symbol 最后；缺失角标语义不变）
```

- [ ] **Step 5: README 更新**（README.md:78-84 渲染生成器小节追加一行）：

```markdown
python3 Tools/render_generator.py --apk <apk> --catalog <dir>   # 全量渲染 catalog 全部引用（Issue #25）
```

- [ ] **Step 6: 全量验证**

```bash
python3 -m pytest Tools/tests -q          # 期望全绿
swift test                                # 期望全绿
python3 Tools/validate_game_catalog.py --catalog Sources/COCHelperCore/GameCatalog/18.400.13  # verdict: OK
./scripts/build_app.sh                    # Build complete
```

- [ ] **Step 7: 提交产物与文档**（catalog.json/manifest.json/icons/** 全部入库；PNG 为契约 R12.3 批准的例外）

```bash
git add Sources/COCHelperCore/GameCatalog/18.400.13/ docs/rendered-path-contract.md README.md Tests/COCHelperCoreTests/GameCatalogTests.swift
git commit -m "feat: 全量渲染图标资产入库与 UI 接入验证 (Issue #25)"
```

---

## Task 6: 全量回归 + 验收 + 手工核对清单

- [ ] **Step 1: 完整验证**（同上 Task 5 Step 6 四命令全绿）
- [ ] **Step 2: 固定样本复跑一致性**（确定性 R4）：全量渲染后再跑 `--samples-only`，4 个成功样本 PNG sha256 与入库文件一致（抽样 1-2 个比对即可）：

```bash
python3 Tools/render_generator.py --apk /path/to/base.apk --catalog Sources/COCHelperCore/GameCatalog/18.400.13 --samples-only --report /tmp/r25-recheck.json
shasum -a 256 Sources/COCHelperCore/GameCatalog/18.400.13/icons/ui/icon_unit_barbarian.png
```
比对与 report 中 sha256 一致。

- [ ] **Step 3: 对照 issue #25 验收**：
  1. 目录含 renderedPath 的版本下逐项核对图标（手工）
  2. `UpgradeDisplayRow`：icon 可渲染 → PNG；缺失 → SF Symbol + 橙色角标 + help
  3. `LevelDetailSheet` 逐级行：levelVisual 渲染 PNG；同一项目跨等级共用同一 PNG（不重复渲染/不复制资源）
  4. 无 renderedPath 时行为回退（缺失角标可见）
- [ ] **Step 4: 自查清单（Reflexion）**
  - [ ] 类型契约：`bundledURL()` 签名与计划一致；Core 层无 SwiftUI 依赖
  - [ ] property-based：`test_collect_catalog_refs_deterministic_deduped`（hypothesis）覆盖收集纯函数
  - [ ] 无新增第三方依赖（stdlib + ctypes/libzstd 例外不变）
  - [ ] 无 APK/游戏原始资源入库（PNG 为例外，R12.3）
  - [ ] 失败路径全部 fail loud（CatalogError）或稳定 missingReason
  - [ ] UI 缺失角标语义未变（icon 渲染成功但 levelVisual 缺失 → 角标仍显示）

---

## 风险与边界

- **全量渲染耗时**：实测样本 3.3s/6 键；若全量 >30 分钟 → 暂停评估分批（决策点 1 回退选项 B）
- **锁定测试**：Task 1 渲染产物会破坏 2 个既有测试断言 → Task 5 必须更新，中间态提交不要含渲染产物（Task 1 只提交代码）
- **新 missingReason 枚举**：若全量渲染产生 ASSET_MISSING_REASONS 域外值 → validate 失败 → 阻塞上报（契约 R5 要求域封闭）
- **PNG 体积**：全量 PNG 入库可能数十 MB；App Bundle 打包验证由 build_app.sh 承担；若超 50MB 测试策略已由 #30 预留（抽样断言）
- **UI 层无单测**：Task 3/4 依赖 swift build + 手工验收；不写 UI 自动化测试
