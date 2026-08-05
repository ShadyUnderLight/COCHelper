"""render_spike 测试：Shapes/Textures chunk 解析、ScFile 惰性方法、PNG 编码、
verdict 报告 schema、CLI 主流程（TDD fixture 全合成，无真实 APK 依赖）。

fixture 构造复用 test_fbs.FbBuilder（add_raw_vector 构造 [ubyte]/struct vector，
u8/u16 字段构造 inline 标量）与 test_sc2 的 DataStorage/ExportNames 构造辅助；
SC2 容器字节用与 test_sc2 相同的布局（[SC][version][4B][descriptor_size]
[descriptor][body]，body = [u32 ds_size][DataStorage][chunk 序列]）。
"""

import json
import struct
import zipfile
import zlib
from pathlib import Path

import pytest

from game_catalog.errors import CatalogError
from game_catalog.sc2 import (
    ScFile,
    ScHeader,
    parse_shapes,
    parse_textures,
    shape_textures,
    texture_data,
)
from render_spike import (
    SAMPLES,
    encode_png,
    main,
    render_spike,
    resolve_sample,
)

from test_fbs import FbBuilder


# ---------------------------------------------------------------------------
# fixture 构造
# ---------------------------------------------------------------------------


def build_shapes_payload(shapes: list[tuple[int, list[int] | None]]) -> bytes:
    """Shapes{shapes: [Shape]}；Shape{id: ushort, commands: [struct 16B]}。

    commands 元素 ShapeDrawBitmapCommand 是 struct（非 table）：u32 unk1 /
    u32 texture_index / u32 points_count / u32 points_offset，16 字节连续
    排布；vector 长度字段写元素个数（add_raw_vector 语义）。
    commands=None → 不声明 slot 1（字段缺省）；[] → 声明但 0 元素。
    """
    b = FbBuilder()
    shape_tokens = []
    for shape_id, tex_indices in shapes:
        cmd = b"".join(struct.pack("<4I", 0, ti, 3, 0) for ti in (tex_indices or []))
        fields: dict[int, tuple] = {0: ("u16", shape_id)}
        if tex_indices is not None:
            fields[1] = ("uoffset",
                         b.add_raw_vector(len(tex_indices), cmd))
        shape_tokens.append(b.add_table(fields))
    vec = b.add_vector(shape_tokens)
    root = b.add_table({0: ("uoffset", vec)})
    return b.finish(root)


def _add_texture_data(b: FbBuilder, td: dict) -> int:
    """TextureData table：slot0 fmt u8 / slot1 pt u8 / slot2-3 w,h u16 /
    slot4 data [ubyte] / slot5 external_texture string。字段为 None → 不声明。"""
    fields: dict[int, tuple] = {}
    if td.get("texture_format") is not None:
        fields[0] = ("u8", td["texture_format"])
    if td.get("pixel_type") is not None:
        fields[1] = ("u8", td["pixel_type"])
    fields[2] = ("u16", td["width"])
    fields[3] = ("u16", td["height"])
    if td.get("data") is not None:
        fields[4] = ("uoffset", b.add_raw_vector(len(td["data"]), td["data"]))
    if td.get("external_texture"):
        fields[5] = ("uoffset", b.add_string(td["external_texture"]))
    return b.add_table(fields)


def build_textures_payload(sets: list[dict]) -> bytes:
    """Textures{textures: [TextureSet{lowres?, highres}]}。highres=None → 缺省。"""
    b = FbBuilder()
    set_tokens = []
    for s in sets:
        fields: dict[int, tuple] = {}
        if s.get("lowres") is not None:
            fields[0] = ("uoffset", _add_texture_data(b, s["lowres"]))
        if s.get("highres") is not None:
            fields[1] = ("uoffset", _add_texture_data(b, s["highres"]))
        set_tokens.append(b.add_table(fields))
    vec = b.add_vector(set_tokens)
    root = b.add_table({0: ("uoffset", vec)})
    return b.finish(root)


