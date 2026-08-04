"""时间/数值解析：三套字段（BuildTimeD/H/M/S、UpgradeTimeH/M、UpgradeTimeDays/...）→ 统一秒。"""

from .errors import CatalogError

_FACTORS = {"D": 86400, "H": 3600, "M": 60, "S": 1}


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
