"""目录校验：结构/语义不变量。生成器写盘前自检 + 验证器 CLI 共用同一实现。

只校验目录内容自洽（catalog.json/manifest.json），不依赖真实 APK。
"""

import hashlib
import json
import string
from pathlib import Path

from . import (
    SCHEMA_VERSION,
    ASSET_MISSING_REASONS,
    BASE_MISSING_REASONS,
    ITEM_MISSING_REASONS,
    LEVEL_MISSING_REASONS,
)
from .catalog import counts_for
from .contract import check_rendered_path_contract, rendered_path_format_ok
from .display_categories import (
    DISPLAY_CATEGORIES,
    INTENTIONAL_FALLBACK_DATA_IDS,
    apply_display_categories,
)
from .model import AssetRef, UpgradeCost, catalog_from_dict

_HEX = frozenset(string.hexdigits)
# PNG 文件魔数（前 8 字节）：\x89PNG\r\n\x1a\n（Issue #30 Task 8 内容校验用）
_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

# 非数量型主村 buildings/traps 项（合法无宇宙项；18.400.13 数据源实证：
# townhall_levels 无对应数量列）。分类：大本营（含 TH17 升级中/TH18 预告
# 变体）、英雄神坛、哥布林/单人战役、不祥洞窟、教学/未使用/事件加农炮
# 变体、笼子/装饰/事件建筑、全空列事件陷阱（Halloweenbomb/Slowbomb/
# SantaTrap）、单机陷阱变体。新版本新增非数量型项 → 在此登记（fail loud
# 拒绝未知项，防数量型静默丢失）。
_NON_COUNTABLE_DATA_IDS = frozenset({
    # 大本营
    1000001, 1000103, 1000104,
    # 英雄神坛
    1000022, 1000025, 1000030, 1000066,
    # 哥布林/单人战役
    1000016, 1000017, 1000018, 1000061, 1000069,
    # 不祥洞窟（单人）
    1000062, 1000074, 1000076,
    # 教学/未使用/事件加农炮变体
    1000060, 1000087, 1000088, 1000094, 1000095, 1000096,
    # 笼子/装饰/事件建筑
    1000073, 1000075, 1000083, 1000090, 1000091, 1000092,
    1000098, 1000099, 1000100, 1000101,
    # 全空列事件陷阱 + 单机陷阱变体
    12000003, 12000004, 12000007, 12000017, 12000018, 12000019,
})


def _check_instance_counts(errors: list[str], ic: dict, catalog) -> None:
    """instanceCounts 宇宙不变量（Issue #70 阶段 2）。

    - 键 "section:dataID"（section ∈ {buildings, traps}，dataID 可解析 int）；
    - 值列表长度恒 18（index = TH-1）、每值 ≥ 0 整数（bool 非法）；
    - 反向 join：每个键对应的 (section, dataID) 必须存在于 items；
    - 正向完整性：数量型 home buildings/traps 项必须有宇宙项（排除列表外的）；
    - 值全 0 → 问题项（数量型建筑不可能全 TH 都是 0）。
    """
    item_keys = {(i.section, i.dataID) for i in catalog.items}
    ic_keys: set[tuple[str, int]] = set()
    for key, vals in ic.items():
        if not isinstance(key, str) or ":" not in key:
            errors.append(f"instanceCounts 键格式非法: {key!r}")
            continue
        section, _, dataid_s = key.partition(":")
        if section not in ("buildings", "traps"):
            errors.append(f"instanceCounts 未知 section: {key}")
            continue
        try:
            data_id = int(dataid_s)
        except ValueError:
            errors.append(f"instanceCounts dataID 不可解析: {key}")
            continue
        ic_keys.add((section, data_id))
        if (section, data_id) not in item_keys:
            errors.append(f"instanceCounts 键不在 items: {key}")
            continue
        if not isinstance(vals, list) or len(vals) != 18:
            errors.append(
                f"instanceCounts {key} 长度 != 18: "
                f"{len(vals) if isinstance(vals, list) else type(vals).__name__}")
            continue
        bad = False
        all_zero = True
        for v in vals:
            if isinstance(v, bool) or not isinstance(v, int):
                errors.append(f"instanceCounts {key} 值类型非法: {v!r}（应为整数）")
                bad = True
            elif v < 0:
                errors.append(f"instanceCounts {key} 值为负: {v}")
                bad = True
            elif v != 0:
                all_zero = False
        if not bad and all_zero:
            errors.append(f"instanceCounts {key} 全 0（数量型建筑不可能全 TH 为 0）")
    # 正向完整性：主村数量型（home buildings/traps）必须都有宇宙项；
    # 已知非数量型（排除列表）免查，buildings2/traps2（BB）不做宇宙（决策 5）。
    for i in catalog.items:
        if (i.section in ("buildings", "traps") and i.base == "home"
                and i.dataID not in _NON_COUNTABLE_DATA_IDS
                and (i.section, i.dataID) not in ic_keys):
            errors.append(f"instanceCounts 缺少宇宙项: {i.section}:{i.dataID} ({i.name})")


