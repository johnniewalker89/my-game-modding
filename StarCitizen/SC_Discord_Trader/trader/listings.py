"""Личные черновики объявлений, подтверждённые публикации и удаление без повторов."""

import asyncio
import base64
import logging
import re
import time
import uuid
from typing import TYPE_CHECKING, Any

from trader.catalog import category_label
from trader.marketplace import MarketError
from trader.service import stable_id

if TYPE_CHECKING:
    from trader.service import TraderService

LOGGER = logging.getLogger(__name__)
OPERATIONS = {"buy": "WTB · Купить", "sell": "WTS · Продать", "trade": "WTT · Обменять"}
UNITS = {"scu": "SCU", "cscu": "cSCU", "unit": "Штука", "box": "Коробка", "crate": "Ящик",
         "set": "Комплект", "pack": "Упаковка", "pair": "Пара", "stack": "Стопка",
         "dozen": "Дюжина", "hundred": "Сотня", "thousand": "Тысяча"}
HOURS = (0, 1, 2, 3, 5, 12, 24, 48, 72, 120, 168, 336, 720)
MAX_PHOTO = 7 * 1024 * 1024
DEFAULT_LOCATION = "By arrangement"


def number(value: str, label: str, *, minimum: int = 0) -> int:
    """Принимает целое с пробелами-разделителями, без дробей и отрицательных сумм."""
    cleaned = re.sub(r"[\s\u00a0]", "", value)
    if not re.fullmatch(r"[0-9]{1,15}", cleaned) or int(cleaned) < minimum:
        raise ValueError(f"{label}: введи целое число от {minimum}, можно с пробелами.")
    return int(cleaned)


def listing_payload(draft: dict[str, Any]) -> dict[str, Any]:
    """Собирает поля UEX из черновика; количество передаёт только как запас in_stock."""
    if draft["price"] is None:
        raise ValueError("Заполни количество и цену в «Условиях».")
    location = draft.get("location", "").strip() or DEFAULT_LOCATION
    if draft["operation"] not in OPERATIONS or draft["unit"] not in UNITS or draft["hours"] not in HOURS:
        raise ValueError("Обнови тип сделки, единицы и срок объявления.")
    if draft["operation"] != "trade" and draft["price"] <= 0:
        raise ValueError("Для покупки или продажи цена должна быть больше нуля.")
    if draft["operation"] == "trade" and not draft["description_en"]:
        raise ValueError("Для обмена опиши, что хочешь получить взамен.")
    prefix = OPERATIONS[draft["operation"]].split(" · ")[0]
    quality = f" Q{draft['quality']}" if draft["quality"] is not None else ""
    name = draft["item"]["name"]
    title = re.sub(r"[^A-Za-z0-9 -]", " ", f"{prefix} {name}{quality}")
    description = (f"{prefix} {name}.\n"
                   f"Quality: {draft['quality'] if draft['quality'] is not None else 'not specified'}.\n"
                   f"Trade location: {location}.\n{draft['description_en']}").strip()
    payload = {"id_category": draft["item"]["id_category"], "id_item": draft["item"]["id"],
               "operation": draft["operation"], "type": "item", "language": "en_US",
               "unit": draft["unit"], "price": draft["price"], "currency": "UEC",
               "location": location, "title": title[:140].strip(), "description": description,
               "in_stock": draft["quantity"],
               "availability": "negotiable", "is_hidden": int(draft["hidden"]), "is_tv_allowed": 0}
    if draft["quality"] is not None:
        payload["quality"] = draft["quality"]
    if draft["hours"]:
        payload["hours_expiration"] = draft["hours"]
    if draft.get("photo"):
        payload["image_data"] = draft["photo"]
    return payload


