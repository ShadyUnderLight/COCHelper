# APK 版本化静态升级目录管线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 issue #13：新增 `Tools/generate_game_catalog.py` + `Tools/validate_game_catalog.py`，从 APK 生成版本化静态升级目录（catalog.json + manifest.json + icons/），含逐级升级时长、等级上限、资源、图标/外观引用，供未来 #14 消费。

**Architecture:** 三个候选设计（嵌套 levels[] / section=快照键+category=Swift rawValue / 防御性校验+枚举 missingReason）投票融合。Python 包 `Tools/game_catalog/`（解码、前向填充、时间解析、建模、校验分离），两个 CLI 入口薄壳。不动现有 `generate_account_name_catalog.py`（dataID 兼容用测试锁）。MVP 不渲染图标（renderedPath 全 null+missingReason）。

**Tech Stack:** Python 3.14 stdlib（zipfile/lzma/csv/json/hashlib）+ pytest + hypothesis（已装 9.1.1/6.155.2）。零第三方运行时依赖。

---

## 背景硬事实（已实测，勿再质疑）

- 输入 APK：`/path/to/base.apk`（546MB）。`assets/build.tag` = `18_400_7`。**APK 内无 `18.400.13` 字符串** → gameVersion 必须 CLI 传入。
- Supercell CSV 解包：`lzma.decompress(packed[:8] + b"\0"*4 + packed[8:]).decode("utf-8-sig")`，路径 `assets/logic/<name>.csv`。
- 每张表第 1 行是类型标注行（`Name='String'` 等），必须跳过。
- **空白继承**：每记录首行带 `Name`，后续行 Name 为空；其他列逐列继承上方最近非空值（**单元格级 forward-fill**）。实测 Barbarian 13 行时间全空：UpH 继承自 vl12 的 `'300'`，UpM 继承自 vl1 的 `'30'` → 300h30m = **1,081,800s**。'0' 是真实值 ≠ ''（空）。
- 表结构（列名已实测）：
  - `buildings.csv`: Name/GlobalID/BuildingLevel/TID/SWF/ExportName/BuildTimeD/H/M/S/BuildResource/BuildCost/TownHallLevel/Icon/VillageType。GlobalID 1000000-1000104，105 组。`"Town Hall"`（带空格）lvl18 = 12d = **1,036,800s**。2 组（BB Army Camp/BB Reinforcement Camp）时间全空。
  - `traps.csv`: GlobalID 12000000-12000020, Level, BuildTimeD/H/M（无 S）, VillageType。
  - `characters.csv`: GlobalID 4000000+, VisualLevel, UpgradeTimeH/M, LaboratoryLevel, UpgradeResource/Cost, IconSWF/IconExportName, VillageType, **ProductionBuilding**（`'Siege Workshop'` 行 → 攻城机器，实测 Wall Wrecker/Battle Blimp），SummonTime/RegenTime 是战斗时间**不得使用**。
  - `spells.csv`: GlobalID 26000000+, Level, UpgradeTimeH（无 M）, LaboratoryLevel, VillageType。
  - `heroes.csv`: 无 GlobalID（8 组）, VisualLevel, UpgradeTimeH。
  - `pets.csv`: 无 GlobalID（18 组）, TroopLevel, UpgradeTimeH/M。
  - `character_items.csv`: 无 GlobalID（61 组）, Level, **无任何时间列** → 全 missingReason=no_time_source。
  - `guardians.csv`: 无 GlobalID（10 组, 23 行）, Level, UpgradeData, IconSWF/IconExportName。
  - `upgrade_data.csv`: Name/UpgradeLevel/UpgradeType/UpgradeTimeDays/Hours/Minutes/Seconds/UpgradeResource/AltUpgradeResource/UpgradeCost。Name 空白继承（GuardianGeneral 4 级 + GuardianAssassin 2 级）。
  - `capital_buildings/traps/characters/spells.csv`: BuildTime/UpgradeTime 字段存在但**全空** → 全 missingReason=time_missing。
- VillageType：`''`→home、`'0'`→home（实测 Royal Ghost）、`'1'`→builder、其他→Tier-1 错误。
- 中文名：`assets/localization/cn.csv`（TID,CN）+ `texts_patch.csv`（CN 后覆盖），`clean_name` 去 `\q`、`\n`→空格、strip。
- 现有 `Tools/generate_account_name_catalog.py` 的 dataID 段：heroes 28_000_000、pets 73_000_000、equipment 90_000_000、guardians 107_000_000（base+ordinal，ordinal=表内记录序号从 0 起，跳过 doc 行）。**新管线必须与该段一致**（集成测试对拍）。
- Swift 侧（未来 #14 消费）：`TrackerCategory.rawValue` = buildings/traps/troops/spells/siegeMachines/heroes/equipment/pets/guardians；`AccountSnapshot.objectSections` 键 = buildings/buildings2/traps/traps2/units/units2/siege_machines/spells/heroes/heroes2/equipment/pets/guardians。
- 测试环境：`python3 -m pytest Tools/tests -q`；hypothesis 用 `@given`。集成测试用 `pytest.mark.skipif(not Path(APK).exists())`。

---

## 类型契约（最终版，投票裁决后）

### catalog.json

```json
{
  "schemaVersion": 1,
  "gameVersion": "18.400.13",
  "locale": "zh-CN",
  "items": [
    {
      "section": "units",
      "dataID": 4000000,
      "category": "troops",
      "base": "home",
      "baseMissingReason": null,
      "name": "野蛮人",
      "maxLevel": 13,
      "icon": {"container": "sc/ui.sc", "exportName": "icon_unit_barbarian", "renderedPath": null, "missingReason": "icons_not_rendered"},
      "levelVisual": null,
      "missingReason": null,
      "levels": [
        {
          "level": 13,
          "durationSeconds": 1081800,
          "missingReason": null,
          "upgradeResource": "Elixir",
          "upgradeCost": 24000000,
          "requiredTownHallLevel": null,
          "requiredLaboratoryLevel": 16,
          "icon": null,
          "levelVisual": null
        }
      ]
    }
  ]
}
```

字段契约：
- **CatalogItem**: `section`(str, 快照查找键, snake_case 含 2 后缀) / `dataID`(int, 与 section 复合主键) / `category`(str, Swift rawValue: buildings/traps/troops/spells/siegeMachines/heroes/equipment/pets/guardians/capitalBuildings/capitalTraps/capitalTroops/capitalSpells) / `base`("home"|"builder"|null) / `baseMissingReason`(str|null, capital→`capital_has_no_base`) / `name`(str, 中文名, fallback 英文 Name) / `maxLevel`(int, = max levels[].level) / `icon`(AssetRef|null, item 级 UI 图标) / `levelVisual`(AssetRef|null) / `missingReason`(str|null, item 级: deprecated 记录→`deprecated_in_source`) / `levels`(CatalogLevel[] 按 level 升序)
- **CatalogLevel**: `level`(int, 显式, ≥1, 不假设从 1 开始——Super Barbarian 实测从 5 开始) / `durationSeconds`(int|null, **升级到该等级的单次时长**, 非累计) / `missingReason`(str|null, 枚举: `time_missing`列存在全空 / `time_invalid`非整数 / `upgrade_data_missing`join 无命中 / `no_time_source`表无时间列) / `upgradeResource`(str|null) / `upgradeCost`(int|null) / `requiredTownHallLevel`(int|null) / `requiredLaboratoryLevel`(int|null) / `icon`(AssetRef|null) / `levelVisual`(AssetRef|null)
- **AssetRef**: `container`(str|null, IconSWF 或 SWF) / `exportName`(str|null) / `renderedPath`(str|null, MVP 恒 null) / `missingReason`(str|null, `icons_not_rendered`/`no_icon_columns`/`no_visual_columns`)

null 纪律：durationSeconds=null ⟺ missingReason≠null（0 是真实值）；AssetRef 中 container/exportName 任一为空 → missingReason 必填；所有键恒存在（值为 null 也显式写）。

### manifest.json

```json
{
  "schemaVersion": 1,
  "gameVersion": "18.400.13",
  "buildTag": "18_400_7",
  "locale": "zh-CN",
  "sourceFingerprint": "sha256:<64hex>",
  "generatedFiles": [
    {"path": "catalog.json", "sha256": "<64hex>", "size": 482913},
    {"path": "icons/", "kind": "directory", "entries": 0}
  ],
  "counts": {"items": 884, "levels": 9742, "missingTime": 24, "missingIcons": 0}
}
```
- generatedFiles **不含 manifest 自身**（信任锚）；icons/ 为 MVP 空目录。
- counts 由生成器计算，验证器重算断言相等。
- 无时间戳/随机值（验收 #10 确定性）。

### 缺失原因词表（唯一枚举）

`time_missing` | `time_invalid` | `upgrade_data_missing` | `no_time_source` | `capital_has_no_base` | `deprecated_in_source` | `icons_not_rendered` | `no_icon_columns` | `no_visual_columns`

---

## Python 模块结构

```
Tools/
├── generate_game_catalog.py      # CLI 入口（生成）：--apk 必填 --output 必填 [--game-version] [--locale]
├── validate_game_catalog.py      # CLI 入口（校验）：--catalog 必填 [--strict]
└── game_catalog/
    ├── __init__.py               # SCHEMA_VERSION=1, MISSING_REASONS 常量
    ├── errors.py                 # CatalogError（Tier-1 硬错误）
    ├── apk.py                    # decode_asset/rows/rows_from_text/read_build_tag/localization（唯一碰 zipfile/lzma）
    ├── tables.py                 # TableSpec + TABLES 注册表 + is_doc_row + group_blocks + ffill_columns（纯函数）
    ├── durations.py              # parse_duration/parse_optional_int/to_seconds（纯函数）
    ├── names.py                  # clean_name/display_name
    ├── model.py                  # dataclass + to_json_bytes/from_json_bytes（canonical JSON）
    ├── builders.py               # build_items/build_characters/build_guardians（纯函数，输入已解码行）
    ├── fingerprint.py            # sha256_file/sha256_bytes
    ├── catalog.py                # generate()/write_bundle/load_bundle（编排）
    └── validate.py               # validate_catalog/validate_manifest/catalog_invariants/cross_check → list[str]
Tools/tests/
    ├── conftest.py               # make_csv_text/make_packed_apk fixture 工厂
    ├── test_apk.py  test_tables.py  test_durations.py  test_names.py
    ├── test_model.py  test_builders.py  test_guardians.py
    ├── test_validate.py  test_cli.py  test_determinism.py
    ├── test_property.py          # hypothesis: ffill + durations
    └── test_integration_apk.py   # 真实 APK（skipif）
```

