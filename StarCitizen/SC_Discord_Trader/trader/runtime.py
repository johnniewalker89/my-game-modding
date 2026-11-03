"""Общий жизненный цикл торгового сервиса для HTTP-стенда и отдельного бота."""

import asyncio
import logging
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import AsyncIterator, Callable

import httpx

from trader.config import Settings
from trader.discord_bot import TraderBot
from trader.discord_health import DiscordHttpErrorFilter, ERROR_WINDOW_SECONDS
from trader.diagnostics import status_path, write_status
from trader.listings import ListingService
from trader.marketplace import DemoMarketplace, MarketError, UexMarketplace
from trader.service import DemoSink, TraderService
from trader.store import Store, Vault
from trader.translation import Translator

# Категория существующих эксплуатационных сообщений сохраняется после переноса.
LOGGER = logging.getLogger("trader.app")
POLL_SECONDS = 10
STATUS_SECONDS = 60


@dataclass
class TraderRuntime:
    """Даёт вызывающему сервис и Discord-клиент без владения их ресурсами."""

    service: TraderService
    bot: TraderBot | None
    discord_task: asyncio.Task | None = None
    background_tasks: tuple[asyncio.Task, ...] = ()
    status_provider: Callable[[], dict] | None = None


def configure_logging() -> None:
    """Настраивает журнал и сокращает HTTP-ошибки SDK без HTML и адресов токенов."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("discord.client").setLevel(logging.WARNING)
    logging.getLogger("discord.gateway").setLevel(logging.WARNING)
    for handler in logging.getLogger().handlers:
        if not any(isinstance(item, DiscordHttpErrorFilter) for item in handler.filters):
            handler.addFilter(DiscordHttpErrorFilter())


@asynccontextmanager
async def open_runtime(settings: Settings, *, http_transport: httpx.AsyncBaseTransport | None = None
                       ) -> AsyncIterator[TraderRuntime]:
    """Открывает состояние и фоновые задачи; settings и необязательный транспорт задаёт вызывающий."""
    store = Store(settings.data_dir / f"trader-{settings.mode}.sqlite3")
    vault = Vault(settings.data_dir / "master.key")
    started_at = time.time()
    ready_seen = settings.mode == "demo"
    cleanup_at = None
    cleanup_error = None
    report_path = status_path(settings.data_dir, settings.mode)
    async with httpx.AsyncClient(timeout=90, transport=http_transport) as client:
        translator = Translator(client, settings.translator, settings.translate_url,
                                settings.azure_key, settings.azure_region,
                                groq_key=settings.groq_key, groq_model=settings.groq_model)
        bot = TraderBot(settings, store) if settings.mode == "live" else None
        market = UexMarketplace(client, settings.uex_app_token, settings.send_mode,
                                catalog_store=store) if bot else DemoMarketplace(store)
        service = TraderService(store, vault, market, translator, bot or DemoSink())
        if bot:
            bot.service = service
            bot.listings = ListingService(service, settings.listing_mode)
        else:
            for owner in ("demo-1", "demo-2"):
                if not store.get("account", owner):
                    await service.connect(owner, "local-demo-key")

        async def run_discord() -> None:
            """Подключает бота и сохраняет безопасную причину отказа без токенов."""
            try:
                await bot.start(settings.discord_token)
            except Exception as exc:
                service.last_error = "Discord: " + type(exc).__name__
                LOGGER.error("Discord не запущен error_type=%s", type(exc).__name__)

        async def poll() -> None:
            """Сверяет аккаунты после готовности Discord с прежней паузой десять секунд."""
            nonlocal cleanup_at, cleanup_error
            next_cleanup = 0.0
            while True:
                if time.monotonic() >= next_cleanup:
                    next_cleanup = time.monotonic() + 86400
                    try:
                        messages, drafts = store.prune_expired(time.time())
                        cleanup_at, cleanup_error = time.time(), None
                        if messages or drafts:
                            LOGGER.info("Локальная очистка завершена texts=%s drafts=%s", messages, drafts)
                    except Exception as exc:
                        cleanup_error = type(exc).__name__
                        LOGGER.warning("Локальная очистка не выполнена error_type=%s", type(exc).__name__)
                if bot and not bot.is_ready():
                    await asyncio.sleep(2)
                    continue
                for account in store.all("account"):
                    if not account.get("secret"):
                        continue
                    try:
                        await service.scan(account["owner_id"])
                    except PermissionError:
                        continue
                    except Exception as exc:
                        if isinstance(exc, MarketError) and str(exc) in {"requests_limit_reached", "uex_http_429"}:
                            service.last_error = "UEX: requests_limit_reached"
                            LOGGER.warning("UEX ограничил запросы: квота приложения owner=%s; следующая попытка при сверке", account["owner_id"])
                        else:
                            service.last_error = type(exc).__name__
                            LOGGER.error("Сверка не выполнена owner=%s error_type=%s", account["owner_id"], type(exc).__name__)
                await asyncio.sleep(POLL_SECONDS)

        tasks = [asyncio.create_task(poll(), name="uex-poll")]
        discord_task = None
        if bot:
            discord_task = asyncio.create_task(run_discord(), name="discord")
            tasks.append(discord_task)

            async def refresh_catalog() -> None:
                """Обновляет общий справочник, не блокируя Discord и личные переписки."""
                while True:
                    try:
                        await bot.listings.prepare_catalog()
                    except Exception as exc:
                        LOGGER.warning("Каталог UEX не обновлён error_type=%s", type(exc).__name__)
                        delay = 300
                    else:
                        delay = 3600
                    await asyncio.sleep(delay)

            tasks.append(asyncio.create_task(refresh_catalog(), name="catalog"))

            if settings.hosting_reminder_user_id:
                async def remind_hosting() -> None:
                    """Проверяет срок раз в минуту, не задерживая сверки и heartbeat отправкой DM."""
                    while True:
                        await bot.remind_hosting()
                        await asyncio.sleep(STATUS_SECONDS)

                tasks.append(asyncio.create_task(remind_hosting(), name="hosting-reminder"))

        def snapshot() -> dict:
            """Собирает техническое состояние из памяти; не делает внешних запросов."""
            nonlocal ready_seen
            now = time.time()
            connected = bool(bot and bot.is_ready())
            ready_seen = ready_seen or connected
            scans = service.diagnostics()
            discord_http = bot.http_health.snapshot() if bot else None
            http_error = discord_http["last_error"] if discord_http else None
            recent_http_error = http_error and now - http_error["at"] < ERROR_WINDOW_SECONDS
            oldest = scans["uex_oldest_success_at"]
            pending = scans["uex_checked"] < scans["uex_accounts"]
            stale_scan = bool(oldest and now - oldest > 300)
            degraded = (bool(scans["uex_errors"]) or pending or stale_scan or cleanup_error
                        or (bot is not None and not connected) or recent_http_error)
            state = "ok"
            if any(task.done() for task in tasks):
                state = "failed"
            elif not ready_seen:
                state = "starting"
            elif degraded:
                state = "degraded"
            return {"schema_version": 1, "mode": settings.mode, "state": state,
                    "started_at": started_at, "updated_at": now, "discord_connected": connected,
                    "translator": settings.translator, "poll_interval_seconds": POLL_SECONDS,
                    "discord_http": discord_http,
                    "cleanup_at": cleanup_at, "cleanup_error": cleanup_error, **scans}

        if bot:
            bot.status_provider = snapshot
        try:
            write_status(report_path, snapshot())
        except OSError as exc:
            LOGGER.warning("Начальное состояние не сохранено error_type=%s", type(exc).__name__)

        async def report_status() -> None:
            """Раз в минуту обновляет heartbeat; пишет лог только при смене состояния или ошибок."""
            previous = None
            while True:
                await asyncio.sleep(STATUS_SECONDS)
                current = snapshot()
                try:
                    write_status(report_path, current)
                except OSError as exc:
                    LOGGER.warning("Файл состояния не обновлён error_type=%s", type(exc).__name__)
                    continue
                signature = (current["state"], current["discord_connected"], tuple(current["uex_errors"]))
                if signature != previous:
                    LOGGER.info("Состояние сервиса state=%s discord=%s uex_checked=%s/%s errors=%s", current["state"], current["discord_connected"], current["uex_checked"], current["uex_accounts"], ",".join(current["uex_errors"]) or "none")
                    previous = signature

        tasks.append(asyncio.create_task(report_status(), name="status"))
        LOGGER.info("Сервис инициализирован mode=%s translator=%s poll_seconds=%s", settings.mode, settings.translator, POLL_SECONDS)
        failed_exit = False
        try:
            yield TraderRuntime(service, bot, discord_task, tuple(tasks), snapshot)
        except Exception:
            failed_exit = True
            raise
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            try:
                if bot:
                    await bot.close()
            finally:
                try:
                    write_status(report_path, {**snapshot(), "state": "failed" if failed_exit else "stopped"})
                except OSError as exc:
                    LOGGER.warning("Финальное состояние не сохранено error_type=%s", type(exc).__name__)
                finally:
                    store.close()
