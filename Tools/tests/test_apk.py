import io
import lzma
import zipfile
import pytest

from game_catalog.errors import CatalogError
from game_catalog.apk import decode_asset, rows_from_text, read_build_tag, localization


def _packed(text: str) -> bytes:
    # Supercell 存储格式：LZMA_ALONE 头（13B: props+dict+usz）中 usz 高 4 字节被截掉。
    # Python lzma.compress 写 usz=-1，需先修补为真实长度再截断；
    # decode_asset 用 compressed[:8] + b"\0"*4 + compressed[8:] 恢复标准 ALONE 流。
    data = text.encode("utf-8-sig")
    compressed = lzma.compress(data, format=lzma.FORMAT_ALONE)
    return compressed[:5] + len(data).to_bytes(4, "little") + compressed[13:]


def test_decode_asset_roundtrip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("assets/logic/buildings.csv", _packed("a,b\n1,2\n"))
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        assert decode_asset(z, "assets/logic/buildings.csv") == "a,b\n1,2\n"


def test_decode_asset_missing_member_raises():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w"):
        pass
    buf.seek(0)
    with zipfile.ZipFile(buf) as z:
        with pytest.raises(KeyError):
            decode_asset(z, "assets/logic/nope.csv")


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