### CLI 契约

```bash
python3 Tools/generate_game_catalog.py --apk base.apk.1 --output /tmp/coc-game-catalog
# --game-version 可选：未传时从 build.tag 推断（"18_400_7"→"18.400.7"，下划线→点、去末尾段）
# 显式传 --game-version 18.400.13 时目录内 gameVersion=18.400.13
# 写盘前自检（validate_catalog+catalog_invariants），失败不落盘；tmp+os.replace 原子写
# 输出目录已存在且非空 → 报错退出（提示先清空，不自动 rmtree）
# 退出码 0=成功 1=Tier-1 错误 2=用法错误

python3 Tools/validate_game_catalog.py --catalog /tmp/coc-game-catalog
# 报告：版本/项目数/等级记录数/缺失时间数/缺失图标数 + SAMPLES 断言 + verdict
# 退出码 0=通过 1=存在 error 2=用法错误；--strict 把 warning 升级为失败
```

---

## Task 1: 包骨架 + errors + apk 解码层

**Files:**
- Create: `Tools/game_catalog/__init__.py`
- Create: `Tools/game_catalog/errors.py`
- Create: `Tools/game_catalog/apk.py`
- Test: `Tools/tests/test_apk.py`

- [ ] **Step 1: 写失败测试** `Tools/tests/test_apk.py`：

```python
import io
import lzma
import zipfile
import pytest

from game_catalog.errors import CatalogError
from game_catalog.apk import decode_asset, rows_from_text, read_build_tag, localization


def _packed(text: str) -> bytes:
    data = text.encode("utf-8-sig")
    compressed = lzma.compress(data)
    return compressed[:8] + b"\0" * 4 + compressed[8:]


def test_decode_asset_roundtrip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/logic/buildings.csv", _packed("a,b\n1,2\n"))
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        assert decode_asset(z, "assets/logic/buildings.csv") == "a,b\n1,2\n"


def test_decode_asset_missing_member_raises():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w"):
        pass
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        with pytest.raises(KeyError):
            decode_asset(z, "assets/logic/nope.csv")


def test_rows_from_text_skips_nothing_returns_dicts():
    rows = rows_from_text("Name,Level\nA,1\nB,2\n")
    assert rows == [{"Name": "A", "Level": "1"}, {"Name": "B", "Level": "2"}]


def test_rows_from_text_cells_stripped():
    rows = rows_from_text("Name,Level\n A , 1 \n")
    assert rows == [{"Name": "A", "Level": "1"}]


def test_read_build_tag():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        assert read_build_tag(z) == "18_400_7"


def test_localization_cn_then_patch_overrides():
    cn = _packed("TID,CN\nTID_A,甲\nTID_B,乙\n")
    patch = _packed("TID,CN,Other\nTID_B,丙,x\n")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/localization/cn.csv", cn)
        z.writestr("assets/localization/texts_patch.csv", patch)
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        loc = localization(z)
    assert loc["TID_A"] == "甲"
    assert loc["TID_B"] == "丙"


def test_localization_clean_name():
    cn = _packed("TID,CN\nTID_A,有\\q引号 \\n换行 \n")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/localization/cn.csv", cn)
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        loc = localization(z)
    assert loc["TID_A"] == "有引号 换行"
```

- [ ] **Step 2: 跑测试确认失败** `python3 -m pytest Tools/tests/test_apk.py -q` → 模块不存在，全 FAIL（预期）

- [ ] **Step 3: 最小实现**

`Tools/game_catalog/__init__.py`:
```python
"""APK 静态游戏目录生成管线（issue #13）。"""

SCHEMA_VERSION = 1

MISSING_REASONS = frozenset({
    "time_missing", "time_invalid", "upgrade_data_missing", "no_time_source",
    "capital_has_no_base", "deprecated_in_source", "icons_not_rendered",
    "no_icon_columns", "no_visual_columns",
})
```

`Tools/game_catalog/errors.py`:
```python
"""Tier-1 硬错误：生成/校验过程中任何不可恢复的问题。"""


class CatalogError(Exception):
    """生成或校验目录时的硬错误（fail loud，绝不静默降级）。"""
```

`Tools/game_catalog/apk.py`:
```python
"""APK/CSV IO 层：唯一触碰 zipfile/lzma 的模块。"""

import csv
import io
import lzma
import zipfile

from .errors import CatalogError

# 现有 generate_account_name_catalog.py 的解包技巧（独立实现，不 import 旧脚本）
def decode_asset(archive: zipfile.ZipFile, path: str) -> str:
    packed = archive.read(path)
    decoded = lzma.decompress(packed[:8] + b"\0" * 4 + packed[8:])
    return decoded.decode("utf-8-sig")


def rows(archive: zipfile.ZipFile, table: str) -> list[dict[str, str]]:
    return rows_from_text(decode_asset(archive, "assets/logic/" + table))


def rows_from_text(text: str) -> list[dict[str, str]]:
    reader = csv.DictReader(io.StringIO(text))
    return [{k: (v or "").strip() for k, v in row.items() if k} for row in reader]


def read_build_tag(archive: zipfile.ZipFile) -> str:
    try:
        return archive.read("assets/build.tag").decode("utf-8").strip()
    except KeyError as exc:
        raise CatalogError("APK 缺少 assets/build.tag") from exc


def clean_localized(value: str) -> str:
    return value.replace("\\q", "").replace("\\n", " ").strip()


def localization(archive: zipfile.ZipFile) -> dict[str, str]:
    values: dict[str, str] = {}
    for row in rows_from_text(decode_asset(archive, "assets/localization/cn.csv")):
        if row.get("TID"):
            values[row["TID"]] = clean_localized(row.get("CN", ""))
    for row in rows_from_text(decode_asset(archive, "assets/localization/texts_patch.csv")):
        if row.get("TID") and row.get("CN"):
            values[row["TID"]] = clean_localized(row["CN"])
    return values
```

- [ ] **Step 4: 跑测试确认通过** `python3 -m pytest Tools/tests/test_apk.py -q` → 全 PASS

- [ ] **Step 5: Commit**

```bash
git add Tools/game_catalog Tools/tests/test_apk.py
git commit -m "feat: add game catalog package skeleton with APK decode layer (issue #13)"
```

---

## Task 2: 表格注册表 + 分组 + 逐列 forward-fill（核心算法）

**Files:**
- Create: `Tools/game_catalog/tables.py`
- Test: `Tools/tests/test_tables.py`

- [ ] **Step 1: 写失败测试** `Tools/tests/test_tables.py`：

```python
import pytest

from game_catalog.errors import CatalogError
from game_catalog.tables import (
    TableSpec,
    TABLES,
    is_doc_row,
    group_blocks,
    ffill_columns,
    section_for,
)


def make_rows(*rows: tuple[str, ...], names: tuple[str, ...] | None = None) -> list[dict[str, str]]:
    cols = ("Name", "Level", "Time", "Cost")
    out = []
    for r in rows:
        out.append(dict(zip(cols, r)))
    return out


def test_is_doc_row():
    assert is_doc_row({"Name": "String", "Level": "int"})
    assert not is_doc_row({"Name": "Town Hall", "Level": "int"})


def test_group_blocks_splits_by_name_and_skips_doc():
    rows = make_rows(
        ("String", "int", "int", "int"),
        ("A", "1", "", ""),
        ("", "2", "10", ""),
        ("B", "1", "20", ""),
        ("", "2", "", ""),
    )
    blocks = group_blocks(rows)
    assert [b.name for b in blocks] == ["A", "B"]
    assert [len(b.rows) for b in blocks] == [2, 2]


def test_ffill_columns_forward_fills_within_block_only():
    block_rows = [
        {"Name": "A", "Time": "10", "Cost": ""},
        {"Name": "", "Time": "", "Cost": "5"},
        {"Name": "", "Time": "30", "Cost": ""},
    ]
    filled = ffill_columns(block_rows, ("Time", "Cost"))
    assert filled[0] == {"Name": "A", "Time": "10", "Cost": ""}
    assert filled[1] == {"Name": "", "Time": "10", "Cost": "5"}
    assert filled[2] == {"Name": "", "Time": "30", "Cost": "5"}


def test_ffill_preserves_zero():
    block_rows = [
        {"Name": "A", "Time": "0"},
        {"Name": "", "Time": ""},
    ]
    filled = ffill_columns(block_rows, ("Time",))
    assert filled[1]["Time"] == "0"


def test_ffill_does_not_fill_non_whitelisted_columns():
    block_rows = [
        {"Name": "A", "Time": "10", "Level": "1"},
        {"Name": "", "Time": "", "Level": "2"},
    ]
    filled = ffill_columns(block_rows, ("Time",))
    assert filled[1]["Time"] == "10"
    assert filled[1]["Level"] == "2"  # 等级列不参与继承（自身带值）


def test_section_for():
    assert section_for("") == "home"
    assert section_for("0") == "home"
    assert section_for("1") == "builder"
    with pytest.raises(CatalogError):
        section_for("2")


def test_tables_registry_has_expected_sections():
    sections = {s.section for s in TABLES}
    assert sections == {
        "buildings", "traps", "units", "spells", "heroes", "pets",
        "equipment", "guardians", "capital_buildings", "capital_traps",
        "capital_characters", "capital_spells",
    }
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 最小实现** `Tools/game_catalog/tables.py`：

```python
"""表注册表（唯一事实源）+ 记录分组 + 逐列 forward-fill。"""

from dataclasses import dataclass
from typing import Iterable, Iterator, Mapping

from .errors import CatalogError

# ---- 记录分组 ----

def is_doc_row(row: Mapping[str, str]) -> bool:
    """Supercell 类型标注行：Name == 'String'。"""
    return row.get("Name") == "String"


def is_real_name(value: str | None) -> bool:
    return bool(value) and value != "String"


