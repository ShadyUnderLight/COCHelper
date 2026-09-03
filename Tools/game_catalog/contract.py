"""renderedPath 输出契约纯函数（Issue #27 R-A/R-B/R-D 规则；E0-03/Issue #303
已撤销 R-C manifest 登记门）。

与 Swift CatalogAssetRef.isRenderable（Sources/COCHelperCore/GameCatalog.swift）同一
语义；契约错误消息文本与 validate.py 现有负例校验消息一致（不含调用方追加的
"(<context>)" 后缀，由 validate.py 负责）。

纯 stdlib、无 IO：file_exists 由调用方计算后传入（bool），保持纯函数可测。
"""

import re

_RD_RE = re.compile(r"^icons/[^/]+/[^/]+\.png$")
# gameVersion 段（契约 R7 版本隔离：renderedPath 内不得含版本段，如 18.400 / 18.400.13）
_VERSION_SEGMENT_RE = re.compile(r"^\d+\.\d+(\.\d+)?$")
# 契约 R2.2：文件名（export_key 段，含 .png 扩展）长度上限 200 字节
_MAX_FILENAME_BYTES = 200


def rendered_path_format_ok(rendered_path: str) -> bool:
    """R-D 严格格式：`icons/<container_key>/<export_key>.png` 两级结构（契约 R2.1）。

    拒绝：`.` / `..` 路径段（段级逃逸；`[^/]+` 不排除字面 `.`/`..`，须显式拒绝）、
    版本段（第一段形如 `18.400` / `18.400.13`）、绝对路径、单级/多级路径、非 `.png`、
    无 `icons/` 前缀、export 文件名超过 200 字节（契约 R2.2）。纯函数无 IO——
    validate.py 用它短路文件系统探测（防 NB-3 逃逸）。
    """
    if not _RD_RE.match(rendered_path):
        return False
    parts = rendered_path.split("/")
    if "." in parts or ".." in parts:
        return False
    if "%" in rendered_path:
        # 拒绝 URL 编码段（如 %2e%2e / %2F）：pathlib 不解码，但未来若出现
        # URL 解码消费者会引入真实逃逸；段内 % 对合法文件名也无意义。
        return False
    if "\\" in rendered_path:
        # 拒绝未 sanitize 的反斜杠（契约 R2.2：生成器 sanitize 将 `\` 替换为
        # `_`，renderedPath 必须是 sanitize 后形态；Windows 上 `\` 是路径
        # 分隔符，跨平台逃逸风险，P2-1c）。
        return False
    if _VERSION_SEGMENT_RE.match(parts[1]):
        return False
    export_key = parts[2][:-4]  # 去掉 .png 后缀——R2.2 约束的是 sanitize 后的 export key
    if export_key in ("", ".", ".."):
        # 空 key（如 ".png" 已被正则拒绝，此处防御）；key 为 "."/".."（如
        # "..png"/"...png"）是点号段逃逸的变形，`"." in parts` 查不到（带 .png
        # 后缀不再是独立段），须在此显式拒绝（P2-1）。
        return False
    return len(parts[2].encode("utf-8")) <= _MAX_FILENAME_BYTES


def is_renderable(rendered_path: str | None, missing_reason: str | None) -> bool:
    """与 Swift CatalogAssetRef.isRenderable 同一语义：renderedPath 非空 且 missingReason 为空。

    Swift 定义 `renderedPath != nil && missingReason == nil`（GameCatalog.swift:47-49），
    **空串 "" 视为不可渲染**（交叉审核 P1-2：空路径不得被当作可渲染资源，
    违反契约 R2.2/R5.3；Swift 侧同规则）。
    """
    return (rendered_path is not None and rendered_path != ""
            and missing_reason is None)


def check_rendered_path_contract(
    rendered_path: str | None,
    missing_reason: str | None,
    file_exists: bool,
) -> list[str]:
    """返回违反的契约错误列表（空=通过）。

    规则顺序（与 validate.py 一致）：
    R-B 互斥（renderedPath 非空且 missingReason 非空）→ R-D 格式（严格两级
    `icons/<container_key>/<export_key>.png`，见 rendered_path_format_ok）→
    R-A 文件存在。
    rendered_path 为 None（无引用）→ 返回 []；**空串 "" 不是合法渲染路径，
    走 R-D 报格式非法**（交叉审核 P1-2：空路径不得绕过校验）。
    missing_reason 按 `is not None` 判定（空串 "" 也触发 R-B 互斥）。

    R-B 是独立轴（最优先、不被 R-D 短路）；R-D 失败后短路剩余轴。

    rendered_path 非 str 时行为未定义（AttributeError 上抛；validate.py 顶层
    wrapper 捕获后转 "catalog 内容非法"，勿在此处擅自拦截）。
    """
    if rendered_path is None:
        return []
    errors: list[str] = []
    if missing_reason is not None:
        errors.append(
            f"renderedPath 与 missingReason 同时存在（成功字段与失败原因互斥）: {rendered_path} "
            f"missingReason={missing_reason!r}")
    if not rendered_path_format_ok(rendered_path):
        errors.append(
            f"renderedPath 格式非法: {rendered_path!r}"
            "（须 icons/<container_key>/<export_key>.png 两级结构，"
            "且不含版本段/.. 段/绝对路径）")
        return errors
    if not file_exists:
        errors.append(f"renderedPath 指向不存在的文件: {rendered_path}")
    return errors
