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

# 限时节日/活动条目（第三方评审 P1：不得声明为 permanent——availability 会
# permanent 短路并永久隐藏阶段信息；必须保持 seasonalCandidate + 来源 note）。
# 来源：Supercell 官方活动公告 + Clash of Clans 官方维基 TemporaryTroop
#（圣诞/新年/农历新年/万圣节/生日/世界杯/愚人节/Mashup/Dark Deal/Sound of Clash）。
SEASONAL_FESTIVE_KEYS = {
    "buildings:1000073", "buildings:1000075", "buildings:1000083",
    "buildings:1000090", "buildings:1000091", "buildings:1000092",
    "buildings:1000101",
    "spells:26000004", "spells:26000006", "spells:26000022",
    "spells:26000073", "spells:26000084",
    "traps:12000003", "traps:12000007", "traps:12000009", "traps:12000015",
    "pets:73000006", "pets:73000012", "pets:73000013", "pets:73000014", "pets:73000015",
    "units:4000030", "units:4000045", "units:4000047", "units:4000048",
    "units:4000050", "units:4000060", "units:4000061", "units:4000067",
    "units:4000072",
    "units:4000094", "units:4000101", "units:4000102", "units:4000103",
    "units:4000104", "units:4000108", "units:4000126", "units:4000130",
    "units:4000118", "units:4000119", "units:4000120", "units:4000121",
    "units:4000122", "units:4000125", "units:4000128", "units:4000129",
    "units:4000136", "units:4000142", "units:4000143", "units:4000144",
    "units:4000145",
    "units:4000156", "units:4000157", "units:4000158", "units:4000159",
    "units:4000162", "units:4000163", "units:4000164", "units:4000165",
    "units:4000166", "units:4000167", "units:4000168",
    "units:4000179", "units:4000180",
    "units:4000185", "units:4000186", "units:4000187",
}
# 名字/icon 含节日特征但人工判定为常驻内容的条目（防误标 seasonalCandidate 的
# 反向保护：这些条目标 permanent 是有意的，note 留痕待复核）。
PERMANENT_FESTIVE_LOOKING_KEYS = {
    "equipment:90000014", "equipment:90000032", "equipment:90000041",
    "equipment:90000048", "equipment:90000049", "equipment:90000051",
    "capital_buildings:110000027", "buildings:1000012",
    "spells:26000120", "traps:12000017",
}
# icon exportName 强活动特征词（全量扫描用）：命中且不在白名单 → 必须
# seasonalCandidate（红队建议：防显式清单与数据脱钩——新增活动条目漏标时
# 测试自动变红；通用词 dragon/skeleton/法师 等不在此列避免误报）。
STRONG_FESTIVE_ICON_TOKENS = (
    "xmas", "christmas", "birthday", "halloween", "lny_", "cookie", "football",
    "april", "santa", "party", "ghost", "pumpkin", "mashup", "tax", "barcher",
    "lavaloon", "snake", "firecracker", "majo",
    "clashmas", "present", "candy", "wwe", "icewizard",
    "slimesnail", "hastespirit", "spiritjellyfish", "firework",
    "meteor", "shrink",
)


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
    """14 个防御全部有声明；3 条精工防御 seasonalCandidate，其余 11 条 permanent；
    craft_table_catalog.json 落盘 lifecycle 与声明逐条一致（审核 F2：声明只查
    JSON 文件不查落盘值的历史盲区，此处锁定）。"""
    decl = load_declarations()
    raw = json.loads((CATALOG_DIR / "craft_table_catalog.json").read_text(encoding="utf-8"))
    defenses = raw["defenses"]
    assert len(defenses) == 14
    for d in defenses:
        key = f"buildings:{d['dataID']}"
        assert key in decl, key
        # 审核 F2：落盘 lifecycle 必须 == 声明值（validate 只锁 catalog.json 的
        # 一致性，craft JSON 落盘值此前无测试锁定——两处声明源不得漂移）。
        assert d.get("lifecycle") == decl[key], f"{d['dataID']}"
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