@dataclass
class Block:
    name: str
    rows: list[dict[str, str]]


def group_blocks(rows: list[dict[str, str]]) -> list[Block]:
    """按 Name 非空行切分记录；跳过 doc 行；空行并入当前块。"""
    blocks: list[Block] = []
    for row in rows:
        if is_doc_row(row):
            continue
        if is_real_name(row.get("Name")):
            blocks.append(Block(name=row["Name"].strip(), rows=[row]))
        elif blocks:
            blocks[-1].rows.append(row)
        else:
            raise CatalogError(f"doc/类型标注行之后的孤儿行: {row}")
    return blocks


def ffill_columns(rows: list[dict[str, str]], columns: Iterable[str]) -> list[dict[str, str]]:
    """块内逐列 forward-fill：空 cell 继承本列上方最近非空值；'0' 是真实值。

    纯函数，不修改输入；只填充白名单列；绝不跨块（调用方按块传入）。
    """
    result = [dict(r) for r in rows]
    for col in columns:
        carry = ""
        for row in result:
            value = row.get(col, "")
            if value == "":
                row[col] = carry
            else:
                carry = value
    return result


def section_for(village_type: str) -> str:
    """VillageType → 主村/建筑工人基地。''/'0'→home，'1'→builder。"""
    if village_type in ("", "0"):
        return "home"
    if village_type == "1":
        return "builder"
    raise CatalogError(f"未知 VillageType: {village_type!r}")


# ---- 表注册表 ----

@dataclass(frozen=True)
class TableSpec:
    table: str                          # 源 CSV 文件名
    section: str                        # catalog section（快照查找键）
    section2: str | None = None         # builder 后缀 section（如 buildings2）
    category: str = ""                  # Swift TrackerCategory rawValue
    category2: str | None = None
    level_column: str = "Level"
    time_columns: tuple[str, ...] = ()
    resource_column: str | None = None
    cost_column: str | None = None
    town_hall_column: str | None = None
    laboratory_column: str | None = None
    icon_columns: tuple[str, ...] = ()          # (IconSWF, IconExportName) 或 (Icon,)
    visual_columns: tuple[str, ...] = ()        # (SWF, ExportName)
    village_type_column: str | None = None
    fill_columns: tuple[str, ...] = ()          # forward-fill 白名单（不含等级列）
    id_base: int | None = None                  # None=用 GlobalID
    base_default: str | None = "home"           # capital 表传 None
    has_deprecated: bool = False
    join_upgrade_data: bool = False


TABLES: tuple[TableSpec, ...] = (
    TableSpec(
        table="buildings.csv", section="buildings", section2="buildings2",
        category="buildings", level_column="BuildingLevel",
        time_columns=("BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS"),
        resource_column="BuildResource", cost_column="BuildCost",
        town_hall_column="TownHallLevel",
        icon_columns=("Icon",), visual_columns=("SWF", "ExportName"),
        village_type_column="VillageType",
        fill_columns=("TID", "GlobalID", "VillageType", "SWF", "ExportName",
                      "Icon", "BuildResource", "BuildCost", "TownHallLevel",
                      "BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS"),
    ),
    TableSpec(
        table="traps.csv", section="traps", section2="traps2",
        category="traps", level_column="Level",
        time_columns=("BuildTimeD", "BuildTimeH", "BuildTimeM"),
        resource_column="BuildResource", cost_column="BuildCost",
        icon_columns=("IconSWF", "IconExportName"), visual_columns=("SWF", "ExportName"),
        village_type_column="VillageType",
        fill_columns=("TID", "GlobalID", "VillageType", "SWF", "ExportName",
                      "IconSWF", "IconExportName", "BuildResource", "BuildCost",
                      "BuildTimeD", "BuildTimeH", "BuildTimeM"),
    ),
    TableSpec(
        table="characters.csv", section="units", section2="units2",
        category="troops", category2="troops", level_column="VisualLevel",
        time_columns=("UpgradeTimeH", "UpgradeTimeM"),
        resource_column="UpgradeResource", cost_column="UpgradeCost",
        laboratory_column="LaboratoryLevel",
        icon_columns=("IconSWF", "IconExportName"),
        village_type_column="VillageType",
        fill_columns=("TID", "GlobalID", "VillageType", "IconSWF", "IconExportName",
                      "UpgradeResource", "UpgradeCost", "LaboratoryLevel",
                      "UpgradeTimeH", "UpgradeTimeM", "ProductionBuilding"),
        has_deprecated=True,
    ),
    TableSpec(
        table="spells.csv", section="spells", category="spells",
        level_column="Level", time_columns=("UpgradeTimeH",),
        resource_column="UpgradeResource", cost_column="UpgradeCost",
        laboratory_column="LaboratoryLevel",
        icon_columns=("IconSWF", "IconExportName"),
        village_type_column="VillageType",
        fill_columns=("TID", "GlobalID", "VillageType", "IconSWF", "IconExportName",
                      "UpgradeResource", "UpgradeCost", "LaboratoryLevel", "UpgradeTimeH"),
    ),
    TableSpec(
        table="heroes.csv", section="heroes", section2="heroes2",
        category="heroes", level_column="VisualLevel",
        time_columns=("UpgradeTimeH",),
        resource_column="UpgradeResource", cost_column="UpgradeCost",
        town_hall_column="RequiredTownHallLevel",
        icon_columns=("IconSWF", "IconExportName"),
        village_type_column="VillageType",
        fill_columns=("TID", "VillageType", "IconSWF", "IconExportName",
                      "UpgradeResource", "UpgradeCost", "RequiredTownHallLevel", "UpgradeTimeH"),
        id_base=28_000_000,
    ),
    TableSpec(
        table="pets.csv", section="pets", category="pets",
        level_column="TroopLevel", time_columns=("UpgradeTimeH", "UpgradeTimeM"),
        resource_column="UpgradeResource", cost_column="UpgradeCost",
        laboratory_column="LaboratoryLevel",
        icon_columns=("IconSWF", "IconExportName"),
        village_type_column="VillageType",
        fill_columns=("TID", "VillageType", "IconSWF", "IconExportName",
                      "UpgradeResource", "UpgradeCost", "LaboratoryLevel",
                      "UpgradeTimeH", "UpgradeTimeM"),
        id_base=73_000_000,
    ),
    TableSpec(
        table="character_items.csv", section="equipment", category="equipment",
        level_column="Level", time_columns=(),  # 无时间列 → no_time_source
        resource_column="UpgradeResources", cost_column="UpgradeCosts",
        icon_columns=("IconSWF", "IconExportName"),
        fill_columns=("TID", "IconSWF", "IconExportName", "UpgradeResources", "UpgradeCosts"),
        id_base=90_000_000,
    ),
    TableSpec(
        table="guardians.csv", section="guardians", category="guardians",
        level_column="Level", time_columns=(),  # 时长来自 upgrade_data join
        icon_columns=("IconSWF", "IconExportName"),
        fill_columns=("TID", "IconSWF", "IconExportName", "UpgradeData"),
        id_base=107_000_000,
        has_deprecated=True,
        join_upgrade_data=True,
    ),
    TableSpec(
        table="capital_buildings.csv", section="capital_buildings",
        category="capitalBuildings", level_column="BuildingLevel",
        time_columns=("BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS"),
        resource_column="BuildResource", cost_column="BuildCost",
        visual_columns=("SWF", "ExportName"),
        fill_columns=("TID", "SWF", "ExportName", "BuildResource", "BuildCost",
                      "BuildTimeD", "BuildTimeH", "BuildTimeM", "BuildTimeS"),
        base_default=None,
    ),
    TableSpec(
        table="capital_traps.csv", section="capital_traps",
        category="capitalTraps", level_column="Level",
        time_columns=("BuildTimeD", "BuildTimeH", "BuildTimeM"),
        resource_column="BuildResource", cost_column="BuildCost",
        fill_columns=("TID", "BuildResource", "BuildCost",
                      "BuildTimeD", "BuildTimeH", "BuildTimeM"),
        base_default=None,
    ),
    TableSpec(
        table="capital_characters.csv", section="capital_characters",
        category="capitalTroops", level_column="TroopLevel",
        time_columns=("UpgradeTimeH", "UpgradeTimeM"),
        icon_columns=("IconSWF", "IconExportName"),
        fill_columns=("TID", "IconSWF", "IconExportName", "UpgradeTimeH", "UpgradeTimeM"),
        base_default=None,
    ),
    TableSpec(
        table="capital_spells.csv", section="capital_spells",
        category="capitalSpells", level_column="Level",
        time_columns=("UpgradeTimeH",),
        icon_columns=("IconSWF", "IconExportName"),
        fill_columns=("TID", "IconSWF", "IconExportName", "UpgradeTimeH"),
        base_default=None,
    ),
)


def spec_for_table(table: str) -> TableSpec:
    for spec in TABLES:
        if spec.table == table:
            return spec
    raise CatalogError(f"未注册的表: {table}")
```

- [ ] **Step 4: 跑测试确认通过**

- [ ] **Step 5: Commit**

```bash
git add Tools/game_catalog/tables.py Tools/tests/test_tables.py
git commit -m "feat: table registry with block grouping and forward-fill (issue #13)"
```

---

## Task 3: 时间解析（纯函数）

**Files:**
- Create: `Tools/game_catalog/durations.py`
- Test: `Tools/tests/test_durations.py`

- [ ] **Step 1: 写失败测试** `Tools/tests/test_durations.py`：

```python
import pytest

from game_catalog.durations import parse_duration, parse_optional_int


def test_parse_duration_full_dhms():
    # 1天2小时3分4秒
    sec, reason = parse_duration(
        {"D": "1", "H": "2", "M": "3", "S": "4"}, ("D", "H", "M", "S"))
    assert sec == 93784
    assert reason is None


def test_parse_duration_partial_columns_default_zero():
    # H=1, M 为空 → 3600
    sec, reason = parse_duration({"H": "1", "M": ""}, ("H", "M"))
    assert sec == 3600
    assert reason is None


def test_parse_duration_all_empty_is_missing():
    sec, reason = parse_duration({"H": "", "M": ""}, ("H", "M"))
    assert sec is None
    assert reason == "time_missing"