def build_movieclips_payload(ids: list[int]) -> bytes:
    """MovieClips{clips: [MovieClip{id: ushort}]}（spike 证据链仅需 id）。"""
    b = FbBuilder()
    tokens = [b.add_table({0: ("u16", i)}) for i in ids]
    vec = b.add_vector(tokens)
    return b.finish(b.add_table({0: ("uoffset", vec)}))


def make_sc(chunks: dict[str, bytes], export_names: dict[str, int]) -> ScFile:
    return ScFile(
        header=ScHeader(version=6, descriptor_size=0, shape_count=0,
                        movie_clips_count=0, texture_count=0,
                        text_fields_count=0, resources_offset=0,
                        textures_length=0, compressed_size=0,
                        external_matrix_bank_size=0),
        metadata=[], strings=[], export_names=export_names, chunks=chunks)


def _minimal_chunk() -> bytes:
    b = FbBuilder()
    return b.finish(b.add_table({}))


def build_full_sc_bytes(strings: list[str], exports: list[tuple[int, int]],
                        shapes_payload: bytes, textures_payload: bytes) -> bytes:
    """完整 SC2 V6 文件（未压缩 body）：DataStorage + 6 个 chunk 序列。

    chunk 固定顺序：ExportNames → TextFields → Shapes → MovieClips →
    MovieClipModifiers → Textures；中间 chunk 用最小空 table 占位。
    """
    from test_sc2 import build_data_storage, build_export_names
    ds = build_data_storage(strings)
    en = build_export_names([oid for _, oid in exports],
                            [ref for ref, _ in exports])
    tf = mc = mcm = _minimal_chunk()
    body = (struct.pack("<I", len(ds)) + ds
            + struct.pack("<I", len(en)) + en
            + struct.pack("<I", len(tf)) + tf
            + struct.pack("<I", len(shapes_payload)) + shapes_payload
            + struct.pack("<I", len(mc)) + mc
            + struct.pack("<I", len(mcm)) + mcm
            + struct.pack("<I", len(textures_payload)) + textures_payload)
    resources_offset = 4 + len(ds)
    b = FbBuilder()
    descriptor = b.finish(b.add_table({8: ("u32", resources_offset)}))
    return (b"SC" + struct.pack("<H", 6) + b"\x00" * 4
            + struct.pack("<I", len(descriptor)) + descriptor + body)


def decode_png(data: bytes) -> tuple[int, int, int, bytes]:
    """手工解析 PNG：签名 / IHDR / IDAT(zlib 解压) / 逐行 filter。"""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    idat = b""
    ct = 6
    w = h = 0
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        cdata = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            w, h, _, ct, *_ = struct.unpack(">IIBBBBB", cdata)
        elif ctype == b"IDAT":
            idat += cdata
        pos += 12 + length
    raw = zlib.decompress(idat)
    bpp = {6: 4, 4: 2, 0: 1}[ct]
    stride = w * bpp
    out = bytearray()
    for y in range(h):
        assert raw[y * (stride + 1)] == 0  # filter None
        out += raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)]
    return w, h, ct, bytes(out)


# ---------------------------------------------------------------------------
# parse_shapes（struct vector 元素解析）
# ---------------------------------------------------------------------------


def test_parse_shapes_struct_commands():
    """16 字节 struct vector：元素连续排布，texture_index 位于每元素 +4。"""
    payload = build_shapes_payload([(7, [0, 3, 5]), (9, None), (11, [1])])
    assert parse_shapes(payload) == {7: [0, 3, 5], 9: [], 11: [1]}


def test_parse_shapes_empty_commands_field():
    payload = build_shapes_payload([(7, [])])
    assert parse_shapes(payload) == {7: []}


def test_parse_shapes_missing_shapes_vector_empty():
    b = FbBuilder()
    assert parse_shapes(b.finish(b.add_table({}))) == {}


def test_parse_shapes_malformed_raises_catalog_error():
    with pytest.raises(CatalogError):
        parse_shapes(b"\xff\xff\xff\xff")


# ---------------------------------------------------------------------------
# parse_textures
# ---------------------------------------------------------------------------

