"""渲染生成器测试（Issue #30 Task 7）：纯函数 + 合成 zip + 真实 APK 集成。

策略：
- 纯函数（无 APK）：container_key（R2.1）/ sanitize_export_key（R2.2）/
  sample_png_relpath（契约对照表）/ apply_rendered_paths 回写（成功/失败/去重/
  无关引用不动）/ PNG 写入（成功才写、去重单写）/ 原子性（replace 失败不破坏
  原 catalog.json）/ JSON 格式保持（indent=2 + sort_keys + ensure_ascii=False）
- 合成 zip：container_not_found（空 zip）、export_not_found（最小可加载
  SC2——DataStorage(strings) + ExportNames chunk，复用 test_fbs.FbBuilder）
- 多命令合成（render.composite_shapes）：两张图叠加 → 共享画布 + src-over
- 真实 APK（COC_APK_PATH + skipif，标记 slow）：4 成功样本 PNG 存在且非空、
  IHDR 尺寸可解析、sha256 两次一致（R4 确定性）、2 失败样本 missingReason
  正确、catalog 回写字段正确、失败样本不产生 PNG；火焰喷射器额外覆盖
  嵌套 MovieClip 递归展开

真实样本期望（Task 1-6 实证 + 本任务对拍）：
- icon_unit_barbarian：帧 0 有 2 元素（textfield 跳过 + shape 8025 单命令）→ 成功
- icon_spell_rage：帧 0 单元素 shape 21490 单命令 → 成功
- fireplace_lvl1：帧 0 有 shape 1549（单命令）+ 嵌套 movieclip 1607（360 帧，
  递归取帧 0）→ 成功
- blacksmith_lvl1：帧 0 shape 1643 五命令（合成一画布）+ 嵌套 movieclip 1645
  （递归合成）→ 成功
- icon_unit_does_not_exist / sc/traps.sc town_hall_lvl1 → 失败
"""

import hashlib
import json
import os
import struct
import zipfile
from pathlib import Path

import pytest

from hypothesis import HealthCheck, given, settings, strategies as st

from game_catalog.errors import CatalogError
from game_catalog.validate import validate_catalog
from render_generator import (
    SAMPLES,
    _compose_matrices,
    apply_rendered_paths,
    collect_catalog_refs,
    container_key,
    refresh_manifest,
    render_samples,
    sample_png_relpath,
    sanitize_export_key,
    write_rendered_outputs,
)
from game_catalog.sc2 import Matrix2x3
from test_validate import (
    _load_catalog,
    _load_manifest,
    _valid_dir,
    _write,
    _write_with_hash,
)

APK = Path(os.environ.get("COC_APK_PATH", "/Users/lmz/Downloads/base.apk.1"))
_real_apk = pytest.mark.skipif(
    not APK.is_file(), reason="真实 APK 不存在（设置 COC_APK_PATH 可启用）"
)

_REPO_ROOT = Path(__file__).resolve().parents[2]
_BUNDLED = _REPO_ROOT / "Sources/COCHelperCore/GameCatalog/18.400.13"

_PNG_SIG = b"\x89PNG\r\n\x1a\n"


def png_size(data: bytes) -> tuple[int, int]:
    """PNG IHDR 宽高（测试断言输出尺寸可解析）。"""
    assert data.startswith(_PNG_SIG)
    return struct.unpack(">II", data[16:24])


def _ok_verdict(container: str, export: str, relpath: str,
                data: bytes = _PNG_SIG + b"test") -> dict:
    return {
        "assetKey": {"container": container, "exportName": export},
        "status": "success", "missingReason": None, "relPath": relpath,
        "png": {"size": len(data), "sha256": "x" * 64},
        "pngBytes": data, "durationMs": 1, "details": {},
    }


def _fail_verdict(container: str, export: str, reason: str) -> dict:
    return {
        "assetKey": {"container": container, "exportName": export},
        "status": "failed", "missingReason": reason, "relPath": None,
        "png": None, "pngBytes": None, "durationMs": 1,
        "details": {"message": "模拟失败"},
    }


def _mini_catalog() -> dict:
    """迷你 catalog：命中/未命中引用混合（item 级 + level 级）。"""
    return {
        "schemaVersion": 1, "gameVersion": "18.400.13", "locale": "zh-CN",
        "items": [
            {
                "section": "units", "dataID": 4000000, "name": "野蛮人",
                "maxLevel": 1, "category": "units",
                "icon": {"container": "sc/ui.sc", "exportName": "icon_unit_barbarian",
                         "renderedPath": None, "missingReason": "icons_not_rendered"},
                "levelVisual": None, "base": "home", "baseMissingReason": None,
                "missingReason": None,
                "levels": [
                    {"level": 1, "icon": {"container": "sc/ui.sc",
                                          "exportName": "icon_unit_barbarian",
                                          "renderedPath": None,
                                          "missingReason": "icons_not_rendered"},
                     "levelVisual": {"container": "sc/buildings.sc",
                                     "exportName": "fireplace_lvl1",
                                     "renderedPath": None,
                                     "missingReason": "icons_not_rendered"},
                     "durationSeconds": 60, "missingReason": None},
                ],
            },
            {
                "section": "buildings", "dataID": 1000070, "name": "铁匠铺",
                "maxLevel": 2, "category": "buildings",
                "icon": None,
                "levelVisual": {"container": "sc/buildings.sc",
                                "exportName": "blacksmith_lvl1",
                                "renderedPath": None,
                                "missingReason": "icons_not_rendered"},
                "base": "home", "baseMissingReason": None,
                "missingReason": None,
                "levels": [
                    {"level": 1, "icon": None,
                     "levelVisual": {"container": "sc/buildings.sc",
                                     "exportName": "blacksmith_lvl1",
                                     "renderedPath": None,
                                     "missingReason": "icons_not_rendered"},
                     "durationSeconds": 60, "missingReason": None},
                    {"level": 2, "icon": None,
                     "levelVisual": {"container": "sc/buildings.sc",
                                     "exportName": "blacksmith_lvl1",
                                     "renderedPath": None,
                                     "missingReason": "icons_not_rendered"},
                     "durationSeconds": 60, "missingReason": None},
                ],
            },
            {
                "section": "spells", "dataID": 26000002, "name": "狂暴法术",
                "maxLevel": 0, "category": "spells",
                "icon": {"container": "sc/ui.sc", "exportName": "icon_spell_rage",
                         "renderedPath": None, "missingReason": "icons_not_rendered"},
                "levelVisual": None, "base": "home", "baseMissingReason": None,
                "missingReason": None,
                "levels": [],
            },
            {
                "section": "heroes", "dataID": 999, "name": "无关条目",
                "maxLevel": 0, "category": "heroes",
                "icon": {"container": "sc/ui.sc", "exportName": "icon_unit_king",
                         "renderedPath": None, "missingReason": "icons_not_rendered"},
                "levelVisual": None, "base": "home", "baseMissingReason": None,
                "missingReason": None,
                "levels": [],
            },
        ],
    }


def _sample_verdicts() -> list[dict]:
    """与 _mini_catalog 匹配的样本 verdicts（4 成功 2 失败）。"""
    return [
        _ok_verdict("sc/ui.sc", "icon_unit_barbarian",
                    "icons/ui/icon_unit_barbarian.png"),
        _ok_verdict("sc/ui.sc", "icon_spell_rage",
                    "icons/ui/icon_spell_rage.png"),
        _ok_verdict("sc/buildings.sc", "fireplace_lvl1",
                    "icons/buildings/fireplace_lvl1.png"),
        _ok_verdict("sc/buildings.sc", "blacksmith_lvl1",
                    "icons/buildings/blacksmith_lvl1.png"),
        _fail_verdict("sc/ui.sc", "icon_unit_does_not_exist", "export_not_found"),
        _fail_verdict("sc/traps.sc", "town_hall_lvl1", "container_not_found"),
    ]