def test_parse_duration_zero_is_zero_not_missing():
    sec, reason = parse_duration({"D": "0", "H": "0", "M": "0", "S": "0"}, ("D", "H", "M", "S"))
    assert sec == 0
    assert reason is None


def test_parse_duration_garbage_is_invalid():
    sec, reason = parse_duration({"H": "abc", "M": ""}, ("H", "M"))
    assert sec is None
    assert reason == "time_invalid"


def test_parse_duration_negative_raises():
    with pytest.raises(Exception):
        parse_duration({"H": "-1", "M": ""}, ("H", "M"))


def test_parse_optional_int():
    assert parse_optional_int("") is None
    assert parse_optional_int("0") == 0
    assert parse_optional_int("250") == 250
    assert parse_optional_int("abc") is None
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 最小实现** `Tools/game_catalog/durations.py`：

```python
"""时间/数值解析：三套字段（BuildTimeD/H/M/S、UpgradeTimeH/M、UpgradeTimeDays/...）→ 统一秒。"""

from .errors import CatalogError

_FACTORS = {"D": 86400, "H": 3600, "M": 60, "S": 1}
_DAY_KEYS = {"Days", "Hours", "Minutes", "Seconds"}


def parse_optional_int(value: str) -> int | None:
    """''→None；'0'→0；非纯数字→None（不抛错，由调用方决定 reason）。"""
    if value == "":
        return None
    if value.isdigit():
        return int(value)
    return None


def _component_seconds(key: str, value: str) -> int:
    if value == "":
        return 0
    if not value.isdigit():
        raise CatalogError(f"时间分量非数字: {key}={value!r}")
    return int(value) * _FACTORS[key]


def parse_duration(cells: dict[str, str], columns: tuple[str, ...]) -> tuple[int | None, str | None]:
    """解析时长列组 → (seconds, missing_reason)。

    - 全空 → (None, "time_missing")
    - 任一非数字 → (None, "time_invalid")
    - 负数 → CatalogError（Tier-1）
    - 任一非空 → 其余空列按 0 求和；'0' 是真实值
    """
    values = {c: cells.get(c, "") for c in columns}
    if all(v == "" for v in values.values()):
        return None, "time_missing"
    if any(v.startswith("-") for v in values.values()):
        raise CatalogError(f"时间分量不能为负: {values}")
    seconds = 0
    for col, v in values.items():
        if v == "":
            continue
        if not v.isdigit():
            return None, "time_invalid"
        key = col
        # 兼容 UpgradeTimeDays/Hours/Minutes/Seconds 命名
        for day_key, factor in (("Days", 86400), ("Hours", 3600), ("Minutes", 60), ("Seconds", 1)):
            if key.endswith(day_key):
                key = {"Days": "D", "Hours": "H", "Minutes": "M", "Seconds": "S"}[day_key]
                break
        seconds += int(v) * _FACTORS[key]
    return seconds, None
```

- [ ] **Step 4: 跑测试确认通过**

- [ ] **Step 5: Commit**

```bash
git add Tools/game_catalog/durations.py Tools/tests/test_durations.py
git commit -m "feat: duration parsing to seconds (issue #13)"
```

---

## Task 4: 数据模型 + canonical JSON（序列化 round-trip）

**Files:**
- Create: `Tools/game_catalog/model.py`
- Test: `Tools/tests/test_model.py`

- [ ] **Step 1: 写失败测试** `Tools/tests/test_model.py`：

