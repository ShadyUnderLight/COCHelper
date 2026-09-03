"""APK 静态游戏目录生成管线（issue #13）。"""

# v3 (E0-03/Issue #303)：manifest 精简为四字段版本/构建元数据
# （schemaVersion/gameVersion/buildTag/locale），sourceFingerprint /
# generatedFiles / counts 整体删除；catalog.json 与 manifest 共用同一版本号。
SCHEMA_VERSION = 3

# Issue #97：铁匠铺（Blacksmith）等级合法域。equipment 的 requiredBlacksmithLevel
# 校验（validate.py）与回填（annotate_blacksmith_levels.py）共用单一事实源；
# 未来版本铁匠铺等级上限变化时只需改这里（源数据实测 18.400.13：BS ∈ 1..10）。
BLACKSMITH_LEVEL_MIN = 1
BLACKSMITH_LEVEL_MAX = 10

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
    "movieclip_not_parsed",  # export 的 object_id 非 Shape 非 MovieClip（引用损坏，防御分支发射）；嵌套 MovieClip 走 skippedElements 记录不发射（契约 §6）
    "texture_compressed_astc",  # 内嵌 KTX/ASTC 压缩纹理，无解码器
    "texture_external_sctx",  # 纹理存外部 .sctx 文件（实测 texture_format=0 + external_texture 非空；.sctx 头 pixel_type=208=ASTC_RGBA8_6x6，社区枚举，待验证），无解码器
    "zstd_unavailable",  # libzstd 无法加载（ctypes 全路径失败）
    # Issue #30 Task 7：渲染生成器（Tools/render_generator.py）稳定枚举
    "container_not_found",  # APK 无此容器（assets/sc/*.sc 缺失）
    "export_not_found",  # exportNames 无此导出名
    "astc_unsupported",  # KTX/SCTX 容器解析失败或 ASTC 格式不支持（HDR 等）
    "texture_missing",  # 纹理无内嵌数据 / 外部 .sctx 缺失或读取失败
    "render_failed",  # 渲染链失败（bounds/光栅化/PNG 编码/引用越界）
})

# 兼容别名：全量并集（既有引用可用；新代码请用分域词表）
MISSING_REASONS = (LEVEL_MISSING_REASONS | BASE_MISSING_REASONS
                   | ITEM_MISSING_REASONS | ASSET_MISSING_REASONS)