def _mini_manifest() -> str:
    """迷你 manifest.json（陈旧 hash/counts——refresh 会刷新，此处只保证可解析）。"""
    return json.dumps({
        "schemaVersion": 1, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN", "sourceFingerprint": "sha256:" + "a" * 64,
        "generatedFiles": [
            {"path": "catalog.json", "sha256": "sha256:" + "b" * 64, "size": 1},
            {"path": "icons/", "kind": "directory"},
        ],
        "counts": {"items": 0, "levels": 0, "missingTime": 0, "missingIcons": 0},
    }, ensure_ascii=False) + "\n"


def _mini_dir(tmp_path: Path) -> Path:
    """迷你完整目录：catalog.json（_mini_catalog，引用全部 4 个成功样本）+
    manifest.json + icons/。"""
    d = tmp_path / "cat"
    d.mkdir()
    (d / "catalog.json").write_text(
        json.dumps(_mini_catalog(), ensure_ascii=False, indent=2,
                   sort_keys=True) + "\n", encoding="utf-8")
    (d / "manifest.json").write_text(_mini_manifest(), encoding="utf-8")
    (d / "icons").mkdir()
    return d


# ---------------------------------------------------------------------------
# 纯函数：R2.1 container_key / R2.2 sanitize / 契约对照表
# ---------------------------------------------------------------------------


def test_container_key_contract_examples():
    assert container_key("sc/ui.sc") == "ui"
    assert container_key("sc/buildings.sc") == "buildings"
    assert container_key("sc/buildings_cc.sc") == "buildings_cc"


def test_container_key_without_prefix_or_suffix():
    # 无 sc/ 前缀 / 无 .sc 后缀时只去掉存在的部分（真实数据恒带两者）
    assert container_key("ui.sc") == "ui"
    assert container_key("sc/ui") == "ui"


def test_container_key_fail_loud():
    with pytest.raises(CatalogError):
        container_key("sc/")
    with pytest.raises(CatalogError):
        container_key("sc/a/b.sc")  # 剩余段含 /
    with pytest.raises(CatalogError):
        container_key("sc/..")
    with pytest.raises(CatalogError):
        container_key("sc/.")


def test_sanitize_export_key_replaces_separators():
    assert sanitize_export_key("a/b") == "a_b"
    assert sanitize_export_key("a\\b") == "a_b"
    assert sanitize_export_key("icon_unit_barbarian") == "icon_unit_barbarian"


def test_sanitize_export_key_fail_loud():
    with pytest.raises(CatalogError):
        sanitize_export_key("")
    with pytest.raises(CatalogError):
        sanitize_export_key(".")
    with pytest.raises(CatalogError):
        sanitize_export_key("..")
    # 200 字节上限（R2.2）：200 字节通过，201 字节拒绝
    assert sanitize_export_key("x" * 200) == "x" * 200
    with pytest.raises(CatalogError):
        sanitize_export_key("x" * 201)
    # URL 编码段拒绝（与 validate.py rendered_path_format_ok 一致）
    with pytest.raises(CatalogError):
        sanitize_export_key("a%2eb")
    with pytest.raises(CatalogError):
        sanitize_export_key("a%2Fb")


def test_sample_png_relpath_contract_table():
    # 契约 R2.1 对照表：sc/ui.sc + icon_unit_barbarian ⇒ icons/ui/icon_unit_barbarian.png
    assert (sample_png_relpath("sc/ui.sc", "icon_unit_barbarian")
            == "icons/ui/icon_unit_barbarian.png")
    assert (sample_png_relpath("sc/buildings.sc", "fireplace_lvl1")
            == "icons/buildings/fireplace_lvl1.png")


def test_render_samples_rejects_key_collision(tmp_path):
    """R2.3：sanitize 后同路径 → fail loud，不静默覆盖。"""
    apk = tmp_path / "empty.apk"
    with zipfile.ZipFile(apk, "w"):
        pass
    samples = [
        {"container": "sc/ui.sc", "exportName": "a/b"},
        {"container": "sc/ui.sc", "exportName": "a\\b"},
    ]
    with pytest.raises(CatalogError, match="冲突"):
        render_samples(apk, samples)


def test_render_samples_missing_apk_raises(tmp_path):
    with pytest.raises(CatalogError, match="zip"):
        render_samples(tmp_path / "nope.apk")


# ---------------------------------------------------------------------------
# apply_rendered_paths：回写纯逻辑
# ---------------------------------------------------------------------------


def test_apply_rendered_paths_success_and_failure():
    catalog = _mini_catalog()
    new, updated = apply_rendered_paths(catalog, _sample_verdicts())

    assert updated == 7  # barbarian item+level icon、fireplace levelVisual、
    # blacksmith item+level1+level2、rage item icon
    # 成功样本 → renderedPath + missingReason null
    ref = new["items"][0]["icon"]
    assert ref["renderedPath"] == "icons/ui/icon_unit_barbarian.png"
    assert ref["missingReason"] is None
    lv_ref = new["items"][0]["levels"][0]["icon"]
    assert lv_ref["renderedPath"] == "icons/ui/icon_unit_barbarian.png"
    assert lv_ref["missingReason"] is None
    # 失败样本 → renderedPath null + 稳定枚举
    fail_ref = None
    for item in new["items"]:
        if item["section"] == "heroes":
            continue
        for key in ("icon", "levelVisual"):
            r = item.get(key)
            if r and r["exportName"] == "icon_unit_does_not_exist":
                fail_ref = r
    assert fail_ref is None  # mini catalog 不含失败样本引用——失败引用用例见下


def test_apply_rendered_paths_failure_reason_written():
    """匹配失败样本 (container, exportName) 的引用 → renderedPath null + missingReason。"""
    catalog = _mini_catalog()
    catalog["items"][3]["icon"] = {
        "container": "sc/ui.sc", "exportName": "icon_unit_does_not_exist",
        "renderedPath": None, "missingReason": "icons_not_rendered",
    }
    new, updated = apply_rendered_paths(catalog, _sample_verdicts())
    assert updated == 8
    ref = new["items"][3]["icon"]
    assert ref["renderedPath"] is None
    assert ref["missingReason"] == "export_not_found"


def test_apply_rendered_paths_unmatched_untouched():
    """无关引用（icon_unit_king）不在样本表 → 原字段不动（原地修改，匹配引用
    才变更）。"""
    catalog = _mini_catalog()
    new, updated = apply_rendered_paths(catalog, _sample_verdicts())
    assert updated == 7
    assert new is catalog  # 原地修改（2.9MB 真实 catalog 不复制）
    assert new["items"][3]["icon"]["missingReason"] == "icons_not_rendered"
    assert new["items"][3]["icon"]["renderedPath"] is None
    assert new["items"][3] == _mini_catalog()["items"][3]


def test_apply_rendered_paths_dedup_shared_path():
    """R2.4：黑smith 3 个引用（item + level1 + level2）共享同一 renderedPath。"""
    catalog = _mini_catalog()
    new, updated = apply_rendered_paths(catalog, _sample_verdicts())
    assert updated == 7
    item = new["items"][1]
    shared = "icons/buildings/blacksmith_lvl1.png"
    assert item["levelVisual"]["renderedPath"] == shared
    assert item["levels"][0]["levelVisual"]["renderedPath"] == shared
    assert item["levels"][1]["levelVisual"]["renderedPath"] == shared
    for lv in item["levels"]:
        assert lv["levelVisual"]["missingReason"] is None


def test_apply_rendered_paths_missing_refs_skipped():
    """container/exportName 为 None 的引用 → 不崩溃、不更新。"""
    catalog = _mini_catalog()
    catalog["items"][2]["icon"] = {"container": None, "exportName": None,
                                   "renderedPath": None, "missingReason": None}
    new, updated = apply_rendered_paths(catalog, _sample_verdicts())
    assert updated == 6
    assert new["items"][2]["icon"]["renderedPath"] is None


# ---------------------------------------------------------------------------
# write_rendered_outputs：PNG 落盘 + catalog.json 原子回写
# ---------------------------------------------------------------------------


