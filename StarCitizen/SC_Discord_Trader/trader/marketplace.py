"""Документированный UEX API и отдельная локальная тестовая площадка."""

import asyncio
import hashlib
import logging
import re
import time
import uuid
from decimal import Decimal, InvalidOperation
from typing import Any

import httpx

from trader.store import Store

LOGGER = logging.getLogger(__name__)


def _price_fields(listing: dict[str, Any]) -> dict[str, str] | None:
    """Берёт цену за единицу из карточки; пропускает отсутствующие или некорректные значения."""
    raw = str(listing.get("price", ""))
    currency, unit = listing.get("currency"), listing.get("unit")
    if (len(raw) > 64 or not isinstance(currency, str) or not re.fullmatch(r"[A-Za-z]{2,8}", currency)
            or not isinstance(unit, str) or not re.fullmatch(r"[a-z]{1,12}", unit)):
        return None
    try:
        amount = Decimal(raw)
    except InvalidOperation:
        return None
    if not amount.is_finite() or amount < 0 or amount > Decimal("1e18") or (amount and amount < Decimal("0.000001")):
        return None
    return {"amount": str(amount), "currency": currency, "unit": unit}


class MarketError(Exception):
    """Передаёт безопасный код ошибки и неопределённость результата записи."""

    def __init__(self, code: str, *, uncertain: bool = False):
        """Помечает uncertain, если сообщение могло уйти несмотря на ошибку ответа."""
        super().__init__(code)
        self.uncertain = uncertain


