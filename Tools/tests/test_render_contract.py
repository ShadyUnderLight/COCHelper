"""renderedPath 契约纯函数（Issue #27）property-based + 确定性测试。

契约语义对齐 Swift CatalogAssetRef.isRenderable（renderedPath 非空且 missingReason
为空，**空串 "" 不可渲染**，见 Sources/COCHelperCore/GameCatalog.swift:47-53）与
validate.py 现有负例校验。

交叉审核 P1-2 修正（2026-08-05）：空串 renderedPath 不再视为"无引用"——None 才是
无引用（返回 []）；"" 是非法渲染路径（R-D 报格式非法）。missing_reason 按
`is not None` 判定（"" 也触发 R-B 互斥），validate.py 域校验同规则（"" → 未知
missingReason）。

property 实证修正（相对任务原稿）：
- sampled_from(ASSET_MISSING_REASONS) 崩：hypothesis 6.155 要求有序集合，改用 sorted()；
- 不变量 1 原稿 "is_renderable 为真 ⇒ 无错误" 不可成立：is_renderable 只表达 Swift
  "路径存在且无失败原因"，格式/文件/登记轴（R-D/R-A/R-C）对可渲染项仍合法报错
  （实证反例 rp='0', mr=None → 报 R-D）。改为 sound 双断言：互斥轴一致 + 无伪通过；
- 不变量 2 原稿 "mr is not None" 对 "" 失败（truthiness vs None-ness），P1-2 后
  契约统一为 is not None 语义，"" 亦触发互斥。
"""

from hypothesis import given, strategies as st

import pytest

from game_catalog.contract import is_renderable, check_rendered_path_contract
from game_catalog import ASSET_MISSING_REASONS

_REASONS = sorted(ASSET_MISSING_REASONS)  # hypothesis 要求稳定有序（hash 随机化会破坏 replay）


@given(rp=st.one_of(st.none(), st.text()),
       mr=st.one_of(st.none(), st.sampled_from(_REASONS)))
def test_is_renderable_matches_swift_semantics(rp, mr):
    assert is_renderable(rp, mr) == (rp is not None and rp != "" and mr is None)


@given(rp=st.one_of(st.none(), st.text()), mr=st.one_of(st.none(), st.text()),
       fe=st.booleans(), reg=st.one_of(st.none(), st.booleans()))
def test_contract_invariants(rp, mr, fe, reg):
    errs = check_rendered_path_contract(rp, mr, fe, reg)
    # 不变量 1: 契约与 Swift isRenderable 互斥轴一致——契约报互斥错误 ⇒ is_renderable 为假；
    # 且无"伪通过"：renderedPath 非空且无错误 ⇒ missingReason 为 None。
    # （注意 is_renderable 为真≠无错误：R-D/R-A/R-C 轴对可渲染项仍合法报错。）
    if any("互斥" in e for e in errs):
        assert not is_renderable(rp, mr)
    if rp is not None and rp != "" and not errs:
        assert mr is None
    # 不变量 2: renderedPath 非空（含 ""）且 missingReason 非空（含 ""）⇒ 必有互斥错误
    if rp is not None and mr is not None:
        assert any("互斥" in e for e in errs)
    # 不变量 3: 错误数量 ≤ 4
    assert len(errs) <= 4
    # 不变量 4: renderedPath 非空且无错误 ⇒ file_exists 必须为 True（R-A）
    if rp is not None and rp != "" and not errs:
        assert fe
    # 不变量 5: 空串 renderedPath 必报格式非法（P1-2 fail-closed）
    if rp == "":
        assert any("格式非法" in e for e in errs)


# ---- 确定性用例（每个契约规则一个，含边界）----

def test_det_rb_mutual_exclusion():
    """R-B: renderedPath 与 missingReason 非空 → 互斥错误（独立轴，最优先）。"""
    errs = check_rendered_path_contract("icons/ui/a.png", "icons_not_rendered", True, True)
    assert any("互斥" in e for e in errs)


def test_det_rd_format_illegal():
    """R-D: 缺 icons/ 前缀或非 .png 结尾 → 格式非法错误。"""
    errs = check_rendered_path_contract("x.png", None, True, True)
    assert any("格式非法" in e for e in errs)
    errs = check_rendered_path_contract("icons/ui/x.jpg", None, True, True)
    assert any("格式非法" in e for e in errs)


def test_det_ra_file_missing():
    """R-A: 文件不存在 → 错误含"不存在"。"""
    errs = check_rendered_path_contract("icons/ui/a.png", None, False, True)
    assert any("不存在" in e for e in errs)