def test_write_pngs_only_success_samples(tmp_path):
    """失败样本不写 PNG 文件、不写伪造路径（R5）。"""
    stats = write_rendered_outputs(tmp_path, _sample_verdicts(),
                                   write_catalog=False)
    assert sorted(stats["pngWritten"]) == [
        "icons/buildings/blacksmith_lvl1.png",
        "icons/buildings/fireplace_lvl1.png",
        "icons/ui/icon_spell_rage.png",
        "icons/ui/icon_unit_barbarian.png",
    ]
    for rel in stats["pngWritten"]:
        assert (tmp_path / rel).is_file()
    # 失败样本无任何文件
    assert not (tmp_path / "icons/ui/icon_unit_does_not_exist.png").exists()
    assert not (tmp_path / "icons/traps/town_hall_lvl1.png").exists()
    # 目录结构：icons/<container_key>/<export_key>.png
    assert (tmp_path / "icons/ui/icon_unit_barbarian.png").read_bytes() \
        == _PNG_SIG + b"test"


def test_write_pngs_dedup_single_file_per_key(tmp_path):
    """同 key 多引用 → 每 key 只写一张 PNG（R2.4）。"""
    verdicts = [_ok_verdict("sc/buildings.sc", "blacksmith_lvl1",
                            "icons/buildings/blacksmith_lvl1.png")]
    stats = write_rendered_outputs(tmp_path, verdicts, write_catalog=False)
    assert stats["pngWritten"] == ["icons/buildings/blacksmith_lvl1.png"]
    assert len(list((tmp_path / "icons/buildings").iterdir())) == 1


def test_write_catalog_atomic_and_format_preserved(tmp_path):
    """回写后 catalog.json 格式与生成管线一致（indent=2、sort_keys、
    ensure_ascii=False、尾部换行）+ 文件内容正确。"""
    (tmp_path / "catalog.json").write_text(
        json.dumps(_mini_catalog(), ensure_ascii=False, indent=2,
                   sort_keys=True) + "\n", encoding="utf-8")
    (tmp_path / "manifest.json").write_text(_mini_manifest(), encoding="utf-8")
    verdicts = [_ok_verdict("sc/ui.sc", "icon_spell_rage",
                            "icons/ui/icon_spell_rage.png")]
    stats = write_rendered_outputs(tmp_path, verdicts, write_catalog=True)
    assert stats["updatedRefs"] == 1

    text = (tmp_path / "catalog.json").read_text(encoding="utf-8")
    assert text.endswith("\n")
    assert "野蛮人" in text  # ensure_ascii=False：中文原样
    assert text.startswith('{\n  "gameVersion"')  # sort_keys 字母序
    new = json.loads(text)
    assert new["items"][2]["icon"]["renderedPath"] == \
        "icons/ui/icon_spell_rage.png"
    assert new["items"][2]["icon"]["missingReason"] is None


def test_write_catalog_missing_file_fails_loud(tmp_path):
    with pytest.raises(CatalogError, match="catalog.json"):
        write_rendered_outputs(tmp_path, _sample_verdicts(), write_catalog=True)


def test_catalog_replace_failure_keeps_original(tmp_path, monkeypatch):
    """原子性：catalog.json replace 失败 → 原文件不被破坏，已替换 PNG 回滚清理。"""
    original = json.dumps(_mini_catalog(), ensure_ascii=False, indent=2,
                          sort_keys=True) + "\n"
    (tmp_path / "catalog.json").write_text(original, encoding="utf-8")
    (tmp_path / "manifest.json").write_text(_mini_manifest(), encoding="utf-8")

    import render_generator as rg

    real_replace = rg.os.replace

    def boom(src, dst):
        if Path(dst).name == "catalog.json":
            raise OSError("simulated replace failure")
        return real_replace(src, dst)

    monkeypatch.setattr(rg.os, "replace", boom)
    with pytest.raises(CatalogError, match="simulated"):
        write_rendered_outputs(tmp_path, _sample_verdicts(), write_catalog=True)
    assert (tmp_path / "catalog.json").read_text(encoding="utf-8") == original
    # 已替换的 PNG 被回滚清理、无 .tmp 残留
    assert list(tmp_path.rglob("*.png")) == []
    assert not any(".render-tmp-" in p.name for p in tmp_path.rglob("*"))


# ---------------------------------------------------------------------------
# P2：事务性落盘（前置检查 / 阶段 1 全 .tmp / 阶段 2 统一替换 / 失败回滚）
# ---------------------------------------------------------------------------


def test_write_catalog_missing_no_png_left(tmp_path):
    """P2：catalog.json 缺失 → 前置检查 fail loud，不写任何 PNG/.tmp。

    match 收紧为完整消息（"catalog.json 不存在"）——区分前置检查路径与
    回滚路径（回滚消息为"渲染落盘失败（已回滚…）"）。
    """
    with pytest.raises(CatalogError, match="catalog.json 不存在"):
        write_rendered_outputs(tmp_path, _sample_verdicts(), write_catalog=True)
    assert list(tmp_path.rglob("*.png")) == []
    assert not any(".render-tmp-" in p.name for p in tmp_path.rglob("*"))


def test_replace_failure_rolls_back_all_outputs(tmp_path, monkeypatch):
    """P2：第 N 次 os.replace 失败（第 3 次替换，即第 2 张 PNG）→ 已替换 PNG
    + 全部 .tmp 清理，catalog.json/manifest.json 保持原内容。"""
    original = json.dumps(_mini_catalog(), ensure_ascii=False, indent=2,
                          sort_keys=True) + "\n"
    (tmp_path / "catalog.json").write_text(original, encoding="utf-8")
    (tmp_path / "manifest.json").write_text(_mini_manifest(), encoding="utf-8")

    import render_generator as rg

    real_replace = rg.os.replace
    counter = {"n": 0}

    def boom(src, dst):
        counter["n"] += 1
        if counter["n"] == 3:  # 替换顺序：4 PNG → catalog.json → manifest.json
            raise OSError("simulated replace failure")
        return real_replace(src, dst)

    monkeypatch.setattr(rg.os, "replace", boom)
    with pytest.raises(CatalogError) as exc_info:
        write_rendered_outputs(tmp_path, _sample_verdicts(), write_catalog=True)
    assert "回滚" in str(exc_info.value)
    assert "simulated replace failure" in str(exc_info.value)
    # 无最终 PNG、无 .tmp；catalog.json 原内容保留
    assert list(tmp_path.rglob("*.png")) == []
    assert not any(".render-tmp-" in p.name for p in tmp_path.rglob("*"))
    assert (tmp_path / "catalog.json").read_text(encoding="utf-8") == original
    assert (tmp_path / "manifest.json").read_text(encoding="utf-8") \
        == _mini_manifest()


def test_manifest_replace_failure_restores_catalog(tmp_path, monkeypatch):
    """P2：第 6 次 os.replace 失败（manifest 替换——坏窗口）→ catalog.json
    按事务前字节快照恢复（旧实现 unlink 会删掉新 catalog.json，导致文件
    消失），manifest.json 原内容保留，PNG/.tmp 零残留。"""
    original_bytes = (json.dumps(_mini_catalog(), ensure_ascii=False,
                                 indent=2, sort_keys=True) + "\n") \
        .encode("utf-8")
    (tmp_path / "catalog.json").write_bytes(original_bytes)
    original_manifest = _mini_manifest().encode("utf-8")
    (tmp_path / "manifest.json").write_bytes(original_manifest)

    import render_generator as rg

    real_replace = rg.os.replace
    counter = {"n": 0}

    def boom(src, dst):
        counter["n"] += 1
        # 替换顺序：4 PNG → catalog.json(第 5 次) → manifest.json(第 6 次)
        if counter["n"] == 6:
            raise OSError("simulated manifest replace failure")
        return real_replace(src, dst)

    monkeypatch.setattr(rg.os, "replace", boom)
    with pytest.raises(CatalogError, match="simulated manifest replace failure"):
        write_rendered_outputs(tmp_path, _sample_verdicts(), write_catalog=True)
    # 坏窗口：catalog.json 已替换——必须字节级恢复为事务前内容
    assert (tmp_path / "catalog.json").read_bytes() == original_bytes
    assert (tmp_path / "manifest.json").read_bytes() == original_manifest
    # 已替换 PNG 回滚清理、无 .tmp 残留
    assert list(tmp_path.rglob("*.png")) == []
    assert not any(".render-tmp-" in p.name for p in tmp_path.rglob("*"))


