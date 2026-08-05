"""renderedPath 契约纯函数（Issue #27）property-based + 确定性测试。

契约语义对齐 Swift CatalogAssetRef.isRenderable（renderedPath != nil && missingReason == nil，
空字符串 ≠ nil，见 Sources/COCHelperCore/GameCatalog.swift:47-49）与 validate.py 现有负例校验。

注意 missingReason="" 的合成边界：契约按 validate.py 的 truthiness 语义（"非空"）判定 R-B，
is_renderable 按 None-ness 判定（Swift 语义），二者对 "" 有差异——property 策略不生成 ""，
确定性用例只覆盖真实域（None 或非空枚举）。

property 实证修正（相对任务原稿）：
- sampled_from(ASSET_MISSING_REASONS) 崩：hypothesis 6.155 要求有序集合，改用 sorted()；
- 不变量 1 原稿 "is_renderable 为真 ⇒ 无错误" 不可成立：is_renderable 只表达 Swift
  "路径存在且无失败原因"，格式/文件/登记轴（R-D/R-A/R-C）对可渲染项仍合法报错
  （实证反例 rp='0', mr=None → 报 R-D）。改为 sound 双断言：互斥轴一致 + 无伪通过；
- 不变量 2 原稿 "mr is not None" 对 "" 失败（truthiness vs None-ness），收紧为
  "mr 非空"。
"""

from hypothesis import given, strategies as st

from game_catalog.contract import is_renderable, check_rendered_path_contract
from game_catalog import ASSET_MISSING_REASONS

_REASONS = sorted(ASSET_MISSING_REASONS)  # hypothesis 要求稳定有序（hash 随机化会破坏 replay）


@given(rp=st.one_of(st.none(), st.text(min_size=1)),
       mr=st.one_of(st.none(), st.sampled_from(_REASONS)))
def test_is_renderable_matches_swift_semantics(rp, mr):
    assert is_renderable(rp, mr) == (rp is not None and mr is None)


@given(rp=st.one_of(st.none(), st.text()), mr=st.one_of(st.none(), st.text()),
       fe=st.booleans(), reg=st.one_of(st.none(), st.booleans()))
def test_contract_invariants(rp, mr, fe, reg):
    errs = check_rendered_path_contract(rp, mr, fe, reg)
    # 不变量 1: 契约与 Swift isRenderable 互斥轴一致——契约报互斥错误 ⇒ is_renderable 为假；
    # 且无"伪通过"：renderedPath 非空且无错误 ⇒ missingReason 为空。
    # （注意 is_renderable 为真≠无错误：R-D/R-A/R-C 轴对可渲染项仍合法报错。）
    if any("互斥" in e for e in errs):
        assert not is_renderable(rp, mr)
    if rp not in (None, "") and not errs:
        assert mr in (None, "")
    # 不变量 2: renderedPath 非空且 missingReason 非空 ⇒ 必有互斥错误
    if rp not in (None, "") and mr not in (None, ""):
        assert any("互斥" in e for e in errs)
    # 不变量 3: 错误数量 ≤ 4
    assert len(errs) <= 4
    # 不变量 4: renderedPath 非空且无错误 ⇒ file_exists 必须为 True（R-A）
    if rp not in (None, "") and not errs:
        assert fe


# ---- 确定性用例（每个契约规则一个，含边界）----

def test_det_rb_mutual_exclusion():
    """R-B: renderedPath 与 missingReason 非空 → 互斥错误（独立轴，最优先）。"""
    errs = check_rendered_path_contract("icons/a.png", "icons_not_rendered", True, True)
    assert any("互斥" in e for e in errs)


def test_det_rd_format_illegal():
    """R-D: 缺 icons/ 前缀或非 .png 结尾 → 格式非法错误。"""
    errs = check_rendered_path_contract("x.png", None, True, True)
    assert any("格式非法" in e for e in errs)
    errs = check_rendered_path_contract("icons/x.jpg", None, True, True)
    assert any("格式非法" in e for e in errs)


def test_det_ra_file_missing():
    """R-A: 文件不存在 → 错误含"不存在"。"""
    errs = check_rendered_path_contract("icons/a.png", None, False, True)
    assert any("不存在" in e for e in errs)


def test_det_rc_unregistered():
    """R-C: 文件存在但未登记 → 错误含"登记"。"""
    errs = check_rendered_path_contract("icons/a.png", None, True, False)
    assert any("登记" in e for e in errs)


def test_det_rc_skipped_when_registered_none():
    """R-C 跳过: registered=None（manifest 无 generatedFiles）→ 不报"登记"。"""
    assert check_rendered_path_contract("icons/a.png", None, True, None) == []


def test_det_valid_path_no_errors():
    """合法路径: icons/ 前缀 + .png + 文件存在 + 已登记 → 无错误。"""
    assert check_rendered_path_contract("icons/a.png", None, True, True) == []


def test_det_empty_path_no_errors():
    """renderedPath 为空（None 或 ""）→ 不触发任何契约错误。"""
    assert check_rendered_path_contract(None, "icons_not_rendered", False, False) == []
    assert check_rendered_path_contract("", "icons_not_rendered", False, False) == []


def test_det_is_renderable_truth_table():
    """is_renderable 真值表（对齐 Swift GameCatalogTests P2-2）。"""
    assert is_renderable("icons/barbarian.png", None)
    assert not is_renderable(None, None)
    assert not is_renderable("icons/barbarian.png", "icons_not_rendered")
    assert not is_renderable(None, "icons_not_rendered")
    # Swift 语义: 空字符串 ≠ nil → is_renderable 为真（契约 R-D 轴会另行校验格式）
    assert is_renderable("", None)