class ListingService:
    """Ведёт объявления одного процесса с проверкой роли, аккаунта и версии подтверждения."""

    def __init__(self, service: "TraderService", mode: str):
        """Использует штатный аккаунт/Vault и отдельный test/production режим объявлений."""
        if mode not in {"test", "production"}:
            raise ValueError("Неизвестный режим объявлений")
        self.core, self.store, self.mode = service, service.store, mode
        self._locks: dict[str, asyncio.Lock] = {}
        self._catalog_lock = asyncio.Lock()
        self._catalog_index: list[dict[str, Any]] = []
        self._catalog_index_at = 0.0
        saved_catalog = self.store.get("catalog_index", "uex-items-v1")
        if saved_catalog and isinstance(saved_catalog.get("items"), list) and all(
                isinstance(row, dict) and all(key in row for key in ("id", "id_category", "name"))
                for row in saved_catalog["items"]):
            self._catalog_index = saved_catalog["items"]
            self._catalog_index_at = float(saved_catalog.get("cached_at", 0))
        for kind in ("listing_draft", "advertisement"):
            for row in self.store.all(kind):
                if row["status"] in {"sending", "deleting"}:
                    row["status"] = "unknown" if kind == "listing_draft" else "delete_unknown"
                    row.pop("photo", None)
                    self.store.put(kind, row)

    async def categories(self, owner: str) -> list[dict[str, Any]]:
        """Возвращает только категории товаров для подключённого участника."""
        await self.core.account(owner)
        rows = await self.core.market.catalog()
        return sorted([row for row in rows if row.get("type") == "item"],
                      key=category_label)

    @property
    def catalog_ready(self) -> bool:
        """Сообщает UI, есть ли полная сохранённая версия каталога для быстрого поиска."""
        return bool(self._catalog_index_at)

    async def prepare_catalog(self) -> None:
        """Атомарно обновляет общий справочник; при сбое прежняя полная версия остаётся доступной."""
        async with self._catalog_lock:
            if self.catalog_ready and 0 <= time.time() - self._catalog_index_at < 86400:
                return
            refresh = self.catalog_ready
            categories = [row for row in await self.core.market.catalog(refresh=refresh) if row.get("type") == "item"]
            index = {}
            for group in categories:
                for row in await self.core.market.catalog(int(group["id"]), refresh=refresh):
                    index[int(row["id"])] = {**{key: row.get(key) for key in (
                        "id", "id_category", "name", "is_commodity", "is_harvestable")},
                        "category_label": category_label(group)}
            if not index:
                raise ValueError("Каталог UEX пока пуст. Попробуй позже.")
            completed_at = time.time()
            items = list(index.values())
            self.store.put("catalog_index", {"id": "uex-items-v1", "owner_id": "uex-catalog",
                                            "cached_at": completed_at, "items": items})
            self._catalog_index, self._catalog_index_at = items, completed_at
            LOGGER.info("Каталог UEX обновлён categories=%s items=%s", len(categories), len(items))

    async def items(self, owner: str, category: int | None, query: str) -> list[dict[str, Any]]:
        """Ищет конкретный товар во всём каталоге либо с дополнительным фильтром категории."""
        await self.core.account(owner)
        query = query.strip()
        if category is None and not query:
            raise ValueError("Введи название товара, например Sadaryx или Copper.")
        if category is None:
            if not self.catalog_ready:
                await self.prepare_catalog()
            rows = self._catalog_index
        else:
            categories = await self.categories(owner)
            if not any(int(row["id"]) == category for row in categories):
                raise ValueError("Выбери категорию товаров заново.")
            group = next(row for row in categories if int(row["id"]) == category)
            rows = [{**row, "category_label": category_label(group)}
                    for row in await self.core.market.catalog(category)]
        await self.core.account(owner)
        terms = query.casefold().split()
        return sorted([row for row in rows if all(term in row.get("name", "").casefold() for term in terms)],
                      key=lambda row: (row.get("name", "").casefold() != query.casefold(), row.get("name", "")))

    async def start(self, owner: str, category: int, item_id: int) -> dict[str, Any]:
        """Создаёт собственный черновик из реального каталога; прежние открытые черновики отменяет."""
        rows = await self.items(owner, category, "")
        item = next((row for row in rows if int(row["id"]) == item_id and int(row["id_category"]) == category), None)
        if not item:
            raise ValueError("Товар исчез из каталога. Выбери его заново.")
        async with self._locks.setdefault(owner, asyncio.Lock()):
            account = await self.core.account(owner)
            for old in self.store.all("listing_draft", owner):
                if old["status"] == "draft":
                    old.update(status="cancelled", photo=None)
                    self.store.put("listing_draft", old)
            draft = {"id": uuid.uuid4().hex, "owner_id": owner, "account": account["username"],
                     "status": "draft", "revision": 0, "created_at": time.time(),
                     "item": {key: item.get(key) for key in ("id", "id_category", "name", "is_commodity")},
                     "operation": "buy", "unit": "scu" if item.get("is_commodity") else "unit",
                     "quantity": 1, "price": None, "quality": None, "location": DEFAULT_LOCATION,
                     "description_ru": "", "description_en": "", "hours": 0, "hidden": False, "photo": None}
            self.store.put("listing_draft", draft, new_only=True)
            return draft

    async def draft(self, owner: str, draft_id: str) -> dict[str, Any]:
        """Проверяет доступ через Discord перед операцией с черновиком."""
        await self.core.account(owner)
        return self.draft_snapshot(owner, draft_id)

    def draft_snapshot(self, owner: str, draft_id: str) -> dict[str, Any]:
        """Читает актуальные поля для уже проверенного личного окна без сетевого ожидания."""
        account = self.store.get("account", owner)
        draft = self.store.get("listing_draft", draft_id)
        if not draft:
            raise ValueError("Черновик больше недоступен. Начни новое объявление.")
        if (not account or not account.get("secret") or draft["owner_id"] != owner
                or draft["account"] != account["username"]):
            raise PermissionError("Это не твой черновик или подключён другой UEX.")
        return draft

    async def edit(self, owner: str, draft_id: str, revision: int, changes: dict[str, Any]) -> dict[str, Any]:
        """Меняет проверенные поля под блокировкой; старые окна не перезаписывают новые данные."""
        async with self._locks.setdefault(owner, asyncio.Lock()):
            draft = await self.draft(owner, draft_id)
            self._editable(draft, revision)
            if not set(changes) <= {"operation", "unit", "hours", "hidden", "conditions", "photo"}:
                raise ValueError("Неизвестное поле объявления.")
            changes = changes.copy()
            updated = dict(draft)
            if "conditions" in changes:
                fields = changes.pop("conditions").copy()
                quantity = number(fields["quantity"], "Количество", minimum=1)
                price = number(fields["price"], "Цена")
                quality = number(fields["quality"], "Качество", minimum=1) if fields["quality"].strip() else None
                if quality is not None and quality > 1000:
                    raise ValueError("Качество должно быть от 1 до 1000.")
                location, description = fields["location"].strip() or DEFAULT_LOCATION, fields["description"].strip()
                if len(location) > 120 or len(description) > 1000:
                    raise ValueError("Место — до 120 символов, описание — до 1000.")
                # Argos теряет слово «качества» и превращает Q958 в количество.
                # Защищаем весь смысловой оборот, а не только его число.
                translated_input = re.sub(r"\bкачеств[ао]\s*[:=]?\s*(\d{1,4})\b", r"quality \1", description, flags=re.IGNORECASE)
                quality_terms = tuple(re.findall(r"\bquality\s+\d{1,4}\b", translated_input, flags=re.IGNORECASE))
                description_en = (await self.core.translator.translate(translated_input, "ru", "en",
                                    protected=(draft["item"]["name"], *quality_terms),
                                    context={"item": draft["item"]["name"], "quality": quality,
                                             "player_action": changes.get("operation", updated["operation"])})) if re.search(r"[А-Яа-яЁё]", description) else description
                if len(description_en) > 3000:
                    raise ValueError("Перевод слишком длинный для предпросмотра. Сократи описание.")
                updated.update(quantity=quantity, price=price, quality=quality, location=location,
                               description_ru=description, description_en=description_en)
                updated.pop("location_en", None)
            if "photo" in changes:
                photo = changes.pop("photo")
                if photo is not None:
                    if len(photo) > MAX_PHOTO or not (photo.startswith(b"\x89PNG\r\n\x1a\n") or photo.startswith(b"\xff\xd8\xff")):
                        raise ValueError("Нужно фото JPG/PNG размером до 7 МБ.")
                    photo = base64.b64encode(photo).decode("ascii")
                updated["photo"] = photo
            updated.update(changes)
            if updated["operation"] not in OPERATIONS or updated["unit"] not in UNITS or updated["hours"] not in HOURS:
                raise ValueError("Некорректный тип, единицы или срок объявления.")
            if not isinstance(updated["hidden"], bool):
                raise ValueError("Некорректная видимость объявления.")
            account = await self.core.account(owner)
            if account["username"] != draft["account"]:
                raise PermissionError("Аккаунт UEX изменился. Начни заново.")
            updated["revision"] += 1
            self.store.put("listing_draft", updated)
            return updated

    async def review(self, owner: str, draft_id: str, revision: int) -> dict[str, Any]:
        """Проверяет версию и полноту карточки перед показом подтверждения."""
        draft = await self.draft(owner, draft_id)
        self._editable(draft, revision)
        listing_payload(draft)
        return draft

    @staticmethod
    def _editable(draft: dict[str, Any], revision: int) -> None:
        """Отклоняет отправленные, устаревшие и просроченные подтверждения."""
        if draft["status"] != "draft" or draft["revision"] != revision:
            raise ValueError("Это окно устарело. Открой «Объявления» заново; повторной публикации не было.")
        if time.time() - draft["created_at"] > 3600:
            raise ValueError("Черновику больше часа. Начни новое объявление.")

    async def publish(self, owner: str, draft_id: str, revision: int) -> dict[str, Any]:
        """Отправляет показанный черновик один раз; неизвестный результат запрещает повтор."""
        async with self._locks.setdefault(owner, asyncio.Lock()):
            draft = await self.draft(owner, draft_id)
            self._editable(draft, revision)
            payload = listing_payload(draft)
            account = await self.core.account(owner)
            if account["username"] != draft["account"]:
                raise PermissionError("Аккаунт изменился. Начни заново.")
            draft.update(status="sending", production=self.mode == "production")
            self.store.put("listing_draft", draft)
            try:
                result = await self.core.market_for(account).advertise(self.core.vault.decrypt(account["secret"]),
                                                         payload, production=draft["production"])
            except BaseException as exc:
                uncertain = not isinstance(exc, MarketError) or exc.uncertain
                draft.update(status="unknown" if uncertain else "failed", photo=None)
                self.store.put("listing_draft", draft)
                LOGGER.warning("Публикация не подтверждена draft=%s owner=%s outcome=%s error_type=%s", draft_id, owner, draft["status"], type(exc).__name__)
                raise
            draft.update(status="created" if draft["production"] else "tested", result=result, photo=None)
            if draft["production"]:
                remote_id = str(result["id_listing"])
                row = {"id": stable_id(owner, account["username"], "listing", remote_id),
                       "owner_id": owner, "account": account["username"], "external_id": remote_id,
                       "title": payload["title"], "status": "created", "source": "bot",
                       "created_at": time.time()}
                self.store.put("advertisement", row)
            self.store.put("listing_draft", draft)
            LOGGER.info("Объявление обработано draft=%s owner=%s outcome=%s", draft_id, owner, draft["status"])
            return draft

    async def own(self, owner: str) -> list[dict[str, Any]]:
        """Показывает активные и новые карточки; исчезнувшие из каталога сохраняет без показа."""
        account = await self.core.account(owner)
        rows = await self.core.market_for(account).advertisements(account["username"])
        for old in self.store.all("advertisement", owner):
            if old["account"] == account["username"] and old["status"] == "active":
                old["status"] = "unconfirmed"
                self.store.put("advertisement", old)
        for row in rows:
            if str(row.get("user_username", "")).casefold() != account["username"].casefold():
                continue
            remote_id = str(row["id"])
            if not remote_id.isdecimal() or int(remote_id) <= 0:
                continue
            local_id = stable_id(owner, account["username"], "listing", remote_id)
            old = self.store.get("advertisement", local_id) or {}
            if old.get("status") in {"deleted", "deleting", "delete_unknown"}:
                continue
            self.store.put("advertisement", {**old, "id": local_id, "owner_id": owner,
                           "account": account["username"], "external_id": remote_id, "title": str(row.get("title", remote_id)),
                           "status": "active", "source": old.get("source", "catalog"), "created_at": row.get("date_added", 0)})
        return sorted([row for row in self.store.all("advertisement", owner)
                       if row["account"] == account["username"] and row["status"] not in {"deleted", "unconfirmed"}],
                      key=lambda row: -float(row.get("created_at") or 0))

    async def advertisement(self, owner: str, listing_id: str) -> dict[str, Any]:
        """Проверяет локальную карточку перед показом и удалением конкретного объявления."""
        account = await self.core.account(owner)
        row = self.store.get("advertisement", listing_id)
        if not row or row["owner_id"] != owner or row["account"] != account["username"]:
            raise PermissionError("Это не объявление твоего текущего UEX.")
        return row

    async def remove(self, owner: str, listing_id: str) -> dict[str, Any]:
        """Удаляет выбранную собственную карточку после отдельного UI-подтверждения, без повторов."""
        async with self._locks.setdefault(owner, asyncio.Lock()):
            row = await self.advertisement(owner, listing_id)
            if row["status"] not in {"created", "active", "unconfirmed"}:
                raise ValueError("Повтор удаления запрещён. Проверь объявление на UEX.")
            account = await self.core.account(owner)
            if account["username"] != row["account"]:
                raise PermissionError("Аккаунт UEX изменился.")
            previous_status = row["status"]
            row["status"] = "deleting"
            self.store.put("advertisement", row)
            try:
                await self.core.market_for(account).remove_advertisement(self.core.vault.decrypt(account["secret"]),
                    row["external_id"], production=self.mode == "production")
            except BaseException as exc:
                if isinstance(exc, MarketError) and str(exc) == "listing_not_found" and not exc.uncertain:
                    row.update(status="deleted", already_missing=True)
                    self.store.put("advertisement", row)
                    LOGGER.info("UEX подтвердил отсутствие объявления listing=%s owner=%s", row["external_id"], owner)
                    return row
                uncertain = not isinstance(exc, MarketError) or exc.uncertain
                row["status"] = "delete_unknown" if uncertain else previous_status
                self.store.put("advertisement", row)
                LOGGER.warning("Удаление не подтверждено listing=%s owner=%s error_type=%s", row["external_id"], owner, type(exc).__name__)
                raise
            row["status"] = "deleted" if self.mode == "production" else previous_status
            self.store.put("advertisement", row)
            LOGGER.info("Удаление обработано listing=%s owner=%s mode=%s", row["external_id"], owner, self.mode)
            return row
