import pytest

from game_catalog.durations import parse_duration, parse_optional_int


def test_parse_duration_full_dhms():
    # 1天2小时3分4秒
    sec, reason = parse_duration(
        {"D": "1", "H": "2", "M": "3", "S": "4"}, ("D", "H", "M", "S"))
    assert sec == 93784
    assert reason is None


def test_parse_duration_partial_columns_default_zero():
    # H=1, M 为空 → 3600
    sec, reason = parse_duration({"H": "1", "M": ""}, ("H", "M"))
    assert sec == 3600
    assert reason is None


def test_parse_duration_all_empty_is_missing():
    sec, reason = parse_duration({"H": "", "M": ""}, ("H", "M"))
    assert sec is None
    assert reason == "time_missing"


def test_parse_duration_zero_is_zero_not_missing():
    sec, reason = parse_duration({"D": "0", "H": "0", "M": "0", "S": "0"}, ("D", "H", "M", "S"))
    assert sec == 0
    assert reason is None


def test_parse_duration_garbage_is_invalid():
    sec, reason = parse_duration({"H": "abc", "M": ""}, ("H", "M"))
    assert sec is None
    assert reason == "time_invalid"


def test_parse_duration_negative_raises():
    with pytest.raises(Exception):
        parse_duration({"H": "-1", "M": ""}, ("H", "M"))


def test_parse_optional_int():
    assert parse_optional_int("") is None
    assert parse_optional_int("0") == 0
    assert parse_optional_int("250") == 250
    assert parse_optional_int("abc") is None
