"""APK/CSV IO 层：唯一触碰 zipfile/lzma 的模块。"""

import csv
import io
import lzma
import zipfile

from .errors import CatalogError

# 现有 generate_account_name_catalog.py 的解包技巧（独立实现，不 import 旧脚本）
def decode_asset(archive: zipfile.ZipFile, path: str) -> str:
    packed = archive.read(path)
    decoded = lzma.decompress(packed[:8] + b"\0" * 4 + packed[8:])
    return decoded.decode("utf-8-sig")


def rows(archive: zipfile.ZipFile, table: str) -> list[dict[str, str]]:
    return rows_from_text(decode_asset(archive, "assets/logic/" + table))


def rows_from_text(text: str) -> list[dict[str, str]]:
    reader = csv.DictReader(io.StringIO(text))
    return [{k: (v or "").strip() for k, v in row.items() if k} for row in reader]


def read_build_tag(archive: zipfile.ZipFile) -> str:
    try:
        return archive.read("assets/build.tag").decode("utf-8").strip()
    except KeyError as exc:
        raise CatalogError("APK 缺少 assets/build.tag") from exc


def clean_localized(value: str) -> str:
    return value.replace("\\q", "").replace("\\n", " ").strip()


def localization(archive: zipfile.ZipFile) -> dict[str, str]:
    values: dict[str, str] = {}
    for row in rows_from_text(decode_asset(archive, "assets/localization/cn.csv")):
        if row.get("TID"):
            values[row["TID"]] = clean_localized(row.get("CN", ""))
    for row in rows_from_text(decode_asset(archive, "assets/localization/texts_patch.csv")):
        if row.get("TID") and row.get("CN"):
            values[row["TID"]] = clean_localized(row["CN"])
    return values
