"""Tier-1 硬错误：生成/校验过程中任何不可恢复的问题。"""


class CatalogError(Exception):
    """生成或校验目录时的硬错误（fail loud，绝不静默降级）。"""
