"""Чтение и сортировка чужих предложений без изменений объявлений и переписок."""

import json
import logging
import re
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import TYPE_CHECKING, Any
from urllib.parse import quote, urlsplit

if TYPE_CHECKING:
    from trader.service import TraderService

LOGGER = logging.getLogger(__name__)
PAGE_SIZE = 5
UEX_ROWS_LIMIT = 1000
SORT_LABELS = {"price_asc": "Цена: сначала дешевле", "price_desc": "Цена: сначала дороже",
               "quality_desc": "Качество: сначала выше", "quality_asc": "Качество: сначала ниже"}


def whole_number(value: Any) -> int | None:
    """Читает неотрицательное целое из числа или строки API; неизвестное оставляет пустым."""
    if type(value) is int:
        return value if value >= 0 else None
    if isinstance(value, str) and re.fullmatch(r"[0-9]{1,15}", value.strip()):
        return int(value.strip())
    return None


def minimum_quality(text: str) -> int | None:
    """Проверяет необязательный минимальный Q из формы, в принятой шкале UEX 1–1000."""
    if not text.strip():
        return None
    quality = whole_number(text)
    if quality is None or not 1 <= quality <= 1000:
        raise ValueError("Минимальное качество: введи целое число от 1 до 1000 или оставь поле пустым.")
    return quality


def _price(value: Any) -> Decimal | None:
    """Читает указанную положительную цену; нулевое или неизвестное значение оставляет без суммы."""
    if isinstance(value, bool) or len(str(value)) > 64:
        return None
    try:
        amount = Decimal(str(value))
    except InvalidOperation:
        return None
    return amount if amount.is_finite() and Decimal("0.000001") <= amount <= Decimal("1e18") else None


def _photo(value: Any) -> str | None:
    """Берёт первое HTTPS-фото UEX из массива, JSON либо списка URL через запятую."""
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            pass
        if isinstance(value, str):
            value = re.split(r"(?:,\s*)+(?=https?://)", value.strip().rstrip(", \t\r\n"))
    if not isinstance(value, list):
        return None
    for candidate in value:
        if not isinstance(candidate, str) or len(candidate) > 2048:
            continue
        candidate = candidate.strip()
        try:
            url = urlsplit(candidate)
            host = url.hostname or ""
            if (url.scheme == "https" and (host == "uexcorp.space" or host.endswith(".uexcorp.space"))
                    and not url.username and not url.password and url.port in {None, 443}):
                return candidate
        except ValueError:
            continue
    return None


@dataclass(frozen=True)
class Offer:
    """Хранит только публичные поля одной подходящей продажи, без описания и контактов."""

    listing_id: int
    url: str
    seller: str
    quality: int | None
    price: Decimal | None
    currency: str
    unit: str
    stock: int | None
    location: str
    photo: str | None

    @property
    def store_url(self) -> str:
        """Открывает ассортимент по настоящему username UEX, а не отображаемому имени."""
        return f"https://uexcorp.space/@{quote(self.seller, safe='')}?tab=marketplace"


def _offer(row: dict[str, Any], item_id: int, quality_from: int | None) -> Offer | None:
    """Отбирает непроданную карточку выбранного товара и нормализует безопасные поля."""
    if (whole_number(row.get("id_item")) != item_id or row.get("operation") != "sell"
            or row.get("type") != "item" or row.get("is_sold_out") not in (0, "0", False)):
        return None
    listing_id = whole_number(row.get("id"))
    slug, seller = row.get("slug"), row.get("user_username")
    if (not listing_id or not isinstance(slug, str) or not slug or len(slug) > 512
            or not isinstance(seller, str) or not seller.strip()):
        return None
    quality = whole_number(row.get("quality"))
    quality = quality if quality is not None and 1 <= quality <= 1000 else None
    if quality_from is not None and (quality is None or quality < quality_from):
        return None
    currency, unit = row.get("currency"), row.get("unit")
    currency = currency.upper() if isinstance(currency, str) and re.fullmatch(r"[A-Za-z]{2,8}", currency) else "—"
    unit = unit if isinstance(unit, str) and re.fullmatch(r"[a-z]{1,12}", unit) else "—"
    location = row.get("location")
    return Offer(listing_id, f"https://uexcorp.space/marketplace/item/info/{quote(slug, safe='')}/",
                 seller.strip(), quality, _price(row.get("price")), currency, unit,
                 whole_number(row.get("in_stock")) or None, location[:160] if isinstance(location, str) else "",
                 _photo(row.get("photos")))


@dataclass(frozen=True)
class SearchResult:
    """Сохраняет один снимок выдачи для личного окна, листания и смены сортировки."""

    item_name: str
    quality_from: int | None
    offers: tuple[Offer, ...]
    received: int

    @property
    def modes(self) -> tuple[str, ...]:
        """Предлагает качество только при наличии указанного Q во всей подходящей выдаче."""
        return ("price_asc", "price_desc") + (("quality_desc", "quality_asc")
                                             if any(o.quality is not None for o in self.offers) else ())

    def ordered(self, mode: str) -> list[Offer]:
        """Сортирует снимок; цены сравнивает внутри валюты/единицы, неизвестные значения ставит в конец."""
        if mode not in self.modes:
            mode = "price_asc"

        def key(offer: Offer) -> tuple:
            """Строит устойчивый порядок для цены или качества одной карточки."""
            price = offer.price if offer.price is not None else Decimal(0)
            group = (offer.currency != "UEC", offer.currency, offer.unit)
            if mode in {"quality_desc", "quality_asc"}:
                quality = offer.quality or 0
                return (offer.quality is None, -quality if mode == "quality_desc" else quality,
                        *group, offer.price is None, price, offer.listing_id)
            return (*group, offer.price is None, -price if mode == "price_desc" else price, offer.listing_id)

        return sorted(self.offers, key=key)


async def find_offers(core: "TraderService", owner: str, item: dict[str, Any],
                      quality_from: int | None) -> SearchResult:
    """Читает продажи item для проверенного owner; личный ключ не передаётся публичному GET."""
    item_id = whole_number(item.get("id"))
    if not item_id or (quality_from is not None and (type(quality_from) is not int or not 1 <= quality_from <= 1000)):
        raise ValueError("Выбери товар и допустимое минимальное качество заново.")
    account = await core.account(owner)
    market = core.market_for(account)
    rows = await market.offers(item_id)
    current = await core.account(owner)
    if current["username"] != account["username"]:
        raise PermissionError("Аккаунт UEX изменился. Начни поиск заново.")
    unique = {}
    for row in rows:
        offer = _offer(row, item_id, quality_from)
        if offer is not None:
            unique[offer.listing_id] = offer
    LOGGER.info("Поиск UEX owner=%s item=%s received=%s found=%s", owner, item_id, len(rows), len(unique))
    return SearchResult(str(item.get("name") or "Товар UEX")[:200], quality_from, tuple(unique.values()), len(rows))