```python
import json

from game_catalog.model import (
    AssetRef, CatalogLevel, CatalogItem, Catalog,
    item_to_dict, catalog_to_dict, catalog_from_dict,
)


def _sample_item() -> CatalogItem:
    return CatalogItem(
        section="units", dataID=4_000_000, category="troops", base="home",
        baseMissingReason=None, name="野蛮人", maxLevel=13,
        icon=AssetRef(container="sc/ui.sc", exportName="icon_unit_barbarian",
                      renderedPath=None, missingReason="icons_not_rendered"),
        levelVisual=None, missingReason=None,
        levels=[CatalogLevel(
            level=13, durationSeconds=1_081_800, missingReason=None,
            upgradeResource="Elixir", upgradeCost=24_000_000,
            requiredTownHallLevel=None, requiredLaboratoryLevel=16,
            icon=None, levelVisual=None,
        )],
    )


def test_assetref_dict_roundtrip():
    ref = AssetRef("sc/ui.sc", "icon_unit_barbarian", None, "icons_not_rendered")
    assert AssetRef.from_dict(ref.to_dict()) == ref


def test_item_dict_has_all_keys_even_null():
    d = item_to_dict(_sample_item())
    assert d["baseMissingReason"] is None
    assert d["levelVisual"] is None
    assert d["levels"][0]["requiredTownHallLevel"] is None


def test_catalog_roundtrip_through_json():
    cat = Catalog(schemaVersion=1, gameVersion="18.400.13", locale="zh-CN", items=[_sample_item()])
    d = catalog_to_dict(cat)
    text = json.dumps(d, ensure_ascii=False)
    back = catalog_from_dict(json.loads(text))
    assert back == cat


def test_catalog_dict_deterministic_key_order():
    cat = Catalog(schemaVersion=1, gameVersion="18.400.13", locale="zh-CN", items=[_sample_item()])
    d1 = json.dumps(catalog_to_dict(cat), ensure_ascii=False, sort_keys=True)
    d2 = json.dumps(catalog_to_dict(cat), ensure_ascii=False, sort_keys=True)
    assert d1 == d2
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 最小实现** `Tools/game_catalog/model.py`：

```python
"""数据模型 + canonical JSON 序列化。所有键恒存在（null 也写）。"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict


@dataclass
class AssetRef:
    container: str | None
    exportName: str | None
    renderedPath: str | None
    missingReason: str | None

    def to_dict(self) -> dict:
        return {
            "container": self.container,
            "exportName": self.exportName,
            "renderedPath": self.renderedPath,
            "missingReason": self.missingReason,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "AssetRef":
        return cls(d.get("container"), d.get("exportName"),
                   d.get("renderedPath"), d.get("missingReason"))


@dataclass
class CatalogLevel:
    level: int
    durationSeconds: int | None
    missingReason: str | None
    upgradeResource: str | None
    upgradeCost: int | None
    requiredTownHallLevel: int | None
    requiredLaboratoryLevel: int | None
    icon: AssetRef | None
    levelVisual: AssetRef | None

    def to_dict(self) -> dict:
        return {
            "level": self.level,
            "durationSeconds": self.durationSeconds,
            "missingReason": self.missingReason,
            "upgradeResource": self.upgradeResource,
            "upgradeCost": self.upgradeCost,
            "requiredTownHallLevel": self.requiredTownHallLevel,
            "requiredLaboratoryLevel": self.requiredLaboratoryLevel,
            "icon": self.icon.to_dict() if self.icon else None,
            "levelVisual": self.levelVisual.to_dict() if self.levelVisual else None,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "CatalogLevel":
        return cls(
            level=d["level"], durationSeconds=d.get("durationSeconds"),
            missingReason=d.get("missingReason"),
            upgradeResource=d.get("upgradeResource"), upgradeCost=d.get("upgradeCost"),
            requiredTownHallLevel=d.get("requiredTownHallLevel"),
            requiredLaboratoryLevel=d.get("requiredLaboratoryLevel"),
            icon=AssetRef.from_dict(d["icon"]) if d.get("icon") else None,
            levelVisual=AssetRef.from_dict(d["levelVisual"]) if d.get("levelVisual") else None,
        )


@dataclass
class CatalogItem:
    section: str
    dataID: int
    category: str
    base: str | None
    baseMissingReason: str | None
    name: str
    maxLevel: int
    icon: AssetRef | None
    levelVisual: AssetRef | None
    missingReason: str | None
    levels: list[CatalogLevel]

    def to_dict(self) -> dict:
        return {
            "section": self.section,
            "dataID": self.dataID,
            "category": self.category,
            "base": self.base,
            "baseMissingReason": self.baseMissingReason,
            "name": self.name,
            "maxLevel": self.maxLevel,
            "icon": self.icon.to_dict() if self.icon else None,
            "levelVisual": self.levelVisual.to_dict() if self.levelVisual else None,
            "missingReason": self.missingReason,
            "levels": [lv.to_dict() for lv in self.levels],
        }

    @classmethod
    def from_dict(cls, d: dict) -> "CatalogItem":
        return cls(
            section=d["section"], dataID=d["dataID"], category=d["category"],
            base=d.get("base"), baseMissingReason=d.get("baseMissingReason"),
            name=d["name"], maxLevel=d["maxLevel"],
            icon=AssetRef.from_dict(d["icon"]) if d.get("icon") else None,
            levelVisual=AssetRef.from_dict(d["levelVisual"]) if d.get("levelVisual") else None,
            missingReason=d.get("missingReason"),
            levels=[CatalogLevel.from_dict(x) for x in d["levels"]],
        )


@dataclass
class Catalog:
    schemaVersion: int
    gameVersion: str
    locale: str
    items: list[CatalogItem]


def item_to_dict(item: CatalogItem) -> dict:
    return item.to_dict()


def catalog_to_dict(catalog: Catalog) -> dict:
    return {
        "schemaVersion": catalog.schemaVersion,
        "gameVersion": catalog.gameVersion,
        "locale": catalog.locale,
        "items": [i.to_dict() for i in catalog.items],
    }


def catalog_from_dict(d: dict) -> Catalog:
    return Catalog(
        schemaVersion=d["schemaVersion"],
        gameVersion=d["gameVersion"],
        locale=d["locale"],
        items=[CatalogItem.from_dict(x) for x in d["items"]],
    )
```

- [ ] **Step 4: 跑测试确认通过**

- [ ] **Step 5: Commit**

```bash
git add Tools/game_catalog/model.py Tools/tests/test_model.py
git commit -m "feat: catalog data model with canonical JSON serialization (issue #13)"
```

---

## Task 5: builders——各表解析器（含 siege 分流 + guardians join）

**Files:**
- Create: `Tools/game_catalog/builders.py`
- Create: `Tools/game_catalog/names.py`
- Test: `Tools/tests/test_builders.py`
- Test: `Tools/tests/test_guardians.py`
- Test: `Tools/tests/test_names.py`

- [ ] **Step 1: 写失败测试**（三个测试文件，内容要点）：

`Tools/tests/test_names.py`:
```python
from game_catalog.names import clean_name, display_name


def test_clean_name():
    assert clean_name("A\\qB\\nC ") == "AB C"


def test_display_name_tid_hit():
    assert display_name("TID_X", "Fallback", {"TID_X": "中文"}) == "中文"


def test_display_name_fallback():
    assert display_name("TID_MISSING", "Barbarian", {"TID_X": "中文"}) == "Barbarian"
```

`Tools/tests/test_builders.py`（合成行 → build_items 断言 section/category/base/siege 分流）:
```python
import pytest

from game_catalog.builders import build_items
from game_catalog.tables import spec_for_table


def _buildings_rows():
    # doc 行 + Town Hall 两级
    return [
        {"Name": "String", "GlobalID": "int", "BuildingLevel": "int", "TID": "String",
         "SWF": "String", "ExportName": "String", "BuildTimeD": "int", "BuildTimeH": "int",
         "BuildTimeM": "int", "BuildTimeS": "int", "BuildResource": "String",
         "BuildCost": "int", "TownHallLevel": "int", "VillageType": "String"},
        {"Name": "Town Hall", "GlobalID": "1000001", "BuildingLevel": "1", "TID": "TID_TH",
         "SWF": "sc/buildings.sc", "ExportName": "town_hall_lvl1",
         "BuildTimeD": "0", "BuildTimeH": "0", "BuildTimeM": "0", "BuildTimeS": "0",
         "BuildResource": "Gold", "BuildCost": "0", "TownHallLevel": "0", "VillageType": ""},
        {"Name": "", "GlobalID": "", "BuildingLevel": "2", "TID": "",
         "SWF": "", "ExportName": "town_hall_lvl2",
         "BuildTimeD": "1", "BuildTimeH": "0", "BuildTimeM": "0", "BuildTimeS": "0",
         "BuildResource": "", "BuildCost": "1000000", "TownHallLevel": "1", "VillageType": ""},
    ]


def test_buildings_item_section_and_levels():
    items = build_items(_buildings_rows(), spec_for_table("buildings.csv"), {})
    assert len(items) == 1
    item = items[0]
    assert item.section == "buildings"
    assert item.base == "home"
    assert item.dataID == 1000001
    assert item.maxLevel == 2
    assert [lv.level for lv in item.levels] == [1, 2]
    assert item.levels[0].durationSeconds == 0          # 0 是真实值
    assert item.levels[1].durationSeconds == 86400      # 1 天
    assert item.levels[1].upgradeCost == 1000000
    assert item.levels[1].requiredTownHallLevel == 1
    assert item.levelVisual is not None
    assert item.levelVisual.exportName == "town_hall_lvl1"   # 首行继承
    assert item.levels[1].levelVisual is not None
    assert item.levels[1].levelVisual.exportName == "town_hall_lvl2"


def test_characters_siege_split():
    rows = [
        {"Name": "String", "GlobalID": "int", "VisualLevel": "int", "TID": "String",
         "IconSWF": "String", "IconExportName": "String", "ProductionBuilding": "String",
         "UpgradeTimeH": "int", "UpgradeTimeM": "int", "LaboratoryLevel": "int",
         "UpgradeResource": "String", "UpgradeCost": "int", "VillageType": "String"},
        {"Name": "Barbarian", "GlobalID": "4000000", "VisualLevel": "1", "TID": "TID_B",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_unit_barbarian", "ProductionBuilding": "",
         "UpgradeTimeH": "0", "UpgradeTimeM": "30", "LaboratoryLevel": "1",
         "UpgradeResource": "Elixir", "UpgradeCost": "10000", "VillageType": ""},
        {"Name": "Wall Wrecker", "GlobalID": "4000050", "VisualLevel": "1", "TID": "TID_WW",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_unit_wall_wrecker", "ProductionBuilding": "Siege Workshop",
         "UpgradeTimeH": "48", "UpgradeTimeM": "", "LaboratoryLevel": "1",
         "UpgradeResource": "Gold", "UpgradeCost": "3000000", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("characters.csv"), {})
    by_name = {i.name: i for i in items}
    assert by_name["Barbarian"].section == "units"
    assert by_name["Barbarian"].category == "troops"
    assert by_name["Wall Wrecker"].section == "siege_machines"
    assert by_name["Wall Wrecker"].category == "siegeMachines"


def test_no_global_id_table_uses_id_base():
    rows = [
        {"Name": "String", "VisualLevel": "int", "TID": "String",
         "UpgradeTimeH": "int", "VillageType": "String"},
        {"Name": "Barbarian King", "VisualLevel": "1", "TID": "TID_BK",
         "UpgradeTimeH": "0", "VillageType": ""},
    ]
    items = build_items(rows, spec_for_table("heroes.csv"), {})
    assert items[0].dataID == 28_000_000
```

`Tools/tests/test_guardians.py`:
```python
from game_catalog.builders import build_guardians
from game_catalog.tables import spec_for_table


def _guardian_rows():
    return [
        {"Name": "String", "Level": "int", "TID": "String", "UpgradeData": "String",
         "IconSWF": "String", "IconExportName": "String"},
        {"Name": "InfernoArtillery", "Level": "1", "TID": "TID_G", "UpgradeData": "GuardianGeneral",
         "IconSWF": "sc/ui.sc", "IconExportName": "icon_unit_guardian_ranged"},
        {"Name": "", "Level": "2", "TID": "", "UpgradeData": "", "IconSWF": "", "IconExportName": ""},
        {"Name": "", "Level": "5", "TID": "", "UpgradeData": "", "IconSWF": "", "IconExportName": ""},
    ]


def _upgrade_rows():
    return [
        {"Name": "String", "UpgradeLevel": "int", "UpgradeTimeDays": "int",
         "UpgradeTimeHours": "int", "UpgradeTimeMinutes": "int", "UpgradeTimeSeconds": "int",
         "UpgradeResource": "String", "UpgradeCost": "int"},
        {"Name": "GuardianGeneral", "UpgradeLevel": "1", "UpgradeTimeDays": "7",
         "UpgradeTimeHours": "0", "UpgradeTimeMinutes": "0", "UpgradeTimeSeconds": "0",
         "UpgradeResource": "Elixir", "UpgradeCost": "18000000"},
        {"Name": "", "UpgradeLevel": "2", "UpgradeTimeDays": "9",
         "UpgradeTimeHours": "0", "UpgradeTimeMinutes": "0", "UpgradeTimeSeconds": "0",
         "UpgradeResource": "", "UpgradeCost": "22000000"},
    ]


def test_guardian_join_hit_and_miss():
    items = build_guardians(_guardian_rows(), _upgrade_rows(), {})
    assert len(items) == 1
    item = items[0]
    assert item.dataID == 107_000_000
    assert [lv.level for lv in item.levels] == [1, 2, 5]
    assert item.levels[0].durationSeconds == 7 * 86400
    assert item.levels[0].upgradeCost == 18000000
    assert item.levels[1].durationSeconds == 9 * 86400
    assert item.levels[2].durationSeconds is None
    assert item.levels[2].missingReason == "upgrade_data_missing"
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 最小实现**

`Tools/game_catalog/names.py`:
```python
"""中文名解析：TID → cn.csv；fallback 英文 Name。"""


def clean_name(value: str) -> str:
    return value.replace("\\q", "").replace("\\n", " ").strip()


def display_name(tid: str, fallback_name: str, localized: dict[str, str]) -> str:
    if tid:
        translated = localized.get(tid)
        if translated:
            return translated
    return clean_name(fallback_name)
```

`Tools/game_catalog/builders.py`:
```python
"""表 → CatalogItem 构建器（纯函数，输入已解码行 + 本地化表）。"""

from .durations import parse_duration, parse_optional_int
from .errors import CatalogError
from .model import AssetRef, CatalogLevel, CatalogItem
from .names import display_name
from .tables import TableSpec, group_blocks, ffill_columns, section_for

SIEGE_PRODUCTION = "Siege Workshop"


def _asset_ref(container: str | None, export_name: str | None,
               missing_reason: str | None = None) -> AssetRef | None:
    if not container and not export_name:
        return None
    return AssetRef(
        container=container or None,
        exportName=export_name or None,
        renderedPath=None,
        missingReason=missing_reason or "icons_not_rendered",
    )


def _icon_ref(row: dict[str, str], spec: TableSpec) -> AssetRef | None:
    if not spec.icon_columns:
        return None
    if len(spec.icon_columns) == 1:
        container, export_name = spec.icon_columns[0], None
    else:
        container, export_name = spec.icon_columns[0], spec.icon_columns[1]
    c, e = row.get(container, ""), row.get(export_name, "") if export_name else ""
    if not c and not e:
        return None
    return _asset_ref(c, e)


def _visual_ref(row: dict[str, str], spec: TableSpec) -> AssetRef | None:
    if not spec.visual_columns:
        return None
    c, e = row.get(spec.visual_columns[0], ""), row.get(spec.visual_columns[1], "")
    if not c and not e:
        return None
    return _asset_ref(c, e, "icons_not_rendered")


def _make_item(
    block_name: str,
    rows: list[dict[str, str]],
    spec: TableSpec,
    localized: dict[str, str],
    ordinal: int,
    section_override: str | None = None,
    category_override: str | None = None,
) -> CatalogItem:
    first = rows[0]
    filled = ffill_columns(rows, spec.fill_columns)
    tid = filled[0].get("TID", "")
    name = display_name(tid, block_name, localized)

    if spec.id_base is not None:
        data_id = spec.id_base + ordinal
    else:
        gid = filled[0].get("GlobalID", "")
        if not gid:
            raise CatalogError(f"{spec.table}: {block_name} 缺少 GlobalID")
        data_id = int(gid)

    # base
    if spec.base_default is None:
        base, base_missing = None, "capital_has_no_base"
    elif spec.village_type_column:
        vt = filled[0].get(spec.village_type_column, "")
        base = section_for(vt)
        base_missing = None
        # builder → 用 section2
    else:
        base, base_missing = spec.base_default, None

    section = section_override or spec.section
    category = category_override or spec.category
    if base == "builder" and spec.section2:
        section = spec.section2
    if base == "builder" and spec.category2:
        category = spec.category2

    deprecated = spec.has_deprecated and filled[0].get("Deprecated", "").upper() == "TRUE"
    item_missing = "deprecated_in_source" if deprecated else None

    levels = []
    for row in filled:
        level_value = row.get(spec.level_column, "")
        if not level_value:
            raise CatalogError(f"{spec.table}: {block_name} 缺少等级列 {spec.level_column}")
        if not level_value.isdigit():
            raise CatalogError(f"{spec.table}: {block_name} 等级非数字: {level_value!r}")
        level = int(level_value)

        if spec.join_upgrade_data:
            duration, missing = None, None  # 由 guardians join 填充
        else:
            duration, missing = parse_duration(row, spec.time_columns)

        resource = row.get(spec.resource_column, "") if spec.resource_column else ""
        cost = parse_optional_int(row.get(spec.cost_column, "")) if spec.cost_column else None
        th = parse_optional_int(row.get(spec.town_hall_column, "")) if spec.town_hall_column else None
        lab = parse_optional_int(row.get(spec.laboratory_column, "")) if spec.laboratory_column else None

        levels.append(CatalogLevel(
            level=level,
            durationSeconds=duration,
            missingReason=missing,
            upgradeResource=resource or None,
            upgradeCost=cost,
            requiredTownHallLevel=th,
            requiredLaboratoryLevel=lab,
            icon=_icon_ref(row, spec),
            levelVisual=_visual_ref(row, spec),
        ))

    levels.sort(key=lambda lv: lv.level)
    return CatalogItem(
        section=section,
        dataID=data_id,
        category=category,
        base=base,
        baseMissingReason=base_missing,
        name=name,
        maxLevel=levels[-1].level if levels else 0,
        icon=_icon_ref(filled[0], spec),
        levelVisual=_visual_ref(filled[0], spec),
        missingReason=item_missing,
        levels=levels,
    )


def build_items(
    rows: list[dict[str, str]],
    spec: TableSpec,
    localized: dict[str, str],
) -> list[CatalogItem]:
    blocks = group_blocks(rows)
    items: list[CatalogItem] = []
    for ordinal, block in enumerate(blocks):
        section_override = None
        category_override = None
        if spec.table == "characters.csv":
            pb = block.rows[0].get("ProductionBuilding", "")
            if pb == SIEGE_PRODUCTION:
                section_override = "siege_machines"
                category_override = "siegeMachines"
        items.append(_make_item(
            block.name, block.rows, spec, localized, ordinal,
            section_override=section_override, category_override=category_override,
        ))
    return items


def build_guardians(
    rows: list[dict[str, str]],
    upgrade_rows: list[dict[str, str]],
    localized: dict[str, str],
) -> list[CatalogItem]:
    spec = next(s for s in TABLES if s.table == "guardians.csv")
    from .tables import TABLES
    items = build_items(rows, spec, localized)

    # upgrade_data 索引：(Name, Level) → row
    up_blocks = group_blocks(upgrade_rows)
    index: dict[tuple[str, int], dict[str, str]] = {}
    for block in up_blocks:
        filled = ffill_columns(block.rows, ("Name", "UpgradeResource", "AltUpgradeResource", "UpgradeCost"))
        for row in filled:
            lvl = row.get("UpgradeLevel", "")
            if not lvl.isdigit():
                raise CatalogError(f"upgrade_data: 等级非数字 {lvl!r}")
            key = (block.name, int(lvl))
            if key in index:
                raise CatalogError(f"upgrade_data: 重复键 {key}")
            index[key] = row

    for item in items:
        first = item.levels[0]
        # 从源行找 UpgradeData（通过重新分组拿首行）
        blocks = group_blocks(rows)
        # 简化：按 dataID 对应 ordinal 找块
        ordinal = item.dataID - 107_000_000
        block = blocks[ordinal]
        join_key = ffill_columns(block.rows, ("UpgradeData",))[0].get("UpgradeData", "")
        if not join_key:
            raise CatalogError(f"guardians: {item.name} 缺少 UpgradeData")
        for level in item.levels:
            hit = index.get((join_key, level.level))
            if hit is None:
                level.durationSeconds = None
                level.missingReason = "upgrade_data_missing"
                continue
            duration, missing = parse_duration(hit, ("UpgradeTimeDays", "UpgradeTimeHours",
                                                      "UpgradeTimeMinutes", "UpgradeTimeSeconds"))
            level.durationSeconds = duration
            level.missingReason = missing
            level.upgradeResource = hit.get("UpgradeResource") or hit.get("AltUpgradeResource") or None
            level.upgradeCost = parse_optional_int(hit.get("UpgradeCost", ""))
    return items
```

注意：build_guardians 中 `from .tables import TABLES` 应在文件顶部。实现时整理 import。

- [ ] **Step 4: 跑测试确认通过**

- [ ] **Step 5: Commit**

```bash
git add Tools/game_catalog/builders.py Tools/game_catalog/names.py \
       Tools/tests/test_builders.py Tools/tests/test_guardians.py Tools/tests/test_names.py
git commit -m "feat: per-table builders with siege split and guardians join (issue #13)"
```

---

## Task 6: 编排 generate() + fingerprint + CLI 入口

**Files:**
- Create: `Tools/game_catalog/fingerprint.py`
- Create: `Tools/game_catalog/catalog.py`
- Create: `Tools/generate_game_catalog.py`
- Test: `Tools/tests/test_determinism.py`
- Test: `Tools/tests/test_cli.py`

- [ ] **Step 1: 写失败测试**（要点）：

`Tools/tests/test_determinism.py`:
```python
import zipfile, io, lzma, json
from pathlib import Path

from game_catalog.catalog import generate


def _packed(text: str) -> bytes:
    c = lzma.compress(text.encode("utf-8-sig"))
    return c[:8] + b"\0" * 4 + c[8:]


def _minimal_apk(tmp_path: Path) -> Path:
    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/localization/cn.csv", _packed("TID,CN\nTID_A,测试\n"))
        z.writestr("assets/localization/texts_patch.csv", _packed("TID,CN\n"))
        z.writestr("assets/logic/buildings.csv", _packed(
            "Name,GlobalID,BuildingLevel,TID,SWF,ExportName,BuildTimeD,BuildTimeH,BuildTimeM,BuildTimeS,BuildResource,BuildCost,TownHallLevel,VillageType\n"
            "String,int,int,String,String,String,int,int,int,int,String,int,int,String\n"
            "Town Hall,1000001,1,TID_A,sc/buildings.sc,town_hall_lvl1,0,0,0,0,Gold,0,0,\n"))
    return apk


def test_generate_is_deterministic_byte_identical(tmp_path):
    apk = _minimal_apk(tmp_path)
    out1 = tmp_path / "o1"
    out2 = tmp_path / "o2"
    generate(apk, "18.400.13", out1)
    generate(apk, "18.400.13", out2)
    assert (out1 / "catalog.json").read_bytes() == (out2 / "catalog.json").read_bytes()
    assert (out1 / "manifest.json").read_bytes() == (out2 / "manifest.json").read_bytes()


def test_generate_manifest_fingerprint_and_counts(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "o"
    generate(apk, "18.400.13", out)
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["gameVersion"] == "18.400.13"
    assert manifest["buildTag"] == "18_400_7"
    assert manifest["sourceFingerprint"].startswith("sha256:")
    assert manifest["counts"]["items"] == 1
    assert manifest["counts"]["levels"] == 1
    assert (out / "icons").is_dir()


def test_generate_default_game_version_from_build_tag(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "o"
    generate(apk, None, out)
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["gameVersion"] == "18.400.7"
```

`Tools/tests/test_cli.py`（subprocess 测两个入口的退出码）:
```python
import subprocess, sys, zipfile, lzma
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[2] / "Tools"


def _packed(text: str) -> bytes:
    c = lzma.compress(text.encode("utf-8-sig"))
    return c[:8] + b"\0" * 4 + c[8:]


def _minimal_apk(tmp_path: Path) -> Path:
    apk = tmp_path / "fake.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
        z.writestr("assets/localization/cn.csv", _packed("TID,CN\nTID_A,测试\n"))
        z.writestr("assets/localization/texts_patch.csv", _packed("TID,CN\n"))
        z.writestr("assets/logic/buildings.csv", _packed(
            "Name,GlobalID,BuildingLevel,TID,SWF,ExportName,BuildTimeD,BuildTimeH,BuildTimeM,BuildTimeS,BuildResource,BuildCost,TownHallLevel,VillageType\n"
            "String,int,int,String,String,String,int,int,int,int,String,int,int,String\n"
            "Town Hall,1000001,1,TID_A,sc/buildings.sc,town_hall_lvl1,0,0,0,0,Gold,0,0,\n"))
    return apk


def _run(args: list[str]):
    return subprocess.run([sys.executable, *args], capture_output=True, text=True)


def test_generate_cli_success(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "out"
    r = _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
              "--output", str(out), "--game-version", "18.400.13"])
    assert r.returncode == 0, r.stderr
    assert (out / "catalog.json").exists()
    assert (out / "manifest.json").exists()


def test_generate_cli_missing_apk_fails(tmp_path):
    r = _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(tmp_path / "nope.apk"),
              "--output", str(tmp_path / "out")])
    assert r.returncode == 1


def test_validate_cli_success(tmp_path):
    apk = _minimal_apk(tmp_path)
    out = tmp_path / "out"
    _run([str(TOOLS / "generate_game_catalog.py"), "--apk", str(apk),
          "--output", str(out), "--game-version", "18.400.13"])
    r = _run([str(TOOLS / "validate_game_catalog.py"), "--catalog", str(out)])
    assert r.returncode == 0, r.stderr
    assert "verdict: OK" in r.stdout


def test_validate_cli_bad_dir_fails(tmp_path):
    r = _run([str(TOOLS / "validate_game_catalog.py"), "--catalog", str(tmp_path / "empty")])
    assert r.returncode == 1
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 最小实现**

`Tools/game_catalog/fingerprint.py`:
```python
"""SHA-256 指纹。"""

import hashlib
from pathlib import Path


def sha256_file(path: Path, chunk_size: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(chunk_size):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()
```

`Tools/game_catalog/catalog.py`:
```python
"""编排：读取 APK → 解析全部表 → 生成 Catalog + Manifest → 原子写出。"""

import json
import os
import tempfile
from pathlib import Path

from . import SCHEMA_VERSION
from .apk import rows, read_build_tag, localization
from .builders import build_items, build_guardians
from .errors import CatalogError
from .fingerprint import sha256_bytes, sha256_file
from .model import Catalog, catalog_to_dict
from .tables import TABLES


def _infer_game_version(build_tag: str) -> str:
    """'18_400_7' → '18.400.7'（下划线→点、去掉末尾 build 段）。"""
    parts = build_tag.split("_")
    if len(parts) >= 3:
        return ".".join(parts[:3])
    return build_tag.replace("_", ".")


def _build_catalog_items(archive, localized) -> list:
    items = []
    upgrade_rows = None
    for spec in TABLES:
        table_rows = rows(archive, spec.table)
        if spec.join_upgrade_data:
            upgrade_rows = rows(archive, "upgrade_data.csv")
            items.extend(build_guardians(table_rows, upgrade_rows, localized))
        else:
            items.extend(build_items(table_rows, spec, localized))
    items.sort(key=lambda i: (i.section, i.dataID))
    return items


def generate(apk: Path, game_version: str | None, output_dir: Path, locale: str = "zh-CN") -> Path:
    if not Path(apk).is_file():
        raise CatalogError(f"APK 不存在: {apk}")
    out = Path(output_dir)
    if out.exists() and any(out.iterdir()):
        raise CatalogError(f"输出目录已存在且非空（先清空或换目录）: {out}")

    import zipfile
    with zipfile.ZipFile(apk) as archive:
        build_tag = read_build_tag(archive)
        effective_version = game_version or _infer_game_version(build_tag)
        localized = localization(archive)
        items = _build_catalog_items(archive, localized)

    catalog = Catalog(schemaVersion=SCHEMA_VERSION, gameVersion=effective_version,
                      locale=locale, items=items)
    counts = {
        "items": len(items),
        "levels": sum(len(i.levels) for i in items),
        "missingTime": sum(1 for i in items for lv in i.levels if lv.durationSeconds is None),
        "missingIcons": sum(1 for i in items for lv in i.levels if lv.icon and lv.icon.renderedPath is None),
    }

    catalog_bytes = json.dumps(catalog_to_dict(catalog), ensure_ascii=False,
                               indent=2, sort_keys=True).encode("utf-8") + b"\n"
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "gameVersion": effective_version,
        "buildTag": build_tag,
        "locale": locale,
        "sourceFingerprint": sha256_file(apk),
        "generatedFiles": [
            {"path": "catalog.json", "sha256": sha256_bytes(catalog_bytes),
             "size": len(catalog_bytes)},
            {"path": "icons/", "kind": "directory", "entries": 0},
        ],
        "counts": counts,
    }
    manifest_bytes = json.dumps(manifest, ensure_ascii=False, indent=2,
                                sort_keys=True).encode("utf-8") + b"\n"

    # 原子写：tmp 目录 + os.replace
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=".coc-catalog-", dir=str(out.parent)))
    try:
        (tmp / "catalog.json").write_bytes(catalog_bytes)
        (tmp / "manifest.json").write_bytes(manifest_bytes)
        (tmp / "icons").mkdir()
        os.replace(tmp / "catalog.json", out / "catalog.json") if out.exists() else None
        out.mkdir(parents=True, exist_ok=True)
        os.replace(tmp / "catalog.json", out / "catalog.json")
        os.replace(tmp / "manifest.json", out / "manifest.json")
        (out / "icons").mkdir(exist_ok=True)
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
    return out
```

`Tools/generate_game_catalog.py`:
```python
#!/usr/bin/env python3
"""生成 APK 版本化静态升级目录（issue #13）。

