#!/usr/bin/env python3
"""COC 渲染生成器：固定样本 → 真实 PNG + catalog.json renderedPath 回写（Issue #30 Task 7）。

用法:
  python3 Tools/render_generator.py --apk base.apk.1 \
      --catalog Sources/COCHelperCore/GameCatalog/18.400.13
  python3 Tools/render_generator.py --apk base.apk.1 --catalog <dir> \
      --samples-only --report /tmp/render-gen-report.json

流程（对每个样本 key）：
1. zip 打开 APK；container 解析（`assets/` + container，container 即
   `sc/ui.sc` 这类）
2. load_sc(data) → export_names[name] → object_id → movieclip
3. movieclip frames[0]（多帧只取帧 0 并在报告记录）→ frame 0 元素
   （= frame_elements 前 frames[0].used_transform 个）
4. 元素 instance_index → children_ids[i] → 全局 id：shape 元素收集渲染；
   **嵌套 movieclip / textfield 元素记录跳过，不阻断**（实证 fireplace/
   blacksmith 帧 0 含嵌套 mc——阴影/动画层，先不支持）
5. shape → 每条命令：texture_data(texture_index) → 内嵌 KTX（parse_ktx）
   或外部 `.sctx`（zip 读 `assets/sc/<name>`，**同文件只解析一次**缓存）；
   vertices → element_matrix(element) 变换
6. 多命令合成：composite_shapes 画到同一画布（blacksmith 5 命令；不同命令
   可不同纹理，必须逐命令画）
7. 输出 PNG（R2.1 命名 `icons/<container_key>/<export_key>.png`）→ catalog 目录
   icons/；更新 catalog.json 匹配引用（成功 → renderedPath + missingReason
   null；失败 → renderedPath null + 稳定枚举），原子替换
8. 失败样本不产生 PNG 文件、不写伪造路径（R5）
9. 报告 JSON（样本/verdict/path/size/sha256/耗时）→ --report（默认
   /tmp/render-generator-report.json）

**契约对齐**（docs/rendered-path-contract.md）：R2.1 命名、R2.2 sanitize
（fail loud）、R2.3 键冲突 fail loud、R2.4 同 (container, exportName) 只渲染
一次、R4 确定性（render.encode_png 固定 zlib=9 + filter None）、R5 失败语义。

**missingReason 枚举**（新值已登记 ASSET_MISSING_REASONS）：
  container_not_found / export_not_found / movieclip_not_parsed /
  sc_parse_failed / zstd_unavailable / texture_missing / astc_unsupported /
  render_failed

**依赖例外**：SC2 body 解压需要 ctypes + libzstd（sc2.load_libzstd，
brew/系统库，非 pip 包）；其余纯 stdlib。

退出码: 0=成功 1=Tier-1 错误（catalog 读写失败/APK 损坏等） 2=用法错误
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from game_catalog.astc import AstcError
from game_catalog.errors import CatalogError
from game_catalog.ktx import KtxImage, SctxImage, parse_ktx, parse_sctx
from game_catalog.render import (
    composite_shapes,
    encode_png,
    render_shape_from_image,
    transform_vertices,
)
from game_catalog.sc2 import Matrix2x3, ScFile, Shape, load_sc

# ---------------------------------------------------------------------------
# 固定样本表（4 成功 + 2 失败；来源：catalog.json 与真实 APK 对拍）
# ---------------------------------------------------------------------------

SAMPLES: list[dict] = [
    {
        "container": "sc/ui.sc",
        "exportName": "icon_unit_barbarian",
        "note": "单位 icon：帧 0 含 textfield（跳过）+ shape 8025 单命令",
    },
    {
        "container": "sc/ui.sc",
        "exportName": "icon_spell_rage",
        "note": "法术 icon：帧 0 单元素 shape 21490 单命令",
    },
    {
        "container": "sc/buildings.sc",
        "exportName": "fireplace_lvl1",
        "note": "建筑等级外观：shape 1549 单命令 + 嵌套 mc 1607（360 帧动画，跳过）",
    },
    {
        "container": "sc/buildings.sc",
        "exportName": "blacksmith_lvl1",
        "note": "跨等级复用（catalog 铁匠铺 level1-2 共用）：shape 1643 五命令合成 + 嵌套 mc 1645（阴影，跳过）",
    },
    {
        "container": "sc/ui.sc",
        "exportName": "icon_unit_does_not_exist",
        "note": "失败引用：APK/catalog 均无此导出名",
    },
    {
        "container": "sc/traps.sc",
        "exportName": "town_hall_lvl1",
        "note": "container 不存在：APK assets/sc/ 无 traps.sc",
    },
]

_MAX_ENTRY_BYTES = 256 * 1024 * 1024  # 单 zip 条目解压上限（防 deflate 炸弹，对齐 apk.py）
_MAX_FILENAME_BYTES = 200  # 契约 R2.2：export_key 文件名长度上限

# ---------------------------------------------------------------------------
# 纯函数：R2.1 / R2.2 / R2.3（契约 docs/rendered-path-contract.md）
# ---------------------------------------------------------------------------


def container_key(container: str) -> str:
    """R2.1：container → 子目录名（去掉 `sc/` 前缀与 `.sc` 后缀）。

    结果含路径分隔符 / 空串 / `.` / `..` → CatalogError（fail loud，防目录
    逃逸；真实数据 container 恒为 `sc/<name>.sc`）。
    """
    key = container
    if key.startswith("sc/"):
        key = key[3:]
    if key.endswith(".sc"):
        key = key[:-3]
    if not key or "/" in key or "\\" in key or key in (".", ".."):
        raise CatalogError(f"container 无法派生安全目录名: {container!r}")
    return key


def sanitize_export_key(export: str) -> str:
    r"""R2.2：`/`、`\` 替换为 `_`；空串 / `.` / `..` fail loud；≤200 字节（UTF-8）。"""
    if not isinstance(export, str):
        raise CatalogError(f"导出名非字符串: {export!r}")
    key = export.replace("/", "_").replace("\\", "_")
    if "%" in key:
        # 与 validate.py rendered_path_format_ok 一致：拒绝 URL 编码段
        # （%2e%2e / %2F 等；真实导出名无 %）。pathlib 不解码，但未来若
        # 出现 URL 解码消费者会引入真实逃逸，段内 % 对合法文件名也无意义。
        raise CatalogError(f"导出名含 URL 编码段（%），拒绝: {export!r}")
    if not key or key in (".", ".."):
        raise CatalogError(f"导出名 sanitize 后非法: {export!r}")
    if len(key.encode("utf-8")) > _MAX_FILENAME_BYTES:
        raise CatalogError(
            f"导出名 sanitize 后超过 {_MAX_FILENAME_BYTES} 字节: {export!r}")
    return key


def sample_png_relpath(container: str, export: str) -> str:
    """R2.1 命名：`icons/<container_key>/<export_key>.png`。"""
    return f"icons/{container_key(container)}/{sanitize_export_key(export)}.png"


# ---------------------------------------------------------------------------
# 单样本渲染
# ---------------------------------------------------------------------------


class SampleError(Exception):
    """单样本渲染失败（携带稳定 missingReason 枚举，R5）。"""

    def __init__(self, reason: str, detail: str = ""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason
        self.detail = detail


def _failed_verdict(container: str, export: str, reason: str, details: dict,
                    t0: float) -> dict:
    """失败 verdict：不写 relPath/png（R5：不写伪造路径）。"""
    return {
        "assetKey": {"container": container, "exportName": export},
        "status": "failed", "missingReason": reason, "relPath": None,
        "png": None, "pngBytes": None,
        "durationMs": int((time.perf_counter() - t0) * 1000),
        "details": details,
    }


def _resolve_texture(archive: zipfile.ZipFile, sc: ScFile, tex_index: int,
                     sctx_cache: dict[str, SctxImage]) -> KtxImage | SctxImage:
    """TextureData → 可解码图像对象（内嵌 KTX / 外部 .sctx 缓存）。

    失败 → SampleError：texture_missing（无数据/外部文件缺失）或
    astc_unsupported（容器/格式无法解析）。
    """
    td = sc.texture_data(tex_index)  # 索引越界 CatalogError → 由调用方包装
    if td.external_texture:
        path = "assets/sc/" + td.external_texture
        if path not in sctx_cache:
            try:
                info = archive.getinfo(path)
            except KeyError:
                raise SampleError("texture_missing",
                                  f"外部纹理不存在: {path}") from None
            if info.file_size > _MAX_ENTRY_BYTES:
                # 与 _render_sample 的 container 条目同款防炸弹防护
                # （读取前先查 zip 条目大小，不读超大条目）
                raise SampleError(
                    "texture_missing",
                    f"外部纹理超过 {_MAX_ENTRY_BYTES} 防炸弹上限: {path}"
                    f"（{info.file_size} 字节）")
            raw = archive.read(path)
            try:
                sctx_cache[path] = parse_sctx(raw)
            except CatalogError as e:
                raise SampleError("astc_unsupported",
                                  f".sctx 解析失败（{path}）: {e}") from e
        return sctx_cache[path]
    data = td.data
    if not data:
        raise SampleError("texture_missing", "纹理无内嵌数据")
    try:
        return parse_ktx(data)
    except CatalogError as e:
        raise SampleError("astc_unsupported", f"KTX 解析失败: {e}") from e


def _collect_renders(archive: zipfile.ZipFile, sc: ScFile, export: str,
                     sctx_cache: dict[str, SctxImage],
                     details: dict) -> list[tuple[KtxImage | SctxImage, list]]:
    """export → 帧 0 全部可渲染命令（(image, 变换后顶点) 列表）+ details。

    - export 直接指向 Shape（无 movieclip 层）→ 直接渲染（防御路径；
      真实数据 export 全指向 MovieClip）
    - export 指向 MovieClip → frames[0]；shape 元素收集，嵌套 movieclip /
      textfield 元素记录跳过（不阻断——实证 fireplace/blacksmith 帧 0 含
      嵌套 mc：阴影/动画层，Task 7 先不支持）
    - 无任何可渲染命令 → SampleError（movieclip_not_parsed / render_failed）
    """
    mc = sc.movieclip_for_export(export)
    shape_elements: list[tuple[Shape, Matrix2x3 | None]] = []
    if mc is None:
        oid = sc.export_names.get(export)
        shp = sc.shape(oid) if oid is not None else None
        if shp is None:
            raise SampleError(
                "movieclip_not_parsed",
                f"export 的 object_id {oid} 既非 Shape 也非 MovieClip")
        shape_elements = [(shp, None)]
    else:
        if len(mc.frames) != 1:
            details["frameCount"] = len(mc.frames)
            details["renderedFrame"] = 0  # 多帧只渲染帧 0（记录不阻塞）
        if not mc.frames:
            raise SampleError("render_failed", "MovieClip 无任何帧")
        f0 = mc.frames[0]
        elems = mc.frame_elements[:f0.used_transform]
        banks = sc.matrix_banks
        skipped: list[dict] = []
        for el in elems:
            if el.instance_index >= len(mc.children_ids):
                raise CatalogError(
                    f"帧元素 instance_index {el.instance_index} 越界"
                    f"（children 共 {len(mc.children_ids)} 个）")
            gid = mc.children_ids[el.instance_index]
            shp = sc.shape(gid)
            if shp is not None:
                shape_elements.append((shp, mc.element_matrix(el, banks)))
            elif sc.movieclips().get(gid) is not None:
                skipped.append({"kind": "nested_movieclip", "globalId": gid})
            else:
                skipped.append({"kind": "non_shape", "globalId": gid})
        if skipped:
            details["skippedElements"] = skipped

    if not shape_elements:
        raise SampleError("render_failed", "帧 0 无任何可渲染 shape 元素")

    renders: list[tuple[KtxImage | SctxImage, list]] = []
    for shp, matrix in shape_elements:
        for cmd in shp.commands:
            try:
                img = _resolve_texture(archive, sc, cmd.texture_index,
                                       sctx_cache)
            except CatalogError as e:
                # texture_data 索引越界（引用损坏）→ 纹理缺失语义
                raise SampleError(
                    "texture_missing",
                    f"texture_data({cmd.texture_index}): {e}") from e
            vs = cmd.vertices(sc.points)
            renders.append((img, transform_vertices(vs, matrix)))
    if not renders:
        raise SampleError("render_failed", "shape 无任何 draw 命令")
    return renders, details


def _render_sample(archive: zipfile.ZipFile, container: str, export: str,
                   sc_cache: dict[str, ScFile],
                   sctx_cache: dict[str, SctxImage]) -> dict:
    """单样本完整渲染链；一切异常 → failed verdict（不裸抛）。

    t0 记录在函数入口，durationMs 覆盖所有失败分支与成功分支。
    """
    t0 = time.perf_counter()
    details: dict = {}
    entry = "assets/" + container
    try:
        info = archive.getinfo(entry)
    except KeyError:
        return _failed_verdict(
            container, export, "container_not_found",
            {"zipEntry": entry}, t0)
    if info.file_size > _MAX_ENTRY_BYTES:
        return _failed_verdict(
            container, export, "render_failed",
            {"zipEntry": entry, "fileSize": info.file_size,
             "detail": f"zip 条目超过 {_MAX_ENTRY_BYTES} 防炸弹上限"},
            t0)
    try:
        if container not in sc_cache:
            try:
                sc_cache[container] = load_sc(archive.read(entry))
            except CatalogError as e:
                # SC2 容器解析失败 → sc_parse_failed（libzstd 不可用单独枚举）
                msg = str(e)
                reason = ("zstd_unavailable" if "libzstd" in msg
                          else "sc_parse_failed")
                return _failed_verdict(container, export, reason,
                                       {"message": msg}, t0)
        sc = sc_cache[container]

        if export not in sc.export_names:
            return _failed_verdict(
                container, export, "export_not_found",
                {"objectId": None}, t0)

        renders, details = _collect_renders(archive, sc, export,
                                            sctx_cache, details)

        if len(renders) == 1:
            img, vs = renders[0]
            w, h, rgba = render_shape_from_image(img, vs)
        else:
            # 多命令（不同纹理）：合成到同一画布（R3.1 不缩放语义保留：
            # 画布 = union bounds 的 1:1 像素）
            w, h, rgba = composite_shapes(renders)
        png_bytes = encode_png(w, h, rgba)
    except SampleError as e:
        return _failed_verdict(container, export, e.reason,
                               {"message": e.detail}, t0)
    except AstcError as e:
        # HDR / 不支持的 ASTC 模式（解码层错误）
        return _failed_verdict(container, export, "astc_unsupported",
                               {"message": str(e)}, t0)
    except CatalogError as e:
        return _failed_verdict(container, export, "render_failed",
                               {"message": str(e)}, t0)

    rel = sample_png_relpath(container, export)
    return {
        "assetKey": {"container": container, "exportName": export},
        "status": "success", "missingReason": None, "relPath": rel,
        "png": {"size": len(png_bytes),
                "sha256": hashlib.sha256(png_bytes).hexdigest()},
        "pngBytes": png_bytes,  # 瞬态：报告序列化时剔除
        "durationMs": int((time.perf_counter() - t0) * 1000),
        "details": details,
    }


# ---------------------------------------------------------------------------
# 编排：渲染全部样本（内存）→ 落盘 + catalog 回写 → 报告
# ---------------------------------------------------------------------------


def render_samples(apk_path: str | Path,
                   samples: list[dict] | None = None) -> tuple[dict, list[dict]]:
    """读 APK → 渲染固定样本 → (meta, verdicts)。

    - R2.3 键冲突（sanitize 后同路径）fail loud
    - R2.4 同 (container, exportName) 只渲染一次（重复样本复用 verdict）
    - 不写盘（PNG 字节在 verdict.pngBytes）；写盘与回写由
      write_rendered_outputs 负责
    """
    samples = SAMPLES if samples is None else samples
    # R2.3：不同原始键 sanitize 后同路径 → fail loud，不静默覆盖
    seen: dict[str, str] = {}
    for s in samples:
        rel = sample_png_relpath(s["container"], s["exportName"])
        if rel in seen:
            raise CatalogError(
                f"样本键冲突（契约 R2.3）: {seen[rel]} 与 "
                f"{s['container']}/{s['exportName']} 都映射到 {rel}")
        seen[rel] = f"{s['container']}/{s['exportName']}"

    t0 = time.perf_counter()
    try:
        archive = zipfile.ZipFile(apk_path)
    except (zipfile.BadZipFile, OSError) as e:
        raise CatalogError(f"APK 不是有效 zip: {apk_path}（{e}）") from e

    sc_cache: dict[str, ScFile] = {}
    sctx_cache: dict[str, SctxImage] = {}
    verdicts: list[dict] = []
    with archive:
        rendered: dict[tuple[str, str], dict] = {}
        for s in samples:
            key = (s["container"], s["exportName"])
            if key in rendered:
                verdicts.append(rendered[key])  # R2.4：同 key 只渲染一次
                continue
            v = _render_sample(archive, s["container"], s["exportName"],
                               sc_cache, sctx_cache)
            verdicts.append(v)
            rendered[key] = v

    meta = {
        "apk": str(apk_path),
        "apkSizeBytes": Path(apk_path).stat().st_size,
        "samplesCount": len(verdicts),
        "successCount": sum(1 for v in verdicts if v["status"] == "success"),
        "failedCount": sum(1 for v in verdicts if v["status"] == "failed"),
        "durationMs": int((time.perf_counter() - t0) * 1000),
    }
    return meta, verdicts


def apply_rendered_paths(catalog: dict, verdicts: list[dict]) -> tuple[dict, int]:
    """verdicts → catalog.items 的 icon/levelVisual 引用回写（原地修改）。

    匹配键 = (container, exportName)：
      success → renderedPath = verdict.relPath、missingReason = null
      failed  → renderedPath = null、missingReason = 稳定枚举
    其余引用不动。返回 (catalog, 更新引用数)。

    catalog 结构校验（fail loud）：顶层非对象 / items 非数组 / items 含非对象
    → CatalogError 清晰报错（不裸 AttributeError traceback）。
    """
    if (not isinstance(catalog, dict)
            or not isinstance(catalog.get("items"), list)
            or not all(isinstance(item, dict)
                       for item in catalog.get("items", []))):
        raise CatalogError(
            "catalog.json 结构非法: 顶层对象 items 必须是对象数组")
    by_key = {(v["assetKey"]["container"], v["assetKey"]["exportName"]): v
              for v in verdicts}
    updated = 0
    for item in catalog.get("items", []):
        for holder in (item, *item.get("levels", [])):
            for ref_name in ("icon", "levelVisual"):
                ref = holder.get(ref_name)
                if not isinstance(ref, dict):
                    continue
                v = by_key.get((ref.get("container"), ref.get("exportName")))
                if v is None:
                    continue
                if v["status"] == "success":
                    ref["renderedPath"] = v["relPath"]
                    ref["missingReason"] = None
                else:
                    ref["renderedPath"] = None
                    ref["missingReason"] = v["missingReason"]
                updated += 1
    return catalog, updated


def _atomic_write(path: Path, data: bytes) -> None:
    """临时文件 + os.replace 原子替换（与 catalog.generate 同模式）。

    mkstemp 默认 0600，显式 chmod 0644（仓库文件惯例，避免 PNG 私有权限）。
    """
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".render-tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_rendered_outputs(catalog_dir: str | Path, verdicts: list[dict],
                           write_catalog: bool = True) -> dict:
    """成功样本 PNG 落盘（R2.1 路径）+ 可选 catalog.json 原子回写。

    - PNG 逐文件原子写（幂等，重跑覆盖）；失败样本不产生文件（R5）
    - catalog.json：全部 PNG 写完后临时文件 + replace（半写状态防护）；
      格式与生成管线一致（indent=2、sort_keys=True、ensure_ascii=False、
      尾部换行——catalog.py 同参数）
    """
    catalog_dir = Path(catalog_dir)
    written: list[str] = []
    for v in verdicts:
        if v["status"] != "success":
            continue
        target = catalog_dir / v["relPath"]
        target.parent.mkdir(parents=True, exist_ok=True)
        _atomic_write(target, v["pngBytes"])
        written.append(v["relPath"])

    updated = 0
    if write_catalog:
        catalog_path = catalog_dir / "catalog.json"
        if not catalog_path.is_file():
            raise CatalogError(f"catalog.json 不存在: {catalog_path}")
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        catalog, updated = apply_rendered_paths(catalog, verdicts)
        text = (json.dumps(catalog, ensure_ascii=False, indent=2,
                           sort_keys=True) + "\n")
        _atomic_write(catalog_path, text.encode("utf-8"))

    return {"pngWritten": written, "updatedRefs": updated}


def _report_dict(meta: dict, verdicts: list[dict], stats: dict) -> dict:
    """报告 JSON（剔除瞬态 pngBytes）。"""
    samples = []
    for v in verdicts:
        samples.append({k: val for k, val in v.items() if k != "pngBytes"})
    return {"meta": meta, "stats": stats, "samples": samples}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="COC 渲染生成器：固定样本 → PNG + catalog.json 回写（Issue #30）")
    parser.add_argument("--apk", type=Path, required=True,
                        help="COC APK 路径（读 assets/sc/*.sc）")
    parser.add_argument("--catalog", type=Path, required=True,
                        help="catalog.json 所在目录（PNG 输出到其 icons/）")
    parser.add_argument("--samples-only", action="store_true",
                        help="只渲染样本（PNG + 报告），不回写 catalog.json")
    parser.add_argument("--report", type=Path,
                        default=Path("/tmp/render-generator-report.json"),
                        help="报告 JSON 输出路径（默认 /tmp/render-generator-report.json）")
    args = parser.parse_args(argv)

    if not args.apk.is_file():
        print(f"error: APK 不存在: {args.apk}", file=sys.stderr)
        return 2
    if not args.catalog.is_dir():
        print(f"error: catalog 目录不存在: {args.catalog}", file=sys.stderr)
        return 2

    try:
        meta, verdicts = render_samples(args.apk)
        stats = write_rendered_outputs(args.catalog, verdicts,
                                       write_catalog=not args.samples_only)
        report = _report_dict(meta, verdicts, stats)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8")
    except (CatalogError, OSError, ValueError, zipfile.BadZipFile) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    for v in verdicts:
        k = v["assetKey"]
        if v["status"] == "success":
            p = v["png"]
            print(f"[success] {k['container']} / {k['exportName']} → "
                  f"{v['relPath']} ({p['size']}B, sha256 "
                  f"{p['sha256'][:12]}…, {v['durationMs']}ms)")
        else:
            msg = v["details"].get("message", "")
            print(f"[failed] {k['container']} / {k['exportName']} — "
                  f"{v['missingReason']} {msg}".rstrip())
    print(f"--- 汇总: 成功 {meta['successCount']} / 失败 {meta['failedCount']}"
          f"；PNG {len(stats['pngWritten'])} 张；catalog 引用更新 "
          f"{stats['updatedRefs']}；报告: {args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