def test_replace_keyboard_interrupt_not_swallowed(tmp_path, monkeypatch):
    """P2：KeyboardInterrupt 不被吞成 CatalogError——保留中断语义（中断时
    .render-tmp-* 残留可接受，docstring 已注明启动清扫不在本 PR 范围）。"""
    (tmp_path / "catalog.json").write_text(
        json.dumps(_mini_catalog(), ensure_ascii=False, indent=2,
                   sort_keys=True) + "\n", encoding="utf-8")
    (tmp_path / "manifest.json").write_text(_mini_manifest(), encoding="utf-8")

    import render_generator as rg

    def ctrl_c(src, dst):
        raise KeyboardInterrupt

    monkeypatch.setattr(rg.os, "replace", ctrl_c)
    with pytest.raises(KeyboardInterrupt):
        write_rendered_outputs(tmp_path, _sample_verdicts(), write_catalog=True)


# ---------------------------------------------------------------------------
# manifest 刷新（refresh_manifest）：counts 重算 + generatedFiles 一致性
# ---------------------------------------------------------------------------


def test_outputs_manifest_consistent_after_write(tmp_path):
    """正常路径：PNG/catalog.json/manifest.json 三者一致——manifest 中
    catalog.json sha256 == 磁盘、PNG 条目与磁盘一致、counts == validate 重算
    （含 R6.2 renderedIcons == PNG 条目数 / blockedIcons == 失败样本数）。"""
    d = _mini_dir(tmp_path)
    stats = write_rendered_outputs(d, _sample_verdicts())
    assert sorted(stats["pngWritten"]) == [
        "icons/buildings/blacksmith_lvl1.png",
        "icons/buildings/fireplace_lvl1.png",
        "icons/ui/icon_spell_rage.png",
        "icons/ui/icon_unit_barbarian.png",
    ]
    assert stats["cleaned"] == []  # 全部 PNG 均被 catalog 引用，无孤儿

    manifest = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    entries = {e["path"]: e for e in manifest["generatedFiles"]}
    # catalog.json 条目 sha256/size == 磁盘
    cat_bytes = (d / "catalog.json").read_bytes()
    assert entries["catalog.json"]["sha256"] \
        == "sha256:" + hashlib.sha256(cat_bytes).hexdigest()
    assert entries["catalog.json"]["size"] == len(cat_bytes)
    # icons/ 目录条目 entries = PNG 数
    assert entries["icons/"]["entries"] == 4
    # PNG 条目与磁盘一致（引用集合 == 本次写入集合，无孤儿）
    for rel in stats["pngWritten"]:
        data = (d / rel).read_bytes()
        assert entries[rel]["sha256"] \
            == "sha256:" + hashlib.sha256(data).hexdigest()
        assert entries[rel]["size"] == len(data)
    # counts：missingIcons=0（4 个成功样本全部回写）；renderedIcons == PNG 条目数
    assert manifest["counts"] == {"items": 4, "levels": 3,
                                  "missingTime": 0, "missingIcons": 0,
                                  "renderedIcons": 4, "blockedIcons": 2}
    assert validate_catalog(d) == []


def test_write_then_validate_zero_errors(tmp_path):
    """合成目录集成：完整 write_rendered_outputs + refresh_manifest →
    validate_catalog() 零错误（用 test_validate 合成目录工具）。"""
    d = _valid_dir(tmp_path)
    write_rendered_outputs(d, _sample_verdicts())
    assert validate_catalog(d) == []


def test_rewrite_idempotent_validate_clean(tmp_path):
    """重跑幂等：连续两次完整写入 → 第二次后 validate 仍零错误、条目不重复。"""
    d = _valid_dir(tmp_path)
    write_rendered_outputs(d, _sample_verdicts())
    write_rendered_outputs(d, _sample_verdicts())
    assert validate_catalog(d) == []
    manifest = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    paths = [e["path"] for e in manifest["generatedFiles"]]
    assert len(paths) == len(set(paths))


def test_refresh_manifest_standalone_recomputes(tmp_path):
    """refresh_manifest 独立可用（/tmp/refresh_manifest.py 逻辑入库）：陈旧
    counts/hash 全部刷新、PNG 条目原位去重、幂等；blockedIcons 未传入时保留
    manifest 既有值（快照语义），缺失则不写（optional 字段）。"""
    d = _valid_dir(tmp_path)
    png = _PNG_SIG + b"x" * 16
    (d / "icons/ui").mkdir(parents=True)
    (d / "icons/ui/icon_unit_barbarian.png").write_bytes(png)
    m = _load_manifest(d)
    m["counts"] = {"items": 99, "levels": 99, "missingTime": 99,
                   "missingIcons": 99}
    m["generatedFiles"].append({
        "path": "icons/ui/icon_unit_barbarian.png",
        "sha256": "sha256:" + "f" * 64, "size": 1})
    _write(d, manifest=m)

    new = refresh_manifest(d, ["icons/ui/icon_unit_barbarian.png"])
    assert new["counts"] == {"items": 1, "levels": 1,
                             "missingTime": 0, "missingIcons": 0,
                             "renderedIcons": 1}
    entries = {e["path"]: e for e in new["generatedFiles"]}
    assert entries["icons/ui/icon_unit_barbarian.png"] == {
        "path": "icons/ui/icon_unit_barbarian.png",
        "sha256": "sha256:" + hashlib.sha256(png).hexdigest(),
        "size": len(png)}
    assert entries["icons/"]["entries"] == 1
    assert entries["catalog.json"]["sha256"].startswith("sha256:")
    # 幂等：再次刷新不重复追加
    new2 = refresh_manifest(d, ["icons/ui/icon_unit_barbarian.png"])
    paths = [e["path"] for e in new2["generatedFiles"]]
    assert len(paths) == len(set(paths))
    assert validate_catalog(d) == []


def test_refresh_manifest_preserves_blocked_icons_snapshot(tmp_path):
    """独立 refresh_manifest 传入 blocked_count → 写入；未传入 → 保留既有快照值。"""
    d = _valid_dir(tmp_path)
    (d / "icons/ui").mkdir(parents=True)
    (d / "icons/ui/icon_unit_barbarian.png").write_bytes(_PNG_SIG + b"y" * 16)
    m = _load_manifest(d)
    m["counts"]["blockedIcons"] = 3
    _write(d, manifest=m)

    new = refresh_manifest(d, ["icons/ui/icon_unit_barbarian.png"])
    assert new["counts"]["blockedIcons"] == 3  # 未传 blocked_count → 保留快照
    new2 = refresh_manifest(d, ["icons/ui/icon_unit_barbarian.png"],
                            blocked_count=7)
    assert new2["counts"]["blockedIcons"] == 7  # 显式传入 → 覆盖


def test_refresh_manifest_missing_icon_key_fails_loud(tmp_path):
    """refresh_manifest：手编 catalog 的 level 缺 icon 键（畸形数据）→
    CatalogError 语义清晰，不泄漏裸 KeyError（fail loud，缺键属畸形而非
    可容忍缺省）。"""
    d = _valid_dir(tmp_path)
    c = _load_catalog(d)
    del c["items"][0]["levels"][0]["icon"]
    _write(d, catalog=c)
    with pytest.raises(CatalogError, match="icon"):
        refresh_manifest(d, [])


# ---------------------------------------------------------------------------
# R6.2 计数（renderedIcons / blockedIcons）+ 孤儿输出清理（R3 评审项）
# ---------------------------------------------------------------------------


