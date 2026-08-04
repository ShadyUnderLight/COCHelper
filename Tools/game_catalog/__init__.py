"""APK 静态游戏目录生成管线（issue #13）。"""

SCHEMA_VERSION = 1

MISSING_REASONS = frozenset({
    "time_missing", "time_invalid", "upgrade_data_missing", "no_time_source",
    "capital_has_no_base", "deprecated_in_source", "icons_not_rendered",
    "no_icon_columns", "no_visual_columns",
})
