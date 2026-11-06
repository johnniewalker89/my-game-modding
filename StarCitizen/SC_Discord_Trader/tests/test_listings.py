"""Регрессии объявлений: владелец, подтверждение, HTTP-результат и восстановление."""

import asyncio
import base64
import json
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import discord
import httpx

from trader.config import Settings
from trader.discord_bot import PanelView, TraderBot
from trader.listings import ListingService, listing_payload
from trader.listing_ui import CatalogView, ConditionsModal, DraftView, ListingsHome, ManageView, PhotoModal, PreviewView, SearchAgain, SearchModal, draft_embed, render
from trader.marketplace import MarketError, UexMarketplace
from trader.service import DemoSink, TraderService
from trader.store import Store, Vault
from trader.translation import TranslationError

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD7sAAAAASUVORK5CYII=")


class ListingTests(unittest.IsolatedAsyncioTestCase):
    """Проводит запросы через настоящий адаптер с подменённым HTTP, без внешних записей."""

    async def asyncSetUp(self):
        """Открывает отдельную SQLite и два независимых подключённых аккаунта."""
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "state.sqlite3")
        self.requests, self.active = [], []
        self.post_fault = self.delete_fault = None
        self.denied = set()
        self.sink = DemoSink()
        self.sink.allowed = AsyncMock(side_effect=lambda owner, **kwargs: owner not in self.denied)
        self.client = httpx.AsyncClient(transport=httpx.MockTransport(self.http))
        self.market = UexMarketplace(self.client, "application-fixture", "test", interval=0, catalog_store=self.store)
        translator = SimpleNamespace(translate=AsyncMock(side_effect=lambda text, *args, **kwargs: "Translated " + text))
        self.core = TraderService(self.store, Vault(Path(self.temp.name) / "key"), self.market, translator, self.sink)
        await self.core.connect("demo-1", "secret-one", "application-one")
        await self.core.connect("demo-2", "secret-two", "application-two")
        self.service = ListingService(self.core, "production")

    async def asyncTearDown(self):
        """Закрывает HTTP и файлы только своего тестового окружения."""
        await self.client.aclose()
        self.store.close()
        self.temp.cleanup()

    def http(self, request):
        """Имитирует официальный контракт, включая потерю ответа уже отправленного запроса."""
        self.requests.append(request)
        resource = request.url.path.strip("/").split("/")[-1]
        if resource == "user":
            data = {"username": "One" if request.headers.get("secret-key") == "secret-one" else "Two"}
        elif resource == "categories":
            data = [{"id": 36, "name": "Commodities", "section": "Commodities", "type": "item"},
                    {"id": 3, "name": "Weapons", "section": "Weapons", "type": "item"},
                    {"id": 87, "name": "Harvestables", "section": "Commodities", "type": "item"},
                    {"id": 69, "name": "Consumable", "section": "Consumable", "type": "item"},
                    {"id": 99, "name": "Hauling", "type": "service"}]
        elif resource == "items":
            data = {"36": [{"id": 5885, "id_category": 36, "name": "Copper", "is_commodity": 1}],
                    "87": [{"id": 5704, "id_category": 87, "name": "Sadaryx", "is_commodity": 0}],
                    "69": None,
                    "3": [{"id": 2265, "id_category": 3, "name": "Karna Rifle", "is_commodity": 0}]}[request.url.params["id_category"]]
        elif resource == "marketplace_advertise":
            if self.post_fault == "network":
                raise httpx.ReadTimeout("fixture lost response", request=request)
            if self.post_fault == "bad-quality":
                return httpx.Response(400, json={"status": "invalid_quality"})
            if self.post_fault == "malformed":
                return httpx.Response(200, json={"status": "ok", "data": {}})
            body = json.loads(request.content)
            data = {"id_listing": "9971" if body["is_production"] else "0",
                    "test": not body["is_production"], "url_image": "https://cdn.uexcorp.space/fixture.jpg" if body.get("image_data") else None}
        elif resource == "marketplace_listings" and request.method == "DELETE":
            if isinstance(self.delete_fault, tuple):
                return httpx.Response(self.delete_fault[0], json={"status": self.delete_fault[1]})
            if self.delete_fault:
                raise httpx.ReadTimeout("fixture lost deletion response", request=request)
            data = []
        elif resource == "marketplace_listings":
            data = self.active
        else:
            raise AssertionError("Unexpected request " + str(request.url))
        return httpx.Response(200, json={"status": "ok", "data": data})

    async def ready(self, owner="demo-1"):
        """Заполняет карточку Copper Q958, цена за SCU, без сетевой публикации."""
        draft = await self.service.start(owner, 36, 5885)
        return await self.service.edit(owner, draft["id"], 0, {"conditions": {
            "quantity": "2", "price": "30 000 000", "quality": "958", "location": "Area18", "description": "Meet in game."}})

    def writes(self, method="POST"):
        """Возвращает только фактические внешние попытки записи выбранного метода."""
        return [r for r in self.requests if r.method == method]

    async def test_empty_category_null_is_cached_across_restart_without_masking_bad_catalog(self):
        """Настоящий ok/null — пустой каталог; кеш переживает restart, но сохраняет срок годности."""
        self.assertEqual(await self.market.catalog(69), [])
        count = len(self.requests)
        restarted = UexMarketplace(self.client, "fixture", "test", interval=0, catalog_store=self.store)
        self.assertEqual(await restarted.catalog(69), [])
        self.assertEqual(len(self.requests), count)
        saved = self.store.get("catalog_cache", "uex:items:69")
        saved["cached_at"] = time.time() - 86401
        self.store.put("catalog_cache", saved)
        expired = UexMarketplace(self.client, "fixture", "test", interval=0, catalog_store=self.store)
        await expired.catalog(69)
        self.assertEqual(len(self.requests), count + 1)
        async with httpx.AsyncClient(transport=httpx.MockTransport(
                lambda request: httpx.Response(200, json={"status": "ok", "data": {"unexpected": True}}))) as client:
            invalid = UexMarketplace(client, "fixture", "test", interval=0)
            with self.assertRaises(MarketError):
                await invalid.catalog(69)

    async def test_global_search_finds_original_item_category_and_reuses_persistent_index(self):
        """Имя ищется вне выбранной категории, результат несёт настоящий id_category."""
        rows = await self.service.items("demo-1", None, "Sadaryx")
        self.assertEqual([(r["id"], r["id_category"]) for r in rows], [(5704, 87)])
        self.assertEqual(rows[0]["category_label"], "Сырьё → Собираемые ресурсы")
        self.assertEqual(rows[0]["name"], "Sadaryx")
        self.assertEqual(await self.service.items("demo-1", 69, "Sadaryx"), [])
        self.assertEqual((await self.service.items("demo-1", None, "Copper"))[0]["name"], "Copper")
        self.core.translator.translate.assert_not_awaited()
        count = len(self.requests)
        self.core.market = UexMarketplace(self.client, "fixture", "test", interval=0, catalog_store=self.store)
        restarted = ListingService(self.core, "production")
        self.assertEqual((await restarted.items("demo-1", None, "Sadaryx"))[0]["id_category"], 87)
        self.assertEqual(len(self.requests), count)
        with self.assertRaises(ValueError):
            await restarted.items("demo-1", None, " ")
        self.assertEqual(self.writes(), [])

    async def test_catalog_refresh_is_atomic_and_keeps_last_complete_snapshot_when_uex_fails(self):
        """Cold start сообщает сбой; сохранённый полный каталог доступен при неудачном обновлении."""
        original = self.core.market.catalog
        self.core.market.catalog = AsyncMock(side_effect=MarketError("uex_network"))
        with self.assertRaises(MarketError):
            await self.service.items("demo-1", None, "Sadaryx")
        self.assertFalse(self.service.catalog_ready)
        self.core.market.catalog = original
        await self.service.prepare_catalog()
        snapshot = self.store.get("catalog_index", "uex-items-v1")
        snapshot["cached_at"] = time.time() - 90000
        self.store.put("catalog_index", snapshot)
        restarted = ListingService(self.core, "production")
        self.assertTrue(restarted.catalog_ready)
        self.core.market.catalog = AsyncMock(side_effect=MarketError("uex_network"))
        with self.assertRaises(MarketError):
            await restarted.prepare_catalog()
        rows = await restarted.items("demo-1", None, "Sadaryx")
        self.assertEqual([(r["name"], r["id_category"]) for r in rows], [("Sadaryx", 87)])
        self.assertEqual(self.store.get("catalog_index", "uex-items-v1"), snapshot)

    async def test_global_search_modal_selects_concrete_item_and_assigns_category_automatically(self):
        """Первое действие — общий поиск; выбор товара передаёт его категорию в черновик."""
        bot = SimpleNamespace(listings=self.service)
        response = SimpleNamespace(send_modal=AsyncMock(), defer=AsyncMock(), is_done=lambda: True)
        interaction = SimpleNamespace(response=response, edit_original_response=AsyncMock(),
                                      message=SimpleNamespace(attachments=[]))
        await ListingsHome(bot, "demo-1").create(interaction)
        modal = response.send_modal.await_args.args[0]
        self.assertIsInstance(modal, SearchModal)
        self.assertTrue(modal.query.required)
        self.assertIn("Создать объявление", [getattr(child, "label", "") for child in ListingsHome(bot, "demo-1").children])
        modal.query = "Sadaryx"
        await modal.on_submit(interaction)
        view = interaction.edit_original_response.await_args.kwargs["view"]
        self.assertIsInstance(view, CatalogView)
        self.assertEqual(view.selection.options[0].description, "Сырьё → Собираемые ресурсы")
        self.assertNotIn("←", [getattr(item, "label", "") for item in view.children])
        view.selection = SimpleNamespace(values=["5704"])
        await view.selected(interaction)
        drafts = self.store.all("listing_draft", "demo-1")
        self.assertEqual((drafts[0]["item"]["id"], drafts[0]["item"]["id_category"]), (5704, 87))
        self.assertEqual(self.writes(), [])

    async def test_no_search_results_offer_retry_without_category_navigation(self):
        """Не найденный товар позволяет повторить поиск без лишнего пути через категории."""
        bot = SimpleNamespace(listings=self.service)
        modal = SearchModal(bot, "demo-1")
        modal.query = "ZZZmissingItem999"
        interaction = SimpleNamespace(response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True,
                                      send_modal=AsyncMock()), edit_original_response=AsyncMock())
        await modal.on_submit(interaction)
        values = interaction.edit_original_response.await_args.kwargs
        self.assertIn("Товар не найден", values["content"])
        self.assertIsInstance(values["view"], SearchAgain)
        self.assertNotIn("Категории", [getattr(child, "label", "") for child in values["view"].children])
        await values["view"].search(interaction)
        self.assertTrue(interaction.response.send_modal.await_args.args[0].query.required)

    async def test_create_native_quality_photo_total_and_no_double_click(self):
        """Публикация несёт нативное качество и фото, а два подтверждения дают один POST."""
        draft = await self.ready()
        draft = await self.service.edit("demo-1", draft["id"], draft["revision"], {"photo": PNG})
        results = await asyncio.gather(*[self.service.publish("demo-1", draft["id"], draft["revision"]) for _ in range(2)], return_exceptions=True)
        self.assertEqual(sum(isinstance(r, dict) for r in results), 1)
        self.assertEqual(len(self.writes()), 1)
        request = self.writes()[0]
        body = json.loads(request.content)
        self.assertEqual((body["quality"], body["in_stock"], body["price"], body["unit"]), (958, 2, 30000000, "scu"))
        self.assertNotIn("Price:", body["description"])
        self.assertNotIn("UEC total", body["description"])
        self.assertEqual(base64.b64decode(body["image_data"]), PNG)
        self.assertEqual(request.headers["secret-key"], "secret-one")
        self.assertEqual(request.headers["Authorization"], "Bearer application-one")
        self.assertEqual(body["is_production"], 1)
        self.assertFalse(self.market.production)  # отправка сообщений остаётся test
        rows = await self.service.own("demo-1")
        self.assertEqual([(r["external_id"], r["status"]) for r in rows], [("9971", "created")])
        self.assertFalse(self.store.get("listing_draft", draft["id"]).get("photo"))

    async def test_personal_application_is_used_for_listing_create_list_and_delete(self):
        """Личные карточки используют токен владельца, справочник остаётся общим."""
        draft = await self.ready("demo-2")
        await self.service.publish("demo-2", draft["id"], draft["revision"])
        rows = await self.service.own("demo-2")
        await self.service.remove("demo-2", rows[0]["id"])
        personal = [r for r in self.requests if r.url.path.rstrip("/").endswith(
            ("marketplace_advertise", "marketplace_listings"))]
        self.assertEqual({r.method for r in personal}, {"GET", "POST", "DELETE"})
        self.assertTrue(all(r.headers["Authorization"] == "Bearer application-two" for r in personal))
        catalog = [r for r in self.requests if r.url.path.rstrip("/").endswith(("categories", "items"))]
        self.assertTrue(catalog)
        self.assertTrue(all(r.headers["Authorization"] == "Bearer application-fixture" for r in catalog))

    async def test_sandbox_id_zero_is_not_real_listing(self):
        """Sandbox-проверка не появляется как настоящее собственное объявление."""
        self.service = ListingService(self.core, "test")
        draft = await self.ready()
        result = await self.service.publish("demo-1", draft["id"], draft["revision"])
        self.assertEqual(result["status"], "tested")
        self.assertEqual(self.store.all("advertisement"), [])
        self.assertEqual(json.loads(self.writes()[0].content)["is_production"], 0)

    async def test_offer_deadline_is_optional_and_explicit_selection_is_preserved(self):
        """По умолчанию срок не отправляется; выбранные часы передаются без подмены сроком размещения."""
        draft = await self.ready()
        self.assertNotIn("hours_expiration", listing_payload(draft))
        draft = await self.service.edit("demo-1", draft["id"], draft["revision"], {"hours": 24})
        self.assertEqual(listing_payload(draft)["hours_expiration"], 24)
        draft = await self.service.edit("demo-1", draft["id"], draft["revision"], {"hours": 0})
        self.assertNotIn("hours_expiration", listing_payload(draft))

    async def test_location_defaults_or_passes_through_without_translation(self):
        """Форма подставляет By arrangement, пустое место допустимо, своё место не переводится."""
        draft = await self.service.start("demo-1", 36, 5885)
        self.assertEqual(draft["location"], "By arrangement")
        modal = ConditionsModal(SimpleNamespace(listings=self.service), draft)
        self.assertEqual(modal.fields["location"].default, "By arrangement")
        self.assertFalse(modal.fields["location"].required)
        values = {"quantity": "13", "price": "5 000 000", "quality": "", "location": " ", "description": ""}
        draft = await self.service.edit("demo-1", draft["id"], draft["revision"], {"conditions": values})
        body = listing_payload(draft)
        self.assertEqual(body["location"], "By arrangement")
        self.assertIn("Quantity: 13 scu.", body["description"])
        draft = await self.service.edit("demo-1", draft["id"], draft["revision"],
                                        {"conditions": {**values, "location": "Ориса, по договорённости"}})
        self.assertEqual(listing_payload(draft)["location"], "Ориса, по договорённости")
        self.assertIn("Ориса, по договорённости", listing_payload(draft)["description"])
        self.assertNotIn("location_en", draft)
        self.core.translator.translate.assert_not_awaited()
        self.assertEqual(next(f["value"] for f in draft_embed(draft, preview=True).to_dict()["fields"]
                              if f["name"] == "Место"), "Ориса, по договорённости")

    async def test_owner_account_role_and_stale_preview_block_writes(self):
        """Чужой участник, смена UEX, потеря роли и старый просмотр не могут публиковать."""
        draft = await self.ready()
        with self.assertRaises(PermissionError):
            self.service.draft_snapshot("demo-2", draft["id"])
        with self.assertRaises(PermissionError):
            await self.service.publish("demo-2", draft["id"], draft["revision"])
        newer = await self.service.edit("demo-1", draft["id"], draft["revision"], {"hidden": True})
        with self.assertRaises(ValueError):
            await self.service.publish("demo-1", draft["id"], draft["revision"])
        self.denied.add("demo-1")
        with self.assertRaises(PermissionError):
            await self.service.publish("demo-1", draft["id"], newer["revision"])
        self.denied.clear()
        await self.core.connect("demo-1", "secret-two", "application-two")
        with self.assertRaises(PermissionError):
            self.service.draft_snapshot("demo-1", draft["id"])
        with self.assertRaises(PermissionError):
            await self.service.publish("demo-1", draft["id"], newer["revision"])
        self.assertEqual(self.writes(), [])

    async def test_validation_rejects_wrong_item_numbers_photo_and_missing_exchange_terms(self):
        """Ошибочные условия не попадают на площадку и не портят сохранённый черновик."""
        with self.assertRaises(ValueError):
            await self.service.start("demo-1", 36, 2265)
        draft = await self.ready()
        base = {"quantity": "2", "price": "30", "quality": "958", "location": "Area18", "description": ""}
        for key, value in (("quantity", "0"), ("quantity", "1.5"), ("price", "-1"), ("price", "nan"), ("quality", "1001")):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                await self.service.edit("demo-1", draft["id"], draft["revision"], {"conditions": {**base, key: value}})
        with self.assertRaises(ValueError):
            await self.service.edit("demo-1", draft["id"], draft["revision"], {"photo": b"<svg>"})
        self.assertEqual((await self.service.draft("demo-1", draft["id"]))["revision"], draft["revision"])
        newer = await self.service.edit("demo-1", draft["id"], draft["revision"], {"conditions": base})
        newer = await self.service.edit("demo-1", draft["id"], newer["revision"], {"operation": "trade"})
        with self.assertRaises(ValueError):
            await self.service.review("demo-1", draft["id"], newer["revision"])
        self.assertEqual(self.writes(), [])

    async def test_translation_failure_or_role_change_does_not_publish_or_save_partial_edit(self):
        """Перевод и повторная проверка роли завершаются до сохранения подтверждаемой версии."""
        draft = await self.ready()
        changes = {"conditions": {"quantity": "1", "price": "5", "quality": "958", "location": "Orison", "description": "Уточним условия сделки"}}
        self.core.translator.translate.side_effect = RuntimeError("fixture")
        with self.assertRaises(RuntimeError):
            await self.service.edit("demo-1", draft["id"], draft["revision"], changes)
        self.assertEqual((await self.service.draft("demo-1", draft["id"]))["quantity"], 2)
        def revoke(*args, **kwargs):
            """Снимает роль во время перевода, до возможной записи черновика."""
            self.denied.add("demo-1")
            return "Orison"
        self.core.translator.translate.side_effect = revoke
        with self.assertRaises(PermissionError):
            await self.service.edit("demo-1", draft["id"], draft["revision"], changes)
        self.assertEqual(self.writes(), [])

    async def test_description_quality_keeps_its_meaning_during_translation(self):
        """Оборот «качества 958» передаётся защищённым целиком, а не как голое количество."""
        draft = await self.ready()
        await self.service.edit("demo-1", draft["id"], draft["revision"], {"conditions": {
            "quantity": "1", "price": "30", "quality": "958", "location": "Area18",
            "description": "Куплю медь качества 958."}})
        call = self.core.translator.translate.await_args
        self.assertIn("quality 958", call.args[0])
        self.assertIn("quality 958", call.kwargs["protected"])
        self.assertEqual(self.writes(), [])

    async def test_unknown_publication_is_not_retried_and_restart_marks_inflight_unknown(self):
        """Потерянное подтверждение и прерванный процесс не создают повторные POST."""
        draft = await self.ready()
        self.post_fault = "network"
        with self.assertRaises(MarketError) as caught:
            await self.service.publish("demo-1", draft["id"], draft["revision"])
        self.assertTrue(caught.exception.uncertain)
        with self.assertRaises(ValueError):
            await self.service.publish("demo-1", draft["id"], draft["revision"])
        self.assertEqual(len(self.writes()), 1)
        row = self.store.get("listing_draft", draft["id"])
        row["status"] = "sending"
        self.store.put("listing_draft", row)
        restarted = ListingService(self.core, "production")
        self.assertEqual((await restarted.draft("demo-1", draft["id"]))["status"], "unknown")

    async def test_malformed_success_and_known_rejection_are_different_outcomes(self):
        """Неполное подтверждение считается неизвестным результатом, явный отказ — ошибкой."""
        for failure, status, uncertain in (("malformed", "unknown", True), ("bad-quality", "failed", False)):
            draft = await self.ready()
            self.post_fault = failure
            with self.assertRaises(MarketError) as caught:
                await self.service.publish("demo-1", draft["id"], draft["revision"])
            self.assertEqual(caught.exception.uncertain, uncertain)
            self.assertEqual(self.store.get("listing_draft", draft["id"])["status"], status)

    async def test_delete_isolated_and_one_request_even_when_catalog_still_returns_deleted(self):
        """Удаление относится к своему аккаунту и не повторяется после двойного нажатия/старого каталога."""
        self.active = [{"id": 44, "title": "Own listing", "user_username": "One"},
                       {"id": 55, "title": "Someone else's listing", "user_username": "Two"}]
        rows = await self.service.own("demo-1")
        self.assertEqual(len(rows), 1)
        with self.assertRaises(PermissionError):
            await self.service.remove("demo-2", rows[0]["id"])
        results = await asyncio.gather(*[self.service.remove("demo-1", rows[0]["id"]) for _ in range(2)], return_exceptions=True)
        self.assertEqual(sum(isinstance(row, dict) for row in results), 1)
        self.assertEqual(len(self.writes("DELETE")), 1)
        self.assertEqual(dict(self.writes("DELETE")[0].url.params), {"id": "44", "is_production": "1"})
        self.assertEqual(await self.service.own("demo-1"), [])

    async def test_delete_timeout_and_restart_never_report_success_or_retry(self):
        """Неизвестное удаление остаётся видимым для ручной проверки, не превращается в успех."""
        self.active = [{"id": 44, "title": "Own listing", "user_username": "One"}]
        row = (await self.service.own("demo-1"))[0]
        self.delete_fault = True
        with self.assertRaises(MarketError) as caught:
            await self.service.remove("demo-1", row["id"])
        self.assertTrue(caught.exception.uncertain)
        self.assertEqual((await self.service.own("demo-1"))[0]["status"], "delete_unknown")
        with self.assertRaises(ValueError):
            await self.service.remove("demo-1", row["id"])
        self.assertEqual(len(self.writes("DELETE")), 1)
        saved = self.store.get("advertisement", row["id"])
        saved["status"] = "deleting"
        self.store.put("advertisement", saved)
        ListingService(self.core, "production")
        self.assertEqual(self.store.get("advertisement", row["id"])["status"], "delete_unknown")

    async def test_disappearing_active_listing_is_unknown_not_sold_or_deleted(self):
        """Пропавшая активная карточка скрывается, но может вернуться после модерации без потери записи."""
        self.active = [{"id": 44, "title": "Own listing", "user_username": "One"}]
        row = (await self.service.own("demo-1"))[0]
        self.assertEqual(row["status"], "active")
        self.active = []
        self.assertEqual(await self.service.own("demo-1"), [])
        self.assertEqual(self.store.get("advertisement", row["id"])["status"], "unconfirmed")
        self.assertEqual(self.writes("DELETE"), [])
        self.active = [{"id": 44, "title": "After review", "user_username": "One"}]
        returned = (await self.service.own("demo-1"))[0]
        self.assertEqual((returned["id"], returned["status"]), (row["id"], "active"))

    async def test_deleted_on_site_is_acknowledged_when_uex_explicitly_reports_missing(self):
        """404-подобный API-код убирает старую карточку без ложной ошибки и повторного DELETE."""
        for number, http_status in enumerate((200, 400), 100):
            self.active = [{"id": number, "title": "Deleted on site", "user_username": "One"}]
            row = (await self.service.own("demo-1"))[0]
            self.delete_fault = (http_status, "listing_not_found")
            result = await self.service.remove("demo-1", row["id"])
            self.assertEqual(result["status"], "deleted")
            self.assertTrue(result["already_missing"])
            self.assertEqual(await self.service.own("demo-1"), [])
            with self.assertRaises(ValueError):
                await self.service.remove("demo-1", row["id"])
        self.assertEqual(len(self.writes("DELETE")), 2)

    async def test_server_error_or_permission_failure_does_not_confirm_missing_listing(self):
        """Отказ доступа и неподтверждённый ответ сервера не превращаются в успешное удаление."""
        for number, failure, expected in ((200, (500, "listing_not_found"), "delete_unknown"),
                                          (201, (403, "user_not_allowed"), "active")):
            self.active = [{"id": number, "title": "Keep for inspection", "user_username": "One"}]
            row = next(row for row in await self.service.own("demo-1") if row["external_id"] == str(number))
            self.delete_fault = failure
            with self.assertRaises(MarketError):
                await self.service.remove("demo-1", row["id"])
            self.assertEqual(self.store.get("advertisement", row["id"])["status"], expected)
        self.assertEqual(len(self.writes("DELETE")), 2)

    async def test_sandbox_delete_preserves_local_listing(self):
        """Тестовый режим удаления не выдаётся за удаление настоящей карточки."""
        self.service = ListingService(self.core, "test")
        self.active = [{"id": 44, "title": "Own listing", "user_username": "One"}]
        row = (await self.service.own("demo-1"))[0]
        result = await self.service.remove("demo-1", row["id"])
        self.assertEqual(result["status"], "active")
        self.assertEqual(self.writes("DELETE")[0].url.params["is_production"], "0")

    async def test_modal_and_preview_use_actual_sdk_limits_and_render_full_conditions(self):
        """Настоящий SDK собирает формы/фото, а предпросмотр содержит цену и полный английский текст."""
        draft = await self.ready()
        bot = SimpleNamespace(listings=self.service)
        view = DraftView(bot, draft)
        self.assertLessEqual(max(item.row for item in view.children), 4)
        self.assertIn("Предпросмотр", [getattr(item, "label", "") for item in view.children])
        modal = PhotoModal(bot, draft).to_dict()
        self.assertEqual(modal["components"][0]["component"]["type"], discord.ComponentType.file_upload.value)
        embed = draft_embed(draft, preview=True).to_dict()
        self.assertIn("Q958", embed["title"])
        self.assertEqual(embed["description"], listing_payload(draft)["description"])
        self.assertNotIn("Price:", embed["description"])
        self.assertIn({"inline": True, "name": "Всего", "value": "60 000 000 UEC"}, embed["fields"])
        self.assertEqual(len(PreviewView(bot, draft).children), 3)

    async def test_conditions_open_current_revision_after_a_setting_changes(self):
        """Нажатие во время обновления экрана открывает актуальные условия, без ложного конфликта."""
        draft = await self.ready()
        bot = SimpleNamespace(listings=self.service)
        view = DraftView(bot, draft)
        changed = await self.service.edit("demo-1", draft["id"], draft["revision"], {"operation": "sell"})
        interaction = SimpleNamespace(response=SimpleNamespace(send_modal=AsyncMock()))
        self.sink.allowed.reset_mock()
        await view.conditions(interaction)
        self.sink.allowed.assert_not_awaited()
        modal = interaction.response.send_modal.await_args.args[0]
        self.assertEqual(modal.draft["revision"], changed["revision"])
        self.assertEqual(modal.draft["operation"], "sell")
        saved = await self.service.edit("demo-1", modal.draft["id"], modal.draft["revision"],
                                        {"conditions": {key: str(item) for key, item in modal.fields.items()}})
        self.assertEqual(saved["operation"], "sell")
        self.sink.allowed.assert_awaited()
        self.sink.allowed.reset_mock()
        await view.photo(interaction)
        self.sink.allowed.assert_not_awaited()
        self.assertEqual(interaction.response.send_modal.await_args.args[0].draft["revision"], saved["revision"])
        self.assertEqual(self.writes(), [])

    async def test_conditions_survive_translation_failure_and_retry_without_publication(self):
        """Отказ Groq оставляет введённые значения в личном повторе, без сохранения частичного перевода."""
        draft = await self.ready()
        bot = SimpleNamespace(listings=self.service)
        modal = ConditionsModal(bot, draft)
        values = {"quantity": "13", "price": "5000000", "quality": "958",
                  "location": "Area18", "description": "Нужна руда"}
        modal.fields = values
        interaction = SimpleNamespace(response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                                      edit_original_response=AsyncMock())
        self.core.translator.translate.side_effect = TranslationError("fixture unavailable")
        await modal.on_submit(interaction)
        self.assertEqual(self.store.get("listing_draft", draft["id"]), draft)
        retry = interaction.edit_original_response.await_args.kwargs["view"]
        opened = SimpleNamespace(response=SimpleNamespace(send_modal=AsyncMock()))
        self.sink.allowed.reset_mock()
        await retry.retry(opened)
        self.sink.allowed.assert_not_awaited()
        repeated = opened.response.send_modal.await_args.args[0]
        self.assertEqual({key: str(item) for key, item in repeated.fields.items()}, values)
        self.core.translator.translate.side_effect = lambda text, *args, **kwargs: "Translated " + text
        await repeated.on_submit(interaction)
        saved = self.store.get("listing_draft", draft["id"])
        self.assertEqual((saved["quantity"], saved["price"], saved["description_ru"]), (13, 5000000, "Нужна руда"))
        self.assertEqual(saved["status"], "draft")
        self.assertEqual(self.writes(), [])

    async def test_menu_is_personal_and_render_never_overwrites_public_panel(self):
        """/меню работает без UEX-ключа, личные шаги обновляются на месте, общая панель сохраняется."""
        bot = TraderBot(Settings(guild_id=1, role_id=2), self.store)
        bot.interaction_allowed = Mock(return_value=True)
        response = SimpleNamespace(is_done=lambda: False, send_message=AsyncMock(), edit_message=AsyncMock())
        interaction = SimpleNamespace(user=SimpleNamespace(id=123), response=response,
                                      message=SimpleNamespace(flags=SimpleNamespace(ephemeral=False)))
        try:
            await bot.show_menu(interaction)
            self.assertTrue(response.send_message.await_args.kwargs["ephemeral"])
            self.assertIsInstance(response.send_message.await_args.kwargs["view"], PanelView)
            await render(interaction, content="Own data", view=PanelView(bot))
            response.edit_message.assert_not_awaited()
            interaction.message.flags.ephemeral = True
            await bot.show_menu(interaction, replace=True)
            response.edit_message.assert_awaited_once()
            bot.interaction_allowed.return_value = False
            response.send_message.reset_mock()
            await bot.show_menu(interaction)
            self.assertTrue(response.send_message.await_args.kwargs["ephemeral"])
        finally:
            await bot.close()

    async def test_delete_button_requires_a_second_explicit_confirmation(self):
        """Первое нажатие показывает конкретную карточку; внешнее удаление происходит только после второго."""
        row = {"id": "local", "owner_id": "demo-1", "account": "One", "external_id": "44", "title": "Copper", "status": "active"}
        api = SimpleNamespace(mode="production", advertisement=AsyncMock(return_value=row),
                              remove=AsyncMock(return_value={**row, "status": "deleted"}))
        bot = SimpleNamespace(listings=api)
        interaction = SimpleNamespace(response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                                      edit_original_response=AsyncMock())
        await ManageView(bot, "demo-1", row).remove(interaction)
        api.remove.assert_not_awaited()
        confirm = interaction.edit_original_response.await_args.kwargs["view"]
        self.assertTrue(confirm.confirm)
        self.assertIn("44", interaction.edit_original_response.await_args.kwargs["content"])
        await confirm.remove(interaction)
        api.remove.assert_awaited_once_with("demo-1", "local")
        api.remove.return_value = {**row, "status": "deleted", "already_missing": True}
        await ManageView(bot, "demo-1", row, confirm=True).remove(interaction)
        self.assertIn("больше недоступно на UEX", interaction.edit_original_response.await_args.kwargs["content"])
        self.assertNotIn("удалено с UEX", interaction.edit_original_response.await_args.kwargs["content"])

    async def test_view_and_editor_are_separate_links_in_publication_and_management(self):
        """Просмотр ведёт на обычную карточку; редактор сайта явно подписан отдельно."""
        draft = await self.ready()
        bot = SimpleNamespace(listings=self.service)
        interaction = SimpleNamespace(response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                                      edit_original_response=AsyncMock())
        await PreviewView(bot, draft).publish(interaction)
        published = interaction.edit_original_response.await_args.kwargs["view"]
        row = self.store.all("advertisement", "demo-1")[0]
        for view in (published, ManageView(bot, "demo-1", row), ManageView(bot, "demo-1", row, confirm=True)):
            links = {item.label: item.url for item in view.children if getattr(item, "url", None)}
            self.assertEqual(links["Открыть на UEX"], "https://uexcorp.space/marketplace/item/info?id=9971")
            self.assertEqual(links["Редактировать на UEX"], "https://uexcorp.space/marketplace/edit/id/9971/")
        self.assertEqual(len(self.writes()), 1)
        self.assertEqual(self.writes("DELETE"), [])