def test_counts_rendered_and_blocked_icons(tmp_path):
    """R6.2：counts.renderedIcons == generatedFiles PNG 条目数（validate 重算
    断言生效）；blockedIcons == 失败样本数；validate 零错误。"""
    d = _mini_dir(tmp_path)
    stats = write_rendered_outputs(d, _sample_verdicts())
    assert sorted(stats["pngWritten"]) == [
        "icons/buildings/blacksmith_lvl1.png",
        "icons/buildings/fireplace_lvl1.png",
        "icons/ui/icon_spell_rage.png",
        "icons/ui/icon_unit_barbarian.png",
    ]
    assert stats["cleaned"] == [] and stats["cleanupFailed"] == []

    manifest = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    png_entries = [e for e in manifest["generatedFiles"]
                   if e.get("kind") != "directory"
                   and e["path"].endswith(".png")]
    assert len(png_entries) == 4
    assert manifest["counts"]["renderedIcons"] == 4
    assert manifest["counts"]["renderedIcons"] == len(png_entries)
    assert manifest["counts"]["blockedIcons"] == 2
    assert validate_catalog(d) == []


def test_old_success_new_failure_cleans_orphan(tmp_path):
    """旧成功→本次失败：第一轮 barbarian 成功（PNG + manifest 条目 + catalog
    引用）；第二轮 verdict 改为 failed → 孤儿 PNG 被删除、generatedFiles 无
    A 条目、catalog A 引用 renderedPath null + missingReason、validate 零错误。"""
    d = _mini_dir(tmp_path)
    write_rendered_outputs(d, _sample_verdicts())
    assert (d / "icons/ui/icon_unit_barbarian.png").is_file()

    verdicts2 = [_fail_verdict("sc/ui.sc", "icon_unit_barbarian",
                               "export_not_found"),
                 *_sample_verdicts()[1:]]
    stats = write_rendered_outputs(d, verdicts2)
    assert stats["cleaned"] == ["icons/ui/icon_unit_barbarian.png"]
    assert not (d / "icons/ui/icon_unit_barbarian.png").exists()

    manifest = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    paths = [e["path"] for e in manifest["generatedFiles"]]
    assert "icons/ui/icon_unit_barbarian.png" not in paths
    assert manifest["counts"]["renderedIcons"] == 3
    assert manifest["counts"]["blockedIcons"] == 3  # barbarian + 2 固定失败

    catalog = json.loads((d / "catalog.json").read_text(encoding="utf-8"))
    item0 = catalog["items"][0]
    assert item0["icon"]["renderedPath"] is None
    assert item0["icon"]["missingReason"] == "export_not_found"
    assert item0["levels"][0]["icon"]["renderedPath"] is None
    assert item0["levels"][0]["icon"]["missingReason"] == "export_not_found"
    assert validate_catalog(d) == []


def test_rerun_idempotent_no_orphans(tmp_path):
    """重跑幂等：连续两次相同运行 → 无孤儿、generatedFiles 无重复、counts
    稳定、磁盘 PNG 集合 == 引用集合、validate 零错误。"""
    d = _mini_dir(tmp_path)
    write_rendered_outputs(d, _sample_verdicts())
    stats = write_rendered_outputs(d, _sample_verdicts())
    assert stats["cleaned"] == []
    assert stats["cleanupFailed"] == []

    manifest = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    paths = [e["path"] for e in manifest["generatedFiles"]]
    assert len(paths) == len(set(paths))
    assert manifest["counts"]["renderedIcons"] == 4
    assert manifest["counts"]["blockedIcons"] == 2
    # 磁盘 PNG 集合与引用集合一致（无孤儿也无遗漏）
    on_disk = sorted(p.relative_to(d).as_posix()
                     for p in (d / "icons").rglob("*.png"))
    assert on_disk == sorted(
        e["path"] for e in manifest["generatedFiles"]
        if e.get("kind") != "directory" and e["path"].endswith(".png"))
    assert validate_catalog(d) == []


def test_cleanup_failure_does_not_block(tmp_path, monkeypatch):
    """清理失败不阻断：unlink 抛错 → write_rendered_outputs 不抛、返回信息含
    cleanupFailed；孤儿 PNG 残留磁盘但目录仍有效（validate 不查孤儿）。"""
    d = _mini_dir(tmp_path)
    write_rendered_outputs(d, _sample_verdicts())
    verdicts2 = [_fail_verdict("sc/ui.sc", "icon_unit_barbarian",
                               "export_not_found"),
                 *_sample_verdicts()[1:]]

    import render_generator as rg

    def boom(path, *args, **kwargs):
        raise OSError("simulated unlink failure")

    monkeypatch.setattr(rg.os, "unlink", boom)
    stats = write_rendered_outputs(d, verdicts2)  # 不抛异常
    assert stats["cleaned"] == []
    assert stats["cleanupFailed"] == ["icons/ui/icon_unit_barbarian.png"]
    # 孤儿 PNG 删除失败残留磁盘，但 manifest 已无条目、validate 零错误
    assert (d / "icons/ui/icon_unit_barbarian.png").is_file()
    assert validate_catalog(d) == []


# ---------------------------------------------------------------------------
# 合成 zip：container_not_found / export_not_found（不依赖真实 APK）
# ---------------------------------------------------------------------------


def test_render_samples_container_not_found(tmp_path):
    apk = tmp_path / "empty.apk"
    with zipfile.ZipFile(apk, "w"):
        pass
    samples = [{"container": "sc/traps.sc", "exportName": "town_hall_lvl1"}]
    meta, verdicts = render_samples(apk, samples)
    assert meta["failedCount"] == 1
    v = verdicts[0]
    assert v["status"] == "failed"
    assert v["missingReason"] == "container_not_found"
    assert v["relPath"] is None
    assert v["png"] is None
    assert v["details"]["zipEntry"] == "assets/sc/traps.sc"


def _minimal_sc(export_names: dict[str, int]) -> bytes:
    """最小可加载 SC2：DataStorage(strings) + ExportNames chunk（无其他 chunk）。

    布局对齐 test_sc2._build_body：body = DataStorage + u32 len + ExportNames。
    """
    from test_fbs import FbBuilder

    strings = list(export_names)
    b = FbBuilder()
    toks = [b.add_string(s) for s in strings]
    ds = b.add_table({0: ("uoffset", b.add_vector(toks))})
    ds_bytes = b.finish(ds)

    ids = [export_names[s] for s in strings]
    b2 = FbBuilder()
    ids_v = b2.add_raw_vector(len(ids), struct.pack("<%dH" % len(ids), *ids))
    refs_v = b2.add_raw_vector(
        len(strings), struct.pack("<%dI" % len(strings), *range(len(strings))))
    en = b2.add_table({0: ("uoffset", ids_v), 1: ("uoffset", refs_v)})
    en_bytes = b2.finish(en)

    body = ds_bytes + struct.pack("<I", len(en_bytes)) + en_bytes

    b3 = FbBuilder()
    desc = b3.add_table({8: ("u32", len(ds_bytes)), 11: ("u32", 0)})
    descriptor = b3.finish(desc)

    return (b"SC" + struct.pack("<H", 6) + b"\x00" * 4
            + struct.pack("<I", len(descriptor)) + descriptor + body)


def test_render_samples_export_not_found(tmp_path):
    """合成 SC2：容器可加载但导出名不存在 → export_not_found（无 PNG）。"""
    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/sc/ui.sc",
                   _minimal_sc({"icon_unit_king": 1}))
    samples = [{"container": "sc/ui.sc", "exportName": "icon_unit_barbarian"}]
    meta, verdicts = render_samples(apk, samples)
    assert meta["successCount"] == 0
    v = verdicts[0]
    assert v["status"] == "failed"
    assert v["missingReason"] == "export_not_found"
    assert v["png"] is None


def test_render_samples_sc_parse_failed(tmp_path):
    """合成 zip：container 存在但 SC2 头损坏 → sc_parse_failed。"""
    apk = tmp_path / "bad.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/sc/ui.sc", b"XX" + b"\x00" * 20)
    samples = [{"container": "sc/ui.sc", "exportName": "icon_unit_barbarian"}]
    _, verdicts = render_samples(apk, samples)
    assert verdicts[0]["status"] == "failed"
    assert verdicts[0]["missingReason"] == "sc_parse_failed"