def test_festive_items_are_seasonal_candidates():
    """第三方评审 P1：限时节日/活动条目必须声明为 seasonalCandidate 且带来源 note
    （availability 的 permanent 短路会永久隐藏阶段信息，误标 permanent 违反保守
    降级目标）；catalog.json 落盘值与声明一致。"""
    decl = load_declarations()
    raw_items = json.loads(DECLARATIONS.read_text(encoding="utf-8"))["items"]
    catalog = json.loads((CATALOG_DIR / "catalog.json").read_text(encoding="utf-8"))
    for key in SEASONAL_FESTIVE_KEYS:
        assert decl[key] == "seasonalCandidate", f"{key} 被误标为永久内容"
        assert raw_items[key].get("note"), f"{key} 缺少来源 note（限时条目必须可追溯）"
    for key in PERMANENT_FESTIVE_LOOKING_KEYS:
        assert decl[key] == "permanent", f"{key} 不应标 seasonalCandidate"
        assert raw_items[key].get("note"), f"{key} 常驻判定必须留痕"
    # catalog.json 落盘值与声明一致（防仅改声明文件不同步目录）
    for item in catalog["items"]:
        key = f"{item['section']}:{item['dataID']}"
        if key in SEASONAL_FESTIVE_KEYS or key in PERMANENT_FESTIVE_LOOKING_KEYS:
            assert item.get("lifecycle") == decl[key], f"{key} 落盘值不一致"


def test_festive_icon_items_are_not_permanent():
    """icon exportName 强活动特征词全量扫描：命中且不在常驻白名单 → 必须
    seasonalCandidate（红队建议：显式清单与数据脱钩时自动变红——新增活动
    条目漏标 permanent 会被此测试拦截）。"""
    decl = load_declarations()
    catalog = json.loads((CATALOG_DIR / "catalog.json").read_text(encoding="utf-8"))
    for item in catalog["items"]:
        icon = (item.get("icon") or {}).get("exportName", "") or ""
        level_visual = (item.get("levelVisual") or {}).get("exportName", "") or ""
        tokens = [t for t in STRONG_FESTIVE_ICON_TOKENS
                  if t.lower() in (icon + level_visual).lower()]
        if not tokens:
            continue
        key = f"{item['section']}:{item['dataID']}"
        if key in PERMANENT_FESTIVE_LOOKING_KEYS:
            assert decl[key] == "permanent", f"{key} 白名单条目不应标 seasonalCandidate"
        else:
            assert decl[key] == "seasonalCandidate", (
                f"{key} {item['name']} icon 含活动特征词 {tokens} 但声明为 "
                f"{decl[key]!r}——限时条目不得标 permanent（除非移入常驻白名单并留痕）")


def test_catalog_lifecycle_matches_declarations():
    """catalog.json 全量落盘 lifecycle == 声明文件（红队 D1 实验缺陷：此前只查
    「条目在声明中」，640 条落盘值零校验——声明改 seasonalCandidate 但目录未
    同步时测试全绿；此处全量比对，任何漂移立即变红）。"""
    decl = load_declarations()
    catalog = json.loads((CATALOG_DIR / "catalog.json").read_text(encoding="utf-8"))
    for item in catalog["items"]:
        key = f"{item['section']}:{item['dataID']}"
        assert item.get("lifecycle") == decl[key], (
            f"{key} {item['name']} 落盘 lifecycle={item.get('lifecycle')!r} "
            f"!= 声明 {decl[key]!r}")


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


def test_validate_rejects_undeclared_item(tmp_path):
    """目录条目不在声明中（无论 lifecycle 值）→ 报声明缺失（与生成器 fail loud 同口径）。"""
    item = CatalogItem(
        section="units", dataID=9_999_999, category="troops", base="home",
        baseMissingReason=None, name="未声明条目", maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[CatalogLevel(
            level=1, durationSeconds=0, missingReason=None,
            upgradeCosts=None, requiredTownHallLevel=None,
            requiredLaboratoryLevel=None, icon=None, levelVisual=None)],
        lifecycle="permanent",
    )
    d = _valid_dir(tmp_path, item)
    errors = validate_catalog(d)
    assert any("lifecycle 声明缺失" in e and "units:9999999" in e for e in errors)


