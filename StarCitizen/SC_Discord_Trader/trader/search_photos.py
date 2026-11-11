"""Фото и явный Sold Out по публичным страницам кандидатов поиска, без ключей UEX."""

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
    """Читает своё фото и статус только первого заголовка объявления с метками UEX."""

    def __init__(self, listing_id: int):
        """Не позволяет соседним объявлениям, аватарам и миниатюрам стать фото товара."""
        super().__init__(convert_charrefs=True)
        self.pattern = re.compile(rf"/uid[0-9]+/marketplace/listings/{listing_id}/[a-zA-Z0-9_-]+\.(?:jpg|jpeg|png|webp)$")
        self.photo: str | None = None
        self.sold_out = False
        self._in_heading = False
        self._market_heading = False
        self._heading_done = False
        self._badge_depth = 0
        self._badge_text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        """Читает метку статуса и фото; не исполняет HTML или скрипты."""
        values = dict(attrs)
        if tag == "h2" and not self._heading_done:
            self._in_heading = True
            self._market_heading = False
        if tag == "span" and self._in_heading:
            classes = (values.get("class") or "").split()
            if "label-title" in classes:
                self._market_heading = True
            if self._badge_depth:
                self._badge_depth += 1
            elif ("label-title" in classes and "label-red" in classes
                  and values.get("title") == "Item Not Available"):
                self._badge_depth = 1
                self._badge_text = []
        if self.photo or not (tag == "img" or (tag == "meta" and values.get("property") == "og:image")):
            return
        candidate = _photo(values.get("content") if tag == "meta" else values.get("src"))
        if not candidate:
            return
        url = urlsplit(candidate)
        if (url.hostname == "cdn.uexcorp.space" and not url.query and not url.fragment
                and self.pattern.fullmatch(url.path) and not re.search(r"-t\.[^.]+$", url.path)):
            self.photo = candidate

    def handle_data(self, data: str) -> None:
        """Обычное описание или название со словами Sold Out не меняет статус."""
        if self._badge_depth:
            self._badge_text.append(data)

    def handle_endtag(self, tag: str) -> None:
        """Не принимает метки соседних объявлений после основного заголовка."""
        if tag == "span" and self._badge_depth:
            self._badge_depth -= 1
            if not self._badge_depth and " ".join("".join(self._badge_text).split()).casefold() == "sold out":
                self.sold_out = True
        if tag == "h2" and self._in_heading:
            self._heading_done = self._market_heading
            self._in_heading = False
            self._badge_depth = 0


class ListingPhotos:
    """Дополняет фото и исключает явный Sold Out даже при устаревшем признаке API."""

    def __init__(self, client: httpx.AsyncClient):
        """Использует клиент существующего runtime; не владеет его жизненным циклом."""
        self.client = client
        self._slots = asyncio.Semaphore(2)
        self._cache: OrderedDict[str, tuple[float, str | None, bool]] = OrderedDict()

    async def page(self, offers: list[Offer]) -> list[Offer]:
        """Проверяет до пяти кандидатов за вызов, сохраняя порядок непроданных."""
        if len(offers) > PAGE_LIMIT:
            raise ValueError("Фото загружаются только для одной страницы поиска")
        checked = await asyncio.gather(*(self._offer(offer) for offer in offers))
        return [offer for offer in checked if offer is not None]

    async def _offer(self, offer: Offer) -> Offer | None:
        """Скрывает явный Sold Out; при недоступной странице сохраняет исходные данные API."""
        cached = self._cache.get(offer.url)
        if cached and cached[0] > time.monotonic():
            self._cache.move_to_end(offer.url)
            return None if cached[2] else replace(offer, photo=cached[1] or offer.photo)
        photo, sold_out, ttl = None, False, 60
        try:
            async with asyncio.timeout(4):
                async with self._slots:
                    page = await self._fetch(offer)
                    photo, sold_out = page.photo, page.sold_out
                    if sold_out:
                        ttl = 300
                        LOGGER.info("Проданное объявление пропущено listing=%s", offer.listing_id)
        except (httpx.HTTPError, TimeoutError, ValueError) as exc:
            ttl = 60
            LOGGER.warning("Страница объявления не проверена listing=%s error_type=%s", offer.listing_id, type(exc).__name__)
        self._cache[offer.url] = time.monotonic() + ttl, photo, sold_out
        self._cache.move_to_end(offer.url)
        while len(self._cache) > CACHE_LIMIT:
            self._cache.popitem(last=False)
        return None if sold_out else replace(offer, photo=photo or offer.photo)

    async def _fetch(self, offer: Offer) -> ListingImage:
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
            return parser
        finally:
            await response.aclose()