def _sc_with_external_texture(export: str, shape_id: int, sctx_name: str) -> bytes:
    """含外部纹理引用的最小 SC2：ExportNames → Shape(1 命令) → Textures(external)。

    chunk 顺序固定（read_chunks 按位置识别名字）：ExportNames → TextFields →
    Shapes → MovieClips → MovieClipModifiers → Textures；中间三位用空 table
    占位（size=0 会被 read_chunks 视为终止，不能用来占位）。
    Shape 命令 texture_index=0 引用第一个 TextureSet 的 highres
    （external_texture → 触发 _resolve_texture 外部 sctx 分支）。
    """
    from test_fbs import FbBuilder

    # DataStorage(strings)
    b = FbBuilder()
    ds = b.add_table({0: ("uoffset", b.add_vector([b.add_string(export)]))})
    ds_bytes = b.finish(ds)

    # ExportNames：export → shape_id
    b2 = FbBuilder()
    ids_v = b2.add_raw_vector(1, struct.pack("<H", shape_id))
    refs_v = b2.add_raw_vector(1, struct.pack("<I", 0))
    en = b2.add_table({0: ("uoffset", ids_v), 1: ("uoffset", refs_v)})
    en_bytes = b2.finish(en)

    # Shapes：shape_id + 1 条命令（16B struct：unk1 / texture_index / points_count / points_offset）
    b3 = FbBuilder()
    cmd = struct.pack("<4I", 0, 0, 0, 0)
    shape_tbl = b3.add_table({0: ("u16", shape_id),
                              1: ("uoffset", b3.add_raw_vector(1, cmd))})
    shapes = b3.finish(b3.add_table({0: ("uoffset", b3.add_vector([shape_tbl]))}))

    # Textures：TextureSet{highres: TextureData{external_texture}}
    b4 = FbBuilder()
    td = b4.add_table({5: ("uoffset", b4.add_string(sctx_name))})
    ts = b4.add_table({1: ("uoffset", td)})
    textures = b4.finish(b4.add_table({0: ("uoffset", b4.add_vector([ts]))}))

    b5 = FbBuilder()
    empty = b5.finish(b5.add_table({}))

    body = (ds_bytes
            + struct.pack("<I", len(en_bytes)) + en_bytes
            + struct.pack("<I", len(empty)) + empty  # TextFields
            + struct.pack("<I", len(shapes)) + shapes  # Shapes
            + struct.pack("<I", len(empty)) + empty  # MovieClips
            + struct.pack("<I", len(empty)) + empty  # MovieClipModifiers
            + struct.pack("<I", len(textures)) + textures)  # Textures
    b6 = FbBuilder()
    desc = b6.finish(b6.add_table({8: ("u32", len(ds_bytes))}))
    return (b"SC" + struct.pack("<H", 6) + b"\x00" * 4
            + struct.pack("<I", len(desc)) + desc + body)


def test_render_samples_container_size_gate(tmp_path, monkeypatch):
    """防炸弹门回归（container 读取门）：zip 条目超过 _MAX_ENTRY_BYTES →
    render_failed，不整块 read。

    monkeypatch 把门值调小到 100B（不真写 256MB），容器条目 200B 超限。
    """
    apk = tmp_path / "big-container.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/sc/ui.sc", b"x" * 200)
    monkeypatch.setattr("render_generator._MAX_ENTRY_BYTES", 100)
    samples = [{"container": "sc/ui.sc", "exportName": "icon_unit_barbarian"}]
    _, verdicts = render_samples(apk, samples)
    v = verdicts[0]
    assert v["status"] == "failed"
    assert v["missingReason"] == "render_failed"
    assert v["details"]["fileSize"] == 200
    assert "防炸弹上限" in v["details"]["detail"]
    assert v["relPath"] is None and v["png"] is None


def test_render_samples_external_texture_size_gate(tmp_path, monkeypatch):
    """防炸弹门回归（_resolve_texture 门）：外部 .sctx 条目超过
    _MAX_ENTRY_BYTES → texture_missing，不读超大条目。

    门值动态取「容器条目大小 + 1」：SC2 通过、外部纹理超限（不真写
    256MB）。"""
    sc_bytes = _sc_with_external_texture("icon_unit_barbarian", 5, "big.sctx")
    apk = tmp_path / "big-sctx.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/sc/ui.sc", sc_bytes)
        z.writestr("assets/sc/big.sctx", b"x" * (len(sc_bytes) * 2))
    monkeypatch.setattr("render_generator._MAX_ENTRY_BYTES", len(sc_bytes) + 1)
    samples = [{"container": "sc/ui.sc", "exportName": "icon_unit_barbarian"}]
    _, verdicts = render_samples(apk, samples)
    v = verdicts[0]
    assert v["status"] == "failed"
    assert v["missingReason"] == "texture_missing"
    assert "防炸弹上限" in v["details"]["message"]
    assert v["relPath"] is None and v["png"] is None


# ---------------------------------------------------------------------------
# render.composite_shapes：多命令合成（blacksmith 5 命令路径）
# ---------------------------------------------------------------------------


