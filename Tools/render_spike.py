#!/usr/bin/env python3
"""COC SC2 渲染 spike：追踪 export→纹理引用链并输出 verdict（Issue #27）。

用法:
  python3 Tools/render_spike.py --apk base.apk.1 --output /tmp/coc-spike-out [--limit N]

对固定 4 类样本（单位 icon / 建筑等级外观 / 跨等级复用 / 失败引用）执行
export → object_id → Shape 命令 → TextureData 引用链追踪，输出
`spike-report.json`（每样本 verdict：success / blocked / missing）+ 终端摘要。

**依赖例外**：SC2 body 解压需要 ctypes/libzstd（sc2.load_libzstd），与纯
stdlib 生成管线分离（见 rendered-path 契约文档）。PNG 编码用 stdlib zlib，
纹理字节序/像素格式映射见 _PIXEL_FORMATS（0/6/10 来自 sc-workshop
SupercellFlash SWFTexture.h PixelFormat 枚举；1=BGRA8 为社区 SC2 解析器
惯例映射——参考枚举未声明，本 APK 原始路径未触发，未对拍验证）。

退出码: 0=报告已写出（verdict 是数据不是错误） 1=Tier-1 错误 2=用法错误
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import zipfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.errors import CatalogError
from game_catalog.fbs import FlatBuffer
from game_catalog.sc2 import ScFile, load_sc

# ---------------------------------------------------------------------------
# 固定样本（来源：Sources/COCHelperCore/GameCatalog/18.400.13/catalog.json
# 与真实 APK assets/sc/ 对拍）
# ---------------------------------------------------------------------------

SAMPLES: list[dict] = [
    {
        "container": "sc/ui.sc",
        "exportName": "icon_unit_barbarian",
        "note": "单位 icon：真实 ui.sc 导出名（对拍 exports=3024，oid=8397）",
    },
    {
        "container": "sc/buildings.sc",
        "exportName": "fireplace_lvl1",
        "note": "建筑等级外观：catalog 兵营(dataID 1000000) item+level1 的 "
               "levelVisual.exportName",
    },
    {
        "container": "sc/buildings.sc",
        "exportName": "blacksmith_lvl1",
        "note": "跨等级复用：catalog 铁匠铺(dataID 1000070) level1-2 共用 "
               "levelVisual.exportName",
    },
    {
        "container": "sc/ui.sc",
        "exportName": "icon_unit_does_not_exist",
        "note": "失败引用：catalog/APK 中均不存在的导出名",
    },
    {
        "container": "sc/traps.sc",
        "exportName": "town_hall_lvl1",
        "note": "container 不存在：APK 无 assets/sc/traps.sc（543 个 sc 文件"
               "中无 traps）；town_hall_lvl1 是 catalog town hall(1000001) "
               "levelVisual 真实导出名",
    },
]

# pixel_type → (格式名, 每像素字节数, PNG 颜色类型)
# 0/6/10 来自 sc-workshop SWFTexture.h PixelFormat 枚举（RGBA8=0,
# LUMINANCE8_ALPHA8=6, LUMINANCE8=10）；1=BGRA8 为社区惯例（未对拍验证）。
_PIXEL_FORMATS: dict[int, tuple[str, int, int]] = {
    0: ("rgba8", 4, 6),
    1: ("bgra8", 4, 6),
    6: ("luminance8_alpha8", 2, 4),
    10: ("luminance8", 1, 0),
}


# ---------------------------------------------------------------------------
# PNG 编码（stdlib zlib，8-bit）
# ---------------------------------------------------------------------------


def _sanitize_filename(name: str) -> str:
    """导出名 → 安全文件名：替换路径分隔符，防 `../` 写出输出目录。"""
    return name.replace("/", "_").replace("\\", "_")


def encode_png(width: int, height: int, pixels: bytes, color_type: int) -> bytes:
    """RGBA/灰度像素 → PNG 文件字节（filter None，每行 1 字节 filter 前缀）。

    color_type: 6=RGBA8(4B/px)、4=灰度+alpha(2B/px)、0=灰度(1B/px)。
    宽/高必须 > 0（PNG 规范 IHDR 约束）；数据长度与 w*h*每像素字节数
    不符 → ValueError。
    """
    if width <= 0 or height <= 0:
        raise ValueError(f"PNG 尺寸必须 > 0: {width}x{height}")
    bpp = {6: 4, 4: 2, 0: 1}[color_type]
    expected = width * height * bpp
    if len(pixels) != expected:
        raise ValueError(
            f"PNG 像素长度不符: {len(pixels)}（期望 {expected} = "
            f"{width}x{height}x{bpp}B/px）")
    raw = bytearray()
    stride = width * bpp
    for y in range(height):
        raw.append(0)  # filter: None
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(ctype: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + ctype + data
                + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


# ---------------------------------------------------------------------------
# 证据链辅助
# ---------------------------------------------------------------------------


def _movieclip_index(sc: ScFile, object_id: int) -> int | None:
    """object_id 是否为 MovieClip id？返回 vector 索引（证据链用）。

    MovieClips chunk 仅扫描 id 字段（slot 0 ushort），不解析帧结构——
    MovieClips 完整解析是后续 task。
    """
    payload = sc.chunks.get("MovieClips", b"")
    if not payload:
        return None
    try:
        fb = FlatBuffer(payload)
        vec = fb.table_field(fb.root(), 0)
        if vec == 0:
            return None
        for i in range(fb.vector_len(vec)):
            tbl = fb.table(fb.vector_elem(vec, i, 4))
            off = fb.table_field(tbl, 0)
            if not off:
                continue
            # vtable 伪造防御：table_size/偏移越界时 table_field 返回
            # 越界偏移，短切片会抛裸 struct.error（非 ValueError）——跳过
            if off < 0 or off + 2 > len(payload):
                continue
            if struct.unpack("<H", payload[off:off + 2])[0] == object_id:
                return i
    except ValueError:
        return None  # 证据链尽力而为；解析失败不阻断主裁决
    return None


def _ktx_summary(data: bytes) -> dict | None:
    """内嵌纹理是否为 KTX 容器？返回头部摘要（证据链用）。"""
    if len(data) < 64 or data[:12] != b"\xabKTX 11\xbb\r\n\x1a\n":
        return None
    (endian, _gt, _gts, _gf, gif, _gbif, pw, ph, _pd, _ae, fc, ml, _kvb) = \
        struct.unpack("<13I", data[12:64])
    return {"endian": endian, "glInternalFormat": gif,
            "pixelWidth": pw, "pixelHeight": ph, "faces": fc, "mipLevels": ml}


# ---------------------------------------------------------------------------
# verdict 裁决
# ---------------------------------------------------------------------------


def _blocked(reason: str, details: dict) -> dict:
    return {"reason": reason, "details": details}


def _missing(reason: str) -> dict:
    return {"reason": reason, "details": {}}


def _evidence_from_texture(td) -> dict:
    return {
        "textureFormat": td.texture_format,
        "pixelType": td.pixel_type,
        "width": td.width,
        "height": td.height,
        "dataLength": len(td.data) if td.data is not None else None,
        "externalTexture": td.external_texture,
    }


def resolve_sample(sample: dict, sc: ScFile, output_dir: Path,
                   budget: dict[str, int], limit: int | None) -> dict:
    """对已加载 ScFile 的样本裁决（container 存在性由 render_spike 保证）。

    export → object_id → Shape 命令 → TextureData 引用链；PNG 写入
    output_dir。budget 为每容器 texture 解析预算（--limit），超限阻塞。
    """
    container = sample["container"]
    export = sample["exportName"]
    asset_key = {"container": container, "exportName": export}
    oid = sc.export_names.get(export)
    if oid is None:
        return {"asset_key": asset_key, "status": "missing",
                "evidence": {"objectId": None, "exportFound": False},
                "blocker": _missing("export_not_found"), "png": None}

    evidence = {"objectId": oid, "exportFound": True}
    tex_indexes = sc.shape_textures(oid)
    if tex_indexes is None:
        # export 存在但 oid 不是 Shape id——记录 MovieClip 证据链
        mc_idx = _movieclip_index(sc, oid)
        evidence.update({"shapeFound": False, "commandCount": None,
                         "textureIndexes": [],
                         "movieClipFound": mc_idx is not None,
                         "movieClipIndex": mc_idx})
        return {"asset_key": asset_key, "status": "blocked",
                "evidence": evidence,
                "blocker": _blocked(
                    "no_shape_command",
                    {"detail": "export 的 object_id 不在 Shapes chunk（"
                               "真实数据中 export 全部指向 MovieClip，"
                               "需 MovieClip→frame→shape 解析链路）"}),
                "png": None}
    evidence.update({"shapeFound": True, "commandCount": len(tex_indexes),
                     "textureIndexes": tex_indexes})
    if not tex_indexes:
        return {"asset_key": asset_key, "status": "blocked",
                "evidence": evidence,
                "blocker": _blocked("no_shape_command",
                                    {"detail": "Shape 存在但无 draw 命令"}),
                "png": None}

    # 预算检查：每容器最多解析 limit 个 texture
    used = budget.get(container, 0)
    if limit is not None and used >= limit:
        return {"asset_key": asset_key, "status": "blocked",
                "evidence": evidence,
                "blocker": _blocked("texture_limit_exceeded",
                                    {"limit": limit, "container": container}),
                "png": None}
    budget[container] = used + 1

    # 纹理解析（含惰性 data 访问）整体包 try：畸形数据 → 单样本
    # blocked(catalog_error)，不中止整份报告
    try:
        td = sc.texture_data(tex_indexes[0])
        evidence["texture"] = _evidence_from_texture(td)

        if td.external_texture:
            return {"asset_key": asset_key, "status": "blocked",
                    "evidence": evidence,
                    "blocker": _blocked(
                        "needs_sctx_decode",
                        {"path": td.external_texture,
                         "detail": "纹理存于外部 .sctx（SupercellTexture 压缩，"
                                   "参考 C++ SupercellCompressionFormat="
                                   "ASTC_RGBA8_4x4）"}),
                    "png": None}
        if td.texture_format != 0:
            # 对拍：ui.sc fmt=8（内嵌 KTX）、buildings.sc fmt=4（.sctx）；
            # 参考 C++ 仅 NONE=0 走原始缓冲，其余为压缩格式
            return {"asset_key": asset_key, "status": "blocked",
                    "evidence": evidence,
                    "blocker": _blocked(
                        "compressed_texture",
                        {"format": td.texture_format,
                         "ktx": _ktx_summary(td.data) if td.data else None,
                         "detail": "texture_format != 0(NONE)：非原始像素"
                                   "（内嵌 KTX/ASTC 或压缩纹理），需压缩解码"}),
                    "png": None}
        pf = _PIXEL_FORMATS.get(td.pixel_type)
        if pf is None:
            return {"asset_key": asset_key, "status": "blocked",
                    "evidence": evidence,
                    "blocker": _blocked("unsupported_pixel_type",
                                        {"pixelType": td.pixel_type}),
                    "png": None}
        name, bpp, color_type = pf
        if td.width <= 0 or td.height <= 0:
            # 0×0 违反 PNG 规范（IHDR 宽高必须 > 0），不能写假成功
            return {"asset_key": asset_key, "status": "blocked",
                    "evidence": evidence,
                    "blocker": _blocked(
                        "invalid_dimensions",
                        {"width": td.width, "height": td.height}),
                    "png": None}
        data = td.data
        if data is None:
            return {"asset_key": asset_key, "status": "blocked",
                    "evidence": evidence,
                    "blocker": _blocked("no_texture_data",
                                        {"detail": "texture_format=0 但无内嵌数据"}),
                    "png": None}
        expected = td.width * td.height * bpp
        if len(data) != expected:
            return {"asset_key": asset_key, "status": "blocked",
                    "evidence": evidence,
                    "blocker": _blocked(
                        "data_length_mismatch",
                        {"expected": expected, "actual": len(data),
                         "pixelFormat": name}),
                    "png": None}
        if name == "bgra8":  # BGRA → RGBA 字节序转换
            pixels = bytearray(data)
            for i in range(0, len(pixels), 4):
                pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i]
            pixels = bytes(pixels)
        else:
            pixels = data

        png_name = f"{_sanitize_filename(export)}.png"
        png_path = output_dir / png_name
        png_bytes = encode_png(td.width, td.height, pixels, color_type)
        png_path.write_bytes(png_bytes)
        return {"asset_key": asset_key, "status": "success",
                "evidence": evidence, "blocker": None,
                "png": {"path": png_name, "size": len(png_bytes),
                        "sha256": hashlib.sha256(png_bytes).hexdigest()}}
    except CatalogError as e:
        # 惰性 data 访问（loader）畸形数据 → 单样本 blocked，不中止报告
        return {"asset_key": asset_key, "status": "blocked",
                "evidence": evidence,
                "blocker": _blocked("catalog_error", {"message": str(e)}),
                "png": None}


def render_spike(apk: Path, output_dir: Path, limit: int | None) -> dict:
    """读 APK → 逐样本追踪 → 写 PNG + 报告 dict（不写盘）。"""
    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        z = zipfile.ZipFile(apk)
    except zipfile.BadZipFile as e:
        raise CatalogError(f"APK 不是有效 zip: {apk}（{e}）") from e
    budget: dict[str, int] = {}
    verdicts = []
    with z:
        for sample in SAMPLES:
            entry = "assets/" + sample["container"]
            try:
                data = z.read(entry)
            except KeyError:
                verdicts.append({
                    "asset_key": {"container": sample["container"],
                                  "exportName": sample["exportName"]},
                    "status": "missing",
                    "evidence": {"containerFound": False},
                    "blocker": _missing("container_not_found"),
                    "png": None,
                })
                continue
            try:
                sc = load_sc(data)
            except CatalogError as e:
                verdicts.append({
                    "asset_key": {"container": sample["container"],
                                  "exportName": sample["exportName"]},
                    "status": "blocked",
                    "evidence": {"containerFound": True},
                    "blocker": _blocked("catalog_error", {"message": str(e)}),
                    "png": None,
                })
                continue
            verdicts.append(
                resolve_sample(sample, sc, output_dir, budget, limit))
    return {"meta": {"apk": str(apk),
                     "apkSizeBytes": apk.stat().st_size,
                     "textureLimit": limit,
                     "samplesCount": len(verdicts)},
            "samples": verdicts}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="COC SC2 渲染 spike：追踪 export→纹理引用链并输出 verdict")
    parser.add_argument("--apk", type=Path, required=True,
                        help="COC APK 路径（读 assets/sc/*.sc）")
    parser.add_argument("--output", type=Path, required=True,
                        help="输出目录（写 spike-report.json 与 PNG）")
    parser.add_argument("--limit", type=int, default=None,
                        help="每个容器最多解析几个样本的 texture"
                             "（默认不限；避免大 Textures chunk 过度解引用）")
    args = parser.parse_args(argv)

    if not args.apk.is_file():
        print(f"error: APK 不存在: {args.apk}", file=sys.stderr)
        return 2
    try:
        report = render_spike(args.apk, args.output, args.limit)
    except (CatalogError, OSError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    report_path = args.output / "spike-report.json"
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")

    statuses: dict[str, int] = {}
    for v in report["samples"]:
        status = v["status"]
        statuses[status] = statuses.get(status, 0) + 1
        key = v["asset_key"]
        if status == "success":
            p = v["png"]
            print(f"[success] {key['container']} / {key['exportName']} → "
                  f"PNG {p['path']} ({p['size']}B, sha256 {p['sha256'][:12]}…)")
        elif status == "missing":
            print(f"[missing] {key['container']} / {key['exportName']} — "
                  f"{v['blocker']['reason']}")
        else:
            b = v["blocker"]
            detail = b["details"].get("detail") or b["details"].get("path") \
                or b["details"].get("format") or ""
            print(f"[blocked] {key['container']} / {key['exportName']} — "
                  f"{b['reason']} {detail}".rstrip())
    print(f"--- verdict 汇总: {statuses}")
    print(f"写盘: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
