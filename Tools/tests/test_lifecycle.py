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
    PHASE_COVERAGE_VALUES,
    apply_lifecycle,
    find_lifecycle_phase_conflicts,
    lifecycle_for,
    load_declarations,
    load_phase_coverage,
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
    "units:4000178", "units:4000179", "units:4000180",
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
        # schemaVersion=true（bool 是 int 子类且 True == 1，R9 绕过类）→ CatalogError
        ({"schemaVersion": True, "items": {}}, "schemaVersion"),
        # schemaVersion=1.0（float 虽 == 1 但非 int 类型，红队 Nit 5：_load_raw
        # 的 isinstance(sv, int) 额外拦截，方向安全——补用例锁定）→ CatalogError
        ({"schemaVersion": 1.0, "items": {}}, "schemaVersion"),
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


# ---- phaseCoverage：声明层结构化日期覆盖（Issue #112） ----

# required = 有可靠官方日期、必须命中 phase 表（精工防御 3 条 + 派对法师
# Party Wizard，官方公告 2026-04-08 08:00 UTC ~ 2026-04-29 08:00 UTC）。
PHASE_COVERAGE_REQUIRED_KEYS = {
    "buildings:103000008", "buildings:103000009", "buildings:103000010",
    "units:4000072",
}


def test_phase_coverage_wellformed():
    """phaseCoverage 声明契约：required+unknown 之和 == seasonalCandidate 总数；
    required 集合 == 官方可靠日期 4 条清单；permanent 条目不得携带 phaseCoverage
    （防误标）；seasonalCandidate 全部有合法枚举值。"""
    coverage = load_phase_coverage()
    raw_items = json.loads(DECLARATIONS.read_text(encoding="utf-8"))["items"]
    seasonal = [k for k, e in raw_items.items() if e["lifecycle"] == "seasonalCandidate"]
    # required + unknown == seasonalCandidate 总数（数量从文件动态计算，不硬编码）
    assert len(coverage) == len(seasonal)
    assert set(coverage) == set(seasonal)
    assert set(coverage.values()) <= PHASE_COVERAGE_VALUES
    assert all(isinstance(v, str) for v in coverage.values())
    # required 集合 == 官方可靠日期 4 条清单
    required = {k for k, v in coverage.items() if v == "required"}
    assert required == PHASE_COVERAGE_REQUIRED_KEYS
    # permanent 条目不得携带 phaseCoverage（防误标）
    for key, entry in raw_items.items():
        if entry["lifecycle"] == "permanent":
            assert "phaseCoverage" not in entry, f"{key} permanent 误带 phaseCoverage"
    # seasonalCandidate 全部有合法 phaseCoverage
    for key in seasonal:
        assert raw_items[key].get("phaseCoverage") in PHASE_COVERAGE_VALUES, key


def test_phase_coverage_not_written_to_catalog():
    """phaseCoverage 是声明层私有字段：catalog.json / craft_table_catalog.json
    不得携带（Swift CatalogItem/SeasonalDefense 无此字段，落盘会污染 Codable
    解码契约）。"""
    catalog = json.loads((CATALOG_DIR / "catalog.json").read_text(encoding="utf-8"))
    craft = json.loads((CATALOG_DIR / "craft_table_catalog.json").read_text(encoding="utf-8"))
    for item in catalog["items"]:
        assert "phaseCoverage" not in item, f"{item['section']}:{item['dataID']}"
    for defense in craft["defenses"]:
        assert "phaseCoverage" not in defense, f"buildings:{defense['dataID']}"