def _check_display_category_registry(errors: list[str], items) -> None:
    """displayCategory 全量重算比对（Issue #75 工作流 C 评审补强）。

    apply_display_categories 从注册表（display_categories.py，分类知识唯一事实源）
    派生每个 item 的期望分类，与 catalog 实际值全量逐 item 比对。任何差异即
    登记表内错标（如 1000008→military）、兜底项被标分类、非 home 被标、
    1000097 非 craftTable——统一报错。独立 1000097 检查已删除（本比对覆盖，
    避免同一错误双报）。apply 返回新列表且保持顺序，zip 逐对即可。
    """
    for item, expected in zip(items, apply_display_categories(items)):
        if item.displayCategory != expected.displayCategory:
            errors.append(
                f"displayCategory 与注册表不一致: {item.section}:{item.dataID} "
                f"{item.name} 期望={expected.displayCategory} 实际={item.displayCategory!r}")


def _check_rendered_path(
    errors: list[str],
    ref: AssetRef,
    context: str,
    catalog_dir: Path,
    registered: set[str] | None,
) -> None:
    """renderedPath 负例校验（Issue #27 契约 R1/R2/R5），复用 contract 模块。

    契约规则/顺序/消息见 game_catalog/contract.py 的 check_rendered_path_contract；
    file_exists 与 registered 布尔由本处计算（保持契约函数纯、无 IO）。契约返回的
    消息不含 "(<context>)" 后缀，在此追加以保持既有输出文本逐字不变。

    顺序：R-B 互斥（独立轴，先查，不被格式短路）→ R-D 格式 → R-A 文件存在 →
    R-C manifest 登记。renderedPath 为 None（无引用）不触发——counts.missingIcons
    的 "renderedPath is None" 语义不变；**空串 "" 不是合法渲染路径**，走 R-D
    报格式非法（交叉审核 P1-2：空路径不得绕过校验，不得被 isRenderable 视为可渲染）。
     R-D 短路在**文件系统探测之前**：格式非法（版本段/`..` 段/绝对路径/单级/空串等）
     直接报格式非法，不执行 `(catalog_dir / rp).is_file()`——防 `icons/../../x.png`
     逃逸探测 catalog 目录之外的文件（交叉审核 NB-3）。
     文件存在但已登记时 hash/size 一致性由现有 generatedFiles 重算逻辑兜底
     （PNG 条目走同一路径）。文件存在时另做 PNG 内容校验（Issue #30 Task 8）：
     前 8 字节必须是 PNG 魔数，否则报"不是合法 PNG"；仅查魔数不解析完整 PNG，
     小文件（<8 字节）同样报错。读取失败（OSError）报"无法读取"。
    """
    rp = ref.renderedPath
    if rp is None:
        return
    # 纯函数先验格式；`and` 短路保证非法路径从不触碰文件系统
    file_exists = rendered_path_format_ok(rp) and (catalog_dir / rp).is_file()
    violations = check_rendered_path_contract(
        rp, ref.missingReason, file_exists,
        None if registered is None else rp in registered,
    )
    errors.extend(f"{e} ({context})" for e in violations)
    # ---- PNG 内容校验（Issue #30 Task 8）：文件存在但内容非 PNG → error ----
    # 仅 file_exists 时读文件：格式非法/逃逸路径已被上面短路，不触碰文件系统
    # （NB-3 安全不变）。只比对前 8 字节魔数；小文件读出不足魔数长度即报错。
    if file_exists:
        png_target = catalog_dir / rp
        try:
            with png_target.open("rb") as f:
                head = f.read(len(_PNG_MAGIC))
        except OSError as exc:
            errors.append(f"renderedPath 指向的文件无法读取: {rp}: {exc} ({context})")
            return
        if head != _PNG_MAGIC:
            errors.append(f"renderedPath 指向的文件不是合法 PNG: {rp} ({context})")


