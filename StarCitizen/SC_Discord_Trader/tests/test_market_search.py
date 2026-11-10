"""Поиск на искусственных данных: API-контракт, неизвестное Q, приватность и настоящий SDK."""

import asyncio
import json
import unittest
from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import discord
import httpx
from discord.http import handle_message_parameters

from trader.config import Settings
from trader.discord_bot import PanelView, TraderBot
from trader.discord_ui import render
from trader.marketplace import MarketError, UexMarketplace
from trader.search import find_offers, minimum_quality
from trader.search_ui import FindAgain, FindModal, ItemPicker, OffersView, offer_embed, show_offers

ITEM = {"id": 7, "id_category": 10, "name": "Example Mining Head"}


def listing(number, **changes):
    """Создаёт вымышленное объявление number; changes задаёт проверяемое отличие."""
    return {"id": number, "id_item": 7, "operation": "sell", "type": "item", "is_sold_out": 0,
            "quality": 900 + number, "price": number * 100, "currency": "UEC", "unit": "unit",
            "in_stock": 2, "slug": f"synthetic-offer-{number}", "user_username": f"Synthetic_{number}",
            "location": "Example Station", "photos": None, **changes}


class SearchDataTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет реальный клиент UEX через локальный MockTransport без настоящих карточек."""

    async def asyncSetUp(self):
        """Подготавливает проверенный аккаунт и единственный подменённый GET-ресурс."""
        self.rows, self.requests = [], []

        def respond(request):
            """Запрещает все записи и собирает параметры публичного чтения."""
            self.assertEqual(request.method, "GET")
            self.assertEqual(request.url.path, "/2.0/marketplace_listings/")
            self.requests.append(request)
            return httpx.Response(200, json={"status": "ok", "data": self.rows})

        self.client = httpx.AsyncClient(transport=httpx.MockTransport(respond))
        self.market = UexMarketplace(self.client, "synthetic-app-token", "test", interval=0)
        self.core = SimpleNamespace(account=AsyncMock(return_value={"username": "SyntheticOwner"}),
                                    market_for=Mock(return_value=self.market))

    async def asyncTearDown(self):
        """Закрывает локальный HTTP-клиент без внешнего соединения."""
        await self.client.aclose()

    async def result(self, quality=None):
        """Загружает вымышленный товар с необязательным порогом quality."""
        return await find_offers(self.core, "42", ITEM, quality)

    async def test_sold_out_and_foreign_rows_are_removed_before_pages(self):
        """Флаг Sold Out отсекает карточки, а нулевой запас сам по себе не подменяет этот флаг."""
        self.rows = [listing(i, quality=None if i % 3 == 0 else 900 + i) for i in range(1, 13)]
        self.rows[4]["in_stock"] = 0
        self.rows += [listing(13, is_sold_out=1), listing(14, is_sold_out="1"), listing(15, operation="buy"),
                      listing(16, type="service"), listing(17, id_item=8), listing(18, is_sold_out=None)]
        result = await self.result()
        self.assertEqual(len(result.offers), 12)
        self.assertEqual(result.received, 18)
        self.assertEqual([o.listing_id for o in result.ordered("price_asc")], list(range(1, 13)))
        self.assertIsNone(result.offers[4].stock)
        self.assertNotIn("Запас", offer_embed(result.item_name, result.offers[4]).description)
        self.assertEqual(dict(self.requests[0].url.params), {"id_item": "7", "operation": "sell"})
        self.assertNotIn("secret-key", self.requests[0].headers)
        self.assertEqual(self.requests[0].headers["authorization"], "Bearer synthetic-app-token")

    async def test_missing_quality_is_last_and_cannot_pass_a_threshold(self):
        """Неизвестное Q остаётся в обычном поиске, но не считается подходящим заданному минимуму."""
        self.rows = [listing(1, quality=None), listing(2, quality="950"), listing(3, quality=1000),
                     listing(4, quality=0), listing(5, quality="invalid"), listing(6, quality=949)]
        result = await self.result()
        self.assertEqual([o.listing_id for o in result.ordered("quality_desc")], [3, 2, 6, 1, 4, 5])
        filtered = await self.result(950)
        self.assertEqual({o.listing_id for o in filtered.offers}, {2, 3})
        self.assertEqual(filtered.quality_from, 950)

    async def test_quality_mode_uses_all_pages_and_disappears_only_when_all_unknown(self):
        """Качество на второй странице включает режим даже при пустом Q у первой пятёрки."""
        self.rows = [listing(i, quality=None) for i in range(1, 13)]
        self.assertEqual((await self.result()).modes, ("price_asc", "price_desc"))
        self.rows[-1]["quality"] = 975
        result = await self.result()
        self.assertIn("quality_desc", result.modes)
        self.assertEqual(result.ordered("quality_desc")[0].listing_id, 12)

    async def test_unknown_prices_are_last_and_different_units_are_not_compared(self):
        """Договорные/невалидные цены идут последними внутри группы; валюты и единицы разделены."""
        self.rows = [listing(1, price=10), listing(2, price=0), listing(3, price="NaN"),
                     listing(4, price=30), listing(5, price=1, currency="WIF"), listing(6, price=1000, unit="set")]
        result = await self.result()
        self.assertEqual([o.listing_id for o in result.ordered("price_asc")], [6, 1, 4, 2, 3, 5])
        self.assertEqual([o.listing_id for o in result.ordered("price_desc")], [6, 4, 1, 2, 3, 5])

    async def test_safe_links_keep_full_username_and_only_public_uex_photo(self):
        """Имя магазина не обрезается; подставные адреса фото и Markdown не становятся URL назначения."""
        seller = "Synthetic_" + "x" * 110 + "[shop](name)"
        self.rows = [listing(1, user_username=seller, slug="test/with?#spaces and symbols",
                             photos=json.dumps(["http://cdn.uexcorp.space/test.png", "https://example.invalid/pixel.png",
                                                "https://user:pass@cdn.uexcorp.space/test.png",
                                                "https://cdn.uexcorp.space/synthetic-photo.png"]))]
        offer = (await self.result()).offers[0]
        self.assertIn("x" * 110, offer.store_url)
        self.assertIn("%5Bshop%5D%28name%29", offer.store_url)
        self.assertTrue(offer.url.startswith("https://uexcorp.space/marketplace/item/info/test%2Fwith%3F%23"))
        self.assertEqual(offer.photo, "https://cdn.uexcorp.space/synthetic-photo.png")

    async def test_photo_csv_trailing_separator_and_json_formats_keep_a_valid_image_url(self):
        """Разделитель UEX не входит в адрес фото; разные форматы не обходят проверку домена."""
        expected = "https://cdn.uexcorp.space/synthetic-photo.jpg"
        formats = [expected, expected + ",", " " + expected + ", \n",
                   "https://example.invalid/no.jpg, " + expected + ",",
                   "https://user:pass@cdn.uexcorp.space/no.jpg," + expected + ",",
                   json.dumps(expected), json.dumps([expected]), [expected]]
        for photos in formats:
            with self.subTest(photos=photos):
                self.rows = [listing(1, photos=photos)]
                offer = (await self.result()).offers[0]
                self.assertEqual(offer.photo, expected)
                self.assertEqual(offer_embed(ITEM["name"], offer).thumbnail.url, expected)

    async def test_empty_response_is_distinct_from_an_invalid_response(self):
        """Штатное отсутствие продаж не скрывает повреждённую структуру ответа UEX."""
        self.rows = False
        self.assertEqual((await self.result()).offers, ())
        self.rows = {"unexpected": "shape"}
        with self.assertRaisesRegex(MarketError, "uex_invalid_listings"):
            await self.result()
        with self.assertRaises(ValueError):
            await self.market.offers(True)

    async def test_account_change_after_request_does_not_return_stale_results(self):
        """Повторная проверка подключения не отдаёт результат старому личному окну."""
        self.rows = [listing(1)]
        self.core.account.side_effect = [{"username": "Before"}, {"username": "After"}]
        with self.assertRaises(PermissionError):
            await self.result()

    def test_quality_input_is_optional_but_never_silently_relaxed(self):
        """Пустой порог разрешён, а дроби, ноль и значения вне 1–1000 отклоняются."""
        self.assertIsNone(minimum_quality(" "))
        self.assertEqual(minimum_quality("1000"), 1000)
        for value in ("0", "-1", "1001", "9.5", "abc"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                minimum_quality(value)


class SearchWindowTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет настоящие ViewStore/сериализацию SDK с искусственным транспортом Discord."""

    async def asyncSetUp(self):
        """Готовит локальную регистрацию окон и искусственный снимок из двенадцати продаж."""
        self.client = discord.Client(intents=discord.Intents.none())
        self.views, self.visible = [], {}
        self.changed = asyncio.Event()
        self.bot = SimpleNamespace(interaction_allowed=Mock(return_value=True), show_menu=AsyncMock(), begin_disconnect=AsyncMock())
        market = Mock()
        market.offers = AsyncMock(return_value=[listing(i, quality=None if i == 1 else 900 + i) for i in range(1, 13)])
        core = SimpleNamespace(account=AsyncMock(return_value={"username": "SyntheticOwner"}), market_for=Mock(return_value=market))
        self.bot.service = core
        self.result = await find_offers(core, "42", ITEM, None)
        self.market = market

    async def asyncTearDown(self):
        """Останавливает таймеры всех искусственных личных окон."""
        for view in self.views:
            view.stop()
        await self.client.close()

    def interaction(self, *, private=False, deferred=False):
        """Создаёт ответ на личное сообщение10 либо новую форму с проверкой SDK-параметров."""
        message = SimpleNamespace(id=10, flags=SimpleNamespace(ephemeral=True))

        async def save(**values):
            """Сериализует реальные embeds/View и регистрирует успешно отправленное окно."""
            self.visible = values
            with handle_message_parameters(content=values.get("content"), view=values.get("view"),
                                           **({"embeds": values["embeds"]} if "embeds" in values else {"embed": values.get("embed")})) as parameters:
                self.serialized = parameters.payload
            view = values.get("view")
            if view is not None:
                self.views.append(view)
                self.client._connection.store_view(view, 10)
            self.changed.set()
            return SimpleNamespace(id=10)

        interaction = SimpleNamespace(user=SimpleNamespace(id=42), extras={}, message=message if private else None,
                                      expires_at=discord.utils.utcnow() + timedelta(minutes=15),
                                      response=SimpleNamespace(is_done=Mock(return_value=deferred),
                                                               send_message=AsyncMock(side_effect=save),
                                                               edit_message=AsyncMock(side_effect=save),
                                                               defer=AsyncMock(), send_modal=AsyncMock()),
                                      edit_original_response=AsyncMock(side_effect=save), followup=SimpleNamespace(send=AsyncMock()))
        return interaction

    async def dispatch(self, item, value=None):
        """Передаёт нажатие или выбор через настоящий SDK ViewStore, включая новые custom_id."""
        self.changed.clear()
        click = self.interaction(private=True)
        click.data = {"custom_id": item.custom_id}
        if value is not None:
            click.data["values"] = [value]
        self.client._connection._view_store.dispatch_view(3 if value is not None else 2, item.custom_id, click)
        await asyncio.wait_for(self.changed.wait(), 1)

    async def test_five_cards_links_and_sdk_payload_fit_discord(self):
        """Реальные Embed содержат два назначения ссылок, фото только при наличии и укладываются в лимиты."""
        await OffersView(self.bot, "42", self.result).show(self.interaction())
        embeds = self.visible["embeds"]
        self.assertEqual(len(embeds), 5)
        self.assertLessEqual(sum(len(embed) for embed in embeds), 6000)
        self.assertNotIn("Q", embeds[0].title)
        self.assertIn("/synthetic-offer-1/", embeds[0].url)
        self.assertIn("https://uexcorp.space/@Synthetic_1?tab=marketplace", embeds[0].description)
        self.assertNotIn("thumbnail", embeds[0].to_dict())
        self.assertTrue(self.visible["ephemeral"])
        self.assertEqual(len(self.serialized["embeds"]), 5)
        self.assertNotIn("/поиск", self.visible["content"])
        self.assertEqual(len(self.serialized["components"]), 2)
        sorting = self.serialized["components"][0]["components"]
        self.assertEqual(len(sorting), 1)
        self.assertEqual(sorting[0]["type"], 3)
        self.assertEqual([option["value"] for option in sorting[0]["options"]],
                         ["price_asc", "price_desc", "quality_desc"])
        self.assertEqual([option["value"] for option in sorting[0]["options"] if option["default"]], ["price_asc"])
        self.assertEqual([b["label"] for b in self.serialized["components"][1]["components"]],
                         ["← Назад", "Далее →"])

    async def test_sdk_select_and_buttons_work_after_replace_without_uex_requests(self):
        """Новый select выбирает режим напрямую; первая попытка после замены работает, страницы5/5/2."""
        await OffersView(self.bot, "42", self.result).show(self.interaction())
        self.assertEqual(len(self.visible["embeds"]), 5)
        for expected in (5, 2):
            view = self.visible["view"]
            await self.dispatch(view.children[2])
            self.assertEqual(len(self.visible["embeds"]), expected)
        await self.dispatch(self.visible["view"].sorting, "price_desc")
        self.assertEqual(self.visible["view"].mode, "price_desc")
        self.assertEqual(self.visible["view"].page, 0)
        await self.dispatch(self.visible["view"].children[2])
        self.assertEqual(self.visible["view"].mode, "price_desc")
        self.assertEqual(self.visible["view"].page, 1)
        self.assertEqual([o.value for o in self.visible["view"].sorting.options if o.default], ["price_desc"])
        self.assertEqual(self.market.offers.await_count, 1)
        await self.dispatch(self.visible["view"].sorting, "quality_desc")
        self.assertEqual(self.visible["view"].mode, "quality_desc")
        self.assertEqual(self.visible["view"].page, 0)
        await render(self.interaction(private=True), content="Меню", view=PanelView(self.bot, "42"))
        self.assertEqual(self.serialized["embeds"], [])

    async def test_modal_defers_privately_and_keeps_quality_for_item_selection(self):
        """Даже форма из публичной панели создаёт только личный результат и сохраняет порог."""
        self.bot.listings = SimpleNamespace(catalog_ready=True, items=AsyncMock(return_value=[ITEM, {**ITEM, "id": 8}]))
        modal = FindModal(self.bot, "42")
        modal.query._value, modal.quality._value = "Example", "950"
        click = self.interaction(deferred=True)
        await modal.on_submit(click)
        click.response.defer.assert_awaited_once_with(ephemeral=True, thinking=True)
        self.assertIsInstance(self.visible["view"], ItemPicker)
        self.assertEqual(self.visible["view"].quality, 950)
        self.assertEqual(self.market.offers.await_count, 1)

    async def test_empty_search_keeps_explicit_filter_and_does_not_offer_useless_sorting(self):
        """Пустой результат предлагает изменить форму вместо скрытого снижения качества."""
        self.market.offers.return_value = [listing(1, quality=None)]
        await show_offers(self.bot, self.interaction(deferred=True), "42", ITEM, 950)
        self.assertIsInstance(self.visible["view"], FindAgain)
        self.assertEqual(self.visible["view"].quality, "950")
        self.assertIn("950", self.visible["content"])
        self.assertEqual(self.serialized["embeds"], [])

    async def test_no_quality_offers_only_price_sorting_and_api_failure_stays_a_failure(self):
        """Окно без качества не предлагает Q; отказ UEX не выдаётся за отсутствие объявлений."""
        self.market.offers.return_value = [listing(1, quality=None), listing(2, quality=None)]
        result = await find_offers(self.bot.service, "42", ITEM, None)
        await OffersView(self.bot, "42", result).show(self.interaction())
        self.assertEqual([o.value for o in self.visible["view"].sorting.options], ["price_asc", "price_desc"])
        await self.dispatch(self.visible["view"].sorting, "price_desc")
        self.assertEqual(self.visible["view"].mode, "price_desc")
        await self.dispatch(self.visible["view"].sorting, "price_asc")
        self.assertEqual(self.visible["view"].mode, "price_asc")
        self.market.offers.side_effect = MarketError("uex_network")
        click = self.interaction(deferred=True)
        with self.assertRaises(MarketError) as failure:
            await show_offers(self.bot, click, "42", ITEM, None)
        await self.visible["view"].on_error(click, failure.exception, Mock())
        self.assertTrue(click.followup.send.await_args.kwargs["ephemeral"])
        self.assertIn("Не удалось загрузить", click.followup.send.await_args.args[0])

    async def test_api_limit_and_price_groups_are_visible_to_the_reader(self):
        """Предупреждения о неполной выдаче и несопоставимых единицах не остаются только в логах."""
        from dataclasses import replace
        mixed = replace(self.result, received=1000,
                        offers=(self.result.offers[0], replace(self.result.offers[1], currency="WIF")))
        await OffersView(self.bot, "42", mixed).show(self.interaction())
        self.assertIn("1000", self.visible["content"])
        self.assertIn("часть предложений", self.visible["content"])
        self.assertIn("каждой валюты и единицы", self.visible["content"])

    async def test_foreign_owner_and_lost_role_cannot_use_search(self):
        """Проверка владельца и роли срабатывает до действий с выдачей и формой."""
        view = OffersView(self.bot, "42", self.result)
        self.views.append(view)
        click = self.interaction(private=True)
        click.response.send_message = AsyncMock()
        click.user.id = 99
        self.assertFalse(await view.interaction_check(click))
        click.user.id = 42
        self.bot.interaction_allowed.return_value = False
        modal = FindModal(self.bot, "42")
        self.assertFalse(await modal.interaction_check(click))

    async def test_modal_opens_without_waiting_for_uex_or_discord_http(self):
        """Кнопка поиска использует локальные проверки до открытия формы, не теряя первый клик."""
        store = Mock()
        store.get.return_value = {"secret": "synthetic-ciphertext", "app_token": "synthetic-ciphertext"}
        async with TraderBot(Settings(), store) as bot:
            bot.interaction_allowed = Mock(return_value=True)
            click = self.interaction()
            await bot.begin_search(click)
            self.assertIsInstance(click.response.send_modal.await_args.args[0], FindModal)

    def test_photo_quality_and_long_values_render_without_discord_overflow(self):
        """Пять крупных карточек сохраняют фото и укладываются в общий лимит текста SDK."""
        original = self.result.offers[1]
        offer = type(original)(original.listing_id, original.url, "Synthetic_[shop]", 1000, Decimal("1e18"),
                               "UEC", "unit", 1000000, "Место_" * 30, "https://cdn.uexcorp.space/synthetic.png")
        embed = offer_embed("Товар_" * 40, offer)
        self.assertIn("Q1000", embed.title)
        self.assertEqual(embed.thumbnail.url, offer.photo)
        self.assertIn(r"Synthetic\_\[shop\]", embed.description)
        self.assertLessEqual(len(embed) * 5, 6000)


if __name__ == "__main__":
    unittest.main()
