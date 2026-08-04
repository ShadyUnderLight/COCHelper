import io
import lzma
import zipfile
import pytest

from game_catalog.errors import CatalogError
from game_catalog.apk import decode_asset, rows_from_text, read_build_tag, localization


def _packed(text: str) -> bytes:
    # Supercell 存储格式头 = 5B props + 4B usz（小端）= 9B（与真实 APK 一致，
    # 实测真实头 = 5d00000400 + usz 4B + 数据）。
    # Python lzma.compress 写 13B 标准 ALONE 头（8B usz），需截断为 4B usz；
    # decode_asset 用 packed[:9] + b"\0"*4 + packed[9:] 恢复标准 ALONE 流。
    data = text.encode("utf-8-sig")
    compressed = lzma.compress(data, format=lzma.FORMAT_ALONE)
    return compressed[:5] + len(data).to_bytes(4, "little") + compressed[13:]


def _packed_with_usz(text: str, usz: int) -> bytes:
    """按给定 usz 构造 9B 头（用于 zip bomb / 超限回归测试）。"""
    data = text.encode("utf-8-sig")
    compressed = lzma.compress(data, format=lzma.FORMAT_ALONE)
    return compressed[:5] + usz.to_bytes(4, "little") + compressed[13:]


def _zip_with(path: str, payload: bytes) -> io.BytesIO:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(path, payload)
    buf.seek(0)
    return buf


def test_decode_asset_roundtrip():
    with zipfile.ZipFile(_zip_with("assets/logic/buildings.csv", _packed("a,b\n1,2\n"))) as z:
        assert decode_asset(z, "assets/logic/buildings.csv") == "a,b\n1,2\n"


def test_decode_asset_large_over_16mb_roundtrip():
    """I6 回归：usz ≥ 2^24（16MB）时，9B 头的第 4 字节不再被错位进数据流。
    旧实现 packed[:8] + b"\0"*4 + packed[8:] 对 ≥16MB 资源会 LZMAError。"""
    payload = ("x" * 17 * 1024 * 1024) + "\nEND\n"
    packed = _packed(payload)
    assert len(payload) > 16 * 1024 * 1024  # 确保 usz 第 4 字节非 0
    with zipfile.ZipFile(_zip_with("assets/logic/big.csv", packed)) as z:
        decoded = decode_asset(z, "assets/logic/big.csv")
    assert decoded == payload
    assert len(decoded) > 16 * 1024 * 1024


def test_decode_asset_zip_bomb_usz_rejected_before_decompress():
    """I6 回归：头里 usz 超 256MB → 直接拒绝（不解压），防 zip bomb。"""
    packed = _packed_with_usz("small", 300 * 1024 * 1024)
    with zipfile.ZipFile(_zip_with("assets/logic/bomb.csv", packed)) as z:
        with pytest.raises(CatalogError, match="资源过大"):
            decode_asset(z, "assets/logic/bomb.csv")


def test_decode_asset_huge_output_rejected(monkeypatch):
    """I6 回归：解压输出超过上限 → CatalogError（解压后兜底检查，绕过 usz 预检）。"""
    import game_catalog.apk as apk_mod
    monkeypatch.setattr(apk_mod, "_MAX_ASSET_BYTES", 100)
    monkeypatch.setattr(apk_mod, "_MAX_HEADER_USZ", 10 ** 9)  # 跳过预检，只测兜底
    with zipfile.ZipFile(_zip_with("assets/logic/big.csv", _packed("y" * 200))) as z:
        with pytest.raises(CatalogError, match="资源过大"):
            decode_asset(z, "assets/logic/big.csv")


def test_decode_asset_missing_member_raises():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w"):
        pass
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        with pytest.raises(CatalogError) as excinfo:
            decode_asset(z, "assets/logic/nope.csv")
    assert "nope.csv" in str(excinfo.value)


def test_decode_asset_corrupt_lzma_raises():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/logic/buildings.csv", b"not-lzma-data")
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        with pytest.raises(CatalogError) as excinfo:
            decode_asset(z, "assets/logic/buildings.csv")
    assert "buildings.csv" in str(excinfo.value)


def test_rows_from_text_skips_nothing_returns_dicts():
    rows = rows_from_text("Name,Level\nA,1\nB,2\n")
    assert rows == [{"Name": "A", "Level": "1"}, {"Name": "B", "Level": "2"}]


def test_rows_from_text_cells_stripped():
    rows = rows_from_text("Name,Level\n A , 1 \n")
    assert rows == [{"Name": "A", "Level": "1"}]


def test_read_build_tag():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/build.tag", "18_400_7")
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        assert read_build_tag(z) == "18_400_7"


def test_read_build_tag_missing_raises():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w"):
        pass  # 不含 assets/build.tag 的假 zip
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        with pytest.raises(CatalogError) as excinfo:
            read_build_tag(z)
    assert "build.tag" in str(excinfo.value)


def test_localization_cn_then_patch_overrides():
    cn = _packed("TID,CN\nTID_A,甲\nTID_B,乙\n")
    patch = _packed("TID,CN,Other\nTID_B,丙,x\n")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/localization/cn.csv", cn)
        z.writestr("assets/localization/texts_patch.csv", patch)
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        loc = localization(z)
    assert loc["TID_A"] == "甲"
    assert loc["TID_B"] == "丙"


def test_localization_clean_name():
    cn = _packed("TID,CN\nTID_A,有\\q引号\\n换行 \n")
    patch = _packed("TID,CN\n")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/localization/cn.csv", cn)
        z.writestr("assets/localization/texts_patch.csv", patch)
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        loc = localization(z)
    assert loc["TID_A"] == "有引号 换行"