@pytest.mark.parametrize(
    ("content", "message_fragment"),
    [
        # seasonalCandidate 缺 phaseCoverage（可追溯性缺失）→ CatalogError
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "note": "n"}}}, "phaseCoverage"),
        # phaseCoverage 未知值（闭枚举外）→ CatalogError
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "phaseCoverage": "maybe",
                                                "note": "n"}}}, "phaseCoverage"),
        # phaseCoverage 非字符串（JSON 数组/对象/数字）→ CatalogError 而非裸 TypeError
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "phaseCoverage": ["required"],
                                                "note": "n"}}}, "phaseCoverage"),
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "phaseCoverage": {"v": "required"},
                                                "note": "n"}}}, "phaseCoverage"),
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "phaseCoverage": 123,
                                                "note": "n"}}}, "phaseCoverage"),
        # permanent 条目误带 phaseCoverage → CatalogError（防误标）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "phaseCoverage": "required",
                                                "note": "n"}}}, "permanent"),
        # lifecycle 未知值（与 load_declarations 同口径）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "other"}}}, "未知值"),
        # 文件缺失（临时目录下不存在）
        (None, "声明文件缺失"),
        # schemaVersion != 1
        ({"schemaVersion": 2, "items": {}}, "schemaVersion"),
        # schemaVersion=true（bool 是 int 子类且 True == 1，R9 绕过类）→ CatalogError
        ({"schemaVersion": True, "items": {}}, "schemaVersion"),
        # items 键缺失
        ({"schemaVersion": 1}, "缺少 items"),
        # 条目值非法（非 dict / lifecycle 非字符串）
        ({"schemaVersion": 1, "items": {"a:1": "required"}}, "条目非法"),
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": 123,
                                                "phaseCoverage": "required"}}}, "条目非法"),
        # 顶层非 dict（如列表）→ CatalogError
        ([1, 2], "schemaVersion"),
        # JSON 语法错误（原始串，非 json.dumps 产物）→ CatalogError
        ("{not json", "解析失败"),
    ],
)
def test_load_phase_coverage_failure_paths(monkeypatch, tmp_path, content, message_fragment):
    """load_phase_coverage 失败路径全部 fail loud → CatalogError（消息含具体原因）；
    phaseCoverage 只存在于声明层，不写入 catalog 产物（成功路径用真实声明文件，
    其余测试不受 monkeypatch 影响）。"""
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
        load_phase_coverage()
    assert message_fragment in str(ei.value)