RGBA_2X2 = bytes([
    255, 0, 0, 255, 0, 255, 0, 255,
    0, 0, 255, 255, 255, 255, 0, 255,
])


def test_parse_textures_fields_and_data():
    payload = build_textures_payload([
        {"highres": {"texture_format": 0, "pixel_type": 1, "width": 2,
                     "height": 2, "data": RGBA_2X2}},
        {"lowres": {"texture_format": 0, "pixel_type": 0, "width": 1,
                    "height": 1, "data": b"\x01"},
         "highres": {"texture_format": 8, "pixel_type": 0, "width": 4,
                     "height": 4, "data": b"KTX", "external_texture": "x.sctx"}},
    ])
    tex = parse_textures(payload)
    assert len(tex) == 2
    assert (tex[0].texture_format, tex[0].pixel_type) == (0, 1)
    assert (tex[0].width, tex[0].height) == (2, 2)
    assert tex[0].data == RGBA_2X2
    assert tex[0].external_texture is None
    assert (tex[1].texture_format, tex[1].pixel_type) == (8, 0)
    assert tex[1].external_texture == "x.sctx"
    assert tex[1].data == b"KTX"


def test_parse_textures_missing_data_field_none():
    payload = build_textures_payload([
        {"highres": {"texture_format": 0, "pixel_type": 0, "width": 1,
                     "height": 1}}])
    tex = parse_textures(payload)
    assert tex[0].data is None
    assert tex[0].external_texture is None


def test_parse_textures_missing_highres_raises():
    payload = build_textures_payload([
        {"lowres": {"texture_format": 0, "pixel_type": 0, "width": 1,
                    "height": 1, "data": b"\x00"}}])
    with pytest.raises(CatalogError, match="highres"):
        parse_textures(payload)


def test_parse_textures_malformed_raises_catalog_error():
    with pytest.raises(CatalogError):
        parse_textures(b"\xff\xff\xff\xff")


# ---------------------------------------------------------------------------
# ScFile 惰性方法
# ---------------------------------------------------------------------------


def test_shape_textures_lookup_and_miss():
    sc = make_sc({"Shapes": build_shapes_payload([(5, [0, 2])])}, {})
    assert shape_textures(sc, 5) == [0, 2]
    assert shape_textures(sc, 999) is None


def test_shape_textures_empty_commands():
    sc = make_sc({"Shapes": build_shapes_payload([(5, None)])}, {})
    assert shape_textures(sc, 5) == []


def test_texture_data_out_of_range_raises():
    sc = make_sc({"Textures": build_textures_payload([
        {"highres": {"texture_format": 0, "pixel_type": 0, "width": 1,
                     "height": 1, "data": b"\x00"}}])}, {})
    with pytest.raises(CatalogError, match="越界"):
        texture_data(sc, 1)


# ---------------------------------------------------------------------------
# PNG 编码器
# ---------------------------------------------------------------------------


def test_encode_png_rgba_roundtrip():
    png = encode_png(2, 2, RGBA_2X2, 6)
    assert decode_png(png) == (2, 2, 6, RGBA_2X2)


def test_encode_png_grayscale():
    pixels = bytes([0, 128, 255])
    assert decode_png(encode_png(3, 1, pixels, 0)) == (3, 1, 0, pixels)


def test_encode_png_gray_alpha():
    pixels = bytes([10, 200, 30, 100, 50, 60])
    assert decode_png(encode_png(3, 1, pixels, 4)) == (3, 1, 4, pixels)


def test_encode_png_data_length_mismatch_raises():
    with pytest.raises(ValueError, match="长度"):
        encode_png(2, 2, b"\x00" * 10, 6)  # 期望 16 字节


# ---------------------------------------------------------------------------
# verdict 报告 schema（resolve_sample 直接裁决）
# ---------------------------------------------------------------------------


def _sample(name: str = "icon_x") -> dict:
    return {"container": "sc/ui.sc", "exportName": name}