def _const_block(r: int, g: int, b: int, a: int) -> bytes:
    """ASTC const U16 块（可解码为整块同色，对齐 test_ktx）。

    通道为 16 位打包值（0xFF00 = 255、0x8000 = 128）。
    """
    head = bytes([0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    return head + struct.pack("<4H", r, g, b, a)


def _make_ktx(width: int, height: int, color: tuple[int, int, int, int]) -> bytes:
    """单 const 块 KTX（ASTC 4x4）：2x2 尺寸 + 1 块。"""
    level0 = _const_block(*color)
    header = struct.pack("<13I", 0x04030201, 0, 1, 0, 0x93B0, 6408,
                         width, height, 0, 0, 1, 1, 0)
    return (b"\xabKTX 11\xbb\r\n\x1a\n" + header
            + struct.pack("<I", len(level0)) + level0)


def _v(x: float, y: float, u: float, v: float):
    from game_catalog.sc2 import Vertex
    return Vertex(x=x, y=y, u=u, v=v)


def _quad(x0: float, y0: float, x1: float, y1: float,
          u0: float, v0: float, u1: float, v1: float):
    """8 顶点 quad（triangle strip 惯例）。"""
    return [_v(x0, y0, u0, v0), _v(x0, y1, u0, v1),
            _v(x1, y0, u1, v0), _v(x1, y1, u1, v1),
            _v(x1, y0, u1, v0), _v(x0, y1, u0, v1),
            _v(x1, y1, u1, v1), _v(x0, y1, u0, v1)]


def test_composite_shapes_union_canvas_and_blend():
    """两命令（不同纹理/不同位置）→ 同一画布 + src-over 混合（后覆盖前）。"""
    from game_catalog.ktx import parse_ktx
    from game_catalog.render import composite_shapes

    img_red = parse_ktx(_make_ktx(2, 2, (0xFF00, 0, 0, 0xFF00)))
    img_blue = parse_ktx(_make_ktx(2, 2, (0, 0, 0xFF00, 0x8000)))
    red_quad = _quad(0, 0, 10, 10, 0, 0, 1, 1)
    blue_quad = _quad(5, 5, 15, 15, 0, 0, 1, 1)
    w, h, rgba = composite_shapes([(img_red, red_quad), (img_blue, blue_quad)])
    assert (w, h) == (15, 15)  # union bounds 0..15 → ceil 15x15
    # 重叠区（蓝色半透明覆盖红色）→ 颜色混合
    for x in (7, 8):
        off = (8 * w + x) * 4
        assert rgba[off + 3] > 0
    # 纯蓝区 alpha=128、纯红区 alpha=255
    blue_only = rgba[(8 * w + 12) * 4:(8 * w + 12) * 4 + 4]
    assert blue_only[3] == 128 and blue_only[0] == 0
    red_only = rgba[(2 * w + 2) * 4:(2 * w + 2) * 4 + 4]
    assert red_only == bytes((255, 0, 0, 255))


def test_composite_shapes_single_equals_render_shape_from_image():
    from game_catalog.ktx import parse_ktx
    from game_catalog.render import composite_shapes, render_shape_from_image

    img = parse_ktx(_make_ktx(2, 2, (0x0A00, 0x1400, 0x1E00, 0xFF00)))
    vs = _quad(0, 0, 8, 6, 0, 0, 1, 1)
    assert composite_shapes([(img, vs)]) == render_shape_from_image(img, vs)


def test_composite_shapes_ignores_degenerate_layer_when_other_layer_is_valid():
    """共线的 APK 占位层不应吞掉同一 MovieClip 中的有效图层。"""
    from game_catalog.ktx import parse_ktx
    from game_catalog.render import composite_shapes

    img = parse_ktx(_make_ktx(2, 2, (0x0A00, 0x1400, 0x1E00, 0xFF00)))
    valid = _quad(0, 0, 8, 6, 0, 0, 1, 1)
    degenerate = [
        _v(20, 20, 0, 0), _v(25, 25, 0.5, 0.5),
        _v(30, 30, 1, 1), _v(35, 35, 1, 1),
    ]
    w, h, rgba = composite_shapes([(img, valid), (img, degenerate)])
    assert (w, h) == (8, 6)
    assert any(rgba[i + 3] for i in range(0, len(rgba), 4))


def test_composite_shapes_empty_fails():
    from game_catalog.render import composite_shapes
    with pytest.raises(CatalogError, match="无任何"):
        composite_shapes([])


def test_compose_matrices_applies_child_then_parent():
    """嵌套 MovieClip：先应用子层局部矩阵，再应用父层矩阵。"""
    parent = Matrix2x3(a=2, b=0, c=0, d=3, tx=10, ty=20)
    child = Matrix2x3(a=1, b=0, c=0, d=1, tx=4, ty=5)
    composed = _compose_matrices(parent, child)
    assert composed is not None
    assert composed.apply(1, 1) == (20, 38)
    assert _compose_matrices(None, child) == child
    assert _compose_matrices(parent, None) == parent


# ---------------------------------------------------------------------------
# 真实 APK 集成（标记 slow；COC_APK_PATH 缺失时跳过）
# ---------------------------------------------------------------------------


@_real_apk
class TestRealApk:
    def test_firespitter_recursively_renders_nested_movieclips(self):
        """火焰喷射器不是单个 shape：嵌套层必须进入最终 PNG。"""
        _, verdicts = render_samples(APK, [{
            "container": "sc/buildings.sc",
            "exportName": "firespitter_lvl1",
        }])
        v = verdicts[0]
        assert v["status"] == "success", v
        assert v["missingReason"] is None
        assert v["details"]["shapeElementCount"] > 1
        tree = v["details"]["movieClipTree"]
        assert any(node["depth"] > 0 for node in tree)
        assert not any(
            item["kind"] == "nested_movieclip"
            for item in v["details"].get("skippedElements", [])
        )
        w, h = png_size(v["pngBytes"])
        assert w > 0 and h > 0

    def test_render_samples_4_success_2_failed(self, tmp_path):
        """4 成功样本 PNG 存在且非空 + IHDR 尺寸可解析；失败样本无 PNG。"""
        meta, verdicts = render_samples(APK)
        assert meta["successCount"] == 4
        assert meta["failedCount"] == 2

        by_key = {(v["assetKey"]["container"], v["assetKey"]["exportName"]): v
                  for v in verdicts}
        success_keys = [
            ("sc/ui.sc", "icon_unit_barbarian"),
            ("sc/ui.sc", "icon_spell_rage"),
            ("sc/buildings.sc", "fireplace_lvl1"),
            ("sc/buildings.sc", "blacksmith_lvl1"),
        ]
        for k in success_keys:
            v = by_key[k]
            assert v["status"] == "success", v
            assert v["missingReason"] is None
            w, h = png_size(v["pngBytes"])
            assert w > 0 and h > 0
            assert v["png"]["size"] == len(v["pngBytes"])
            assert v["relPath"].startswith("icons/")

        assert by_key[("sc/ui.sc", "icon_unit_does_not_exist")]["missingReason"] \
            == "export_not_found"
        assert by_key[("sc/traps.sc", "town_hall_lvl1")]["missingReason"] \
            == "container_not_found"
        # 失败样本不产出 PNG
        for v in verdicts:
            if v["status"] == "failed":
                assert v["png"] is None and v["relPath"] is None

        # 完整链路落盘（写 PNG + 迷你 catalog 回写）在写盘测试覆盖；
        # 此处再断言 blacksmith 多命令合成输出尺寸合理（> 单命令最小）
        b = by_key[("sc/buildings.sc", "blacksmith_lvl1")]
        w, h = png_size(b["pngBytes"])
        assert w >= 100 and h >= 100  # 5 命令 union bounds 画布

    def test_determinism_sha256_stable(self):
        """R4：同一 APK 两次生成 → PNG 字节一致。"""
        _, v1 = render_samples(APK)
        _, v2 = render_samples(APK)
        ok1 = {v["relPath"]: v["png"]["sha256"] for v in v1
               if v["status"] == "success"}
        ok2 = {v["relPath"]: v["png"]["sha256"] for v in v2
               if v["status"] == "success"}
        assert ok1 == ok2
        assert len(ok1) == 4

    def test_writeback_on_catalog_copy(self, tmp_path):
        """完整回写（迷你 catalog 副本，Issue #25 全量模式）：收集引用全更新、
        PNG 落盘、失败引用写入 missingReason 且不写文件。"""
        from render_generator import main

        catalog = _mini_catalog()
        # heroes 条目改为已知失败键：验证失败引用也参与全量收集与回写
        catalog["items"][3]["icon"] = {
            "container": "sc/ui.sc", "exportName": "icon_unit_does_not_exist",
            "renderedPath": None, "missingReason": "icons_not_rendered"}
        (tmp_path / "catalog.json").write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2,
                       sort_keys=True) + "\n", encoding="utf-8")
        (tmp_path / "manifest.json").write_text(_mini_manifest(),
                                                encoding="utf-8")

        rc = main(["--apk", str(APK), "--catalog", str(tmp_path),
                   "--report", str(tmp_path / "report.json")])
        assert rc == 0

        new = json.loads((tmp_path / "catalog.json").read_text(encoding="utf-8"))

        def count_refs(pred) -> int:
            n = 0
            for item in new["items"]:
                for holder in (item, *item.get("levels", [])):
                    for key in ("icon", "levelVisual"):
                        r = holder.get(key)
                        if r and pred(r):
                            n += 1
            return n

        # 全量收集 5 键（4 成功 + 1 失败）→ 7 处成功引用 + 1 处失败引用
        assert count_refs(lambda r: r.get("renderedPath") is not None) == 7
        assert count_refs(lambda r: r.get("missingReason") is not None) == 1
        fail_ref = None
        for item in new["items"]:
            r = item.get("icon")
            if r and r["exportName"] == "icon_unit_does_not_exist":
                fail_ref = r
        assert fail_ref["renderedPath"] is None
        assert fail_ref["missingReason"] == "export_not_found"

        # 每个成功样本的 PNG 落盘（R2.1 命名）
        for s in SAMPLES[:4]:
            rel = sample_png_relpath(s["container"], s["exportName"])
            f = tmp_path / rel
            assert f.is_file() and f.stat().st_size > 0
            # renderedPath 指向真实文件
            assert count_refs(lambda r, rel=rel: r.get("renderedPath") == rel) > 0
        # 失败样本无文件、无路径
        assert not (tmp_path / "icons/ui/icon_unit_does_not_exist.png").exists()
        assert not (tmp_path / "icons/traps").exists()

        # 报告 JSON 可解析且含 verdict/sha256
        report = json.loads((tmp_path / "report.json").read_text(encoding="utf-8"))
        assert report["meta"]["successCount"] == 4
        assert report["meta"]["failedCount"] == 1
        assert len(report["samples"]) == 5
        assert report["samples"][0]["png"]["sha256"]

    def test_cli_samples_only_does_not_touch_catalog(self, tmp_path):
        """--samples-only：PNG + 报告，catalog.json 原样。"""
        from render_generator import main

        src = _BUNDLED / "catalog.json"
        dst = tmp_path / "catalog.json"
        dst.write_bytes(src.read_bytes())
        before = dst.read_bytes()

        rc = main(["--apk", str(APK), "--catalog", str(tmp_path),
                   "--samples-only", "--report", str(tmp_path / "r.json")])
        assert rc == 0
        assert dst.read_bytes() == before
        assert (tmp_path / "icons/ui/icon_unit_barbarian.png").is_file()
        assert (tmp_path / "r.json").is_file()