@pytest.mark.parametrize(
    ("content", "message_fragment"),
    [
        # seasonalCandidate 缺 phaseCoverage（可追溯性缺失）→ CatalogError
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "note": "n"}}}, "phaseCoverage"),
        # phaseCoverage 未知值（闭枚举外）→ CatalogError
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "phaseCoverage": "maybe",
                                                "note": "n"}}}, "phaseCoverage"),
        # phaseCoverage 非字符串（JSON 数组/对象）→ CatalogError 而非裸 TypeError
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "phaseCoverage": ["required"],
                                                "note": "n"}}}, "phaseCoverage"),
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "seasonalCandidate",
                                                "phaseCoverage": {"v": "required"},
                                                "note": "n"}}}, "phaseCoverage"),
        # permanent 条目误带 phaseCoverage → CatalogError（防误标）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "permanent",
                                                "phaseCoverage": "required",
                                                "note": "n"}}}, "permanent"),
    ],
)
def test_load_declarations_rejects_bad_phase_coverage(
    monkeypatch, tmp_path, content, message_fragment
):
    """红队 Fix 1：phaseCoverage 良构校验必须进入生成管线——load_declarations
    是 apply_lifecycle/lifecycle_for（→ 生成器）的唯一入口，若它不校验 phaseCoverage，
    「声明文件是生成前置条件」对 phaseCoverage 维度落空（实测：删掉一条
    phaseCoverage 后生成照常产出，只有 pytest 红）。此处锁定：非法声明文件
    连 load_declarations 本身都 CatalogError。"""
    path = tmp_path / "declarations.json"
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
    # Issue #98 复审 P1：validator 强制 craft 条目存在——fixture 目录必须配套
    craft_bytes = b'{"schemaVersion":1,"gameVersion":"18.400.13","buildTag":"18_400_7","locale":"zh-CN","source":"t","defenses":[],"modules":[]}\n'
    (d / "craft_table_catalog.json").write_bytes(craft_bytes)
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 2, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN", "sourceFingerprint": "sha256:" + "a" * 64,
        "generatedFiles": [
            {"path": "catalog.json",
             "sha256": "sha256:" + hashlib.sha256(catalog_bytes).hexdigest(),
             "size": len(catalog_bytes)},
            {"path": "icons/", "kind": "directory"},
            {"path": "craft_table_catalog.json",
             "sha256": "sha256:" + hashlib.sha256(craft_bytes).hexdigest(),
             "size": len(craft_bytes)},
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
    assert validate_catalog(d) == []


def test_validate_rejects_structurally_invalid_craft(tmp_path):
    """复审 P1 负例：craft 文件 hash/size 一致但缺必填字段（Swift Codable 解码
    失败 → 运行时精制台不可用）→ validator 必须 fail loud。"""
    d = _valid_dir(tmp_path, _town_hall(lifecycle="permanent"))
    invalid = b'{"schemaVersion":1,"gameVersion":"18.400.13","defenses":[],"modules":[]}\n'  # 缺 buildTag/locale/source
    (d / "craft_table_catalog.json").write_bytes(invalid)
    m = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    for e in m["generatedFiles"]:
        if e.get("path") == "craft_table_catalog.json":
            e["sha256"] = "sha256:" + hashlib.sha256(invalid).hexdigest()
            e["size"] = len(invalid)
    (d / "manifest.json").write_text(json.dumps(m, ensure_ascii=False), encoding="utf-8")
    errors = validate_catalog(d)
    assert any("craft_table_catalog.json 缺少必填字段" in e and "buildTag" in e for e in errors)


@pytest.mark.parametrize("mutate", [
    # 审核 D：标量类型错 → Swift Codable 解码失败，validator 必须拦截
    ("defenses", 0, "dataID", "not-an-int"),
    ("defenses", 0, "name", 123),
    ("defenses", 0, "lifecycle", "unknown"),
    ("defenses", 0, "moduleIDs", [2 ** 63]),  # 超出 Int64 上界
    ("modules", 0, "maxLevel", "13"),
    ("modules", 0, "levels", [{"level": "1"}]),
    # 终审补强：顶层/Optional 字段类型漏检场景
    ("top", None, "buildTag", 123),
    ("defenses", 0, "totalModuleLevelThresholds", [2 ** 63]),
    ("modules", 0, "levels", [{"level": 1, "durationSeconds": 2 ** 63}]),
    ("modules", 0, "levels", [{"level": 1, "upgradeResource": 123}]),
    ("modules", 0, "levels", [{"level": 1, "requiredTownHallLevel": "9"}]),
    # 复审 R9：schemaVersion=true 绕过（Python True == 1）+ Int/Int64 范围镜像
    ("top", None, "schemaVersion", True),
    ("defenses", 0, "dataID", 2 ** 63),
    ("defenses", 0, "dataID", -(2 ** 63) - 1),
    ("modules", 0, "dataID", 2 ** 63),
    ("modules", 0, "maxLevel", 2 ** 63),
    ("modules", 0, "levels", [{"level": 2 ** 63}]),
    ("modules", 0, "levels", [{"level": 1, "requiredTownHallLevel": 2 ** 63}]),
])
def test_validate_rejects_craft_scalar_type_mismatch(tmp_path, mutate):
    """craft 标量字段类型与 Swift Codable 契约不符 → 报错（审核 D 补强：
    与缺字段同失败类别——validator 绿但运行时解码失败）。"""
    list_key, index, field, value = mutate
    d = _valid_dir(tmp_path, _town_hall(lifecycle="permanent"))
    raw = json.loads((d / "craft_table_catalog.json").read_text(encoding="utf-8"))
    if list_key == "top":
        raw[field] = value
    elif list_key == "defenses":
        raw["defenses"] = [{"dataID": 1, "name": "n", "sourceName": "s",
                            "specialAbility": "a", "moduleIDs": [], "totalModuleLevelThresholds": []}]
        raw["defenses"][index][field] = value
    else:
        raw["modules"] = [{"dataID": 1, "name": "n", "sourceName": "s",
                           "specialAbility": "a", "statTypes": [], "displayTitles": [],
                           "maxLevel": 1, "levels": [{"level": 1}]}]
        raw["modules"][index][field] = value
    craft_bytes = json.dumps(raw, ensure_ascii=False).encode("utf-8") + b"\n"
    (d / "craft_table_catalog.json").write_bytes(craft_bytes)
    m = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    for e in m["generatedFiles"]:
        if e.get("path") == "craft_table_catalog.json":
            e["sha256"] = "sha256:" + hashlib.sha256(craft_bytes).hexdigest()
            e["size"] = len(craft_bytes)
    (d / "manifest.json").write_text(json.dumps(m, ensure_ascii=False), encoding="utf-8")
    errors = validate_catalog(d)
    assert errors, f"craft {list_key}[{index}].{field}={value!r} 类型错未被拦截"
    assert any("craft_table_catalog.json" in e for e in errors)


def test_validate_rejects_missing_craft_entry(tmp_path):
    """manifest 缺 craft_table_catalog.json 条目 → 报错（复审 P1 负例：validator
    不得放行"生成成功但运行时不可用"的三方不一致；缺条目时 App fail-closed
    精制台不可用，必须 fail loud 前置）。"""
    d = _valid_dir(tmp_path, _town_hall(lifecycle="permanent"))
    m = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    m["generatedFiles"] = [e for e in m["generatedFiles"]
                           if e.get("path") != "craft_table_catalog.json"]
    (d / "manifest.json").write_text(json.dumps(m, ensure_ascii=False), encoding="utf-8")
    errors = validate_catalog(d)
    assert any("必须恰好包含一个 craft_table_catalog.json 条目" in e for e in errors)


def test_validate_rejects_tampered_craft_entry(tmp_path):
    """craft_table_catalog.json 被篡改（hash 失配）→ validate 报哈希不一致
    （审核 P1-2 负例：篡改数据不得静默进入投影）。"""
    d = _valid_dir(tmp_path, _town_hall(lifecycle="permanent"))
    craft_bytes, _ = _craft_payload()
    (d / "craft_table_catalog.json").write_bytes(craft_bytes)
    m = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    for e in m["generatedFiles"]:
        if e.get("path") == "craft_table_catalog.json":
            e["sha256"] = "sha256:" + "0" * 64
    (d / "manifest.json").write_text(json.dumps(m, ensure_ascii=False), encoding="utf-8")
    errors = validate_catalog(d)
    assert any("craft_table_catalog.json" in e and "哈希不一致" in e for e in errors)


def test_update_manifest_craft_entry_idempotent(tmp_path):
    """生成器写盘后登记 craft 条目：幂等（两次调用只有一条）且 hash/size 正确；
    manifest 缺失/损坏 → CatalogError（复审 P1：登记失败必须 fail loud，
    主流程以非零退出且不留下成功状态产物）。"""
    import hashlib as _hashlib

    from game_catalog.errors import CatalogError
    from generate_craft_table_catalog import _update_manifest_craft_entry

    d = tmp_path / "cat"
    d.mkdir()
    craft_bytes, _ = _craft_payload()
    # 无 manifest → CatalogError（不再静默跳过）
    with pytest.raises(CatalogError, match="manifest.json 不存在"):
        _update_manifest_craft_entry(d, craft_bytes)
    # 有 manifest → 追加 + 幂等
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
    # 损坏 manifest → CatalogError
    (d / "manifest.json").write_text("{broken", encoding="utf-8")
    with pytest.raises(CatalogError, match="manifest.json 损坏"):
        _update_manifest_craft_entry(d, craft_bytes)


def test_generate_main_fails_loud_without_manifest(tmp_path):
    """复审 P1 负例：craft 生成器在 manifest 缺失时非零退出且不写 craft 文件
    （不留下"生成成功但运行时不可用"的产物）。合成 APK 含两张 seasonal 表 +
    localization，确保 build_catalog 成功、失败精确落在 manifest 登记分支。"""
    import lzma
    import zipfile

    import generate_craft_table_catalog as g

    def _packed(text: str) -> bytes:
        data = text.encode("utf-8-sig")
        compressed = lzma.compress(data, format=lzma.FORMAT_ALONE)
        return compressed[:5] + len(data).to_bytes(4, "little") + compressed[13:]

    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/localization/cn.csv", _packed("TID,CN\nTID_A,测试\n"))
        z.writestr("assets/localization/texts_patch.csv", _packed("TID,CN\n"))
        z.writestr("assets/logic/seasonal_defense_archetypes.csv", _packed("Name\nString\n"))
        z.writestr("assets/logic/seasonal_defense_modules.csv", _packed("Name\nString\n"))
    out = tmp_path / "cat" / "craft_table_catalog.json"
    rc = g.main(["--apk", str(apk), "--game-version", "18.400.13",
                 "--output", str(out)])
    assert rc == 1
    assert not out.exists(), "登记失败时不得留下 craft 产物"


# ---- Issue #113：permanent 声明 ∩ 官方阶段表 → blocking 冲突 ----

def _write_decl_items(tmp_path, items: dict) -> Path:
    """写最小声明文件（schemaVersion=1）到 tmp_path，返回路径。"""
    path = tmp_path / "lifecycle_declarations.json"
    path.write_text(json.dumps({"schemaVersion": 1, "items": items},
                               ensure_ascii=False), encoding="utf-8")
    return path


def _write_phases_file(tmp_path, phases: list) -> Path:
    """写最小阶段表（schemaVersion=1）到 tmp_path，返回路径。"""
    path = tmp_path / "seasonal_phases.json"
    path.write_text(json.dumps({"schemaVersion": 1, "phases": phases},
                               ensure_ascii=False), encoding="utf-8")
    return path


def test_find_lifecycle_phase_conflicts_none_on_real_data():
    """正例（真实数据形态）：bundled 声明文件 + 阶段表无冲突 → []。

    Issue #113 是纯防御性校验（permanent ∩ phase = ∅）；此测试锁定真实数据
    不得回归出冲突（新增阶段条目误把 permanent 内容登记进阶段表时立即变红）。
    """
    assert find_lifecycle_phase_conflicts() == []


def test_phases_path_for_version_binding(monkeypatch, tmp_path):
    """评审 Minor #2：phases_path_for 统一「版本 → 阶段表路径」绑定
    （coverage_report 与 validator 冲突校验共用，消除跨模块私有访问）。

    version 非 None → _phases_path(version) 推导 bundled 路径；
    None → 默认版本 PHASES_PATH 常量。"""
    sentinel = tmp_path / "seasonal_phases.json"
    default = tmp_path / "default_phases.json"
    monkeypatch.setattr(lifecycle_module, "_phases_path", lambda version: sentinel)
    monkeypatch.setattr(lifecycle_module, "PHASES_PATH", default)
    assert lifecycle_module.phases_path_for("99.99.99") == sentinel
    assert lifecycle_module.phases_path_for(None) == default


def test_find_lifecycle_phase_conflicts_no_conflict(tmp_path):
    """正例（注入）：permanent key 不在阶段表、seasonalCandidate key 命中
    阶段表 → 均不算冲突 → []。"""
    decl = _write_decl_items(tmp_path, {
        "buildings:1000001": {"lifecycle": "permanent"},
        "units:4000072": {"lifecycle": "seasonalCandidate",
                          "phaseCoverage": "required", "note": "n"},
    })
    phases = _write_phases_file(tmp_path, [
        {"phaseID": "p1", "name": "阶段一", "from": 100, "until": 200,
         "itemKeys": ["units:4000072"], "sourceURL": "https://x"},
    ])
    assert find_lifecycle_phase_conflicts(decl, phases) == []


def test_find_lifecycle_phase_conflicts_permanent_hit(tmp_path):
    """负例：permanent key 命中合法区间 phase → 1 项冲突，字段完整
    （key/phaseID/phaseName/declarationsPath/phasesPath/sourceURL）。"""
    decl = _write_decl_items(tmp_path, {
        "buildings:1000001": {"lifecycle": "permanent"},
    })
    phases = _write_phases_file(tmp_path, [
        {"phaseID": "p1", "name": "阶段一", "from": 100, "until": 200,
         "itemKeys": ["buildings:1000001", "units:4000072"],
         "sourceURL": "https://supercell.example/p1"},
    ])
    conflicts = find_lifecycle_phase_conflicts(decl, phases)
    assert len(conflicts) == 1
    conflict = conflicts[0]
    assert conflict["key"] == "buildings:1000001"
    assert conflict["phaseID"] == "p1"
    assert conflict["phaseName"] == "阶段一"
    assert conflict["declarationsPath"] == str(decl)
    assert conflict["phasesPath"] == str(phases)
    assert conflict["sourceURL"] == "https://supercell.example/p1"


@pytest.mark.parametrize(("frm", "until"), [
    (200, 100),   # from >= until
    (100, 100),   # from == until（零时长）
])
def test_find_lifecycle_phase_conflicts_illegal_interval_not_conflict(
    tmp_path, frm, until
):
    """负例：数字类型但非法区间 phase（from >= until）的 key 不得算命中——
    与 Swift phase(forItemKey:at:) 过滤语义及 compute_phase_coverage 的
    phase_keys 口径一致（非数字类型的 from/until 属结构错误，见
    test_find_lifecycle_phase_conflicts_phases_failure_paths——fail loud）。"""
    decl = _write_decl_items(tmp_path, {
        "buildings:1000001": {"lifecycle": "permanent"},
    })
    phases = _write_phases_file(tmp_path, [
        {"phaseID": "bad", "name": "非法区间", "from": frm, "until": until,
         "itemKeys": ["buildings:1000001"]},
    ])
    assert find_lifecycle_phase_conflicts(decl, phases) == []


def test_find_lifecycle_phase_conflicts_float_interval_is_hit(tmp_path):
    """Issue #113 审计 F1：float 时间戳（如 796694400.5）必须算合法命中。

    Swift Date 经 JSONDecoder .deferredToDate 解码接受浮点时间戳（Double）；
    Python 若只认 int 会漏报冲突（validator fail-open，门禁绕过）。"""
    decl = _write_decl_items(tmp_path, {
        "buildings:1000001": {"lifecycle": "permanent"},
    })
    phases = _write_phases_file(tmp_path, [
        {"phaseID": "p1", "name": "阶段一", "from": 100.5, "until": 200.5,
         "itemKeys": ["buildings:1000001"]},
    ])
    conflicts = find_lifecycle_phase_conflicts(decl, phases)
    assert len(conflicts) == 1
    assert conflicts[0]["key"] == "buildings:1000001"
    assert conflicts[0]["phaseID"] == "p1"


def test_find_lifecycle_phase_conflicts_deduplicates_duplicate_item_keys(
    tmp_path
):
    """Issue #113 审计 F5：同一 phase 内 itemKeys 重复 key → 只报一条冲突
    （(key, phaseID) 去重，保持表序）。"""
    decl = _write_decl_items(tmp_path, {
        "buildings:1000001": {"lifecycle": "permanent"},
    })
    phases = _write_phases_file(tmp_path, [
        {"phaseID": "p1", "from": 100, "until": 200,
         "itemKeys": ["buildings:1000001", "buildings:1000001",
                      "buildings:1000001"]},
    ])
    conflicts = find_lifecycle_phase_conflicts(decl, phases)
    assert len(conflicts) == 1, f"重复 key 必须去重，实际 {len(conflicts)} 条"


def test_find_lifecycle_phase_conflicts_non_utf8_phases_file_fails(tmp_path):
    """Issue #113 审计 F8：非 UTF-8 阶段表文件 → CatalogError（裸
    UnicodeDecodeError 不得逃逸为 traceback）。"""
    decl = _write_decl_items(tmp_path, {
        "buildings:1000001": {"lifecycle": "permanent"},
    })
    path = tmp_path / "seasonal_phases.json"
    path.write_bytes(b"\xff\xfe\x00\x01\x02")  # 非 UTF-8 字节
    with pytest.raises(CatalogError) as ei:
        find_lifecycle_phase_conflicts(decl, path)
    assert "阶段表文件解析失败" in str(ei.value)


def test_find_lifecycle_phase_conflicts_seasonal_candidate_not_conflict(tmp_path):
    """负例：seasonalCandidate key 命中合法 phase → 不算冲突（#113 只拦截
    permanent 声明；seasonalCandidate 命中是正常状态，走 #112 coverage）。"""
    decl = _write_decl_items(tmp_path, {
        "units:4000072": {"lifecycle": "seasonalCandidate",
                          "phaseCoverage": "required", "note": "n"},
    })
    phases = _write_phases_file(tmp_path, [
        {"phaseID": "p1", "name": "阶段一", "from": 100, "until": 200,
         "itemKeys": ["units:4000072"]},
    ])
    assert find_lifecycle_phase_conflicts(decl, phases) == []


def test_find_lifecycle_phase_conflicts_multiple_phases_all_reported(tmp_path):
    """负例：permanent key 命中多个合法 phase → 报告全部命中（Python 是数据
    审计视角，与 Swift 单一确定性选择不同，spec 明确如此）；phaseName/sourceURL
    缺失时返回 None。"""
    decl = _write_decl_items(tmp_path, {
        "buildings:1000001": {"lifecycle": "permanent"},
    })
    phases = _write_phases_file(tmp_path, [
        {"phaseID": "p1", "from": 100, "until": 200,
         "itemKeys": ["buildings:1000001"]},
        {"phaseID": "p2", "from": 300, "until": 400,
         "itemKeys": ["buildings:1000001"]},
    ])
    conflicts = find_lifecycle_phase_conflicts(decl, phases)
    assert [c["phaseID"] for c in conflicts] == ["p1", "p2"]
    for conflict in conflicts:
        assert conflict["key"] == "buildings:1000001"
        assert conflict["phaseName"] is None
        assert conflict["sourceURL"] is None


@pytest.mark.parametrize(
    ("content", "message_fragment"),
    [
        # 文件缺失（临时目录下不存在）→ CatalogError
        (None, "阶段表文件缺失"),
        # JSON 语法错误（原始串，非 json.dumps 产物）→ CatalogError
        ("{not json", "阶段表文件解析失败"),
        # schemaVersion != 1 / 顶层非 dict（与 load_phase_coverage 同口径）
        ({"schemaVersion": 2, "phases": []}, "schemaVersion"),
        ([1, 2], "schemaVersion"),
        # 缺 phases 键
        ({"schemaVersion": 1}, "缺少 phases"),
        # phase 非 dict
        ({"schemaVersion": 1, "phases": ["not-a-dict"]}, "非 dict"),
        # phaseID 缺失 / 非 str（Swift Codable 必填，缺失 → 运行时解码失败）
        ({"schemaVersion": 1, "phases": [{"from": 1, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "phaseID"),
        ({"schemaVersion": 1, "phases": [{"phaseID": 123, "from": 1, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "phaseID"),
        # name/sourceURL 存在时非 str（Optional<String>：缺失/null 合法）
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "name": 123,
                                          "from": 1, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "name"),
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "sourceURL": ["u"],
                                          "from": 1, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "sourceURL"),
        # itemKeys 非 list / 缺失 / 元素非 str（fail loud，与 coverage_report
        # 同口径——不静默容忍，否则幽灵 key 或裸 TypeError）
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": 2,
                                          "itemKeys": "units:4000072"}]}, "itemKeys"),
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": 2}]},
         "itemKeys"),
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": 2,
                                          "itemKeys": [12345]}]}, "itemKeys"),
        # from/until 类型结构校验（Issue #113 审计 F2）：非数字（str/bool/缺失）
        # → fail loud——Swift Date 解码失败会整表变空，Python 不得静默跳过
        #（否则同一文件两侧对冲突给出相反答案）
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": "1", "until": 2,
                                          "itemKeys": ["a:1"]}]}, "from 缺失或非数字"),
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": 1, "until": "2",
                                          "itemKeys": ["a:1"]}]}, "until 缺失或非数字"),
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "until": 2,
                                          "itemKeys": ["a:1"]}]}, "from 缺失或非数字"),
        ({"schemaVersion": 1, "phases": [{"phaseID": "x", "from": True, "until": 2,
                                          "itemKeys": ["a:1"]}]}, "from 缺失或非数字"),
    ],
)
def test_find_lifecycle_phase_conflicts_phases_failure_paths(
    tmp_path, content, message_fragment
):
    """阶段表结构校验 fail-loud（与 coverage_report/load_phase_coverage 同口径）：
    文件缺失/解析失败/schemaVersion != 1/缺 phases/phaseID 非 str/name、
    sourceURL 存在时非 str/itemKeys 非 list 或元素非 str → CatalogError。"""
    decl = _write_decl_items(tmp_path, {
        "buildings:1000001": {"lifecycle": "permanent"},
    })
    if content is None:
        path = tmp_path / "missing_seasonal_phases.json"  # 不存在
    else:
        path = tmp_path / "seasonal_phases.json"
        if isinstance(content, str):
            path.write_text(content, encoding="utf-8")  # JSON 语法错误用例
        else:
            path.write_text(json.dumps(content), encoding="utf-8")
    with pytest.raises(CatalogError) as ei:
        find_lifecycle_phase_conflicts(decl, path)
    assert message_fragment in str(ei.value)


