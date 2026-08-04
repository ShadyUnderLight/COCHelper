from game_catalog.names import clean_name, display_name


def test_clean_name():
    assert clean_name("A\\qB\\nC ") == "AB C"


def test_display_name_tid_hit():
    assert display_name("TID_X", "Fallback", {"TID_X": "中文"}) == "中文"


def test_display_name_fallback():
    assert display_name("TID_MISSING", "Barbarian", {"TID_X": "中文"}) == "Barbarian"
