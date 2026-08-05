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
    # Issue #27 R5：渲染管线失败语义（spike 实证触发条件，契约 docs/rendered-path-contract.md §6）
    "sc_parse_failed",  # SC2 容器解析失败（magic/version/descriptor/chunk 越界等）
    "movieclip_not_parsed",  # export 指向 MovieClip 且帧解析链路未实现（真实数据 export 全指向 MovieClip）
    "texture_compressed_astc",  # 内嵌 KTX/ASTC 压缩纹理，无解码器
    "texture_external_sctx",  # 纹理存外部 .sctx 文件（ASTC_RGBA8_4x4），无解码器
    "zstd_unavailable",  # libzstd 无法加载（ctypes 全路径失败）
})

# 兼容别名：全量并集（既有引用可用；新代码请用分域词表）
MISSING_REASONS = (LEVEL_MISSING_REASONS | BASE_MISSING_REASONS
                   | ITEM_MISSING_REASONS | ASSET_MISSING_REASONS)