@pytest.mark.parametrize(
    ("content", "message_fragment"),
    [
        # 文件缺失（临时目录下不存在）→ CatalogError
        (None, "声明文件缺失"),
        # JSON 语法错误（原始串，非 json.dumps 产物）→ CatalogError
        ("{not json", "解析失败"),
        # schemaVersion != 1 / 顶层非 dict（与 load_declarations 同口径）
        ({"schemaVersion": 2, "items": {}}, "schemaVersion"),
        ([1, 2], "schemaVersion"),
        # items 键缺失
        ({"schemaVersion": 1}, "缺少 items"),
        # 条目非法 / lifecycle 未知值（fail loud 与 load_declarations 同口径）
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": 123}}}, "条目非法"),
        ({"schemaVersion": 1, "items": {"a:1": {"lifecycle": "other"}}}, "未知值"),
    ],
)
def test_find_lifecycle_phase_conflicts_declarations_failure_paths(
    tmp_path, content, message_fragment
):
    """声明文件结构校验 fail-loud（与 load_declarations 同口径）：文件缺失/
    解析失败/schemaVersion != 1/缺 items/条目非法/未知 lifecycle → CatalogError。"""
    if content is None:
        path = tmp_path / "missing_lifecycle_declarations.json"  # 不存在
    else:
        path = tmp_path / "lifecycle_declarations.json"
        if isinstance(content, str):
            path.write_text(content, encoding="utf-8")
        else:
            path.write_text(json.dumps(content), encoding="utf-8")
    phases = _write_phases_file(tmp_path, [
        {"phaseID": "p1", "from": 1, "until": 2, "itemKeys": []},
    ])
    with pytest.raises(CatalogError) as ei:
        find_lifecycle_phase_conflicts(path, phases)
    assert message_fragment in str(ei.value)
