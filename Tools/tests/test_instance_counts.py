"""Issue #70 阶段 2：townhall_levels → instanceCounts 宇宙管线（TDD 契约）。

契约要点（数据源实证，见计划文档）：
- TH 行 = Name ∈ {"1".."18"} 恒 18 行，缺行 → CatalogError；
- '' = 沿用上一 TH 的值（首值前 = 0），稀疏列语义（与 wiki 交叉验证一致）；
- 列跳过：CONFIG_COLUMNS、"BB " 前缀、TH 行全空（'' 或 '0'）；
- 非空非整数值 → CatalogError（消息含列名）；join 失败 → CatalogError（消息含列名）；
- 输出键 "section:dataID" 排序，值长度恒 18（index = TH-1）。
"""

import csv
import io
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from game_catalog.errors import CatalogError
from game_catalog.instance_counts import build_instance_counts, CONFIG_COLUMNS

APK = Path(os.environ.get("COC_APK_PATH", "/Users/lmz/Downloads/base.apk.1"))
TOOLS = Path(__file__).resolve().parents[2] / "Tools"

skip_no_apk = pytest.mark.skipif(
    not APK.is_file(),
    reason="真实 APK 不存在（设置 COC_APK_PATH 指向 base.apk.1 可启用集成测试）",
)


def _rows(csv_text: str) -> list[dict[str, str]]:
    return list(csv.DictReader(io.StringIO(csv_text)))


def _townhall_csv(columns: dict[str, dict[int, str]]) -> str:
    """合成 townhall_levels：18 个 TH 行（Name 1..18）+ 类型行。

    columns: {列名: {TH等级: 值}}；未列出的 TH 单元格为 ''。
    """
    header = ["Name"] + list(columns)
    lines = [",".join(header), ",".join(["String"] + ["int"] * len(columns))]
    for th in range(1, 19):
        vals = [columns[c].get(th, "") for c in columns]
        lines.append(",".join([str(th)] + vals))
    return "\n".join(lines) + "\n"


def _named_csv(rows: list[tuple[str, int]]) -> str:
    """合成 buildings/traps：类型行 + 数据行（Name, GlobalID）。"""
    lines = ["Name,GlobalID,BuildingLevel,VillageType", "String,int,int,String"]
    for name, gid in rows:
        lines.append(f"{name},{gid},1,home")
    return "\n".join(lines) + "\n"


def _counts(columns: dict[str, dict[int, str]],
            buildings: list[tuple[str, int]] = (),
            traps: list[tuple[str, int]] = ()) -> dict[str, list[int]]:
    return build_instance_counts(
        _rows(_townhall_csv(columns)),
        _rows(_named_csv(list(buildings))),
        _rows(_named_csv(list(traps))),
    )


# ---- 正常路径 ----

def test_building_counts_by_th_index_mapping():
    """Cannon 稀疏列（TH1=1、TH2=2、TH5=3）→ 数组 index = TH-1，'' 沿用上一 TH。"""
    counts = _counts({"Cannon": {1: "1", 2: "2", 5: "3"}},
                     buildings=[("Cannon", 1000008)])
    assert list(counts) == ["buildings:1000008"]
    vals = counts["buildings:1000008"]
    assert len(vals) == 18
    assert vals[0] == 1        # TH1
    assert vals[1] == 2        # TH2
    assert vals[2] == 2        # TH3 空 → 沿用 TH2
    assert vals[4] == 3        # TH5
    assert vals[17] == 3       # TH18 空 → 沿用 TH5


def test_zero_before_first_value():
    """首值前的 '' = 0（如 Wall 在 TH1 为 0）。"""
    counts = _counts({"Wall": {2: "25", 3: "50"}},
                     buildings=[("Wall", 1000010)])
    vals = counts["buildings:1000010"]
    assert vals[0] == 0
    assert vals[1] == 25
    assert vals[2] == 50
    assert vals[17] == 50


def test_buildings_and_traps_dual_section_join():
    """buildings + traps 双 section join，输出键按 "section:dataID" 排序。"""
    counts = _counts({"Cannon": {1: "1"}, "Air Bomb": {5: "2"}},
                     buildings=[("Cannon", 1000008)],
                     traps=[("Air Bomb", 12000005)])
    assert list(counts) == ["buildings:1000008", "traps:12000005"]
    assert counts["buildings:1000008"][0] == 1
    assert counts["traps:12000005"][0] == 0
    assert counts["traps:12000005"][4] == 2


def test_duplicate_name_rows_share_first_global_id():
    """buildings.csv 每 Name 多等级行共享 GlobalID：取首个出现行。"""
    buildings = (
        "Name,GlobalID,BuildingLevel,VillageType\n"
        "String,int,int,String\n"
        "Cannon,1000008,1,home\n"
        "Cannon,1000008,2,home\n"
        "Cannon,1000008,3,home\n"
    )
    counts = build_instance_counts(
        _rows(_townhall_csv({"Cannon": {1: "1"}})), _rows(buildings), [])
    assert list(counts) == ["buildings:1000008"]


# ---- 跳过规则 ----

def test_config_columns_skipped():
    """CONFIG 列（含 Treasury 6 列，设计评审 B3）不产出宇宙项。"""
    assert {"TreasuryGold", "TreasuryElixir", "TreasuryDarkElixir",
            "TreasuryWarGold", "TreasuryWarElixir", "TreasuryWarDarkElixir"} \
        <= CONFIG_COLUMNS
    counts = _counts({
        "Cannon": {1: "1"},
        "HeroBoostHours": {1: "120"},
        "TreasuryGold": {1: "1000000"},
        "TreasuryWarDarkElixir": {1: "500000"},
    }, buildings=[("Cannon", 1000008)])
    assert list(counts) == ["buildings:1000008"]