def _craft_payload() -> tuple[bytes, dict]:
    """最小 craft 目录负载（defenses/modules 空数组即可通过 validate 文件级校验）。"""
    payload = {"schemaVersion": 1, "gameVersion": "18.400.13", "buildTag": "18_400_7",
               "locale": "zh-CN", "source": "t", "defenses": [], "modules": []}
    data = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
    return data, payload


def _add_craft_manifest_entry(d: Path, craft_bytes: bytes, declared_sha256: str) -> None:
    """把 craft 条目写入目录 manifest（declare 值可篡改以模拟 tampered）。"""
    m = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    m["generatedFiles"].append({"path": "craft_table_catalog.json",
                                "sha256": declared_sha256, "size": len(craft_bytes)})
    (d / "manifest.json").write_text(json.dumps(m, ensure_ascii=False), encoding="utf-8")


def test_validate_accepts_matching_craft_entry(tmp_path):
    """manifest 含 craft_table_catalog.json 条目且 hash/size 一致 → validate 通过
    （审核 P1-2 正向：craft 目录运行时完整性门禁的数据侧契约）。"""
    d = _valid_dir(tmp_path, _town_hall(lifecycle="permanent"))
    craft_bytes, _ = _craft_payload()
    (d / "craft_table_catalog.json").write_bytes(craft_bytes)
    _add_craft_manifest_entry(d, craft_bytes, "sha256:" + hashlib.sha256(craft_bytes).hexdigest())
    assert validate_catalog(d) == []


def test_validate_rejects_tampered_craft_entry(tmp_path):
    """craft_table_catalog.json 被篡改（hash 失配）→ validate 报哈希不一致
    （审核 P1-2 负例：篡改数据不得静默进入投影）。"""
    d = _valid_dir(tmp_path, _town_hall(lifecycle="permanent"))
    craft_bytes, _ = _craft_payload()
    (d / "craft_table_catalog.json").write_bytes(craft_bytes)
    _add_craft_manifest_entry(d, craft_bytes, "sha256:" + "0" * 64)
    errors = validate_catalog(d)
    assert any("craft_table_catalog.json" in e and "哈希不一致" in e for e in errors)


def test_update_manifest_craft_entry_idempotent(tmp_path):
    """生成器写盘后登记 craft 条目：幂等（两次调用只有一条）且 hash/size 正确；
    manifest 缺失时静默跳过不炸。"""
    import hashlib as _hashlib

    from generate_craft_table_catalog import _update_manifest_craft_entry

    d = tmp_path / "cat"
    d.mkdir()
    craft_bytes, _ = _craft_payload()
    # 无 manifest → 不炸
    _update_manifest_craft_entry(d, craft_bytes)
    # 有 manifest → 追加
    (d / "manifest.json").write_text(json.dumps(
        {"schemaVersion": 2, "gameVersion": "18.400.13", "buildTag": "18_400_7",
         "locale": "zh-CN", "sourceFingerprint": "sha256:" + "a" * 64,
         "generatedFiles": [], "counts": {"items": 0, "levels": 0}},
        ensure_ascii=False), encoding="utf-8")
    _update_manifest_craft_entry(d, craft_bytes)
    _update_manifest_craft_entry(d, craft_bytes)  # 幂等
    m = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    entries = [e for e in m["generatedFiles"] if e.get("path") == "craft_table_catalog.json"]
    assert len(entries) == 1
    assert entries[0]["sha256"] == "sha256:" + _hashlib.sha256(craft_bytes).hexdigest()
    assert entries[0]["size"] == len(craft_bytes)
    # 损坏 manifest → 静默跳过
    (d / "manifest.json").write_text("{broken", encoding="utf-8")
    _update_manifest_craft_entry(d, craft_bytes)
