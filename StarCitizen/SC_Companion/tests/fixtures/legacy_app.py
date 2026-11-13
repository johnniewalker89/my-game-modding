"""Загружает закрытый конфиг хостинга и запускает стандартный worker."""
import json
import os
import time
from pathlib import Path

config_path = Path("operator-config.json")
config_path.chmod(0o600)
os.environ.update(json.loads(config_path.read_text(encoding="utf-8")))
time.tzset()
data_dir = Path(os.environ["TRADER_DATA_DIR"])
for path in [data_dir, *data_dir.rglob("*")]:
    path.chmod(0o700 if path.is_dir() else 0o600)

from trader.worker import main
main()