# ---------------------------------------------------------------------------
# Issue #25：全量引用收集（collect_catalog_refs）
# ---------------------------------------------------------------------------


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


@given(pairs=st.lists(st.tuples(
    st.one_of(st.none(), st.text(min_size=1)),
    st.one_of(st.none(), st.text(min_size=1)),
), max_size=50))
@settings(max_examples=100,
          suppress_health_check=[HealthCheck.function_scoped_fixture])
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


# ---------------------------------------------------------------------------
# Issue #25：collect_catalog_refs 畸形输入 fail loud（CatalogError）
# ---------------------------------------------------------------------------


def test_collect_catalog_refs_malformed_top_level(tmp_path):
    """catalog 顶层非对象 → CatalogError（fail loud，不被 main() 吞掉）。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps(["not-an-object"]), encoding="utf-8")
    with pytest.raises(CatalogError, match="顶层不是对象"):
        collect_catalog_refs(cat)


@pytest.mark.parametrize("bad", [{"a": 1}, 42, "items", True])
def test_collect_catalog_refs_malformed_items(tmp_path, bad):
    """items 非 list → CatalogError（消息含字段名）。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({"items": bad}), encoding="utf-8")
    with pytest.raises(CatalogError, match="items"):
        collect_catalog_refs(cat)


def test_collect_catalog_refs_items_none_is_empty(tmp_path):
    """items 缺失或为 None → 空引用列表（不报错，契约兼容）。"""
    cat = tmp_path / "catalog.json"
    for payload in ({}, {"items": None}):
        cat.write_text(json.dumps(payload), encoding="utf-8")
        assert collect_catalog_refs(cat) == []


@pytest.mark.parametrize("bad", ["x", 42, None, True, [1, 2]])
def test_collect_catalog_refs_malformed_item(tmp_path, bad):
    """items 元素非 dict → CatalogError（fail loud，消息含 item 字段）。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({"items": [bad]}), encoding="utf-8")
    with pytest.raises(CatalogError, match="item"):
        collect_catalog_refs(cat)


@pytest.mark.parametrize("bad", [{"a": 1}, 42, "lvl", True])
def test_collect_catalog_refs_malformed_levels(tmp_path, bad):
    """item.levels 非 list → CatalogError。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({"items": [{"levels": bad}]}), encoding="utf-8")
    with pytest.raises(CatalogError, match="levels"):
        collect_catalog_refs(cat)


def test_collect_catalog_refs_levels_none_is_empty(tmp_path):
    """item.levels 缺失或为 None → 不报错。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({"items": [{"levels": None}]}), encoding="utf-8")
    assert collect_catalog_refs(cat) == []


@pytest.mark.parametrize("bad", ["x", 42, None, True, [1, 2]])
def test_collect_catalog_refs_malformed_level(tmp_path, bad):
    """level 元素非 dict → CatalogError。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({"items": [{"levels": [bad]}]}), encoding="utf-8")
    with pytest.raises(CatalogError, match="level"):
        collect_catalog_refs(cat)


@pytest.mark.parametrize("field", ["container", "exportName"])
def test_collect_catalog_refs_malformed_ref_field(tmp_path, field):
    """item 级 container/exportName 非 str 但非 None → CatalogError
    （防 `container: 123` 这类 truthy 非 str 静默通过）。"""
    cat = tmp_path / "catalog.json"
    ref = {"container": "sc/ui.sc", "exportName": "a", field: 123}
    cat.write_text(json.dumps({"items": [{"icon": ref}]}), encoding="utf-8")
    with pytest.raises(CatalogError, match=field):
        collect_catalog_refs(cat)


def test_collect_catalog_refs_malformed_level_ref_field(tmp_path):
    """level 级引用 container 非 str → CatalogError（add 统一入口覆盖）。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({
        "items": [{"levels": [{"icon": {"container": 123, "exportName": "x"}}]}]
    }), encoding="utf-8")
    with pytest.raises(CatalogError, match="container"):
        collect_catalog_refs(cat)


@pytest.mark.parametrize("payload", [
    {"icon": "foo"},                  # item 级 icon 为 str
    {"levelVisual": 42},              # item 级 levelVisual 为 int
    {"levels": [{"icon": ["x"]}]},    # level 级 icon 为 list
])
def test_collect_catalog_refs_malformed_ref_value(tmp_path, payload):
    """icon/levelVisual 非 None 且非 dict → CatalogError（消息含路径，
    不静默跳过）。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({"items": [payload]}), encoding="utf-8")
    with pytest.raises(CatalogError, match="非对象") as exc_info:
        collect_catalog_refs(cat)
    assert str(cat) in str(exc_info.value)


def test_collect_catalog_refs_ref_none_and_dict_ok(tmp_path):
    """icon/levelVisual 为 None 或正常 dict → 不受影响（None 跳过、dict 收集）。"""
    cat = tmp_path / "catalog.json"
    cat.write_text(json.dumps({"items": [
        {"icon": None, "levelVisual": None},
        {"icon": {"container": "sc/ui.sc", "exportName": "icon_ok"}},
        {"levels": [
            {"levelVisual": None},
            {"levelVisual": {"container": "sc/ui.sc", "exportName": "icon_lvl"}},
        ]},
    ]}), encoding="utf-8")
    assert collect_catalog_refs(cat) == [
        {"container": "sc/ui.sc", "exportName": "icon_ok"},
        {"container": "sc/ui.sc", "exportName": "icon_lvl"},
    ]


# ---------------------------------------------------------------------------
# Issue #25：_blend_src_over 溢出修复回归（EB3DC59 已修复，钉住行为）
# ---------------------------------------------------------------------------


def test_blend_src_over_low_alpha_no_overflow():
    """Issue #25 回归：sa=da=1 且 src=dst=255 时旧公式分子 509>255
    ValueError；修复后必须输出合法 RGBA 值。"""
    from game_catalog.render import _blend_src_over

    canvas = bytearray([255, 255, 255, 1])
    layer = bytes([255, 255, 255, 1])
    _blend_src_over(canvas, layer)  # 修复前抛 ValueError
    assert all(0 <= b <= 255 for b in canvas)


def test_blend_src_over_range_and_alpha_exhaustive():
    """Issue #25 回归：小范围穷举 sa/da ∈ {1,2,254} × src/dst ∈ {0,128,255}，
    输出字节全部 ∈ [0,255]（覆盖修复前分子 >255 的溢出路径），且 alpha
    精确等于 src-over 公式 sa + da*(255-sa)//255。"""
    from game_catalog.render import _blend_src_over

    for sa in (1, 2, 254):
        for da in (1, 2, 254):
            for src in (0, 128, 255):
                for dst in (0, 128, 255):
                    canvas = bytearray([dst, dst, dst, da])
                    layer = bytes([src, src, src, sa])
                    _blend_src_over(canvas, layer)
                    assert all(0 <= b <= 255 for b in canvas), (
                        sa, da, src, dst, list(canvas))
                    # alpha 按 src-over 公式精确成立（整数除，确定性）
                    expected_a = sa + da * (255 - sa) // 255
                    assert canvas[3] == expected_a, (
                        sa, da, src, dst, list(canvas))