用法:
  python3 Tools/generate_game_catalog.py --apk base.apk.1 --output /tmp/coc-game-catalog
  python3 Tools/generate_game_catalog.py --apk base.apk.1 --game-version 18.400.13 --output /tmp/coc-game-catalog
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.catalog import generate
from game_catalog.errors import CatalogError
from game_catalog.validate import validate_catalog, catalog_invariants


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="生成 APK 静态升级目录")
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--game-version", default=None,
                        help="游戏版本（APK 内无该字符串；默认从 build.tag 推断）")
    parser.add_argument("--locale", default="zh-CN")
    args = parser.parse_args(argv)

    try:
        generate(args.apk, args.game_version, args.output, args.locale)
    except CatalogError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    # 写盘后自检
    try:
        errors = validate_catalog(args.output)
        if errors:
            for e in errors:
                print(f"error: {e}", file=sys.stderr)
            return 1
    except CatalogError as exc:
        print(f"error: 自检失败: {exc}", file=sys.stderr)
        return 1
    print(f"wrote catalog to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

注意：generate 中原子写部分有笔误（`os.replace` 被调用两次且第一处 `if out.exists()` 分支错误），实现时修正为：`out.mkdir(parents=True, exist_ok=True)` 后直接 `os.replace` 两个文件 + `(out/"icons").mkdir(exist_ok=True)`。

- [ ] **Step 4: 跑测试确认通过**

- [ ] **Step 5: Commit**

```bash
git add Tools/game_catalog/fingerprint.py Tools/game_catalog/catalog.py \
       Tools/generate_game_catalog.py \
       Tools/tests/test_determinism.py Tools/tests/test_cli.py
git commit -m "feat: generation orchestration with atomic write and CLI (issue #13)"
```

---

## Task 7: 验证器 validate.py + CLI

**Files:**
- Create: `Tools/game_catalog/validate.py`
- Create: `Tools/validate_game_catalog.py`
- Test: `Tools/tests/test_validate.py`

- [ ] **Step 1: 写失败测试** `Tools/tests/test_validate.py`（要点）：

```python
import json
from pathlib import Path

from game_catalog.validate import validate_catalog
from game_catalog.model import catalog_to_dict, Catalog, CatalogItem


def _valid_dir(tmp_path: Path) -> Path:
    item = CatalogItem(
        section="units", dataID=4_000_000, category="troops", base="home",
        baseMissingReason=None, name="野蛮人", maxLevel=1,
        icon=None, levelVisual=None, missingReason=None,
        levels=[],
    )
    catalog = Catalog(schemaVersion=1, gameVersion="18.400.13", locale="zh-CN",
                      items=[item])
    d = tmp_path / "cat"
    d.mkdir()
    (d / "catalog.json").write_text(json.dumps(catalog_to_dict(catalog), ensure_ascii=False))
    (d / "manifest.json").write_text(json.dumps({
        "schemaVersion": 1, "gameVersion": "18.400.13", "buildTag": "18_400_7",
        "locale": "zh-CN", "sourceFingerprint": "sha256:" + "a" * 64,
        "generatedFiles": [{"path": "catalog.json", "sha256": "", "size": 0}],
        "counts": {"items": 1, "levels": 0, "missingTime": 0, "missingIcons": 0},
    }))
    return d


def test_validate_ok(tmp_path):
    assert validate_catalog(_valid_dir(tmp_path)) == []


def test_validate_missing_manifest(tmp_path):
    d = _valid_dir(tmp_path)
    (d / "manifest.json").unlink()
    errors = validate_catalog(d)
    assert any("manifest" in e for e in errors)


def test_validate_game_version_mismatch(tmp_path):
    d = _valid_dir(tmp_path)
    m = json.loads((d / "manifest.json").read_text())
    m["gameVersion"] = "18.400.12"
    (d / "manifest.json").write_text(json.dumps(m))
    errors = validate_catalog(d)
    assert any("gameVersion" in e for e in errors)


def test_validate_duplicate_dataid(tmp_path):
    d = _valid_dir(tmp_path)
    c = json.loads((d / "catalog.json").read_text())
    c["items"].append(dict(c["items"][0]))
    (d / "catalog.json").write_text(json.dumps(c))
    errors = validate_catalog(d)
    assert any("dataID" in e for e in errors)


def test_validate_duration_null_requires_reason(tmp_path):
    d = _valid_dir(tmp_path)
    c = json.loads((d / "catalog.json").read_text())
    c["items"][0]["levels"] = [{"level": 1, "durationSeconds": None, "missingReason": None,
                                 "upgradeResource": None, "upgradeCost": None,
                                 "requiredTownHallLevel": None, "requiredLaboratoryLevel": None,
                                 "icon": None, "levelVisual": None}]
    (d / "catalog.json").write_text(json.dumps(c))
    errors = validate_catalog(d)
    assert any("missingReason" in e for e in errors)
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 最小实现** `Tools/game_catalog/validate.py`：

```python
"""目录校验：结构/语义不变量。生成器写盘前自检 + 验证器 CLI 共用同一实现。"""

import json
from pathlib import Path

from . import SCHEMA_VERSION, MISSING_REASONS
from .errors import CatalogError
from .model import catalog_from_dict


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
    except (json.JSONDecodeError, OSError, KeyError, ValueError) as exc:
        return [f"catalog.json 解析失败: {exc}"]

    # 版本一致性
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"manifest schemaVersion={manifest.get('schemaVersion')} != {SCHEMA_VERSION}")
    if catalog.schemaVersion != SCHEMA_VERSION:
        errors.append(f"catalog schemaVersion={catalog.schemaVersion} != {SCHEMA_VERSION}")
    if manifest.get("gameVersion") != catalog.gameVersion:
        errors.append(f"gameVersion 不一致: manifest={manifest.get('gameVersion')} catalog={catalog.gameVersion}")

    # 指纹格式
    fp = manifest.get("sourceFingerprint", "")
    if not (isinstance(fp, str) and fp.startswith("sha256:") and len(fp) == 7 + 64):
        errors.append(f"sourceFingerprint 格式非法: {fp!r}")

    # 主键唯一性 + level 升序 + null/reason 配对
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

    return errors


