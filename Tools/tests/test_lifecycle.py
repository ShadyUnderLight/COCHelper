"""Issue #98：目录生命周期声明（lifecycle 字段）数据层测试。测试是契约。

- 声明文件（lifecycle_declarations.json）覆盖真实目录（catalog + craft_table）；
- seasonalCandidate 必须与阶段表（seasonal_phases.json）命中一致；
- apply_lifecycle 写入 / fail loud；validate 闭枚举 + 声明一致性。
"""

import hashlib
import json
from pathlib import Path

import pytest

import game_catalog.lifecycle as lifecycle_module
from game_catalog.catalog import generate
from game_catalog.errors import CatalogError
from game_catalog.lifecycle import (
    LIFECYCLE_VALUES,
    apply_lifecycle,
    lifecycle_for,
    load_declarations,
)
from game_catalog.model import Catalog, CatalogItem, CatalogLevel, catalog_to_dict
from game_catalog.validate import validate_catalog

_REPO_ROOT = Path(__file__).resolve().parents[2]
CATALOG_DIR = _REPO_ROOT / "Sources/COCHelperCore/GameCatalog/18.400.13"
DECLARATIONS = (
    Path(__file__).resolve().parents[1]
    / "game_catalog" / "lifecycle_declarations.json"
)

# 精工防御（2026-04 官方公告限时，阶段表 crafted-defenses-2026-04-sound-of-clash）
SEASONAL_DEFENSE_IDS = (103000008, 103000009, 103000010)


# ---- 声明文件 vs 真实目录 ----

def test_declarations_cover_main_catalog():
    """声明 items 数 == catalog.json 条目数 + craft_table 防御数；每条 lifecycle
    闭枚举；每个 catalog 条目在声明中（fail loud 的完整性前提）。"""
    decl = load_declarations()
    raw = json.loads(DECLARATIONS.read_text(encoding="utf-8"))
    assert raw["schemaVersion"] == 1
    catalog = json.loads((CATALOG_DIR / "catalog.json").read_text(encoding="utf-8"))
    craft = json.loads((CATALOG_DIR / "craft_table_catalog.json").read_text(encoding="utf-8"))
    assert len(raw["items"]) == len(catalog["items"]) + len(craft["defenses"])
    for key, entry in raw["items"].items():
        assert entry["lifecycle"] in LIFECYCLE_VALUES, f"{key}: {entry['lifecycle']!r}"
    for item in catalog["items"]:
        assert f"{item['section']}:{item['dataID']}" in decl


def test_declarations_cover_craft_table():
    """14 个防御全部有声明；3 条精工防御 seasonalCandidate，其余 11 条 permanent。"""
    decl = load_declarations()
    raw = json.loads((CATALOG_DIR / "craft_table_catalog.json").read_text(encoding="utf-8"))
    defenses = raw["defenses"]
    assert len(defenses) == 14
    for d in defenses:
        key = f"buildings:{d['dataID']}"
        assert key in decl, key
    seasonal = {d["dataID"] for d in defenses
                if decl[f"buildings:{d['dataID']}"] == "seasonalCandidate"}
    assert seasonal == set(SEASONAL_DEFENSE_IDS)
    for d in defenses:
        if d["dataID"] not in SEASONAL_DEFENSE_IDS:
            assert decl[f"buildings:{d['dataID']}"] == "permanent"


def test_seasonal_candidates_match_phase_table():
    """阶段表命中的条目必须是已知限时候选（声明 ∩ 阶段表 → 全 seasonalCandidate）；
    模组 key（不在声明中）跳过。"""
    decl = load_declarations()
    phases = json.loads((CATALOG_DIR / "seasonal_phases.json").read_text(encoding="utf-8"))
    phase_keys = [k for phase in phases["phases"] for k in phase["itemKeys"]]
    assert phase_keys  # 阶段表非空
    for key in phase_keys:
        if key in decl:
            assert decl[key] == "seasonalCandidate", (
                f"{key} 命中阶段表但声明为 {decl[key]!r}")


# ---- apply_lifecycle：写入 / fail loud ----

def test_apply_lifecycle_writes_field(full_minimal_apk, tmp_path):
    """generate 产物（Town Hall 1000001）带 lifecycle 且 == 声明值。"""
    out = tmp_path / "out"
    generate(full_minimal_apk, None, out)
    data = json.loads((out / "catalog.json").read_text(encoding="utf-8"))
    items = data["items"]
    assert items and items[0]["dataID"] == 1000001
    decl = load_declarations()
    for item in items:
        key = f"{item['section']}:{item['dataID']}"
        assert "lifecycle" in item
        assert item["lifecycle"] == decl[key]


def test_apply_lifecycle_missing_declaration_fails():
    """声明外条目 → CatalogError，消息含 section:dataID（fail loud 不静默）。"""
    items = [
        CatalogItem(
            section="units", dataID=9_999_999, category="troops", base="home",
            baseMissingReason=None, name="无声明条目", maxLevel=1,
            icon=None, levelVisual=None, missingReason=None,
            levels=[CatalogLevel(
                level=1, durationSeconds=0, missingReason=None,
                upgradeCosts=None, requiredTownHallLevel=None,
                requiredLaboratoryLevel=None, icon=None, levelVisual=None)],
        )
    ]
    with pytest.raises(CatalogError) as ei:
        apply_lifecycle(items)
    assert "units:9999999" in str(ei.value)
    assert "无声明条目" in str(ei.value)


