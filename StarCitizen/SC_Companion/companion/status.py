"""Отдельные состояния двух модулей, без внешних запросов и чтения webhook key."""

import argparse
import json
import time

from companion.worker import load_configuration
from patch_alerts.scanner import read_json
from trader.diagnostics import read_status, status_path


def snapshot() -> dict:
    """Читает heartbeat торговца и новостей с их собственными критериями устаревания."""
    trader, news = load_configuration()
    try:
        trader_status = read_status(status_path(trader.data_dir, trader.mode))
    except (OSError, ValueError, TypeError) as exc:
        trader_status = {"state": "unavailable", "error_type": type(exc).__name__}
    news_status = {"state": "disabled"}
    if news.enabled:
        try:
            news_status = read_json(news.data_dir / "worker-status.json", {"state": "starting"})
            if time.time() - news_status.get("updated_at", 0) > max(180, news.poll_seconds * 3):
                news_status = {**news_status, "state": "stale"}
        except (OSError, ValueError, TypeError) as exc:
            news_status = {"state": "unavailable", "error_type": type(exc).__name__}
    return {"service": "SC Companion", "trader": trader_status, "patches": news_status}


def main() -> None:
    """Выводит JSON либо проверяет живость модулей; внешняя деградация не вызывает restart-loop."""
    parser = argparse.ArgumentParser(description="Состояния модулей SC Companion")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        value = snapshot()
    except (OSError, ValueError, TypeError) as exc:
        value = {"trader": {"state": "unavailable"}, "patches": {"state": "unavailable"}, "error_type": type(exc).__name__}
    if not args.check:
        print(json.dumps(value, ensure_ascii=False, indent=2))
    alive = value["trader"]["state"] in {"ok", "degraded"} and value["patches"]["state"] in {"ok", "degraded", "disabled"}
    raise SystemExit(0 if alive else 1)


if __name__ == "__main__":
    main()
