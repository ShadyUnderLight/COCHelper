"""中文名解析：TID → cn.csv；fallback 英文 Name。"""


def clean_name(value: str) -> str:
    return value.replace("\\q", "").replace("\\n", " ").strip()


def display_name(tid: str, fallback_name: str, localized: dict[str, str]) -> str:
    if tid:
        translated = localized.get(tid)
        if translated:
            return translated
    return clean_name(fallback_name)