def test_lifecycle_for_known_and_unknown():
    """lifecycle_for：已知 → 声明值；未知 → CatalogError。"""
    assert lifecycle_for("buildings", 1000001) == "permanent"
    assert lifecycle_for("buildings", 103000008) == "seasonalCandidate"
    with pytest.raises(CatalogError):
        lifecycle_for("buildings", 9_999_999)


@pytest.mark.parametrize(
    ("content", "message_fragment"),
    [
        # 文件缺失（临时目录下不存在）
        (None, "声明文件缺失"),
        # schemaVersion != 1
        ({"schemaVersion": 2, "items": {}}, "schemaVersion"),
        # items 键缺失
        ({"schemaVersion": 1}, "缺少 items"),
        # 条目值非法（非 dict / lifecycle 非字符串）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": 123}}}, "条目非法"),
        ({"schemaVersion": 1, "items": {"a:1": "permanent"}}, "条目非法"),
        # lifecycle 未知值（闭枚举外）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "other"}}}, "未知值"),
        # JSON 语法错误（原始串，非 json.dumps 产物）→ CatalogError
        ("{not json", "解析失败"),
        # 顶层非 dict（如列表）→ CatalogError
        ([1, 2], "schemaVersion"),
    ],
)
def test_load_declarations_failure_paths(monkeypatch, tmp_path, content, message_fragment):
    """load_declarations 失败路径全部 fail loud → CatalogError（消息含具体原因）；
    成功路径不受 monkeypatch 影响（其余测试用真实声明文件）。"""
    if content is None:
        path = tmp_path / "missing_lifecycle_declarations.json"  # 不存在
    else:
        path = tmp_path / "declarations.json"
        if isinstance(content, str):
            # JSON 语法错误用例：原始内容直接写入（不经过 json.dumps）
            path.write_text(content, encoding="utf-8")
        else:
            path.write_text(json.dumps(content), encoding="utf-8")
    monkeypatch.setattr(lifecycle_module, "DECLARATIONS_PATH", path)
    with pytest.raises(CatalogError) as ei:
        load_declarations()
    assert message_fragment in str(ei.value)


# ---- validate：闭枚举 / 声明一致性 ----

def _town_hall(lifecycle=None):
    """真实目录中的 Town Hall（buildings:1000001，声明=permanent）。"""
    return CatalogItem(
        section="buildings", dataID=1000001, category="buildings", base="home",
        baseMissingReason=None, name="Town Hall", maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[CatalogLevel(
            level=1, durationSeconds=0, missingReason=None,
            upgradeCosts=None, requiredTownHallLevel=None,
            requiredLaboratoryLevel=None, icon=None, levelVisual=None)],
        lifecycle=lifecycle,
    )


def _valid_dir(tmp_path, item) -> Path:
    d = tmp_path / "cat"
    d.mkdir()
    catalog = Catalog(schemaVersion=2, gameVersion="18.400.13", locale="zh-CN",
                      items=[item])
    catalog_bytes = json.dumps(catalog_to_dict(catalog),
                               ensure_ascii=False).encode("utf-8")
    (d / "catalog.json").write_bytes(catalog_bytes)
    (d / "icons").mkdir()
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 2, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN", "sourceFingerprint": "sha256:" + "a" * 64,
        "generatedFiles": [
            {"path": "catalog.json",
             "sha256": "sha256:" + hashlib.sha256(catalog_bytes).hexdigest(),
             "size": len(catalog_bytes)},
            {"path": "icons/", "kind": "directory"},
        ],
        "counts": {"items": 1, "levels": 1, "missingTime": 0, "missingIcons": 0},
    }))
    return d


def test_validate_rejects_missing_lifecycle(tmp_path):
    """旧产物（无 lifecycle 字段，声明中存在该 key）→ 报缺少 lifecycle 字段。"""
    d = _valid_dir(tmp_path, _town_hall(lifecycle=None))
    errors = validate_catalog(d)
    assert any("缺少 lifecycle 字段" in e and "buildings:1000001" in e for e in errors)


def test_validate_rejects_unknown_lifecycle(tmp_path):
    """lifecycle 非闭枚举值 → 报错。"""
    d = _valid_dir(tmp_path, _town_hall(lifecycle="unknown"))
    errors = validate_catalog(d)
    assert any("lifecycle 未知值" in e and "'unknown'" in e for e in errors)


def test_validate_consistency_mismatch(tmp_path):
    """lifecycle 与声明文件不一致 → 报错（目录=seasonalCandidate 声明=permanent）。"""
    d = _valid_dir(tmp_path, _town_hall(lifecycle="seasonalCandidate"))
    errors = validate_catalog(d)
    assert any("lifecycle 与声明不一致" in e and "buildings:1000001" in e
               and "'seasonalCandidate'" in e and "'permanent'" in e for e in errors)
