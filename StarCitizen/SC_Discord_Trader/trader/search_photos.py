"""Оригиналы публичных фото только для видимой страницы поиска, без ключей UEX."""

import asyncio
import logging
import re
import time
from collections import OrderedDict
from dataclasses import replace
from html.parser import HTMLParser
from urllib.parse import urlsplit

import httpx

from trader.search import Offer, _photo

LOGGER = logging.getLogger(__name__)
PAGE_LIMIT = 5
HTML_LIMIT = 1024 * 1024
CACHE_LIMIT = 512


class ListingImage(HTMLParser):
    """Принимает оригинал из разметки только своего listing ID на CDN UEX."""

    def __init__(self, listing_id: int):
        """Не позволяет соседним объявлениям, аватарам и миниатюрам стать фото товара."""
        super().__init__(convert_charrefs=True)
        self.pattern = re.compile(rf"/uid[0-9]+/marketplace/listings/{listing_id}/[a-zA-Z0-9_-]+\.(?:jpg|jpeg|png|webp)$")
        self.photo: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        """Смотрит только метаданные и изображения; не исполняет HTML или скрипты."""
        values = dict(attrs)
        if self.photo or not (tag == "img" or (tag == "meta" and values.get("property") == "og:image")):
            return
        candidate = _photo(values.get("content") if tag == "meta" else values.get("src"))
        if not candidate:
            return
        url = urlsplit(candidate)
        if (url.hostname == "cdn.uexcorp.space" and not url.query and not url.fragment
                and self.pattern.fullmatch(url.path) and not re.search(r"-t\.[^.]+$", url.path)):
            self.photo = candidate


class ListingPhotos:
    """Кэширует фото по публичной странице; необязательная загрузка не ломает выдачу."""

    def __init__(self, client: httpx.AsyncClient):
        """Использует клиент существующего runtime; не владеет его жизненным циклом."""
        self.client = client
        self._slots = asyncio.Semaphore(2)
        self._cache: OrderedDict[str, tuple[float, str | None]] = OrderedDict()

    async def page(self, offers: list[Offer]) -> list[Offer]:
        """Уточняет максимум пять видимых объявлений; данные поиска и порядок неизменны."""
        if len(offers) > PAGE_LIMIT:
            raise ValueError("Фото загружаются только для одной страницы поиска")
        return await asyncio.gather(*(self._offer(offer) for offer in offers))

    async def _offer(self, offer: Offer) -> Offer:
        """Возвращает оригинал либо прежнее API-фото при недоступной публичной странице."""
        cached = self._cache.get(offer.url)
        if cached and cached[0] > time.monotonic():
            self._cache.move_to_end(offer.url)
            return replace(offer, photo=cached[1] or offer.photo)
        photo, ttl = None, 300
        try:
            async with asyncio.timeout(4):
                async with self._slots:
                    photo = await self._fetch(offer)
        except (httpx.HTTPError, TimeoutError, ValueError) as exc:
            ttl = 60
            LOGGER.warning("Оригинал фото не загружен listing=%s error_type=%s", offer.listing_id, type(exc).__name__)
        self._cache[offer.url] = time.monotonic() + ttl, photo
        self._cache.move_to_end(offer.url)
        while len(self._cache) > CACHE_LIMIT:
            self._cache.popitem(last=False)
        return replace(offer, photo=photo or offer.photo)

    async def _fetch(self, offer: Offer) -> str | None:
        """Читает ограниченный HTML без Authorization, Secret Key, cookies и редиректов."""
        url = urlsplit(offer.url)
        if (url.scheme != "https" or url.netloc != "uexcorp.space" or url.query or url.fragment
                or not url.path.startswith("/marketplace/item/info/")):
            raise ValueError("Неверный адрес публичной карточки")
        request = httpx.Request("GET", offer.url, headers={"Accept": "text/html"},
            extensions={"timeout": {"connect": 3, "read": 3, "write": 3, "pool": 3}})
        response = await self.client.send(request, stream=True, auth=None, follow_redirects=False)
        try:
            if response.status_code != 200:
                raise ValueError("Публичная карточка недоступна")
            if "text/html" not in response.headers.get("content-type", "").lower():
                raise ValueError("Публичная карточка вернула не HTML")
            body = bytearray()
            async for part in response.aiter_bytes():
                body.extend(part)
                if len(body) > HTML_LIMIT:
                    raise ValueError("Публичная карточка слишком велика")
            parser = ListingImage(offer.listing_id)
            parser.feed(body.decode("utf-8", errors="replace"))
            return parser.photo
        finally:
            await response.aclose()
