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
class CatalogLevel:
    level: int
    durationSeconds: int | None
    missingReason: str | None
    upgradeResource: str | None
    upgradeCost: int | None
    requiredTownHallLevel: int | None
    requiredLaboratoryLevel: int | None
    icon: AssetRef | None
    levelVisual: AssetRef | None

    def to_dict(self) -> dict:
        return {
            "level": self.level,
            "durationSeconds": self.durationSeconds,
            "missingReason": self.missingReason,
            "upgradeResource": self.upgradeResource,
            "upgradeCost": self.upgradeCost,
            "requiredTownHallLevel": self.requiredTownHallLevel,
            "requiredLaboratoryLevel": self.requiredLaboratoryLevel,
            "icon": self.icon.to_dict() if self.icon else None,
            "levelVisual": self.levelVisual.to_dict() if self.levelVisual else None,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "CatalogLevel":
        if not isinstance(d, dict):
            raise ValueError(f"CatalogLevel 需要 dict，实际 {type(d).__name__}: {d!r}")
        return cls(
            level=d["level"], durationSeconds=d.get("durationSeconds"),
            missingReason=d.get("missingReason"),
            upgradeResource=d.get("upgradeResource"), upgradeCost=d.get("upgradeCost"),
            requiredTownHallLevel=d.get("requiredTownHallLevel"),
            requiredLaboratoryLevel=d.get("requiredLaboratoryLevel"),
            icon=AssetRef.from_dict(d["icon"]) if d.get("icon") else None,
            levelVisual=AssetRef.from_dict(d["levelVisual"]) if d.get("levelVisual") else None,
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
