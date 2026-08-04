"""真实 APK 集成测试（issue #13 验收 #1-10 锚点）。无 APK 时跳过。

生成一次约 30-60 秒（546MB APK 哈希），module scope fixture 只跑一次。
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

APK = Path("/Users/lmz/Downloads/base.apk.1")
TOOLS = Path(__file__).resolve().parents[2] / "Tools"

pytestmark = pytest.mark.skipif(not APK.is_file(), reason="真实 APK 不存在")

# (section, dataID) → 期望 maxLevel；level → 期望秒数
SAMPLES = {
    "town_hall": {"key": ("buildings", 1000001), "max_level": 18, "level_18_seconds": 1036800},
    "barbarian": {"key": ("units", 4000000), "max_level": 13, "level_13_seconds": 1081800},
    "lightning": {"key": ("spells", 26000000), "max_level": 13},
    "hero": {"key": ("heroes", 28000000)},
    "pet": {"key": ("pets", 73000000)},
}

def _find(items, section, data_id):
    return next((i for i in items if i["section"] == section and i["dataID"] == data_id), None)


def _run_generate(out: Path) -> None:
    if out.exists():
        shutil.rmtree(out)
    r = subprocess.run([sys.executable, str(TOOLS / "generate_game_catalog.py"),
                        "--apk", str(APK), "--output", str(out),
                        "--game-version", "18.400.13"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


@pytest.fixture(scope="module")
def catalog():
    out = Path("/tmp/coc-game-catalog-test")
    _run_generate(out)
    data = json.loads((out / "catalog.json").read_text(encoding="utf-8"))
    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    return data, manifest, out


def test_acceptance_version_and_buildtag(catalog):
    data, manifest, _ = catalog
    assert manifest["gameVersion"] == "18.400.13"
    assert manifest["buildTag"] == "18_400_7"
    assert manifest["sourceFingerprint"].startswith("sha256:")
    assert data["gameVersion"] == manifest["gameVersion"]


def test_acceptance_core_items_exist(catalog):
    data, _, _ = catalog
    for name, sample in SAMPLES.items():
        section, data_id = sample["key"]
        item = _find(data["items"], section, data_id)
        assert item is not None, f"{name} 未找到 ({section}:{data_id})"
        if "max_level" in sample:
            assert item["maxLevel"] == sample["max_level"], f"{name} maxLevel"


def test_acceptance_town_hall_18_is_12_days(catalog):
    data, _, _ = catalog
    item = _find(data["items"], "buildings", 1000001)
    lv18 = next(lv for lv in item["levels"] if lv["level"] == 18)
    assert lv18["durationSeconds"] == 1036800


def test_acceptance_barbarian_13_is_300h30m(catalog):
    data, _, _ = catalog
    item = _find(data["items"], "units", 4000000)
    lv13 = next(lv for lv in item["levels"] if lv["level"] == 13)
    assert lv13["durationSeconds"] == 1081800


def test_acceptance_distinct_asset_references(catalog):
    data, _, _ = catalog
    th = _find(data["items"], "buildings", 1000001)
    assert th["levelVisual"] is not None
    lv1 = next(lv for lv in th["levels"] if lv["level"] == 1)
    lv18 = next(lv for lv in th["levels"] if lv["level"] == 18)
    assert lv1["levelVisual"]["exportName"] != lv18["levelVisual"]["exportName"]
    barb = _find(data["items"], "units", 4000000)
    assert barb["icon"] is not None
    assert barb["icon"]["exportName"] == "icon_unit_barbarian"


def test_acceptance_siege_machines_split(catalog):
    data, _, _ = catalog
    siege = [i for i in data["items"] if i["section"] == "siege_machines"]
    assert siege, "攻城机器段为空"
    assert all(i["category"] == "siegeMachines" for i in siege)
    # 中文显示名：攻城战车 = Wall Wrecker、攻城飞艇 = Battle Blimp
    assert any(i["name"] == "攻城战车" for i in siege)


def test_acceptance_equipment_missing_reason(catalog):
    data, _, _ = catalog
    items = [i for i in data["items"] if i["section"] == "equipment"]
    assert items
    assert all(lv["missingReason"] == "no_time_source" for i in items for lv in i["levels"])


def test_acceptance_capital_missing_reason(catalog):
    data, _, _ = catalog
    items = [i for i in data["items"] if i["section"].startswith("capital_")]
    assert items
    assert all(lv["missingReason"] == "time_missing" for i in items for lv in i["levels"])
    # 都城无主村/工人基地概念：base=null + baseMissingReason
    assert all(i["base"] is None and i["baseMissingReason"] == "capital_has_no_base"
               for i in items)


def test_acceptance_no_merge_and_level_continuity(catalog):
    data, _, _ = catalog
    barb = _find(data["items"], "units", 4000000)
    levels = [lv["level"] for lv in barb["levels"]]
    assert levels == list(range(1, 14))  # 13 级逐级保留，未合并


def test_acceptance_guardians_join_and_out_of_range(catalog):
    data, _, _ = catalog
    items = [i for i in data["items"] if i["section"] == "guardians"]
    assert items
    first = items[0]
    assert first["dataID"] == 107_000_000
    # 至少前几级来自 upgrade_data，超出范围级 missingReason
    assert any(lv["durationSeconds"] is not None for lv in first["levels"])
    assert any(lv["missingReason"] == "upgrade_data_missing" for i in items for lv in i["levels"])


def test_acceptance_deterministic_regeneration(catalog):
    _, _, out = catalog
    out2 = Path("/tmp/coc-game-catalog-test-2")
    _run_generate(out2)
    assert (out / "catalog.json").read_bytes() == (out2 / "catalog.json").read_bytes()
    assert (out / "manifest.json").read_bytes() == (out2 / "manifest.json").read_bytes()


def test_acceptance_dataid_compat_with_name_catalog(catalog):
    """与现有 generate_account_name_catalog 的 dataID 段对齐（heroes/pets/equipment/guardians）。

    只读调用 legacy build_catalog（不改它）。legacy 是扁平名册字典：heroes 段把全部
    8 个英雄（含工人基地的战争机器/战斗直升机）冗余写入 heroes 和 heroes2 两段；
    新管线按 VillageType 正确分流（主村→heroes、工人基地→heroes2）。因此对齐语义为：
    - 逐段子集：新管线每个 (section, dataID) 都能在 legacy 同名段解析出名称；
    - 并集相等：合并两段后 dataID 集合与 legacy 完全一致（无缺口）。
    """
    data, _, _ = catalog
    sys.path.insert(0, str(TOOLS))
    import generate_account_name_catalog as legacy
    legacy_cat = legacy.build_catalog(APK)
    sections_map = (("heroes", "heroes2"), ("pets", None),
                    ("equipment", None), ("guardians", None))
    for section, section2 in sections_map:
        sections = (section, section2) if section2 else (section,)
        new_ids = {str(i["dataID"]) for i in data["items"] if i["section"] in sections}
        legacy_ids = {k.split(":")[1] for k in legacy_cat if k.split(":")[0] in sections}
        assert new_ids == legacy_ids, \
            f"{sections} dataID 并集不兼容: new={len(new_ids)} legacy={len(legacy_ids)}"
        for s in sections:
            new_s = {str(i["dataID"]) for i in data["items"] if i["section"] == s}
            legacy_s = {k.split(":")[1] for k in legacy_cat if k.split(":")[0] == s}
            assert new_s <= legacy_s, f"{s}: 新管线 dataID 超出 legacy 段: {sorted(new_s - legacy_s)}"