def test_det_rc_unregistered():
    """R-C: 文件存在但未登记 → 错误含"登记"。"""
    errs = check_rendered_path_contract("icons/ui/a.png", None, True, False)
    assert any("登记" in e for e in errs)


def test_det_rc_skipped_when_registered_none():
    """R-C 跳过: registered=None（manifest 无 generatedFiles）→ 不报"登记"。"""
    assert check_rendered_path_contract("icons/ui/a.png", None, True, None) == []


def test_det_valid_path_no_errors():
    """合法路径: icons/<container_key>/<export_key>.png 两级 + 文件存在 + 已登记 → 无错误。"""
    assert check_rendered_path_contract("icons/ui/a.png", None, True, True) == []


@pytest.mark.parametrize("bad", [
    "icons/18.400.13/ui/icon_unit_barbarian.png",  # 版本段 3 级（验收 7 缺口）
    "icons/18.400.13/icon.png",      # container_key 位置是版本段（\d+\.\d+\.\d+）
    "icons/18.400/icon.png",         # 版本段（18.\d+ 形式）
    "icons/../secret.png",           # .. 段逃逸（正则 [^/]+ 不排除字面 ..，须显式拒绝）
    "icons/../../secret.png",        # 多级逃逸
    "icons/./secret.png",            # . 段（R2.2：拒绝，P2-1）
    "icons/ui/./secret.png",         # 第二级 . 段
    "icons/..%2F..%2Fetc/passwd.png",  # URL 编码段逃逸（防未来 URL 解码消费者）
    "icons/%2e%2e/secret.png",       # URL 编码 ..
    "icons/ui/%2e%2e.png",           # export 名含 %
    "icons/a.png",                   # 单级（违反 R2.1 两级结构）
    "icons/ui/a/b.png",              # 三级
    "/icons/ui/a.png",               # 绝对路径
    "icons/ui/a.jpg",                # 非 .png
    "ui/a.png",                      # 无 icons/ 前缀
])
def test_det_rd_strict_two_level_rejected(bad):
    """R-D 严格两级结构（交叉审核）：版本段/.. 段/绝对路径/单级/非 png/无前缀 → 格式非法。"""
    errs = check_rendered_path_contract(bad, None, True, True)
    assert any("格式非法" in e for e in errs)


def test_det_rd_two_level_valid():
    """R-D 正例：icons/<container_key>/<export_key>.png → 无格式错误。"""
    errs = check_rendered_path_contract(
        "icons/ui/icon_unit_barbarian.png", None, True, True)
    assert errs == []


def test_det_rd_filename_length_limit():
    """R2.2 文件名长度上限 200 字节（P2-1）：超限 → 格式非法；边界值通过。"""
    def check(name: str) -> list:
        return check_rendered_path_contract(f"icons/ui/{name}.png", None, True, True)
    assert check("x" * 196) == []          # 196 + 4(.png) = 200 字节 → 通过
    assert any("格式非法" in e for e in check("x" * 197))   # 201 字节 → 拒绝
    # 多字节 UTF-8 按字节计：66 汉字 * 3 = 198 + 4 = 202 → 拒绝
    assert any("格式非法" in e for e in check("中" * 66))
    assert check("中" * 65) == []          # 195 + 4 = 199 → 通过


def test_det_none_path_no_errors():
    """renderedPath 为 None（无引用）→ 不触发任何契约错误（P1-2 语义：None≠""）。"""
    assert check_rendered_path_contract(None, "icons_not_rendered", False, False) == []


def test_det_empty_path_rejected():
    """renderedPath 为空串 → 报格式非法（P1-2：空路径不得绕过校验，不得视为可渲染）。"""
    errs = check_rendered_path_contract("", None, True, True)
    assert any("格式非法" in e for e in errs)
    errs2 = check_rendered_path_contract("", "icons_not_rendered", False, False)
    assert any("格式非法" in e for e in errs2)
    assert any("互斥" in e for e in errs2)


def test_det_is_renderable_truth_table():
    """is_renderable 真值表（对齐 Swift GameCatalogTests P2-2，含 P1-2 空串修正）。"""
    assert is_renderable("icons/barbarian.png", None)
    assert not is_renderable(None, None)
    assert not is_renderable("icons/barbarian.png", "icons_not_rendered")
    assert not is_renderable(None, "icons_not_rendered")
    # P1-2: 空串路径不可渲染（契约 R2.2/R5.3，Swift 同规则）
    assert not is_renderable("", None)
    assert not is_renderable("", "icons_not_rendered")
