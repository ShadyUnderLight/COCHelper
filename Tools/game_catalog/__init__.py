"""APK 静态游戏目录生成管线（issue #13）。"""

SCHEMA_VERSION = 1

# 按字段域拆分的 missingReason 词表：level / base / item / asset 各域互不混用，
# 校验时用分域词表拒绝跨域污染（如 level 上写 "capital_has_no_base"）。
LEVEL_MISSING_REASONS = frozenset({
    "time_missing", "time_invalid", "upgrade_data_missing", "no_time_source",
    "min_level_initial_no_upgrade",  # to_next 表最低等级 = 初始等级（非 1 起始如超级兵 5、直升机 15），无升级
})
BASE_MISSING_REASONS = frozenset({"capital_has_no_base"})
ITEM_MISSING_REASONS = frozenset({"deprecated_in_source"})
ASSET_MISSING_REASONS = frozenset({
    "icons_not_rendered", "no_icon_columns", "no_visual_columns",
})

# 兼容别名：全量并集（既有引用可用；新代码请用分域词表）
MISSING_REASONS = (LEVEL_MISSING_REASONS | BASE_MISSING_REASONS
                   | ITEM_MISSING_REASONS | ASSET_MISSING_REASONS)
