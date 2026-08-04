"""目录校验：结构/语义不变量。生成器写盘前自检 + 验证器 CLI 共用同一实现。

只校验目录内容自洽（catalog.json/manifest.json），不依赖真实 APK。
"""

import json
import string
from pathlib import Path

from . import SCHEMA_VERSION, MISSING_REASONS
from .model import catalog_from_dict

_HEX = frozenset(string.hexdigits)


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
    except (json.JSONDecodeError, OSError) as exc:
        return [f"manifest.json 解析失败: {exc}"]

    try:
        catalog = catalog_from_dict(json.loads(catalog_path.read_text(encoding="utf-8")))
    except (json.JSONDecodeError, OSError, KeyError, ValueError, TypeError) as exc:
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

    # ---- 主键唯一性 + level 升序 + null/reason 配对 ----
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
            if lv.missingReason and lv.missingReason not in MISSING_REASONS:
                errors.append(f"{key} level {lv.level}: 未知 missingReason {lv.missingReason!r}")
            if lv.durationSeconds is not None and lv.durationSeconds < 0:
                errors.append(f"{key} level {lv.level}: durationSeconds 为负")
        if item.base is None and item.baseMissingReason is None:
            errors.append(f"{key}: base=null 但 baseMissingReason 为空")
        if item.base is not None and item.baseMissingReason is not None:
            errors.append(f"{key}: base={item.base} 却有 baseMissingReason")
        if item.baseMissingReason and item.baseMissingReason not in MISSING_REASONS:
            errors.append(f"{key}: 未知 baseMissingReason {item.baseMissingReason!r}")

    # ---- counts 与目录内容重算一致 ----
    counts = {
        "items": len(catalog.items),
        "levels": sum(len(i.levels) for i in catalog.items),
        "missingTime": sum(1 for i in catalog.items for lv in i.levels if lv.durationSeconds is None),
        "missingIcons": sum(1 for i in catalog.items for lv in i.levels if lv.icon and lv.icon.renderedPath is None),
    }
    manifest_counts = manifest.get("counts")
    if not isinstance(manifest_counts, dict):
        errors.append("manifest 缺少 counts")
    else:
        for field in ("items", "levels", "missingTime", "missingIcons"):
            if manifest_counts.get(field) != counts[field]:
                errors.append(f"counts.{field} 不一致: manifest={manifest_counts.get(field)} 重算={counts[field]}")

    return errors


def catalog_invariants(dir_path: str | Path) -> list[str]:
    """语义层校验（当前与 validate_catalog 合并，保留函数签名供 CLI 自检）。"""
    return validate_catalog(dir_path)