class UexMarketplace:
    """Обращается к UEX от одного API-приложения с собственной очередью запросов."""

    def __init__(self, client: httpx.AsyncClient, app_token: str,
                 send_mode: str, interval: float = 1.0, *, catalog_store: Store | None = None):
        """Настраивает app_token, интервал запросов в секундах и режим is_production."""
        self.client = client
        self.app_token = app_token
        self.production = send_mode == "production"
        self.interval = interval
        self._rate_lock = asyncio.Lock()
        self._next_request = 0.0
        self._listing_cache: dict[str, tuple[float, bool]] = {}
        self._listing_operations: dict[str, str] = {}
        self._listing_qualities: dict[str, int | None] = {}
        self._listing_prices: dict[str, dict[str, str] | None] = {}
        self._catalog_cache: dict[tuple[str, int], tuple[float, list[dict[str, Any]]]] = {}
        self._catalog_store = catalog_store
        self._app_clients: dict[str, UexMarketplace] = {}

    def for_app_token(self, app_token: str) -> "UexMarketplace":
        """Возвращает клиент app_token со своей очередью; одинаковый токен использует одну очередь."""
        if app_token == self.app_token:
            return self
        key = hashlib.sha256(app_token.encode()).hexdigest()
        if key not in self._app_clients:
            self._app_clients[key] = UexMarketplace(
                self.client, app_token, "production" if self.production else "test",
                self.interval, catalog_store=self._catalog_store)
        return self._app_clients[key]

    async def _request(self, method: str, resource: str, secret: str | None,
                       **kwargs: Any) -> Any:
        """Ограничивает частоту; GET допускает повторы, POST автоматически не повторяет."""
        attempts = 3 if method == "GET" else 1
        for attempt in range(attempts):
            async with self._rate_lock:
                await asyncio.sleep(max(0, self._next_request - time.monotonic()))
                self._next_request = time.monotonic() + self.interval
            try:
                headers = {"Authorization": f"Bearer {self.app_token}"}
                if secret is not None:
                    headers["secret-key"] = secret
                response = await self.client.request(
                    method, f"https://api.uexcorp.uk/2.0/{resource}/",
                    headers=headers,
                    timeout=25, **kwargs,
                )
            except httpx.TransportError as exc:
                if method == "GET" and attempt + 1 < attempts:
                    LOGGER.warning("Повтор UEX resource=%s попытка=%s причина=network", resource, attempt + 2)
                    await asyncio.sleep(2 ** attempt)
                    continue
                raise MarketError("uex_network", uncertain=method in {"POST", "DELETE"}) from exc
            if method == "GET" and (response.status_code == 429 or response.status_code >= 500):
                if attempt + 1 < attempts:
                    LOGGER.warning("Повтор UEX resource=%s попытка=%s http=%s", resource, attempt + 2, response.status_code)
                    await asyncio.sleep(2 ** attempt)
                    continue
            # UEX реально возвращает 400/no_messages_found для пустой истории.
            # Это штатный пустой результат только этого GET, а не отказ авторизации.
            if method == "GET" and resource == "marketplace_negotiations_messages" and response.status_code == 400:
                try:
                    empty = response.json()
                except ValueError:
                    empty = None
                if isinstance(empty, dict) and empty.get("status") == "no_messages_found":
                    return []
            if not response.is_success:
                code = f"uex_http_{response.status_code}"
                try:
                    status = response.json().get("status")
                    if status in {"invalid_quality", "invalid_image_data", "image_data_exceeds_limit",
                                  "listing_already_added", "user_not_verified", "user_not_allowed",
                                  "invalid_secret_key", "listing_not_found", "user_active_listings_limit_reached"}:
                        code = status
                except (ValueError, AttributeError, TypeError):
                    pass
                raise MarketError(code, uncertain=method in {"POST", "DELETE"} and response.status_code >= 500)
            try:
                payload = response.json()
                status = payload["status"]
                if status == "no_messages_found":
                    return []
                if status != "ok":
                    safe_codes = {"invalid_secret_key", "missing_secret_key", "user_not_allowed",
                                  "user_not_found", "negotiation_closed", "negotiation_not_found",
                                  "requests_limit_reached", "listing_not_found"}
                    code = status if status in safe_codes else "uex_api_error"
                    raise MarketError(code)
                return payload["data"]
            except (ValueError, KeyError, TypeError) as exc:
                raise MarketError("uex_invalid_response", uncertain=method in {"POST", "DELETE"}) from exc
        raise MarketError("uex_retry_exhausted")

    async def profile(self, secret: str) -> str:
        """Проверяет личный ключ по GET user и возвращает только username."""
        data = await self._request("GET", "user", secret)
        if isinstance(data, list):
            data = data[0] if data else {}
        username = data.get("username") if isinstance(data, dict) else None
        if not isinstance(username, str) or not username:
            raise MarketError("uex_missing_username")
        return username

    async def catalog(self, category_id: int | None = None, *, refresh: bool = False) -> list[dict[str, Any]]:
        """Возвращает категории товаров либо товары выбранной категории, с кешем на сутки."""
        resource = "items" if category_id is not None else "categories"
        key = resource, category_id or 0
        cached = self._catalog_cache.get(key)
        if not refresh and cached and time.monotonic() - cached[0] < 86400:
            return cached[1]
        cache_id = f"uex:{resource}:{category_id or 0}"
        saved = self._catalog_store.get("catalog_cache", cache_id) if self._catalog_store else None
        if not refresh and saved and 0 <= time.time() - saved.get("cached_at", 0) < 86400:
            data = saved.get("data")
            if isinstance(data, list) and all(isinstance(row, dict) and "id" in row for row in data):
                self._catalog_cache[key] = time.monotonic() - (time.time() - saved["cached_at"]), data
                return data
        data = await self._request("GET", resource, None,
                                   params={"id_category": category_id} if category_id is not None else {})
        # UEX отвечает ok/data:null для существующих, но пустых категорий.
        if resource == "items" and data is None:
            data = []
        if not isinstance(data, list) or not all(isinstance(row, dict) and "id" in row for row in data):
            raise MarketError("uex_invalid_catalog")
        self._catalog_cache[key] = time.monotonic(), data
        if self._catalog_store:
            self._catalog_store.put("catalog_cache", {"id": cache_id, "owner_id": "uex-catalog",
                                      "cached_at": time.time(), "data": data})
        return data

    async def advertisements(self, username: str) -> list[dict[str, Any]]:
        """Читает до 100 активных карточек пользователя; скрытые/модерация не обещаются."""
        data = await self._request("GET", "marketplace_listings", None, params={"username": username})
        if data is False:
            return []
        if not isinstance(data, list) or not all(isinstance(row, dict) and "id" in row for row in data):
            raise MarketError("uex_invalid_listings")
        return data

    async def advertise(self, secret: str, payload: dict[str, Any], *, production: bool) -> dict[str, Any]:
        """Создаёт карточку один раз; режим объявлений независим от отправки сообщений."""
        data = await self._request("POST", "marketplace_advertise", secret,
                                   json={**payload, "is_production": int(production)})
        if not isinstance(data, dict):
            raise MarketError("uex_invalid_response", uncertain=True)
        remote_id = str(data.get("id_listing", ""))
        if not remote_id.isdecimal() or (production and (int(remote_id) <= 0 or data.get("test"))):
            raise MarketError("uex_invalid_response", uncertain=True)
        if not production and not data.get("test"):
            raise MarketError("uex_invalid_response", uncertain=True)
        return data

    async def remove_advertisement(self, secret: str, listing_id: str, *, production: bool) -> None:
        """Удаляет ровно одну выбранную карточку; DELETE при сбое не повторяется."""
        if not listing_id.isdecimal() or int(listing_id) <= 0:
            raise ValueError("Некорректный номер объявления")
        await self._request("DELETE", "marketplace_listings", secret,
                            params={"id": int(listing_id), "is_production": int(production)})

    async def negotiations(self, account: dict[str, Any], secret: str) -> list[dict[str, Any]]:
        """Возвращает все переговоры подключённого аккаунта без записи на UEX."""
        data = await self._request("GET", "marketplace_negotiations", secret)
        if not isinstance(data, list):
            raise MarketError("uex_invalid_negotiations")
        return data

    async def listing_active(self, listing_id: str, *, refresh: bool = False) -> bool:
        """Проверяет наличие объявления в активном каталоге, с общим кешем на 120 секунд."""
        cached = self._listing_cache.get(listing_id)
        if not refresh and cached and time.monotonic() - cached[0] < 120:
            return cached[1]
        data = await self._request("GET", "marketplace_listings", None, params={"id": listing_id})
        if data is False or data == []:
            active = False
        elif isinstance(data, dict) and str(data.get("id")) == listing_id:
            active = True
        elif isinstance(data, list) and all(isinstance(row, dict) and "id" in row for row in data):
            active = any(str(row["id"]) == listing_id for row in data)
        else:
            raise MarketError("uex_invalid_listing_status")
        listing = data if isinstance(data, dict) else next(
            (row for row in data if str(row["id"]) == listing_id), {}
        ) if isinstance(data, list) else {}
        operation = listing.get("operation")
        if operation in {"buy", "sell", "trade", "rent"}:
            self._listing_operations[listing_id] = operation
        quality = listing.get("quality")
        if isinstance(quality, str) and quality.isdecimal():
            quality = int(quality)
        self._listing_qualities[listing_id] = quality if type(quality) is int and 1 <= quality <= 1000 else None
        self._listing_prices[listing_id] = _price_fields(listing)
        self._listing_cache[listing_id] = (time.monotonic(), active)
        return active

    def listing_operation(self, listing_id: str) -> str | None:
        """Возвращает тип объявления из той же проверки каталога без нового запроса."""
        return self._listing_operations.get(listing_id)

    def listing_quality(self, listing_id: str) -> int | None:
        """Возвращает указанное качество объявления из последней проверки каталога."""
        return self._listing_qualities.get(listing_id)

    def listing_price(self, listing_id: str) -> dict[str, str] | None:
        """Возвращает цену из прежней проверки каталога, не выполняя дополнительный запрос."""
        return self._listing_prices.get(listing_id)

    async def messages(self, account: dict[str, Any], secret: str,
                       negotiation_id: str) -> list[dict[str, Any]]:
        """Получает историю одной переписки по её числовому id."""
        data = await self._request("GET", "marketplace_negotiations_messages", secret,
                                   params={"id_negotiation": negotiation_id})
        if not isinstance(data, list):
            raise MarketError("uex_invalid_messages")
        return data

    async def send(self, account: dict[str, Any], secret: str,
                   negotiation_id: str, text: str) -> str:
        """Один раз отправляет перевод с явно заданным тестовым/реальным режимом UEX."""
        data = await self._request("POST", "marketplace_negotiations_messages", secret, json={
            "id_negotiation": int(negotiation_id), "message": text,
            "is_production": int(self.production),
        })
        remote_id = data.get("id_message") if isinstance(data, dict) else data
        if not isinstance(remote_id, (str, int)) or not str(remote_id):
            raise MarketError("uex_missing_message_id", uncertain=True)
        return str(remote_id)