def test_verdict_success_writes_png(tmp_path: Path):
    sc = make_sc({
        "Shapes": build_shapes_payload([(5, [0])]),
        "Textures": build_textures_payload([
            {"highres": {"texture_format": 0, "pixel_type": 0, "width": 2,
                         "height": 2, "data": RGBA_2X2}}]),
    }, {"icon_x": 5})
    v = resolve_sample(_sample(), sc, tmp_path, {}, None)
    assert v["status"] == "success"
    assert v["blocker"] is None
    png = tmp_path / v["png"]["path"]
    assert png.is_file()
    assert png.stat().st_size == v["png"]["size"]
    assert v["png"]["sha256"]
    assert decode_png(png.read_bytes()) == (2, 2, 6, RGBA_2X2)
    assert v["evidence"]["shapeFound"] is True
    assert v["evidence"]["textureIndexes"] == [0]


def test_verdict_bgra_swaps_to_rgba(tmp_path: Path):
    # 源像素 (255,0,0) 以 BGRA 存为 (0,0,255,255)
    bgra = bytes([0, 0, 255, 255, 255, 255, 0, 255,
                  0, 255, 0, 255, 0, 0, 0, 255])
    sc = make_sc({
        "Shapes": build_shapes_payload([(5, [0])]),
        "Textures": build_textures_payload([
            {"highres": {"texture_format": 0, "pixel_type": 1, "width": 2,
                         "height": 2, "data": bgra}}]),
    }, {"icon_x": 5})
    v = resolve_sample(_sample(), sc, tmp_path, {}, None)
    assert v["status"] == "success"
    png = tmp_path / v["png"]["path"]
    # 每个像素 R/B 交换：BGRA(0,0,255)→RGBA(255,0,0) 等
    assert decode_png(png.read_bytes())[3] == bytes([
        255, 0, 0, 255, 0, 255, 255, 255,
        0, 255, 0, 255, 0, 0, 0, 255])


def test_verdict_blocked_no_shape_command(tmp_path: Path):
    sc = make_sc({
        "Shapes": build_shapes_payload([(5, [0])]),
        "MovieClips": build_movieclips_payload([3, 9, 99]),
    }, {"icon_x": 99})
    v = resolve_sample(_sample(), sc, tmp_path, {}, None)
    assert v["status"] == "blocked"
    assert v["blocker"]["reason"] == "no_shape_command"
    assert v["evidence"]["shapeFound"] is False
    assert v["evidence"]["movieClipFound"] is True
    assert v["evidence"]["movieClipIndex"] == 2
    assert v["png"] is None


def test_verdict_blocked_compressed_texture(tmp_path: Path):
    ktx = (b"\xabKTX 11\xbb\r\n\x1a\n"
           + struct.pack("<13I", 0x04030201, 0, 1, 0, 37808, 6408,
                         4, 4, 0, 0, 1, 1, 0) + b"\x00" * 64)
    sc = make_sc({
        "Shapes": build_shapes_payload([(5, [0])]),
        "Textures": build_textures_payload([
            {"highres": {"texture_format": 8, "pixel_type": 0, "width": 4,
                         "height": 4, "data": ktx}}]),
    }, {"icon_x": 5})
    v = resolve_sample(_sample(), sc, tmp_path, {}, None)
    assert v["status"] == "blocked"
    assert v["blocker"]["reason"] == "compressed_texture"
    assert v["blocker"]["details"]["format"] == 8
    assert v["blocker"]["details"]["ktx"]["glInternalFormat"] == 37808
    assert v["evidence"]["texture"]["textureFormat"] == 8


def test_verdict_blocked_needs_sctx_decode(tmp_path: Path):
    sc = make_sc({
        "Shapes": build_shapes_payload([(5, [0])]),
        "Textures": build_textures_payload([
            {"highres": {"texture_format": 4, "pixel_type": 0, "width": 8,
                         "height": 8, "external_texture": "buildings_0.sctx"}}]),
    }, {"icon_x": 5})
    v = resolve_sample(_sample(), sc, tmp_path, {}, None)
    assert v["status"] == "blocked"
    assert v["blocker"]["reason"] == "needs_sctx_decode"
    assert v["blocker"]["details"]["path"] == "buildings_0.sctx"


