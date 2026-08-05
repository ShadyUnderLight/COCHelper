"""renderedPath 输出契约纯函数（Issue #27 R-A/R-B/R-C/R-D 规则）。

与 Swift CatalogAssetRef.isRenderable（Sources/COCHelperCore/GameCatalog.swift）同一
语义；契约错误消息文本与 validate.py 现有负例校验消息一致（不含调用方追加的
"(<context>)" 后缀，由 validate.py 负责）。

纯 stdlib、无 IO：file_exists/registered 由调用方计算后传入（bool），保持纯函数可测。
"""


def is_renderable(rendered_path: str | None, missing_reason: str | None) -> bool:
    """与 Swift CatalogAssetRef.isRenderable 同一语义：renderedPath 非空 且 missingReason 为空。

    Swift 定义 `renderedPath != nil && missingReason == nil`（GameCatalog.swift:47-49），
    因此空字符串 "" 也视为非空（≠ nil）；格式/文件存在性由 check_rendered_path_contract 另行校验。
    """
    return rendered_path is not None and missing_reason is None


def check_rendered_path_contract(
    rendered_path: str | None,
    missing_reason: str | None,
    file_exists: bool,
    registered: bool | None,
) -> list[str]:
    """返回违反的契约错误列表（空=通过）。

    规则顺序（与 validate.py 一致）：
    R-B 互斥（renderedPath 非空且 missingReason 非空）→ R-D 格式（icons/ 前缀 + .png 后缀）→
    R-A 文件存在 → R-C manifest 登记（registered None 时跳过 R-C）。
    rendered_path 为空（None 或 ""）→ 返回 []。

    R-B 是独立轴（最优先、不被 R-D 短路）；R-D 失败后短路剩余轴；R-A/R-C 互斥
    （文件不存在时不报 R-C，与 validate.py 的 if/elif 一致）。

    rendered_path 非 str 时行为未定义（AttributeError 上抛；validate.py 顶层
    wrapper 捕获后转 "catalog 内容非法"，勿在此处擅自拦截）。
    """
    if rendered_path is None or rendered_path == "":
        return []
    errors: list[str] = []
    if missing_reason:
        errors.append(
            f"renderedPath 与 missingReason 同时存在（成功字段与失败原因互斥）: {rendered_path} "
            f"missingReason={missing_reason!r}")
    if not (rendered_path.startswith("icons/") and rendered_path.endswith(".png")):
        errors.append(f"renderedPath 格式非法: {rendered_path!r}（须相对版本目录 icons/ 且 .png 结尾）")
        return errors
    if not file_exists:
        errors.append(f"renderedPath 指向不存在的文件: {rendered_path}")
    elif registered is not None and not registered:
        errors.append(f"renderedPath 文件未在 manifest generatedFiles 登记: {rendered_path}")
    return errors