class DemoMarketplace:
    """Имитирует площадку только в собственной локальной базе; не вызывает UEX."""

    def __init__(self, store: Store):
        """Использует store для переживающих перезапуск тестовых переписок."""
        self.store = store

    async def profile(self, secret: str) -> str:
        """Возвращает имя локального тестового аккаунта без сетевых запросов."""
        return "DemoTrader"

    async def negotiations(self, account: dict[str, Any], secret: str) -> list[dict[str, Any]]:
        """Возвращает переговоры только выбранного тестового владельца."""
        return [{**row, "id_listing": row.get("id_listing", row["id"])}
                for row in self.store.all("remote_deal", account["owner_id"])]

    async def listing_active(self, listing_id: str, *, refresh: bool = False) -> bool:
        """Возвращает тестовую доступность объявления, не обращаясь к UEX."""
        rows = [row for row in self.store.all("remote_deal")
                if str(row.get("id_listing", row["id"])) == listing_id]
        return any(row.get("listing_active", True) for row in rows)

    def listing_operation(self, listing_id: str) -> str | None:
        """Использует sell для обычной демо-карточки либо явно заданный тип объявления."""
        return next((row.get("operation", "sell") for row in self.store.all("remote_deal")
                     if str(row.get("id_listing", row["id"])) == listing_id), None)

    def listing_quality(self, listing_id: str) -> int | None:
        """Читает необязательное качество из локального объявления с listing_id."""
        return next((row.get("quality") for row in self.store.all("remote_deal")
                     if str(row.get("id_listing", row["id"])) == listing_id), None)

    def listing_price(self, listing_id: str) -> dict[str, str] | None:
        """Читает необязательную тестовую цену по тому же контракту, что и UEX."""
        row = next((row for row in self.store.all("remote_deal")
                    if str(row.get("id_listing", row["id"])) == listing_id), {})
        return _price_fields(row)

    async def messages(self, account: dict[str, Any], secret: str,
                       negotiation_id: str) -> list[dict[str, Any]]:
        """Возвращает сообщения указанной тестовой переписки в хронологическом порядке."""
        rows = [m for m in self.store.all("remote_message", account["owner_id"])
                if m["id_negotiation"] == negotiation_id]
        return sorted(rows, key=lambda m: (m["date_added"], m["id"]))

    async def send(self, account: dict[str, Any], secret: str,
                   negotiation_id: str, text: str) -> str:
        """Записывает отправленное сообщение на тестовой площадке для проверки эха."""
        row = self.add_message(account["owner_id"], negotiation_id, account["username"], text)
        return row["id"]

    def add_deal(self, owner_id: str, direction: str, title: str, peer: str) -> dict[str, Any]:
        """Создаёт тестовую продажу или покупку с отдельным собеседником."""
        row = {"id": uuid.uuid4().hex, "owner_id": owner_id, "listing_title": title,
               "advertiser_username": "DemoTrader" if direction == "sell" else peer,
               "client_username": peer if direction == "sell" else "DemoTrader",
               "is_listing_advertiser": int(direction == "sell"),
               "date_modified": time.time(), "date_closed": 0, "date_closed_client": 0}
        self.store.put("remote_deal", row)
        return row

    def add_message(self, owner_id: str, negotiation_id: str, author: str,
                    text: str, *, request_id: str | None = None) -> dict[str, Any]:
        """Добавляет внешний тестовый ответ и обновляет дату переговоров."""
        deal = self.store.get("remote_deal", negotiation_id)
        if not deal or deal["owner_id"] != owner_id:
            raise PermissionError("Чужая тестовая сделка")
        message_id = (uuid.uuid5(uuid.NAMESPACE_URL, f"{owner_id}:{negotiation_id}:{request_id}").hex
                      if request_id else uuid.uuid4().hex)
        existing = self.store.get("remote_message", message_id)
        if existing:
            if existing["message"] != text or existing["user_username"] != author:
                raise ValueError("Повторный id с другим сообщением")
            return existing
        row = {"id": message_id, "owner_id": owner_id, "id_negotiation": negotiation_id,
               "user_username": author, "message": text, "event": None,
               "date_added": time.time()}
        self.store.put("remote_message", row)
        deal["date_modified"] = row["date_added"]
        self.store.put("remote_deal", deal)
        return row

    def close_deal(self, owner_id: str, negotiation_id: str) -> None:
        """Завершает только собственную сторону локальной тестовой сделки."""
        deal = self.store.get("remote_deal", negotiation_id)
        if not deal or deal["owner_id"] != owner_id:
            raise PermissionError("Чужая тестовая сделка")
        field = "date_closed" if deal["is_listing_advertiser"] else "date_closed_client"
        deal[field] = time.time()
        self.store.put("remote_deal", deal)
