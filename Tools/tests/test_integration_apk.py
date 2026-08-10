"""真实 APK 集成测试（issue #13 验收 #1-10 锚点）。无 APK 时跳过。

生成一次约 30-60 秒（546MB APK 哈希），module scope fixture 只跑一次。
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

APK = Path(__import__("os").environ.get("COC_APK_PATH", "/Users/lmz/Downloads/base.apk.1"))
TOOLS = Path(__file__).resolve().parents[2] / "Tools"

pytestmark = pytest.mark.skipif(
    not APK.is_file(),
    reason="真实 APK 不存在（设置 COC_APK_PATH 指向 base.apk.1 可启用集成测试）",
)

# (section, dataID) → 期望 maxLevel；level → 期望秒数
SAMPLES = {
    "town_hall": {"key": ("buildings", 1000001), "max_level": 18, "level_18_seconds": 1036800},
    "barbarian": {"key": ("units", 4000000), "max_level": 13, "level_13_seconds": 1080000},
    "lightning": {"key": ("spells", 26000000), "max_level": 13, "level_13_seconds": 1209600},
    "hero": {"key": ("heroes", 28000000)},
    "pet": {"key": ("pets", 73000000)},
    "inferno_artillery": {"key": ("guardians", 107000000), "max_level": 5, "level_5_seconds": 1123200},
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
    # Issue #98 复审 P1：完整两步生成链——craft 表生成器登记 manifest 条目
    #（validator 强制条目存在；主生成器自检豁免，独立校验强制）
    r = subprocess.run([sys.executable, str(TOOLS / "generate_craft_table_catalog.py"),
                        "--apk", str(APK), "--game-version", "18.400.13",
                        "--output", str(out / "craft_table_catalog.json")],
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


def test_acceptance_barbarian_to_next_semantics(catalog):
    """单位表 to_next 语义锚点（真实 APK 验证 + wiki/statscell 双源）：
    - 行 12（300h）→ level 13 = 1080000（不是 300h30m=1081800 的错误继承）
    - 行 1（0h30m）→ level 2 = 1800（升级到 2 级 = 30 分钟）
    - 行 2（1h）→ level 3 = 3600（UpM='' 按 0，不继承行 1 的 30m）
    - level 1 = 初始等级，无升级
    """
    data, _, _ = catalog
    item = _find(data["items"], "units", 4000000)
    by_lvl = {lv["level"]: lv for lv in item["levels"]}
    assert item["maxLevel"] == 13
    assert sorted(by_lvl) == list(range(1, 14))  # levels 覆盖 1..13 共 13 项
    assert by_lvl[1]["durationSeconds"] is None
    assert by_lvl[1]["missingReason"] == "min_level_initial_no_upgrade"
    assert by_lvl[2]["durationSeconds"] == 1800       # 行 1 = 0h30m
    assert by_lvl[3]["durationSeconds"] == 3600       # 行 2 = 1h（不继承 30m）
    assert by_lvl[13]["durationSeconds"] == 1080000   # 行 12 = 300h


def test_acceptance_lightning_13_is_336h(catalog):
    """法术表 to_next 锚点：行 12 UpgradeTimeH=336 → level 13 = 1209600（wiki 确认 13 级=14 天）。"""
    data, _, _ = catalog
    item = _find(data["items"], "spells", 26000000)
    lv13 = next(lv for lv in item["levels"] if lv["level"] == 13)
    assert lv13["durationSeconds"] == 1209600


def test_acceptance_town_hall_18_is_12_days(catalog):
    data, _, _ = catalog
    item = _find(data["items"], "buildings", 1000001)
    lv18 = next(lv for lv in item["levels"] if lv["level"] == 18)
    assert lv18["durationSeconds"] == 1036800


def test_acceptance_to_next_min_level_is_initial(catalog):
    """所有 to_next_level 表（单位/法术/英雄/宠物/首都单位/首都法术/守卫）的
    最低等级 = null + min_level_initial_no_upgrade（初始等级无升级）。

    最低等级保留源表原始编号（战斗直升机 15、Super Barbarian 5），不一定是 1。
    """
    data, _, _ = catalog
    to_next_sections = {"units", "units2", "spells", "heroes", "heroes2",
                        "pets", "guardians", "capital_characters", "capital_spells"}
    items = [i for i in data["items"] if i["section"] in to_next_sections]
    assert items
    for i in items:
        lv_min = min(i["levels"], key=lambda lv: lv["level"])
        assert lv_min["durationSeconds"] is None, f"{i['name']} 最低等级不应有时长"
        assert lv_min["missingReason"] == "min_level_initial_no_upgrade", f"{i['name']}"


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
    for i in items:
        for lv in i["levels"]:
            if i["section"] in ("capital_characters", "capital_spells"):
                # to_next：level 1 = 初始；其余无时间数据 → time_missing
                expected = ("min_level_initial_no_upgrade" if lv["level"] == 1
                            else "time_missing")
            else:
                expected = "time_missing"  # capital 建筑/陷阱 to_level
            assert lv["missingReason"] == expected, f"{i['section']}:{i['dataID']} lvl{lv['level']}"
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
    # InfernoArtillery（远袭者，107000000）5 级，GuardianGeneral 数据 4 条（L1-L4）：
    # 升级到 level 5 用 L4 = 13 天 = 1123200（to_next join 完美匹配）
    ia = _find(data["items"], "guardians", 107_000_000)
    assert ia is not None
    by_lvl = {lv["level"]: lv for lv in ia["levels"]}
    assert by_lvl[1]["durationSeconds"] is None
    assert by_lvl[1]["missingReason"] == "min_level_initial_no_upgrade"
    assert by_lvl[2]["durationSeconds"] == 7 * 86400        # L1
    assert by_lvl[3]["durationSeconds"] == 9 * 86400        # L2
    assert by_lvl[4]["durationSeconds"] == 11 * 86400       # L3
    assert by_lvl[5]["durationSeconds"] == 1123200          # L4 = 13 天
    # 5 级守卫的 L1-L4 全部命中（to_next join 完美匹配，无 upgrade_data_missing）；
    # 只有 1 级（初始）的守卫不参与 join
    for i in items:
        lvl_nums = [lv["level"] for lv in i["levels"]]
        for lv in i["levels"]:
            if lv["level"] == 1:
                assert lv["missingReason"] == "min_level_initial_no_upgrade"
            elif lv["level"] <= 5 and lvl_nums == [1, 2, 3, 4, 5]:
                assert lv["durationSeconds"] is not None, f"{i['name']} lvl{lv['level']}"
            else:
                assert lv["missingReason"] in ("upgrade_data_missing",), f"{i['name']} lvl{lv['level']}"


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
