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
from .model import AssetRef, catalog_from_dict

_HEX = frozenset(string.hexdigits)
# PNG 文件魔数（前 8 字节）：\x89PNG\r\n\x1a\n（Issue #30 Task 8 内容校验用）
_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


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
        catalog = catalog_from_dict(json.loads(catalog_path.read_text(encoding="utf-8")))
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
            for ref, ref_name in ((item.icon, "icon"), (item.levelVisual, "levelVisual")):
                if ref and ref.missingReason is not None and ref.missingReason not in ASSET_MISSING_REASONS:
                    errors.append(f"{key}: {ref_name}.missingReason 未知 {ref.missingReason!r}")
                if ref:
                    _check_rendered_path(errors, ref,
                                         f"item={key}, {ref_name}",
                                         catalog_path.parent, registered)
    except (TypeError, ValueError, AttributeError) as exc:
        return [f"catalog 内容非法: {exc}"]

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

    return errors


def catalog_invariants(dir_path: str | Path) -> list[str]:
    """语义层校验（当前与 validate_catalog 合并，保留函数签名供 CLI 自检）。"""
    return validate_catalog(dir_path)
