"""Общие сценарии обмена: владельцы, перевод, дедупликация и подтверждённая доставка."""

import asyncio
import hashlib
import logging
import time
from contextlib import asynccontextmanager
from typing import Any, Protocol

from trader.marketplace import DemoMarketplace, MarketError, UexMarketplace
from trader.store import Store, Vault
from trader.translation import TranslationError, Translator

LOGGER = logging.getLogger(__name__)


class Sink(Protocol):
    """Определяет личную доставку; только пустой фоновый опрос допускает кеш роли."""

    async def allowed(self, owner_id: str, *, refresh: bool = True) -> bool:
        """Проверяет право owner_id; refresh=False допускает короткий кеш для фоновой сверки."""
        ...

    async def thread(self, deal: dict[str, Any]) -> str:
        """Возвращает существующую или создаёт приватную ветку сделки."""
        ...

    async def incoming(self, deal: dict[str, Any], message: dict[str, Any]) -> str:
        """Публикует перевод в подготовленную ветку deal и возвращает подтверждённый id сообщения."""
        ...

    async def archive(self, deal: dict[str, Any], *, locked: bool = True) -> None:
        """Архивирует ветку; locked блокирует завершённую сделку, False оставляет паузу."""
        ...

    async def restore(self, deal: dict[str, Any]) -> None:
        """Возвращает существующую незаблокированную ветку из личного архива."""
        ...


class DemoSink:
    """Представляет личные ветки в локальном стенде без отправок в Discord."""

    async def allowed(self, owner_id: str, *, refresh: bool = True) -> bool:
        """Разрешает два тестовых аккаунта; refresh сохраняет контракт живого адаптера."""
        return owner_id in {"demo-1", "demo-2"}

    async def thread(self, deal: dict[str, Any]) -> str:
        """Назначает устойчивый идентификатор тестовой ветки."""
        return f"demo-{deal['id']}"

    async def incoming(self, deal: dict[str, Any], message: dict[str, Any]) -> str:
        """Подтверждает локальное представление сообщения, не вызывая Discord API."""
        return f"demo-{message['id']}"

    async def archive(self, deal: dict[str, Any], *, locked: bool = True) -> None:
        """Завершает сценарий архива в локальном стенде."""
        return None

    async def restore(self, deal: dict[str, Any]) -> None:
        """Возвращает существующее локальное представление без внешних отправок."""
        return None


def stable_id(*parts: str) -> str:
    """Строит устойчивый ключ операции из владельца, сделки и внешнего id."""
    return hashlib.sha256("\x00".join(parts).encode()).hexdigest()[:32]


def owner_trade_type(advertiser: bool, operation: str | None) -> str | None:
    """Отражает намерение самого игрока, учитывая WTB-объявления и обмен."""
    if operation == "buy":
        return "WTB" if advertiser else "WTS"
    if operation == "sell":
        return "WTS" if advertiser else "WTB"
    return {"trade": "WTT", "rent": "WTR"}.get(operation)


