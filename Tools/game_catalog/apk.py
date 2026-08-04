"""APK/CSV IO 层：唯一触碰 zipfile/lzma 的模块。"""

import csv
import io
import lzma
import zipfile

from .errors import CatalogError

# 现有 generate_account_name_catalog.py 的解包技巧（独立实现，不 import 旧脚本）
# Supercell 存储格式头 = 5B LZMA props + 4B usz（小端）+ 数据，共 9 字节；
# 标准 LZMA_ALONE 头 = 5B props + 8B usz。解包 = 在 usz 后补 4 个 0 字节。
# 注意不能用 packed[:8] + b"\0"*4 + packed[8:]：usz ≥ 2^24（16MB）时
# usz 第 4 字节会被错位进数据流（LZMAError）。
_SUPERCELL_HEADER = 9
_MAX_ASSET_BYTES = 256 * 1024 * 1024  # 解压输出上限，防 zip bomb
# 头里 usz 的预检上限（独立常量：正常 usz == 实际解压大小，预检即等于输出上限；
# 拆开便于测试分别覆盖预检与解压后兜底两条路径）
_MAX_HEADER_USZ = _MAX_ASSET_BYTES


def decode_asset(archive: zipfile.ZipFile, path: str) -> str:
    try:
        packed = archive.read(path)
    except KeyError as exc:
        raise CatalogError(f"APK 缺少资源: {path}") from exc
    # 先按头里的 usz 预检：超限直接拒绝，不解压（真 zip bomb 会先吃满内存）
    if len(packed) >= _SUPERCELL_HEADER:
        usz = int.from_bytes(packed[5:9], "little")
        if usz > _MAX_HEADER_USZ:
            raise CatalogError(f"资源过大（疑似 zip bomb）: {path}")
    try:
        decoded = lzma.decompress(
            packed[:_SUPERCELL_HEADER] + b"\0" * 4 + packed[_SUPERCELL_HEADER:])
    except (lzma.LZMAError, EOFError) as exc:
        raise CatalogError(f"资源解压失败（损坏或格式不符）: {path}") from exc
    if len(decoded) > _MAX_ASSET_BYTES:
        raise CatalogError(f"资源过大（疑似 zip bomb）: {path}")
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