def validate_catalog(dir_path: str | Path) -> list[str]:
    """校验目录。返回 error 列表（空=通过）。"""
    errors: list[str] = []
    d = Path(dir_path)
    manifest_path = d / "manifest.json"
    catalog_path = d / "catalog.json"

    if not manifest_path.is_file():
        return ["manifest.json 不存在"]
    if not catalog_path.is_file():
        return ["catalog.json 不存在"]

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, ValueError, AttributeError) as exc:
        return [f"manifest.json 解析失败: {exc}"]
    if not isinstance(manifest, dict):
        return ["manifest.json 顶层必须是对象"]

    try:
        raw_catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        catalog = catalog_from_dict(raw_catalog)
    except (json.JSONDecodeError, OSError, KeyError, ValueError, TypeError, AttributeError) as exc:
        return [f"catalog.json 解析失败: {exc}"]

    # ---- 版本/语言一致性 ----
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"manifest schemaVersion={manifest.get('schemaVersion')} != {SCHEMA_VERSION}")
    if catalog.schemaVersion != SCHEMA_VERSION:
        errors.append(f"catalog schemaVersion={catalog.schemaVersion} != {SCHEMA_VERSION}")
    if manifest.get("gameVersion") != catalog.gameVersion:
        errors.append(f"gameVersion 不一致: manifest={manifest.get('gameVersion')} catalog={catalog.gameVersion}")
    if manifest.get("locale") != catalog.locale:
        errors.append(f"locale 不一致: manifest={manifest.get('locale')} catalog={catalog.locale}")

    # ---- sourceFingerprint 格式："sha256:" + 64 hex ----
    fp = manifest.get("sourceFingerprint")
    if not (isinstance(fp, str) and fp.startswith("sha256:")
            and len(fp) == 7 + 64 and all(c in _HEX for c in fp[7:])):
        errors.append(f"sourceFingerprint 格式非法: {fp!r}")

    # ---- generatedFiles 完整性：hash/size 重算比对 + icons/ 目录存在 ----
    gen = manifest.get("generatedFiles")
    registered: set[str] | None = None  # 非 directory 条目路径集合（R-C 用）
    png_count: int | None = 0 if isinstance(gen, list) else None  # R6.2：PNG 条目数
    if not isinstance(gen, list):
        errors.append("manifest 缺少 generatedFiles")
    else:
        seen_files = set()
        registered = set()
        for entry in gen:
            path = entry.get("path") if isinstance(entry, dict) else None
            if not isinstance(path, str) or not path:
                errors.append(f"generatedFiles 条目缺少 path: {entry!r}")
                continue
            if path in seen_files:
                errors.append(f"generatedFiles 重复条目: {path}")
            seen_files.add(path)
            if entry.get("kind") == "directory":
                if not (d := catalog_path.parent / path).is_dir():
                    errors.append(f"generatedFiles 目录不存在: {path}")
                continue
            if path.endswith(".png"):
                png_count += 1  # R6.2：renderedIcons 重算断言依据
            registered.add(path)
            target = catalog_path.parent / path
            if not target.is_file():
                errors.append(f"generatedFiles 文件不存在: {path}")
                continue
            try:
                actual = "sha256:" + hashlib.sha256(target.read_bytes()).hexdigest()
            except OSError as exc:
                errors.append(f"generatedFiles 读取失败 {path}: {exc}")
                continue
            declared = entry.get("sha256", "")
            if declared != actual:
                errors.append(f"generatedFiles {path} 哈希不一致: manifest={declared} 实际={actual}")
            size = entry.get("size")
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                errors.append(f"generatedFiles {path} size 缺失或非法: {size!r}")
            elif size != target.stat().st_size:
                errors.append(f"generatedFiles {path} 大小不一致: manifest={size} 实际={target.stat().st_size}")

    # ---- 主键唯一性 + level 升序 + null/reason 配对 + reason 域校验 ----
    # 畸形但可解析的 catalog（如 "level": "1" 字符串）会在不变量比较中抛 TypeError，
    # 统一包一层：内容非法直接短路返回，不裸抛。
    try:
        seen: set[tuple[str, int]] = set()
        for item in catalog.items:
            key = (item.section, item.dataID)
            if key in seen:
                errors.append(f"重复主键 (section={item.section}, dataID={item.dataID})")
            seen.add(key)
            if item.maxLevel != (item.levels[-1].level if item.levels else 0):
                errors.append(f"{key}: maxLevel={item.maxLevel} 与最后等级不符")
            prev = 0
            for lv in item.levels:
                if lv.level <= prev:
                    errors.append(f"{key}: level {lv.level} 未严格升序")
                prev = lv.level
                if lv.durationSeconds is None and lv.missingReason is None:
                    errors.append(f"{key} level {lv.level}: durationSeconds=null 但 missingReason 为空")
                if lv.durationSeconds is not None and lv.missingReason is not None:
                    errors.append(f"{key} level {lv.level}: durationSeconds 有值但 missingReason={lv.missingReason}")
                if lv.missingReason and lv.missingReason not in LEVEL_MISSING_REASONS:
                    errors.append(f"{key} level {lv.level}: 未知 missingReason {lv.missingReason!r}")
                if lv.durationSeconds is not None and lv.durationSeconds < 0:
                    errors.append(f"{key} level {lv.level}: durationSeconds 为负")
                # ---- requiredBlacksmithLevel 域校验（Issue #97：equipment 铁匠铺门槛）----
                # 仅 equipment 强制：每级必须有值且 ∈ 1...10（fail loud，与 displayCategory
                # P1-B「旧产物缺字段报错」先例一致，报错提示回填路径）。不做单调性校验
                # （与 TH/Lab 对称——validate 对它们也无单调检查，单调性由数据源保证）。
                # 类型防御：bool 是 int 子类，JSON true/false 必须报类型非法（参照
                # _check_instance_counts 的 isinstance(v, bool) 先例）。
                if item.section == "equipment":
                    bs = lv.requiredBlacksmithLevel
                    if bs is None:
                        errors.append(
                            f"{key} level {lv.level}: equipment 缺少 requiredBlacksmithLevel"
                            f"（旧产物缺少该字段，请用 annotate_blacksmith_levels.py 回填）")
                    elif isinstance(bs, bool) or not isinstance(bs, int):
                        errors.append(
                            f"{key} level {lv.level}: requiredBlacksmithLevel 类型非法"
                            f" {type(bs).__name__}（应为整数）")
                    elif not 1 <= bs <= 10:
                        errors.append(
                            f"{key} level {lv.level}: requiredBlacksmithLevel={bs}"
                            f" 超出合法域 1...10")
                # ---- upgradeCosts 不变量（Issue #73 Task 1）----
                # None = 无费用数据；非 None 必须非空；每项满足
                # parseFailed ⟺ (amount=None ∧ rawAmount!=None)；resource/rawResource 恒非空。
                ucs = lv.upgradeCosts
                if ucs is not None:
                    if not isinstance(ucs, list) or not ucs:
                        errors.append(f"{key} level {lv.level}: upgradeCosts 为空或非法（应为非空数组或 null）")
                    else:
                        for i, uc in enumerate(ucs):
                            prefix = f"{key} level {lv.level} upgradeCosts[{i}]"
                            if not isinstance(uc, UpgradeCost):
                                errors.append(f"{prefix}: 类型非法 {type(uc).__name__}")
                                continue
                            if not isinstance(uc.parseFailed, bool):
                                errors.append(f"{prefix}: parseFailed 类型非法 {type(uc.parseFailed).__name__}")
                                continue
                            if uc.parseFailed:
                                if uc.amount is not None:
                                    errors.append(f"{prefix}: parseFailed=true 但 amount={uc.amount!r}")
                                if uc.rawAmount is None:
                                    errors.append(f"{prefix}: parseFailed=true 但 rawAmount 缺失")
                            else:
                                if uc.amount is None:
                                    errors.append(f"{prefix}: parseFailed=false 但 amount 缺失")
                                elif isinstance(uc.amount, bool) or not isinstance(uc.amount, int):
                                    errors.append(f"{prefix}: amount 类型非法 {type(uc.amount).__name__}")
                                elif uc.amount < 0:
                                    errors.append(f"{prefix}: amount 为负 {uc.amount}")
                                elif uc.amount > 2**63 - 1:
                                    errors.append(f"{prefix}: amount 超出 Int64 上界 {uc.amount}")
                                if uc.rawAmount is not None:
                                    errors.append(f"{prefix}: parseFailed=false 但 rawAmount={uc.rawAmount!r}")
                            if not uc.rawResource:
                                errors.append(f"{prefix}: rawResource 为空")
                            if not uc.resource:
                                errors.append(f"{prefix}: resource 为空")
                for ref, ref_name in ((lv.icon, "icon"), (lv.levelVisual, "levelVisual")):
                    if ref and ref.missingReason is not None and ref.missingReason not in ASSET_MISSING_REASONS:
                        errors.append(f"{key} level {lv.level}: {ref_name}.missingReason 未知 {ref.missingReason!r}")
                    if ref:
                        _check_rendered_path(errors, ref,
                                             f"item={key}, level={lv.level}, {ref_name}",
                                             catalog_path.parent, registered)
            if item.missingReason and item.missingReason not in ITEM_MISSING_REASONS:
                errors.append(f"{key}: 未知 item.missingReason {item.missingReason!r}")
            if item.base is None and item.baseMissingReason is None:
                errors.append(f"{key}: base=null 但 baseMissingReason 为空")
            if item.base is not None and item.baseMissingReason is not None:
                errors.append(f"{key}: base={item.base} 却有 baseMissingReason")
            if item.baseMissingReason and item.baseMissingReason not in BASE_MISSING_REASONS:
                errors.append(f"{key}: 未知 baseMissingReason {item.baseMissingReason!r}")
            # ---- displayCategory（Issue #75 工作流 C）----
            # 闭枚举 / 域（仅 home buildings 可携带）/ 未分类 fail-loud。
            # 分类知识唯一事实源 display_categories.py。登记表内错标/兜底项被标
            # 分类由循环后的全量重算比对（_check_display_category_registry）统一覆盖。
            dc = item.displayCategory
            if dc is not None and dc not in DISPLAY_CATEGORIES:
                errors.append(f"{key}: displayCategory 未知值 {dc!r}")
            if (item.section, item.base) != ("buildings", "home") and dc is not None:
                errors.append(f"{key}: 非 home buildings 却有 displayCategory={dc!r}")
            if item.section == "buildings" and item.base == "home":
                if dc is None and item.dataID not in INTENTIONAL_FALLBACK_DATA_IDS:
                    # P1-B（评审修复）：防漏机制不放行旧产物（严格性不变），
                    # 错误消息自解释补救路径
                    errors.append(
                        f"新增建筑未分类: {item.dataID} {item.name}"
                        f"（旧产物缺少 displayCategory 字段，"
                        f"请用 annotate_display_categories.py 重新标注）")
            for ref, ref_name in ((item.icon, "icon"), (item.levelVisual, "levelVisual")):
                if ref and ref.missingReason is not None and ref.missingReason not in ASSET_MISSING_REASONS:
                    errors.append(f"{key}: {ref_name}.missingReason 未知 {ref.missingReason!r}")
                if ref:
                    _check_rendered_path(errors, ref,
                                         f"item={key}, {ref_name}",
                                         catalog_path.parent, registered)
    except (TypeError, ValueError, AttributeError) as exc:
        return [f"catalog 内容非法: {exc}"]

    _check_display_category_registry(errors, catalog.items)

    # ---- counts 与目录内容重算一致 ----
    counts = counts_for(catalog.items)
    manifest_counts = manifest.get("counts")
    if not isinstance(manifest_counts, dict):
        errors.append("manifest 缺少 counts")
    else:
        for field in ("items", "levels", "missingTime", "missingIcons"):
            if manifest_counts.get(field) != counts[field]:
                errors.append(f"counts.{field} 不一致: manifest={manifest_counts.get(field)} 重算={counts[field]}")
        # Issue #74b：时长语义拆分桶（可选字段，旧 manifest 缺失不报错；存在必校验）
        for field in ("timed", "instant", "notApplicable", "initialLevel",
                      "sourceMissing", "parseFailed"):
            if field in manifest_counts and manifest_counts[field] != counts[field]:
                errors.append(f"counts.{field} 不一致: manifest={manifest_counts[field]} 重算={counts[field]}")
        # Issue #74b：拆分桶 sum 不变量（六桶之和 == missingTime；
        # timed + instant + missingTime == levels）。旧 manifest 缺新字段时跳过。
        if all(f in manifest_counts for f in
               ("timed", "instant", "notApplicable", "initialLevel",
                "sourceMissing", "parseFailed")):
            bucket_sum = sum(manifest_counts[f] for f in
                             ("notApplicable", "initialLevel", "sourceMissing", "parseFailed"))
            if bucket_sum != manifest_counts.get("missingTime"):
                errors.append(
                    f"counts 不变量被破坏: 缺失类四桶之和 {bucket_sum} != missingTime "
                    f"{manifest_counts.get('missingTime')}")
            if (manifest_counts.get("timed", 0) + manifest_counts.get("instant", 0)
                    + manifest_counts.get("missingTime", 0)) != manifest_counts.get("levels"):
                errors.append(
                    f"counts 不变量被破坏: timed + instant + missingTime != levels "
                    f"({manifest_counts.get('timed')} + {manifest_counts.get('instant')} "
                    f"+ {manifest_counts.get('missingTime')} != {manifest_counts.get('levels')})")
        # ---- R6.2 optional 字段（旧 manifest 缺失不报错）----
        # renderedIcons：渲染成功且落盘的 PNG 数，必须 == generatedFiles PNG
        # 条目数（可重算断言）；generatedFiles 缺失时只校验类型不比对
        ri = manifest_counts.get("renderedIcons")
        if ri is not None:
            if not isinstance(ri, int) or isinstance(ri, bool) or ri < 0:
                errors.append(f"counts.renderedIcons 非法: {ri!r}")
            elif png_count is not None and ri != png_count:
                errors.append(
                    f"counts.renderedIcons 不一致: manifest={ri} "
                    f"重算={png_count}（generatedFiles PNG 条目数）")
        # blockedIcons：失败样本键数，快照语义——只有生成器知道，validate 只
        # 校验存在性/类型/非负，不重算
        bi = manifest_counts.get("blockedIcons")
        if bi is not None and (not isinstance(bi, int)
                               or isinstance(bi, bool) or bi < 0):
            errors.append(f"counts.blockedIcons 非法: {bi!r}")
        # ---- displayCategories（Issue #75 工作流 C，optional 字段）----
        # 旧 manifest 缺失不报错；存在必与 catalog 实际分布一致（防标注/生成遗漏）
        dc_counts = manifest_counts.get("displayCategories")
        if dc_counts is not None:
            if not isinstance(dc_counts, dict):
                errors.append(f"counts.displayCategories 非法: {dc_counts!r}")
            else:
                for k, v in counts["displayCategories"].items():
                    if dc_counts.get(k) != v:
                        errors.append(
                            f"counts.displayCategories.{k} 不一致: "
                            f"manifest={dc_counts.get(k)} 重算={v}")

    # ---- instanceCounts 宇宙（Issue #70 阶段 2）----
    # 旧产物缺字段不报错（向后兼容）；存在时必须通过全部不变量（_check_instance_counts）
    raw_ic = raw_catalog.get("instanceCounts")
    if raw_ic is not None:
        if not isinstance(raw_ic, dict):
            errors.append(f"instanceCounts 类型非法: {type(raw_ic).__name__}（应为 dict）")
        else:
            _check_instance_counts(errors, raw_ic, catalog)

    return errors


def catalog_invariants(dir_path: str | Path) -> list[str]:
    """语义层校验（当前与 validate_catalog 合并，保留函数签名供 CLI 自检）。"""
    return validate_catalog(dir_path)
