"""Оригиналы фото проверяются на вымышленных страницах, без реальных объявлений."""

import asyncio
import unittest
from dataclasses import replace
from decimal import Decimal

import httpx

from trader.search import Offer
from trader.search_photos import HTML_LIMIT, ListingImage, ListingPhotos


def offer(number=1):
    """Возвращает вымышленную продажу с уменьшенной копией изображения."""
    return Offer(number, f"https://uexcorp.space/marketplace/item/info/synthetic-{number}/", "Synthetic",
                 900, Decimal(100), "UEC", "unit", 2, "Synthetic Station",
                 f"https://cdn.uexcorp.space/uid42/marketplace/listings/{number}/abc-t.jpg")


def original(number=1):
    """Даёт искусственный адрес оригинала, который нельзя получить удалением суффикса -t."""
    return f"https://cdn.uexcorp.space/uid42/marketplace/listings/{number}/original123.jpg"


class PhotoTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет публичный транспорт, границы чтения, кэш и безопасный fallback."""

    def test_parser_accepts_only_own_original_and_ignores_foreign_or_unsafe_images(self):
        """Соседние карточки, preview, чужой домен и data URI не подменяют оригинал."""
        parser = ListingImage(1)
        parser.feed(f'''<meta property="og:image" content="https://example.invalid/a.jpg">
            <img src="{original(2)}"><img src="{offer().photo}">
            <img src="data:image/png;base64,invalid">
            <meta property="og:image" content="{original()}">''')
        self.assertEqual(parser.photo, original())

    def test_sold_out_badge_is_read_after_photo_but_not_from_title_or_neighbours(self):
        """Статус принадлежит основному заголовку UEX, а не словам описания или соседней карточке."""
        badge = '<span class="label label-title label-red" title="Item Not Available"> SOLD\n OUT </span>'
        sold = ListingImage(1)
        sold.feed(f'<meta property="og:image" content="{original()}"><h2>{badge}Synthetic</h2>')
        self.assertTrue(sold.sold_out)
        self.assertEqual(sold.photo, original())
        active = ListingImage(1)
        active.feed(f'<h2><span class="label-title">WTS</span>Sold Out is only a title</h2>'
                    f'<p>Sold Out</p><h2>{badge}Another listing</h2>')
        self.assertFalse(active.sold_out)

    async def test_explicit_page_sold_out_overrides_api_stock_and_is_cached(self):
        """Неверный API-флаг и положительный запас не возвращают явно проданное объявление."""
        requests = []

        def respond(request):
            requests.append(request)
            return httpx.Response(200, headers={"content-type": "text/html"},
                text='<h2><span class="label-title label-red" title="Item Not Available">Sold Out</span>Synthetic</h2>')

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            photos = ListingPhotos(client)
            self.assertEqual(await photos.page([offer()]), [])
            self.assertEqual(await photos.page([offer()]), [])
        self.assertEqual(len(requests), 1)
        self.assertEqual(offer().stock, 2)

    async def test_public_get_has_no_auth_or_cookies_and_caches_original_without_api_photo(self):
        """Даже клиент с default-секретами делает чистый GET; отсутствие photos в API допустимо."""
        requests = []

        def respond(request):
            """Вымышленная карточка отдаёт оригинал в Open Graph."""
            requests.append(request)
            self.assertEqual(request.method, "GET")
            self.assertNotIn("authorization", request.headers)
            self.assertNotIn("secret-key", request.headers)
            self.assertNotIn("cookie", request.headers)
            return httpx.Response(200, headers={"content-type": "text/html"},
                                  text=f'<meta property="og:image" content="{original()}">')

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond),
                headers={"Authorization": "synthetic-secret", "secret-key": "synthetic"},
                cookies={"session": "synthetic"}, auth=("synthetic", "password")) as client:
            photos = ListingPhotos(client)
            result = await photos.page([replace(offer(), photo=None)])
            again = await photos.page([offer()])
        self.assertEqual(result[0].photo, original())
        self.assertEqual(again[0].photo, original())
        self.assertEqual(result[0].price, Decimal(100))
        self.assertEqual(len(requests), 1)

    async def test_page_failures_keep_thumbnail_and_do_not_follow_redirects(self):
        """Редирект, не-HTML, большой ответ и timeout не ломают поиск и не повторяются на листании."""
        for failure in ("redirect", "binary", "large", "timeout"):
            with self.subTest(failure=failure):
                requests = []

                def respond(request):
                    """Возвращает один выбранный отказ публичной страницы."""
                    requests.append(request)
                    if failure == "timeout":
                        raise httpx.ReadTimeout("synthetic timeout", request=request)
                    if failure == "redirect":
                        return httpx.Response(302, headers={"location": "http://127.0.0.1/private"})
                    if failure == "binary":
                        return httpx.Response(200, headers={"content-type": "image/png"}, content=b"synthetic")
                    return httpx.Response(200, headers={"content-type": "text/html"}, content=b"x" * (HTML_LIMIT + 1))

                async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
                    photos = ListingPhotos(client)
                    with self.assertLogs("trader.search_photos", level="WARNING"):
                        first = await photos.page([offer()])
                    second = await photos.page([offer()])
                self.assertEqual(first[0].photo, offer().photo)
                self.assertEqual(second[0].photo, offer().photo)
                self.assertEqual(len(requests), 1)

    async def test_missing_image_is_nonfatal_and_unsafe_page_url_never_gets_requested(self):
        """Пустая карточка кэшируется, а подставной URL не достигает транспорта."""
        requests = []

        def respond(request):
            """Возвращает HTML без фотографий."""
            requests.append(request)
            return httpx.Response(200, headers={"content-type": "text/html"}, text="<p>Synthetic</p>")

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            photos = ListingPhotos(client)
            row = replace(offer(), photo=None)
            self.assertIsNone((await photos.page([row]))[0].photo)
            await photos.page([row])
            with self.assertLogs("trader.search_photos", level="WARNING"):
                unsafe = await photos.page([replace(offer(), url="http://127.0.0.1/private")])
        self.assertEqual(unsafe[0].photo, offer().photo)
        self.assertEqual(len(requests), 1)

    async def test_only_five_visible_rows_and_two_parallel_requests_preserve_order(self):
        """Ограничивает нагрузку независимо от размера общего результата и сохраняет порядок карточек."""
        active, maximum, count = 0, 0, 0

        async def respond(request):
            """Отмечает одновременные чтения и возвращает фото соответствующего synthetic ID."""
            nonlocal active, maximum, count
            number = int(request.url.path.rstrip("/").rsplit("-", 1)[-1])
            active, count = active + 1, count + 1
            maximum = max(maximum, active)
            await asyncio.sleep(0)
            active -= 1
            return httpx.Response(200, headers={"content-type": "text/html"},
                                  text=f'<img src="{original(number)}">')

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            photos = ListingPhotos(client)
            with self.assertRaises(ValueError):
                await photos.page([offer(i) for i in range(1, 7)])
            rows = await photos.page([offer(i) for i in range(1, 6)])
        self.assertEqual([row.photo for row in rows], [original(i) for i in range(1, 6)])
        self.assertLessEqual(maximum, 2)
        self.assertEqual(count, 5)
