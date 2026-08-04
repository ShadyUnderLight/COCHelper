"""pytest 共享配置：确保 Tools/ 在 sys.path，供 game_catalog 包导入。"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