def test_verdict_blocked_unsupported_pixel_type(tmp_path: Path):
    sc = make_sc({
        "Shapes": build_shapes_payload([(5, [0])]),
        "Textures": build_textures_payload([
            {"highres": {"texture_format": 0, "pixel_type": 2, "width": 2,
                         "height": 2, "data": b"\x00" * 16}}]),
    }, {"icon_x": 5})
    v = resolve_sample(_sample(), sc, tmp_path, {}, None)
    assert v["status"] == "blocked"
    assert v["blocker"]["reason"] == "unsupported_pixel_type"
    assert v["blocker"]["details"]["pixelType"] == 2


def test_verdict_blocked_data_length_mismatch(tmp_path: Path):
    sc = make_sc({
        "Shapes": build_shapes_payload([(5, [0])]),
        "Textures": build_textures_payload([
            {"highres": {"texture_format": 0, "pixel_type": 0, "width": 2,
                         "height": 2, "data": b"\x00" * 10}}]),
    }, {"icon_x": 5})
    v = resolve_sample(_sample(), sc, tmp_path, {}, None)
    assert v["status"] == "blocked"
    assert v["blocker"]["reason"] == "data_length_mismatch"
    assert v["blocker"]["details"]["expected"] == 16
    assert v["blocker"]["details"]["actual"] == 10


def test_verdict_missing_export():
    sc = make_sc({"Shapes": build_shapes_payload([(5, [0])])}, {})
    v = resolve_sample(_sample("nope"), sc, Path("/tmp"), {}, None)
    assert v["status"] == "missing"
    assert v["blocker"]["reason"] == "export_not_found"
    assert v["png"] is None


def test_verdict_schema_field_completeness(tmp_path: Path):
    """每个 verdict 必须含 asset_key/status/evidence/blocker/png 五字段。"""
    cases = []
    sc_ok = make_sc({
        "Shapes": build_shapes_payload([(5, [0])]),
        "Textures": build_textures_payload([
            {"highres": {"texture_format": 0, "pixel_type": 0, "width": 1,
                         "height": 1, "data": b"\x00\x00\x00\xff"}}]),
    }, {"a": 5})
    cases.append(resolve_sample(_sample("a"), sc_ok, tmp_path, {}, None))
    sc_miss = make_sc({"Shapes": build_shapes_payload([])}, {})
    cases.append(resolve_sample(_sample("b"), sc_miss, tmp_path, {}, None))
    sc_no_shape = make_sc({"Shapes": build_shapes_payload([(5, [0])])},
                          {"c": 77})
    cases.append(resolve_sample(_sample("c"), sc_no_shape, tmp_path, {}, None))
    for v in cases:
        assert set(v) == {"asset_key", "status", "evidence", "blocker", "png"}
        assert isinstance(v["evidence"], dict)
        assert v["status"] in {"success", "blocked", "missing"}
        assert v["blocker"] is None or set(v["blocker"]) == {"reason", "details"}
        assert v["png"] is None or set(v["png"]) == {"path", "size", "sha256"}


def test_texture_limit_caps_resolutions(tmp_path: Path):
    """--limit：容器级 texture 解析预算，超限 → blocked(texture_limit_exceeded)。"""
    sc = make_sc({
        "Shapes": build_shapes_payload([(5, [0, 1])]),
        "Textures": build_textures_payload([
            {"highres": {"texture_format": 8, "pixel_type": 0, "width": 1,
                         "height": 1, "data": b"\x00" * 16}},
            {"highres": {"texture_format": 8, "pixel_type": 0, "width": 1,
                         "height": 1, "data": b"\x00" * 16}},
        ]),
    }, {"icon_x": 5})
    v = resolve_sample(_sample(), sc, tmp_path, {"sc/ui.sc": 2}, 2)
    assert v["status"] == "blocked"
    assert v["blocker"]["reason"] == "texture_limit_exceeded"