def catalog_invariants(dir_path: str | Path) -> list[str]:
    """语义层校验（当前与 validate_catalog 合并，保留函数签名供 CLI 自检）。"""
    return validate_catalog(dir_path)
```

`Tools/validate_game_catalog.py`:
```python
#!/usr/bin/env python3
"""校验 APK 静态升级目录（issue #13）。

用法:
  python3 Tools/validate_game_catalog.py --catalog /tmp/coc-game-catalog
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.validate import validate_catalog
from game_catalog.errors import CatalogError


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="校验 APK 静态升级目录")
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--strict", action="store_true", help="将 warning 升级为失败")
    args = parser.parse_args(argv)

    try:
        errors = validate_catalog(args.catalog)
    except CatalogError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    if errors:
        print("verdict: FAIL")
        return 1
    print("verdict: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 跑测试确认通过**

- [ ] **Step 5: Commit**

```bash
git add Tools/game_catalog/validate.py Tools/validate_game_catalog.py Tools/tests/test_validate.py
git commit -m "feat: catalog validator with shared invariants and CLI (issue #13)"
```

---

## Task 8: property-based 测试（hypothesis）

**Files:**
- Create: `Tools/tests/test_property.py`

- [ ] **Step 1: 写测试**（本任务先写测试，测试本身就是验收工具）：

```python
"""hypothesis property-based：forward-fill 与时间解析不变量。"""

from hypothesis import given, strategies as st

from game_catalog.tables import group_blocks, ffill_columns
from game_catalog.durations import parse_duration


BLOCK_STRATEGY = st.lists(
    st.lists(
        st.tuples(
            st.sampled_from(["", "A", "B"]),          # Name
            st.one_of(st.just(""), st.just("10"), st.just("0"), st.just("5")),  # Time
        ),
        min_size=1, max_size=8,
    ),
    min_size=1, max_size=5,
)


@given(BLOCK_STRATEGY)
def test_ffill_output_rows_equals_input_rows(blocks):
    rows = []
    for block in blocks:
        for i, (name, time) in enumerate(block):
            rows.append({"Name": name if i == 0 else "", "Time": time})
    grouped = group_blocks(rows)
    total_filled = 0
    for g in grouped:
        filled = ffill_columns(g.rows, ("Time",))
        assert len(filled) == len(g.rows)
        total_filled += len(filled)
    assert total_filled == sum(len(b) for b in blocks)


@given(BLOCK_STRATEGY)
def test_ffill_non_empty_values_never_change(blocks):
    for block in blocks:
        rows = [{"Name": n, "Time": t} for n, t in block]
        filled = ffill_columns(rows, ("Time",))
        for orig, new in zip(rows, filled):
            if orig["Time"] != "":
                assert new["Time"] == orig["Time"]


@given(BLOCK_STRATEGY)
def test_ffill_inherited_value_is_last_non_empty_in_block(blocks):
    for block in blocks:
        rows = [{"Name": n, "Time": t} for n, t in block]
        filled = ffill_columns(rows, ("Time",))
        carry = ""
        for row in filled:
            if row["Time"] != "":
                carry = row["Time"]
            else:
                assert row["Time"] == carry  # 空即继承（或 carry 为空时仍空）


@given(st.lists(st.sampled_from(["", "0", "12", "3600"]), min_size=1, max_size=4))
def test_parse_duration_non_negative_and_consistent(values):
    cells = {f"C{i}": v for i, v in enumerate(values)}
    columns = tuple(f"C{i}" for i in range(len(values)))
    seconds, reason = parse_duration(cells, columns)
    if reason is not None:
        assert seconds is None
        assert reason in ("time_missing", "time_invalid")
    else:
        assert seconds is not None and seconds >= 0


@given(st.integers(min_value=0, max_value=10**9))
def test_parse_duration_single_field_roundtrip(total):
    cells = {"H": str(total), "M": ""}
    seconds, reason = parse_duration(cells, ("H", "M"))
    assert seconds == total * 3600
```

- [ ] **Step 2: 跑测试** `python3 -m pytest Tools/tests/test_property.py -q`（需先有 tables/durations 实现，本任务在 Task 2/3 之后执行；如果作为独立任务跑，先确认依赖任务已完成）

- [ ] **Step 3: 修复实现直到 property 全过**（如不变量暴露 bug 则修 tables/durations）

- [ ] **Step 4: Commit**

```bash
git add Tools/tests/test_property.py
git commit -m "test: property-based invariants for forward-fill and durations (issue #13)"
```

---

## Task 9: 真实 APK 集成测试 + 验收样例

**Files:**
- Create: `Tools/tests/test_integration_apk.py`

- [ ] **Step 1: 写测试**：

```python
"""真实 APK 集成测试（验收 #1-10 锚点）。无 APK 时跳过。"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

