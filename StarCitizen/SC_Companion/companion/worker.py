"""Один процесс: прежний торговый worker и отдельный новостной поток."""

import argparse
import asyncio
import contextlib
import json
import logging
import os
import time
from pathlib import Path

from patch_alerts.config import NewsSettings
from patch_alerts.worker import NewsWorker
from trader.config import Settings
from trader.runtime import configure_logging
from trader.worker import run as run_trader

LOGGER = logging.getLogger(__name__)


def load_operator_environment(path: Path) -> None:
    """Загружает прежний закрытый JSON path с TRADER_*/TZ переменными без вывода значений."""
    if path.stat().st_size > 65536:
        raise ValueError("operator_config_too_large")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in value.items()):
        raise ValueError("invalid_operator_config")
    path.chmod(0o600)
    os.environ.update(value)
    if hasattr(time, "tzset"):
        time.tzset()


def load_configuration() -> tuple[Settings, NewsSettings]:
    """Сохраняет operator-config/environment контракт и читает отдельный news config при наличии."""
    operator_path = Path(os.getenv("SC_COMPANION_OPERATOR_CONFIG_FILE", "operator-config.json"))
    if operator_path.exists() or "SC_COMPANION_OPERATOR_CONFIG_FILE" in os.environ:
        load_operator_environment(operator_path)
    trader = Settings.from_env()
    news_path = Path(os.getenv("SC_PATCHES_CONFIG_FILE", "patches-config.json"))
    news = NewsSettings.from_file(news_path.resolve()) if news_path.exists() else NewsSettings()
    if "SC_PATCHES_CONFIG_FILE" in os.environ and not news_path.exists():
        raise ValueError("news_config_missing")
    if news.enabled and news.data_dir == trader.data_dir.resolve():
        raise ValueError("module_data_directories_must_differ")
    return trader, news


def prepare_data(data_dir: Path) -> None:
    """Сохраняет прежний контракт прав каталога торговца, не читая его содержимое."""
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    for path in [data_dir, *data_dir.rglob("*")]:
        path.chmod(0o700 if path.is_dir() else 0o600)


def run_service(trader: Settings, news: NewsSettings) -> None:
    """Запускает неизменённый trader.run с news-потоком и закрывает оба при его выходе."""
    prepare_data(trader.data_dir)
    manager = NewsWorker(news) if news.enabled else contextlib.nullcontext()
    LOGGER.info("SC Companion запускается trader_mode=%s patches=%s", trader.mode, "enabled" if news.enabled else "disabled")
    with manager:
        asyncio.run(run_trader(trader))


def main() -> None:
    """Запускает стандартный worker с прежними секретами и опциональными новостями."""
    os.umask(0o077)
    configure_logging()
    parser = argparse.ArgumentParser(description="SC Companion: общий процесс торговца и новостей")
    parser.add_argument("--check", action="store_true", help="Проверить конфигурацию без запуска")
    if parser.parse_args().check:
        check()
        return
    try:
        run_service(*load_configuration())
    except (OSError, ValueError, RuntimeError) as exc:
        LOGGER.error("SC Companion не запущен или завершился error_type=%s", type(exc).__name__)
        raise SystemExit(1) from None


def check() -> None:
    """Проверяет конфигурацию/импорты без Gateway, сети и изменения рабочих данных."""
    configure_logging()
    try:
        trader, news = load_configuration()
        if news.enabled:
            news.target()
        print(json.dumps({"state": "config_valid", "trader_mode": trader.mode,
                          "patches_enabled": news.enabled, "one_gateway_bot": True}))
    except (OSError, ValueError) as exc:
        LOGGER.error("Конфигурация не принята error_type=%s", type(exc).__name__)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