class TraderService:
    """Оркестрирует одну площадку без хранения секретов в сообщениях и логах."""

    def __init__(self, store: Store, vault: Vault,
                 market: UexMarketplace | DemoMarketplace, translator: Translator, sink: Sink):
        """Связывает постоянное состояние, площадку, переводчик и личные ветки."""
        self.store, self.vault, self.market = store, vault, market
        self.translator, self.sink = translator, sink
        self._deal_locks: dict[str, asyncio.Lock] = {}
        self._scan_locks: dict[str, asyncio.Lock] = {}
        self.last_error: str | None = None
        self.scan_status: dict[str, dict[str, Any]] = {}
        for message in store.all("message"):
            if message["status"] == "sending":
                message["status"] = "unknown"
                store.put("message", message)

    async def account(self, owner_id: str, *, refresh_access: bool = True) -> dict[str, Any]:
        """Проверяет подключение и роль; refresh_access=False разрешён только для фонового чтения."""
        if not await self.sink.allowed(owner_id, refresh=refresh_access):
            raise PermissionError("Нет разрешённой роли на сервере")
        account = self.store.get("account", owner_id)
        if (not account or not account.get("secret")
                or (isinstance(self.market, UexMarketplace) and not account.get("app_token"))):
            raise PermissionError("Подключи свой аккаунт UEX с двумя ключами")
        return account

    def market_for(self, account: dict[str, Any]) -> UexMarketplace | DemoMarketplace:
        """Выбирает личное приложение уже проверенного account; демо сохраняет локальную площадку."""
        if isinstance(self.market, UexMarketplace):
            return self.market.for_app_token(self.vault.decrypt(account["app_token"]))
        return self.market

    async def connect(self, owner_id: str, secret: str, app_token: str = "") -> str:
        """Проверяет и шифрует оба заново введённых ключа, сохраняя историю того же аккаунта."""
        if not await self.sink.allowed(owner_id):
            raise PermissionError("Нет разрешённой роли на сервере")
        old = self.store.get("account", owner_id)
        secret, app_token = secret.strip(), app_token.strip()
        if not secret:
            raise ValueError("Нужен личный Secret Key UEX")
        if isinstance(self.market, UexMarketplace) and not app_token:
            raise ValueError("Нужен токен личного API-приложения UEX")
        market = self.market.for_app_token(app_token) if isinstance(self.market, UexMarketplace) else self.market
        username = await market.profile(secret)
        if not await self.sink.allowed(owner_id):
            raise PermissionError("Роль участника снята")
        since = old["since"] if old and old["username"] == username else time.time()
        self.store.put("account", {"id": owner_id, "owner_id": owner_id,
                                   "username": username, "secret": self.vault.encrypt(secret),
                                   "app_token": self.vault.encrypt(app_token) if app_token else None,
                                   "since": since})
        self.scan_status.pop(owner_id, None)
        LOGGER.info("Аккаунт подключён owner=%s personal_app=%s", owner_id, bool(app_token))
        return username

    def disconnect(self, owner_id: str) -> None:
        """Удаляет оба сохранённых ключа, оставляя историю владельца."""
        account = self.store.get("account", owner_id)
        if account:
            account["secret"] = None
            account["app_token"] = None
            self.store.put("account", account)

    async def deal(self, owner_id: str, deal_id: str) -> dict[str, Any]:
        """Не допускает чужую сделку или отправку через сменившийся аккаунт UEX."""
        account = await self.account(owner_id)
        deal = self.store.get("deal", deal_id)
        if not deal or deal["owner_id"] != owner_id or deal["account"] != account["username"]:
            raise PermissionError("Эта сделка не принадлежит подключённому аккаунту")
        return deal

    async def open_thread(self, owner_id: str, deal_id: str) -> dict[str, Any]:
        """Создаёт или открывает свою актуальную ветку, сохраняя ручной архив при навигации."""
        async with self._deal_locks.setdefault(deal_id, asyncio.Lock()):
            deal = await self.deal(owner_id, deal_id)
            if deal.get("current") is not True or deal["own_closed"] or deal["peer_closed"]:
                raise PermissionError("Эта сделка больше не актуальна. Обнови «Мои сделки».")
            if deal.get("paused") and deal.get("thread_id"):
                return deal
            deal["thread_id"] = await self.sink.thread(deal)
            self.store.put("deal", deal)
            return deal

    async def archive_thread(self, owner_id: str, deal_id: str, thread_id: str) -> None:
        """Убирает свою ветку до нового входящего, не обращаясь к UEX и его ключу."""
        async with self._deal_locks.setdefault(deal_id, asyncio.Lock()):
            if not await self.sink.allowed(owner_id):
                raise PermissionError("Нет разрешённой роли на сервере")
            deal = self.store.get("deal", deal_id)
            if not deal or deal["owner_id"] != owner_id or deal.get("thread_id") != thread_id:
                raise PermissionError("Это не твоя ветка сделки")
            if deal["own_closed"] or deal["peer_closed"]:
                raise ValueError("Завершённая сделка архивируется автоматически")
            await self.sink.archive(deal, locked=False)
            deal["paused"] = True
            self.store.put("deal", deal)
            LOGGER.info("Ветка убрана в архив владельцем deal=%s owner=%s", deal_id, owner_id)

    async def restore_thread(self, owner_id: str, deal_id: str) -> dict[str, Any]:
        """Явно возвращает свою действующую переписку, не создавая новую ветку."""
        async with self._deal_locks.setdefault(deal_id, asyncio.Lock()):
            deal = await self.deal(owner_id, deal_id)
            if deal.get("current") is not True or deal["own_closed"] or deal["peer_closed"]:
                raise PermissionError("Эта сделка больше не актуальна. Обнови «Мои сделки».")
            if not deal.get("thread_id"):
                raise ValueError("Ветка ещё не создана. Она появится при новом входящем с UEX.")
            await self.sink.restore(deal)
            deal["paused"] = False
            self.store.put("deal", deal)
            LOGGER.info("Ветка возвращена из архива владельцем deal=%s owner=%s", deal_id, owner_id)
            return deal

    async def original(self, owner_id: str, message_id: str) -> str:
        """Возвращает оригинал своего сообщения; после TTL читает UEX без перевода и записи текста на диск."""
        record = self.store.get("message", message_id)
        if not record or record["owner_id"] != owner_id:
            raise PermissionError("Это не твоя переписка.")
        account = await self.account(owner_id)
        deal = self.store.get("deal", record["deal_id"])
        if not deal or deal["owner_id"] != owner_id or deal["account"] != account["username"]:
            raise PermissionError("Эта сделка не принадлежит подключённому аккаунту")
        if "original" in record:
            return record["original"]
        if record["source"] != "incoming":
            raise ValueError("Оригинал больше не хранится локально.")
        rows = await self.market_for(account).messages(
            account, self.vault.decrypt(account["secret"]), deal["external_id"])
        await self.deal(owner_id, deal["id"])
        remote = next((row for row in rows if str(row["id"]) == record["external_id"]), None)
        if not remote or not isinstance(remote.get("message"), str) or not remote["message"]:
            raise ValueError("Срок локального хранения истёк, UEX больше не отдаёт оригинал.")
        return remote["message"]

    def is_scanning(self, owner_id: str) -> bool:
        """Сообщает интерфейсу о текущей автоматической загрузке своего аккаунта."""
        lock = self._scan_locks.get(owner_id)
        return bool(lock and lock.locked())

    @asynccontextmanager
    async def _observe_scan(self, owner_id: str):
        """Запоминает исход реальной сверки owner_id без текста ошибок или пользовательских данных."""
        state = self.scan_status.setdefault(owner_id, {})
        try:
            yield
        except Exception as exc:
            quota = isinstance(exc, MarketError) and str(exc) in {"requests_limit_reached", "uex_http_429"}
            state["error"] = "requests_limit_reached" if quota else type(exc).__name__
            raise
        else:
            state["success_at"] = time.time()
            state["error"] = "listing_status_unavailable" if self.last_error == "UEX: listing_status_unavailable" else None

    def diagnostics(self) -> dict[str, Any]:
        """Возвращает только агрегаты подключений и сверок; не раскрывает владельцев, ключи и тексты."""
        owners = [row["owner_id"] for row in self.store.all("account") if row.get("secret")]
        states = [self.scan_status.get(owner, {}) for owner in owners]
        successes = [state["success_at"] for state in states if state.get("success_at")]
        return {"uex_accounts": len(owners), "uex_checked": len(successes),
                "uex_oldest_success_at": min(successes) if successes else None,
                "uex_errors": sorted({state["error"] for state in states if state.get("error")})}

    async def current_deals(self, owner_id: str) -> list[dict[str, Any]]:
        """Показывает свои открытые переписки с историей, исключая пустые записи UEX."""
        account = await self.account(owner_id)
        conversations = {message["deal_id"] for message in self.store.all("message", owner_id)}
        deals = [deal for deal in self.store.all("deal", owner_id)
                 if deal["account"] == account["username"] and deal.get("current") is True
                 and not deal["own_closed"] and not deal["peer_closed"]
                 and (deal.get("thread_id") or deal["id"] in conversations)]
        return sorted(deals, key=lambda deal: -float(deal["modified"] or 0))

    async def scan(self, owner_id: str, *, force: bool = False) -> int:
        """Сверяет сделки аккаунта; даты оптимизируют чтение, полная сверка — раз в 10 минут."""
        lock = self._scan_locks.setdefault(owner_id, asyncio.Lock())
        if lock.locked():
            return 0
        async with lock, self._observe_scan(owner_id):
            account = await self.account(owner_id, refresh_access=force)
            secret = self.vault.decrypt(account["secret"])
            market = self.market_for(account)
            rows = await market.negotiations(account, secret)
            processed = 0
            unknown_listing_status = False
            listing_visibility: dict[str, bool | None] = {}
            for row in rows:
                external_id = str(row["id"])
                deal_id = stable_id(owner_id, account["username"], external_id)
                async with self._deal_locks.setdefault(deal_id, asyncio.Lock()):
                    old = self.store.get("deal", deal_id) or {}
                    advertiser = bool(row["is_listing_advertiser"])
                    own_closed = bool(row.get("date_closed") if advertiser else row.get("date_closed_client"))
                    peer_closed = bool(row.get("date_closed_client") if advertiser else row.get("date_closed"))
                    closed = own_closed or peer_closed
                    listing_id = str(row["id_listing"])
                    current = False
                    if not own_closed and not peer_closed:
                        if listing_id not in listing_visibility:
                            try:
                                listing_visibility[listing_id] = await market.listing_active(listing_id, refresh=force)
                            except MarketError:
                                listing_visibility[listing_id] = None
                        current = listing_visibility[listing_id]
                        if current is None:
                            unknown_listing_status = True
                            LOGGER.warning("Не проверена актуальность объявления deal=%s", deal_id)
                    operation = market.listing_operation(listing_id) or old.get("listing_operation")
                    trade_type = owner_trade_type(advertiser, operation)
                    direction = {"WTB": "buy", "WTS": "sell", "WTT": "trade", "WTR": "rent"}.get(trade_type)
                    deal = {**old, "id": deal_id, "owner_id": owner_id, "account": account["username"],
                            "external_id": external_id, "listing_id": str(row["id_listing"]),
                            "negotiation_hash": row.get("hash", old.get("negotiation_hash")),
                            "listing_slug": row.get("listing_slug", old.get("listing_slug")),
                            "listing_operation": operation, "trade_type": trade_type,
                            "quality": market.listing_quality(listing_id) if current is True else old.get("quality"),
                            "price": market.listing_price(listing_id) if current is True else old.get("price"),
                            "current": current, "title": row["listing_title"],
                            "peer": row["client_username"] if advertiser else row["advertiser_username"],
                            "direction": direction or old.get("direction", "unknown"),
                            "own_closed": own_closed, "peer_closed": peer_closed,
                            "modified": row.get("date_modified", 0)}
                    if closed:
                        deal.setdefault("closed_at", time.time())
                    else:
                        deal.pop("closed_at", None)
                    self.store.put("deal", deal)
                    if closed and old.get("archived"):
                        continue
                    stale = time.time() - old.get("checked_at", 0) >= 600
                    recent_empty = (current is True and not old.get("thread_id")
                                    and row.get("date_added", 0) > account["since"]
                                    and time.time() - row["date_added"] < 600)
                    newly_closed = closed and not (old.get("own_closed") or old.get("peer_closed"))
                    needs_archive = closed and deal.get("thread_id") and not old.get("archived")
                    if not (force or stale or recent_empty or newly_closed or needs_archive or old.get("modified") != deal["modified"]):
                        continue
                    messages = await market.messages(account, secret, external_id)
                    sent_remote_ids = {str(message["remote_id"]) for message in self.store.all("message", owner_id)
                                       if message["deal_id"] == deal_id and message["source"] == "outgoing"
                                       and message.get("remote_id")}
                    for item in sorted(messages, key=lambda m: (m.get("date_added", 0), str(m["id"]))):
                        processed += await self._incoming(account, deal, item, sent_remote_ids)
                    deal["checked_at"] = time.time()
                    if closed and deal.get("thread_id"):
                        awaiting_delivery = sum(
                            message["deal_id"] == deal_id and message["source"] == "incoming"
                            and message["status"] in {"pending", "translation_failed"}
                            for message in self.store.all("message", owner_id))
                        if awaiting_delivery:
                            LOGGER.warning("Архив отложен: ожидает доставки входящих deal=%s count=%s", deal_id, awaiting_delivery)
                        else:
                            await self.sink.archive(deal)
                            deal["archived"] = True
                            deal["paused"] = False
                    self.store.put("deal", deal)
            self.last_error = "UEX: listing_status_unavailable" if unknown_listing_status else None
            return processed

    async def _incoming(self, account: dict[str, Any], deal: dict[str, Any],
                        remote: dict[str, Any], sent_remote_ids: set[str]) -> int:
        """Переносит сообщение UEX; sent_remote_ids исключает эхо ответов, отправленных ботом."""
        if remote.get("event") or not remote.get("message"):
            return 0
        message_id = stable_id(deal["id"], "incoming", str(remote["id"]))
        record = self.store.get("message", message_id)
        from_self = remote.get("user_username") == account["username"]
        skip = (remote.get("date_added", 0) <= account["since"]
                or (from_self and str(remote["id"]) in sent_remote_ids))
        recover_own = (record and not record.get("text_purged_at")
                       and record["status"] == "baseline" and from_self and not skip)
        if record and record["status"] not in {"pending", "translation_failed"} and not recover_own:
            return 0
        if not record:
            record = {"id": message_id, "owner_id": account["owner_id"], "deal_id": deal["id"],
                      "source": "incoming", "external_id": str(remote["id"]),
                      "sender": remote.get("user_username"),
                      "original": remote["message"], "translated": "", "created_at": remote.get("date_added", 0),
                      "status": "baseline" if skip else "pending"}
            self.store.put("message", record, new_only=True)
        if skip:
            return 0
        if not remote.get("user_username"):
            raise MarketError("uex_missing_sender")
        record["sender"] = remote["user_username"]
        if recover_own:
            record["status"] = "pending"
            self.store.put("message", record)
        try:
            record["translated"] = await self.translator.translate(
                record["original"], "en", "ru", (deal["title"], deal["peer"]),
                context={"item": deal["title"], "quality": deal.get("quality"),
                         "player_action": deal.get("trade_type")})
        except TranslationError as exc:
            record["status"] = "translation_failed"
            self.store.put("message", record)
            LOGGER.warning("Перевод входящего недоступен message=%s reason=%s", record["id"], exc.code)
            return 0
        current = await self.account(account["owner_id"])
        if current["username"] != deal["account"]:
            raise PermissionError("Подключён другой аккаунт UEX")
        deal["thread_id"] = await self.sink.thread(deal)
        deal["paused"] = False
        self.store.put("deal", deal)
        record["status"] = "sending"
        self.store.put("message", record)
        try:
            record["display_id"] = await self.sink.incoming(deal, record)
        except Exception:
            record["status"] = "unknown"
            self.store.put("message", record)
            LOGGER.error("Результат доставки в Discord неизвестен message=%s; автоповтор отключён", record["id"])
            raise
        record["status"] = "delivered"
        self.store.put("message", record)
        LOGGER.info("Входящее доставлено deal=%s message=%s", deal["id"], record["id"])
        return 1

    async def reply(self, owner_id: str, deal_id: str, external_id: str, text: str) -> dict[str, Any]:
        """Переводит русский ответ и выполняет одну отправку, сохраняя неопределённый исход."""
        if not text.strip() or len(text) > 2000:
            raise ValueError("Ответ должен содержать от 1 до 2000 символов")
        async with self._deal_locks.setdefault(deal_id, asyncio.Lock()):
            deal = await self.deal(owner_id, deal_id)
            if deal["own_closed"] or deal["peer_closed"]:
                raise ValueError("Сделка уже завершена тобой или собеседником")
            message_id = stable_id(deal_id, "outgoing", external_id)
            existing = self.store.get("message", message_id)
            if existing:
                return existing
            record = {"id": message_id, "owner_id": owner_id, "deal_id": deal_id,
                      "source": "outgoing", "external_id": external_id, "original": text,
                      "translated": "", "created_at": time.time(), "status": "pending"}
            self.store.put("message", record, new_only=True)
            try:
                record["translated"] = await self.translator.translate(text, "ru", "en",
                    (deal["title"], deal["peer"]), context={"item": deal["title"],
                    "quality": deal.get("quality"), "player_action": deal.get("trade_type")})
                account = await self.account(owner_id)
                if account["username"] != deal["account"]:
                    raise PermissionError("Подключён другой аккаунт UEX")
                record["status"] = "sending"
                self.store.put("message", record)
                record["remote_id"] = await self.market_for(account).send(account, self.vault.decrypt(account["secret"]),
                                                              deal["external_id"], record["translated"])
            except TranslationError as exc:
                record["status"] = "translation_failed"
                record["error"] = exc.code
                LOGGER.warning("Перевод исходящего не выполнен message=%s reason=%s", message_id, exc.code)
            except MarketError as exc:
                record["status"] = "unknown" if exc.uncertain else "failed"
                record["error"] = str(exc)
            except PermissionError:
                record["status"] = "failed"
                record["error"] = "access_changed"
            else:
                record["status"] = "delivered"
                deal["paused"] = False
                self.store.put("deal", deal)
            self.store.put("message", record)
            LOGGER.info("Исходящее завершено message=%s status=%s", message_id, record["status"])
            return record