APK = Path("/path/to/base.apk")
TOOLS = Path(__file__).resolve().parents[2] / "Tools"

pytestmark = pytest.mark.skipif(not APK.is_file(), reason="真实 APK 不存在")

SAMPLES = {
    # (section, dataID) → 期望 maxLevel；level → 期望秒数
    "town_hall": {"key": ("buildings", 1000001), "max_level": 18, "level_18_seconds": 1036800},
    "barbarian": {"key": ("units", 4000000), "max_level": 13, "level_13_seconds": 1081800},
    "lightning": {"key": ("spells", 26000000), "max_level": 13},
    "hero": {"key": ("heroes", 28000000)},
    "pet": {"key": ("pets", 73000000)},
}


def _find(items, section, data_id):
    return next((i for i in items if i["section"] == section and i["dataID"] == data_id), None)


@pytest.fixture(scope="module")
def catalog():
    out = Path("/tmp/coc-game-catalog-test")
    if out.exists():
        import shutil
        shutil.rmtree(out)
    r = subprocess.run([sys.executable, str(TOOLS / "generate_game_catalog.py"),
                        "--apk", str(APK), "--output", str(out),
                        "--game-version", "18.400.13"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
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
    # 至少前几级来自 upgrade_data，超出范围级 missingReason
    assert any(lv["durationSeconds"] is not None for lv in first["levels"])
    assert any(lv["missingReason"] == "upgrade_data_missing" for i in items for lv in i["levels"])


def test_acceptance_deterministic_regeneration(catalog):
    _, _, out = catalog
    out2 = Path("/tmp/coc-game-catalog-test-2")
    if out2.exists():
        import shutil
        shutil.rmtree(out2)
    r = subprocess.run([sys.executable, str(TOOLS / "generate_game_catalog.py"),
                        "--apk", str(APK), "--output", str(out2),
                        "--game-version", "18.400.13"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert (out / "catalog.json").read_bytes() == (out2 / "catalog.json").read_bytes()
    assert (out / "manifest.json").read_bytes() == (out2 / "manifest.json").read_bytes()


def test_acceptance_dataid_compat_with_name_catalog(catalog):
    """与现有 generate_account_name_catalog 的 dataID 段对齐（heroes/pets/equipment/guardians）。"""
    data, _, _ = catalog
    sys.path.insert(0, str(TOOLS))
    import generate_account_name_catalog as legacy
    legacy_cat = legacy.build_catalog(APK)
    for section in ("heroes", "pets", "equipment", "guardians"):
        legacy_keys = {k.split(":")[1] for k in legacy_cat if k.split(":")[0] == section}
        new_ids = {str(i["dataID"]) for i in data["items"] if i["section"] == section}
        assert legacy_keys == new_ids, f"{section} dataID 段不兼容: legacy={len(legacy_keys)} new={len(new_ids)}"
```

- [ ] **Step 2: 跑测试** `python3 -m pytest Tools/tests/test_integration_apk.py -q` → 真实 APK 在场应全 PASS

- [ ] **Step 3: 修复实现直到全过**（验收样例如有失败，回修 builders/tables）

- [ ] **Step 4: Commit**

```bash
git add Tools/tests/test_integration_apk.py
git commit -m "test: real APK acceptance samples for issue #13"
```

---

## Task 10: 生成并落库 18.400.13 目录 + README

**Files:**
- Create: `Sources/COCHelperCore/Resources/GameCatalog/18.400.13/catalog.json`
- Create: `Sources/COCHelperCore/Resources/GameCatalog/18.400.13/manifest.json`
- Modify: `README.md`（Tools 用法 + 边界说明）

- [ ] **Step 1: 生成目录**

```bash
python3 Tools/generate_game_catalog.py \
  --apk /path/to/base.apk \
  --game-version 18.400.13 \
  --output Sources/COCHelperCore/Resources/GameCatalog/18.400.13
```

- [ ] **Step 2: 验证**

```bash
python3 Tools/validate_game_catalog.py --catalog Sources/COCHelperCore/Resources/GameCatalog/18.400.13
python3 -m pytest Tools/tests -q
swift test
```

- [ ] **Step 3: README 更新**：在 README「下一阶段建议」旁新增 Tools 小节，说明生成/验证命令、--game-version 语义、边界（不渲染图标、不编造缺失、不改现有脚本）。

- [ ] **Step 4: 确认大小** `du -sh Sources/COCHelperCore/Resources/GameCatalog/18.400.13`（预期 1-3MB 可接受）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/Resources/GameCatalog README.md
git commit -m "feat: bundle 18.400.13 static game catalog (issue #13)"
```

---

## 验证命令（全部任务完成后）

```bash
cd .worktrees/feat-issue13-game-catalog
python3 -m pytest Tools/tests -q
python3 Tools/generate_game_catalog.py --apk /path/to/base.apk --output /tmp/coc-game-catalog
python3 Tools/validate_game_catalog.py --catalog /tmp/coc-game-catalog
swift test
./scripts/build_app.sh
```

---

## 风险与边界（不要顺手做）

- **不改** `Tools/generate_account_name_catalog.py`、`Sources/COCHelperCore/*.swift`、`Package.swift`
- **不渲染图标**（renderedPath 恒 null + icons_not_rendered）；不解析 sc/*.swf 二进制
- **不编造**装备/都城时长；不用 0 填充缺失；不把 '0' 当缺失
- **不解析** weapons.csv / village_objects.csv / mini_levels.csv / decos / obstacles / skins
- **不读** SummonTime / RegenTime / TrainingTime（战斗时间）
- **不自动** rmtree 输出目录；输出目录非空 → 报错提示
- 不提交 APK 或整包游戏资源；不碰 token/密钥
- 每次 commit 前跑 `python3 -m pytest Tools/tests -q` 全绿
