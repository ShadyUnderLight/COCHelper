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
  正确、catalog 回写字段正确、失败样本不产生 PNG

真实样本期望（Task 1-6 实证 + 本任务对拍）：
- icon_unit_barbarian：帧 0 有 2 元素（textfield 跳过 + shape 8025 单命令）→ 成功
- icon_spell_rage：帧 0 单元素 shape 21490 单命令 → 成功
- fireplace_lvl1：帧 0 有 shape 1549（单命令）+ 嵌套 movieclip 1607（360 帧，
  记录跳过）→ 成功
- blacksmith_lvl1：帧 0 shape 1643 五命令（合成一画布）+ 嵌套 movieclip 1645
  （阴影，记录跳过）→ 成功
- icon_unit_does_not_exist / sc/traps.sc town_hall_lvl1 → 失败
"""

import json
import os
import struct
import zipfile
from pathlib import Path

import pytest

from game_catalog.errors import CatalogError
from render_generator import (
    SAMPLES,
    apply_rendered_paths,
    container_key,
    render_samples,
    sample_png_relpath,
    sanitize_export_key,
    write_rendered_outputs,
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
                "maxLevel": 2, "category": "units",
                "icon": {"container": "sc/ui.sc", "exportName": "icon_unit_barbarian",
                         "renderedPath": None, "missingReason": "icons_not_rendered"},
                "levelVisual": None, "base": None, "baseMissingReason": None,
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
                "base": None, "baseMissingReason": None,
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
                "maxLevel": 1, "category": "spells",
                "icon": {"container": "sc/ui.sc", "exportName": "icon_spell_rage",
                         "renderedPath": None, "missingReason": "icons_not_rendered"},
                "levelVisual": None, "base": None, "baseMissingReason": None,
                "missingReason": None,
                "levels": [],
            },
            {
                "section": "heroes", "dataID": 999, "name": "无关条目",
                "maxLevel": 1, "category": "heroes",
                "icon": {"container": "sc/ui.sc", "exportName": "icon_unit_king",
                         "renderedPath": None, "missingReason": "icons_not_rendered"},
                "levelVisual": None, "base": None, "baseMissingReason": None,
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
    """原子性：catalog.json replace 失败 → 原文件不被破坏。"""
    original = json.dumps(_mini_catalog(), ensure_ascii=False, indent=2,
                          sort_keys=True) + "\n"
    (tmp_path / "catalog.json").write_text(original, encoding="utf-8")

    import render_generator as rg

    real_replace = rg.os.replace

    def boom(src, dst):
        if Path(dst).name == "catalog.json":
            raise OSError("simulated replace failure")
        return real_replace(src, dst)

    monkeypatch.setattr(rg.os, "replace", boom)
    with pytest.raises(OSError, match="simulated"):
        write_rendered_outputs(tmp_path, _sample_verdicts(), write_catalog=True)
    assert (tmp_path / "catalog.json").read_text(encoding="utf-8") == original


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


def test_composite_shapes_empty_fails():
    from game_catalog.render import composite_shapes
    with pytest.raises(CatalogError, match="无任何"):
        composite_shapes([])


# ---------------------------------------------------------------------------
# 真实 APK 集成（标记 slow；COC_APK_PATH 缺失时跳过）
# ---------------------------------------------------------------------------


@_real_apk
class TestRealApk:
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
        """完整回写（真实 catalog.json 副本）：匹配引用全更新、PNG 落盘、
        失败样本不更新不写文件。"""
        from render_generator import main

        src = _BUNDLED / "catalog.json"
        assert src.is_file(), f"bundled catalog 缺失: {src}"
        dst = tmp_path / "catalog.json"
        dst.write_bytes(src.read_bytes())

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

        sample_keys = {(s["container"], s["exportName"]) for s in SAMPLES}
        matched_before = 0
        for item in json.loads(src.read_text(encoding="utf-8"))["items"]:
            for holder in (item, *item.get("levels", [])):
                for key in ("icon", "levelVisual"):
                    r = holder.get(key)
                    if r and (r.get("container"), r.get("exportName")) \
                            in sample_keys:
                        matched_before += 1

        # 所有匹配引用：成功 → 同一路径；失败 → 无匹配引用（不动）
        assert matched_before == count_refs(
            lambda r: r.get("renderedPath") is not None
            and r.get("missingReason") is None)
        assert matched_before == count_refs(
            lambda r: (r.get("container"), r.get("exportName"))
            in sample_keys and r.get("renderedPath") is not None)
        # 无关引用保持 missingReason
        assert count_refs(lambda r: r.get("renderedPath") is None
                          and r.get("missingReason") == "icons_not_rendered") > 0

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
        assert len(report["samples"]) == 6
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
