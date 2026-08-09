"""数据模型 + canonical JSON 序列化。所有键恒存在（null 也写）。"""

from __future__ import annotations

from dataclasses import dataclass


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
        if not isinstance(d, dict):
            raise ValueError(f"AssetRef 需要 dict，实际 {type(d).__name__}: {d!r}")
        return cls(d.get("container"), d.get("exportName"),
                   d.get("renderedPath"), d.get("missingReason"))


@dataclass
class UpgradeCost:
    """单项升级费用（Issue #73：多资源升级费用）。

    - resource: 资源标识 = raw 原值（不做资源枚举映射，保留原始值）
    - amount: 金额；解析失败 = None（0 是真实值）
    - rawResource: 源 CSV 原始资源值，恒保留
    - rawAmount: 源 CSV 原始金额串；正常解析时 None
    - parseFailed: 该项是否解析失败（金额非数字 或 配对缺失）
    """
    resource: str
    amount: int | None
    rawResource: str
    rawAmount: str | None
    parseFailed: bool

    def to_dict(self) -> dict:
        return {
            "resource": self.resource,
            "amount": self.amount,
            "rawResource": self.rawResource,
            "rawAmount": self.rawAmount,
            "parseFailed": self.parseFailed,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "UpgradeCost":
        if not isinstance(d, dict):
            raise ValueError(f"UpgradeCost 需要 dict，实际 {type(d).__name__}: {d!r}")
        return cls(
            resource=d["resource"], amount=d.get("amount"),
            rawResource=d["rawResource"], rawAmount=d.get("rawAmount"),
            parseFailed=d.get("parseFailed", False),
        )


@dataclass
class CatalogLevel:
    level: int
    durationSeconds: int | None
    missingReason: str | None
    upgradeCosts: list[UpgradeCost] | None
    requiredTownHallLevel: int | None
    requiredLaboratoryLevel: int | None
    icon: AssetRef | None
    levelVisual: AssetRef | None
    requiredHeroTavernLevel: int | None = None  # Issue #67：英雄殿堂门槛（17 本引入），全 optional

    def to_dict(self) -> dict:
        return {
            "level": self.level,
            "durationSeconds": self.durationSeconds,
            "missingReason": self.missingReason,
            # 契约「非 None 必须非空（[] 非法）」：空列表归一为 None（与
            # from_dict 的 None 语义对称，空列表不进入 JSON）
            "upgradeCosts": [c.to_dict() for c in self.upgradeCosts] if self.upgradeCosts else None,
            "requiredTownHallLevel": self.requiredTownHallLevel,
            "requiredLaboratoryLevel": self.requiredLaboratoryLevel,
            "icon": self.icon.to_dict() if self.icon else None,
            "levelVisual": self.levelVisual.to_dict() if self.levelVisual else None,
            "requiredHeroTavernLevel": self.requiredHeroTavernLevel,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "CatalogLevel":
        if not isinstance(d, dict):
            raise ValueError(f"CatalogLevel 需要 dict，实际 {type(d).__name__}: {d!r}")
        raw = d.get("upgradeCosts")
        # 旧格式 JSON（无 upgradeCosts 键，upgradeResource/upgradeCost）→ None（兼容）；
        # 手写 JSON 含 []（契约非法值）保持原样，由 validate 拦截（"[] 非法"）
        return cls(
            level=d["level"], durationSeconds=d.get("durationSeconds"),
            missingReason=d.get("missingReason"),
            upgradeCosts=None if raw is None else [UpgradeCost.from_dict(x) for x in raw],
            requiredTownHallLevel=d.get("requiredTownHallLevel"),
            requiredLaboratoryLevel=d.get("requiredLaboratoryLevel"),
            icon=AssetRef.from_dict(d["icon"]) if d.get("icon") else None,
            levelVisual=AssetRef.from_dict(d["levelVisual"]) if d.get("levelVisual") else None,
            requiredHeroTavernLevel=d.get("requiredHeroTavernLevel"),
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
    # Issue #75 工作流 C：建筑展示分类（defense/military/craftTable），
    # home buildings 之外恒 None。旧格式 JSON 缺键 → None（向后兼容）。
    displayCategory: str | None = None

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
            "displayCategory": self.displayCategory,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "CatalogItem":
        if not isinstance(d, dict):
            raise ValueError(f"CatalogItem 需要 dict，实际 {type(d).__name__}: {d!r}")
        return cls(
            section=d["section"], dataID=d["dataID"], category=d["category"],
            base=d.get("base"), baseMissingReason=d.get("baseMissingReason"),
            name=d["name"], maxLevel=d["maxLevel"],
            icon=AssetRef.from_dict(d["icon"]) if d.get("icon") else None,
            levelVisual=AssetRef.from_dict(d["levelVisual"]) if d.get("levelVisual") else None,
            missingReason=d.get("missingReason"),
            levels=[CatalogLevel.from_dict(x) for x in d["levels"]],
            displayCategory=d.get("displayCategory"),
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
    if not isinstance(d, dict):
        raise ValueError(f"catalog 根节点需要 dict，实际 {type(d).__name__}")
    if not isinstance(d.get("items"), list):
        raise ValueError("catalog.items 需要 list")
    return Catalog(
        schemaVersion=d["schemaVersion"],
        gameVersion=d["gameVersion"],
        locale=d["locale"],
        items=[CatalogItem.from_dict(x) for x in d["items"]],
    )