# ---------------------------------------------------------------------------
# CLI 主流程（临时目录合成 APK → spike-report.json）
# ---------------------------------------------------------------------------


def _build_fake_apk(tmp_path: Path) -> Path:
    apk = tmp_path / "fake.apk"
    shapes_ui = build_shapes_payload([(5, [0]), (99, None)])
    textures_ui = build_textures_payload([
        {"highres": {"texture_format": 0, "pixel_type": 0, "width": 2,
                     "height": 2, "data": RGBA_2X2}},
    ])
    ui_sc = build_full_sc_bytes(
        ["icon_unit_barbarian", "icon_unit_does_not_exist"],
        [(0, 5)], shapes_ui, textures_ui)
    shapes_b = build_shapes_payload([(7, [0])])
    textures_b = build_textures_payload([
        {"highres": {"texture_format": 4, "pixel_type": 0, "width": 10,
                     "height": 10, "external_texture": "buildings_0.sctx"}},
    ])
    buildings_sc = build_full_sc_bytes(
        ["fireplace_lvl1", "blacksmith_lvl1"],
        [(0, 7), (1, 9999)], shapes_b, textures_b)
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/sc/ui.sc", ui_sc)
        z.writestr("assets/sc/buildings.sc", buildings_sc)
    return apk


def test_main_flow_writes_report(tmp_path: Path):
    apk = _build_fake_apk(tmp_path)
    out = tmp_path / "out"
    assert main(["--apk", str(apk), "--output", str(out)]) == 0
    report = json.loads((out / "spike-report.json").read_text(encoding="utf-8"))
    by_key = {(s["asset_key"]["container"], s["asset_key"]["exportName"]): s
              for s in report["samples"]}
    assert len(report["samples"]) == len(SAMPLES) == 5
    # 1) 单位 icon → 成功（PNG 落盘）
    succ = by_key[("sc/ui.sc", "icon_unit_barbarian")]
    assert succ["status"] == "success"
    png_file = out / succ["png"]["path"]
    assert png_file.is_file()
    assert png_file.stat().st_size == succ["png"]["size"]
    assert succ["png"]["sha256"]
    assert succ["blocker"] is None
    # 2) 建筑等级外观 → 外部 sctx 阻塞
    fire = by_key[("sc/buildings.sc", "fireplace_lvl1")]
    assert fire["status"] == "blocked"
    assert fire["blocker"]["reason"] == "needs_sctx_decode"
    assert fire["blocker"]["details"]["path"] == "buildings_0.sctx"
    # 3) 跨等级复用 → oid 不是 shape → no_shape_command
    bs = by_key[("sc/buildings.sc", "blacksmith_lvl1")]
    assert bs["status"] == "blocked"
    assert bs["blocker"]["reason"] == "no_shape_command"
    # 4) 失败引用：导出名不存在
    miss = by_key[("sc/ui.sc", "icon_unit_does_not_exist")]
    assert miss["status"] == "missing"
    assert miss["blocker"]["reason"] == "export_not_found"
    # 4b) container 不存在
    trap = by_key[("sc/traps.sc", "town_hall_lvl1")]
    assert trap["status"] == "missing"
    assert trap["blocker"]["reason"] == "container_not_found"


def test_main_flow_missing_apk_clear_error(tmp_path: Path):
    code = main(["--apk", str(tmp_path / "nope.apk"),
                 "--output", str(tmp_path / "out")])
    assert code == 2


def test_render_spike_catalog_error_records_blocked(tmp_path: Path):
    """容器存在但 SC 解析失败 → 记入报告 blocked 而非崩溃。"""
    apk = tmp_path / "bad.apk"
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("assets/sc/ui.sc", b"not-an-sc-file")
    report = render_spike(apk, tmp_path / "out", None)
    by_key = {(s["asset_key"]["container"], s["asset_key"]["exportName"]): s
              for s in report["samples"]}
    v = by_key[("sc/ui.sc", "icon_unit_barbarian")]
    assert v["status"] == "blocked"
    assert v["blocker"]["reason"] == "catalog_error"