def test_gearup_columns_skipped():
    """_gearup 强化列（Cannon_gearup 等）非数量列，须白名单跳过（plan 文档）。"""
    assert {"Cannon_gearup", "Archer Tower_gearup", "Mortar_gearup"} <= CONFIG_COLUMNS
    counts = _counts({
        "Cannon": {1: "1"},
        "Cannon_gearup": {1: "1"},
        "Archer Tower_gearup": {1: "1"},
    }, buildings=[("Cannon", 1000008)])
    assert list(counts) == ["buildings:1000008"]


def test_bb_prefix_columns_skipped():
    """BB 前缀列（建筑大师基地，决策 5 不做宇宙）跳过。"""
    counts = _counts({
        "Cannon": {1: "1"},
        "BB Cannon": {1: "1"},
        "BB Wall": {3: "10"},
    }, buildings=[("Cannon", 1000008)])
    assert list(counts) == ["buildings:1000008"]


def test_all_empty_columns_skipped():
    """TH 行全 '' 或全 '0' 的列跳过（如 Mega Cannon、事件陷阱）。"""
    counts = _counts({
        "Cannon": {1: "1"},
        "Mega Cannon": {},
        "SantaTrap": {i: "0" for i in range(1, 19)},
    }, buildings=[("Cannon", 1000008)])
    assert list(counts) == ["buildings:1000008"]


# ---- fail loud ----

def test_missing_th_rows_raises():
    """TH 行不足 18 → CatalogError（长度契约）。"""
    townhall = "Name,Cannon\nString,int\n1,1\n2,2\n3,2\n"
    with pytest.raises(CatalogError, match="大本营行数"):
        build_instance_counts(_rows(townhall),
                              _rows(_named_csv([("Cannon", 1000008)])), [])


def test_unknown_column_fails_loud():
    """非 CONFIG 非 BB 非全空且 join 失败的列 → CatalogError（消息含列名）。"""
    with pytest.raises(CatalogError, match="New Defense"):
        _counts({"Cannon": {1: "1"}, "New Defense": {3: "1"}},
                buildings=[("Cannon", 1000008)])


def test_non_integer_value_fails_loud():
    """非空非整数值 → CatalogError（消息含列名）。"""
    with pytest.raises(CatalogError, match="Cannon"):
        _counts({"Cannon": {3: "abc"}}, buildings=[("Cannon", 1000008)])


# ---- 集成（真实 APK，锚点验证）----


@pytest.fixture(scope="module")
def real_instance_counts():
    """真实 APK 生成到 /tmp/coc-phase2-out：instanceCounts 内容 + validate OK。"""
    out = Path("/tmp/coc-phase2-out")
    if out.exists():
        shutil.rmtree(out)
    r = subprocess.run(
        [sys.executable, str(TOOLS / "generate_game_catalog.py"),
         "--apk", str(APK), "--output", str(out), "--game-version", "18.400.13"],
        capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    from game_catalog.validate import validate_catalog
    assert validate_catalog(out) == [], "真实 APK 生成结果未通过 validate"
    data = json.loads((out / "catalog.json").read_text(encoding="utf-8"))
    return data["instanceCounts"]


@skip_no_apk
def test_integration_all_columns_join_and_key_count(real_instance_counts):
    """主村数量列全部 join 成功（无 CatalogError）+ 键数量合理（~40-60）。"""
    ic = real_instance_counts
    assert 40 <= len(ic) <= 60, f"宇宙键数量异常: {len(ic)}"
    assert all(len(v) == 18 for v in ic.values())
    assert all(isinstance(v, int) and v >= 0 for vals in ic.values() for v in vals)


@skip_no_apk
def test_integration_anchors(real_instance_counts):
    """锚点（wiki 交叉验证）：TH18 Wall=325、Wizard Tower=6、Air Bomb=8、Cannon=7。

    Cannon 锚点说明：任务描述误写 6；数据源实证 + wiki（TH7 第 5 门、TH10 第 6 门、
    TH11 第 7 门，TH17 后不再新增）→ TH18=7。
    """
    ic = real_instance_counts
    assert ic["buildings:1000008"][17] == 7     # Cannon TH18
    assert ic["buildings:1000010"][17] == 325   # Wall TH18
    assert ic["buildings:1000011"][17] == 6     # Wizard Tower TH18
    assert ic["traps:12000005"][17] == 8        # Air Bomb TH18
    # 稀疏语义抽查：Cannon TH1=1、TH2=2、TH7=5、TH11=7（wiki 一致）
    cannon = ic["buildings:1000008"]
    assert cannon[0] == 1 and cannon[1] == 2 and cannon[6] == 5 and cannon[10] == 7


def test_generate_payload_always_has_instance_counts_key(full_minimal_apk, tmp_path):
    """契约：payload 恒含 instanceCounts 键（无数量列时输出 {}）。"""
    from game_catalog.catalog import generate
    out = tmp_path / "out"
    generate(full_minimal_apk, None, out)
    data = json.loads((out / "catalog.json").read_text(encoding="utf-8"))
    assert data["instanceCounts"] == {}
