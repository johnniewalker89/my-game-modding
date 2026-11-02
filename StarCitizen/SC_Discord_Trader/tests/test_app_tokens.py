"""Два ключа UEX: маршрутизация приложений, шифрование, миграция и независимые очереди."""

import asyncio
import json
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import httpx

from trader.discord_bot import ConnectModal
from trader.marketplace import MarketError, UexMarketplace
from trader.service import DemoSink, TraderService
from trader.store import Store, Vault


class AppTokenTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет настоящий клиент и сервис без внешних сообщений и запросов."""

    async def asyncSetUp(self):
        """Создаёт отдельное хранилище и HTTP-контракт для двух владельцев."""
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "state.sqlite3")
        self.vault = Vault(Path(self.temp.name) / "key")
        self.requests = []
        self.failing_app = None
        self.client = httpx.AsyncClient(transport=httpx.MockTransport(self.respond))
        self.market = UexMarketplace(self.client, "service-app", "test", interval=0)
        translator = SimpleNamespace(translate=AsyncMock(side_effect=lambda text, *args, **_kwargs: "translated " + text))
        self.core = TraderService(self.store, self.vault, self.market, translator, DemoSink())

    async def asyncTearDown(self):
        """Закрывает только ресурсы этого теста."""
        await self.client.aclose()
        self.store.close()
        self.temp.cleanup()

    def respond(self, request):
        """Имитирует профиль, переговоры и отправку с проверяемыми заголовками request."""
        self.requests.append(request)
        app = request.headers["Authorization"]
        if app == "Bearer invalid-app":
            return httpx.Response(401, json={"status": "invalid_token"})
        if app == self.failing_app:
            return httpx.Response(200, json={"status": "requests_limit_reached"})
        resource = request.url.path.strip("/").split("/")[-1]
        secret = request.headers.get("secret-key")
        number = 1 if secret == "secret-one" else 2
        name = "One" if number == 1 else "Two"
        if resource == "user":
            data = {"username": name}
        elif resource == "marketplace_negotiations":
            data = [{"id": number, "id_listing": 500 + number, "listing_title": "Copper",
                     "is_listing_advertiser": 1, "advertiser_username": name, "client_username": "Peer",
                     "date_modified": 1, "date_closed": 0, "date_closed_client": 0}]
        elif resource == "marketplace_listings":
            data = {"id": int(request.url.params["id"]), "operation": "sell", "quality": 958}
        elif resource == "marketplace_negotiations_messages" and request.method == "GET":
            data = [{"id": 1000 + number, "user_username": "Peer", "message": "Still available?",
                     "date_added": time.time() + 1}]
        elif resource == "marketplace_negotiations_messages":
            data = {"id_message": 2000 + number}
        else:
            raise AssertionError("Unexpected fixture resource")
        return httpx.Response(200, json={"status": "ok", "data": data})

    async def test_both_keys_are_encrypted_and_app_update_preserves_account_history(self):
        """Добавление второго ключа сохраняет since/историю, отключение удаляет оба ключа."""
        legacy = {"id": "demo-1", "owner_id": "demo-1", "username": "One",
                  "secret": self.vault.encrypt("secret-one"), "since": 1.0}
        self.store.put("account", legacy)
        self.store.put("deal", {"id": "existing", "owner_id": "demo-1", "account": "One", "thread_id": "888"})
        with self.assertRaises(PermissionError):
            await self.core.account("demo-1")
        with self.assertRaises(ValueError):
            await self.core.connect("demo-1", "", "app-one")
        await self.core.connect("demo-1", "secret-one", "app-one")
        saved = self.store.get("account", "demo-1")
        self.assertEqual(saved["since"], 1.0)
        self.assertEqual(self.vault.decrypt(saved["secret"]), "secret-one")
        self.assertEqual(self.vault.decrypt(saved["app_token"]), "app-one")
        self.assertNotIn("app-one", json.dumps(saved))
        self.assertNotIn("secret-one", json.dumps(saved))
        self.assertEqual((await self.core.deal("demo-1", "existing"))["thread_id"], "888")
        self.core.disconnect("demo-1")
        saved = self.store.get("account", "demo-1")
        self.assertIsNone(saved["secret"])
        self.assertIsNone(saved["app_token"])
        with self.assertRaises(PermissionError):
            await self.core.account("demo-1")
        self.assertEqual(self.store.get("deal", "existing")["thread_id"], "888")

    async def test_missing_or_invalid_application_never_uses_shared_fallback_to_connect(self):
        """Новое подключение требует оба ключа и не подменяет ошибочный app-token общим."""
        with self.assertRaises(ValueError):
            await self.core.connect("demo-1", "secret-one")
        self.assertEqual(self.requests, [])
        with self.assertRaises(MarketError):
            await self.core.connect("demo-1", "secret-one", "invalid-app")
        self.assertIsNone(self.store.get("account", "demo-1"))
        self.assertEqual([r.headers["Authorization"] for r in self.requests], ["Bearer invalid-app"])

    async def test_scan_and_reply_use_each_owners_application_and_personal_key(self):
        """Чтение/проверка карточки/отправка каждой сделки идут через приложение её владельца."""
        await self.core.connect("demo-1", "secret-one", "app-one")
        await self.core.connect("demo-2", "secret-two", "app-two")
        await asyncio.gather(self.core.scan("demo-1"), self.core.scan("demo-2"))
        for owner, app, secret in (("demo-1", "app-one", "secret-one"), ("demo-2", "app-two", "secret-two")):
            deal = self.store.all("deal", owner)[0]
            reply = await self.core.reply(owner, deal["id"], "discord-message", "Да")
            self.assertEqual(reply["status"], "delivered")
            self.assertEqual(self.requests[-1].headers["Authorization"], "Bearer " + app)
            self.assertEqual(self.requests[-1].headers["secret-key"], secret)
            self.assertEqual(json.loads(self.requests[-1].content)["id_negotiation"], int(deal["external_id"]))
        self.assertNotIn("Bearer service-app", {r.headers["Authorization"] for r in self.requests})
        for request in self.requests:
            if request.headers.get("secret-key") == "secret-one":
                self.assertEqual(request.headers["Authorization"], "Bearer app-one")
            elif request.headers.get("secret-key") == "secret-two":
                self.assertEqual(request.headers["Authorization"], "Bearer app-two")
        listing_reads = [r for r in self.requests if r.url.path.rstrip("/").endswith("marketplace_listings")]
        self.assertEqual({r.headers["Authorization"] for r in listing_reads}, {"Bearer app-one", "Bearer app-two"})

    async def test_failure_of_one_application_does_not_change_another_accounts_client(self):
        """Отказ квоты одного приложения не переключает его или соседа на общий токен."""
        await self.core.connect("demo-1", "secret-one", "app-one")
        await self.core.connect("demo-2", "secret-two", "app-two")
        self.failing_app = "Bearer app-two"
        results = await asyncio.gather(self.core.scan("demo-1"), self.core.scan("demo-2"), return_exceptions=True)
        self.assertEqual(results[0], 1)
        self.assertIsInstance(results[1], MarketError)
        self.assertEqual(str(results[1]), "requests_limit_reached")
        self.assertEqual(len(self.store.all("deal", "demo-1")), 1)
        self.assertEqual(self.store.all("deal", "demo-2"), [])
        self.assertNotIn("Bearer service-app", {r.headers["Authorization"] for r in self.requests})

    async def test_rate_wait_is_shared_for_same_app_and_independent_for_different_apps(self):
        """Задержка одной очереди не блокирует запрос приложения с другим токеном."""
        self.market.interval = 60
        first = self.market.for_app_token("app-one")
        second = self.market.for_app_token("app-two")
        self.assertIs(self.market.for_app_token("app-one"), first)
        entered, release = asyncio.Event(), asyncio.Event()

        async def controlled_sleep(seconds):
            """Удерживает только положительное ожидание seconds до сигнала теста."""
            if seconds > 0:
                entered.set()
                await release.wait()

        with patch("trader.marketplace.asyncio.sleep", controlled_sleep):
            await first.profile("secret-one")
            pending = asyncio.create_task(first.profile("secret-one"))
            try:
                await asyncio.wait_for(entered.wait(), timeout=1)
                self.assertEqual(await asyncio.wait_for(second.profile("secret-two"), timeout=1), "Two")
                self.assertFalse(pending.done())
            finally:
                release.set()
                await pending

    async def test_connected_players_reenter_both_keys_and_another_actor_cannot_use_the_form(self):
        """Оба поля обязательны даже при сохранённом подключении и не доступны чужому actor."""
        await self.core.connect("demo-1", "secret-one", "app-one")
        bot = SimpleNamespace(store=self.store, service=SimpleNamespace(connect=AsyncMock()), start_account_scan=Mock())
        modal = ConnectModal(bot, "demo-1")
        self.assertTrue(modal.secret.required)
        self.assertTrue(modal.app_token.required)
        self.assertIsNone(modal.secret.default)
        self.assertIsNone(modal.app_token.default)
        interaction = SimpleNamespace(user=SimpleNamespace(id="demo-2"),
            response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
            followup=SimpleNamespace(send=AsyncMock()))
        await modal.on_submit(interaction)
        bot.service.connect.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
