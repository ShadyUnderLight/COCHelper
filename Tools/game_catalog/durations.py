"""时间/数值解析：三套字段（BuildTimeD/H/M/S、UpgradeTimeH/M、UpgradeTimeDays/...）→ 统一秒。"""

from .errors import CatalogError

_FACTORS = {"D": 86400, "H": 3600, "M": 60, "S": 1}
_DAY_KEY_SUFFIXES = {"Days": "D", "Hours": "H", "Minutes": "M", "Seconds": "S"}


def _normalize_key(col: str) -> str:
    """BuildTimeD/UpgradeTimeH/UpgradeTimeDays/... → D/H/M/S 单字母。"""
    for long_name, short in _DAY_KEY_SUFFIXES.items():
        if col.endswith(long_name):
            return short
    if col and col[-1] in "DHMS":
        return col[-1]
    raise CatalogError(f"无法识别的时长列: {col!r}")


def parse_optional_int(value: str) -> int | None:
    """''→None；'0'→0；非纯数字→None（不抛错，由调用方决定 reason）。"""
    if value == "":
        return None
    if value.isdigit():
        return int(value)
    return None


def parse_duration(cells: dict[str, str], columns: tuple[str, ...]) -> tuple[int | None, str | None]:
    """解析时长列组 → (seconds, missing_reason)。

    - 配置错误：整组时间列在输入中都不存在（如列名拼错）→ CatalogError（Tier-1）
    - 全空 → (None, "time_missing")
    - 任一非数字 → (None, "time_invalid")
    - 负数 → CatalogError（Tier-1）
    - 任一非空 → 其余空列按 0 求和；'0' 是真实值
    """
    if all(c not in cells for c in columns):
        raise CatalogError(f"时间列全部缺失（配置错误）: {columns}")
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
        seconds += int(v) * _FACTORS[_normalize_key(col)]
    return seconds, None
