"""HTTP-диагностика Discord: реальные ответы, состояние worker и безопасный журнал."""

import asyncio
import json
import logging
import tempfile
import time
import unittest
from contextlib import closing
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import aiohttp
import discord
from aiohttp import web
from aiohttp.test_utils import TestServer

from trader.config import Settings
from trader.discord_bot import TraderBot
from trader.discord_health import DiscordBackoff, DiscordHttpErrorFilter
from trader.marketplace import DemoMarketplace
from trader.runtime import open_runtime
from trader.service import TraderService
from trader.store import Store, Vault


class DiscordHealthTests(unittest.IsolatedAsyncioTestCase):
    """Не подключается к Discord/UEX; HTTP-сервер доступен только на loopback."""

    async def test_idle_scans_reuse_roles_but_actions_and_delivery_check_fresh_access(self):
        """Тридцать пустых сверок используют одну проверку; снятая роль блокирует действия и входящее."""
        with tempfile.TemporaryDirectory() as folder, closing(Store(Path(folder) / "state.sqlite3")) as store:
            async with TraderBot(Settings(guild_id=1, role_id=2), store) as bot:
                roles = [SimpleNamespace(id=2)]
                guild = Mock(spec=discord.Guild)
                guild.fetch_member = AsyncMock(side_effect=lambda owner: SimpleNamespace(roles=roles))
                bot.get_guild = Mock(return_value=guild)
                market = DemoMarketplace(store)
                translator = SimpleNamespace(translate=AsyncMock(return_value="Перевод"))
                service = TraderService(store, Vault(Path(folder) / "key"), market, translator, bot)
                clock = 1000.0
                with patch("trader.discord_bot.time", SimpleNamespace(monotonic=lambda: clock, time=time.time)):
                    for owner in ("123", "124", "125"):
                        await service.connect(owner, "fixture-secret")
                    clock += 301
                    guild.fetch_member.reset_mock()
                    for tick in range(30):
                        clock = 1301 + tick * 10
                        for owner in ("123", "124", "125"):
                            await service.scan(owner)
                    self.assertEqual(guild.fetch_member.await_count, 3)
                    clock = 1601
                    await service.scan("123")
                    self.assertEqual(guild.fetch_member.await_count, 4)
                    await service.scan("123", force=True)
                    self.assertEqual(guild.fetch_member.await_count, 5)
                    roles = []
                    with self.assertRaises(PermissionError):
                        await service.account("123")
                    roles = [SimpleNamespace(id=2)]
                    await service.account("123")
                    # Снятие роли во время перевода не обходится разрешением из фонового кеша.
                    row = market.add_deal("123", "sell", "Fixture", "Buyer")
                    market.add_message("123", row["id"], "Buyer", "Hello")
                    async def translate(*args, **kwargs):
                        """Снимает роль между чтением UEX и публикацией перевода."""
                        nonlocal roles
                        roles = []
                        return "Перевод"
                    translator.translate.side_effect = translate
                    bot.thread = AsyncMock()
                    with self.assertRaises(PermissionError):
                        await service.scan("123")
                    bot.thread.assert_not_awaited()
                    roles = [SimpleNamespace(id=2)]
                    await service.account("123")
                    roles = []
                    with self.assertRaises(PermissionError):
                        await service.reply("123", store.all("deal")[0]["id"], "outgoing-fixture", "Беру")
                    self.assertFalse(any(message["source"] == "outgoing" for message in store.all("message")))
                    roles = [SimpleNamespace(id=2)]
                    await service.account("123")
                    guild.fetch_member.side_effect = DiscordBackoff(300)
                    with self.assertRaises(DiscordBackoff):
                        await service.account("123")
                    with self.assertRaises(DiscordBackoff):
                        await service.scan("123")

    async def test_blocked_feedback_does_not_raise_or_repeat_outgoing_message(self):
        """Недоступный Discord не вызывает вторую отправку UEX и вложенный traceback уведомления."""
        with tempfile.TemporaryDirectory() as folder, closing(Store(Path(folder) / "state.sqlite3")) as store:
            store.put("deal", {"id": "fixture", "owner_id": "123", "thread_id": "200"})
            async with TraderBot(Settings(guild_id=1, channel_id=100), store) as bot:
                channel = Mock(spec=discord.Thread, id=200, parent_id=100)
                message = Mock(id=300, guild=SimpleNamespace(id=1), channel=channel,
                               author=SimpleNamespace(id=123, bot=False), attachments=[], content="Беру")
                for delivered in (False, True):
                    for error in (DiscordBackoff(300), discord.HTTPException(
                            SimpleNamespace(status=429, reason="Too Many Requests"), "fixture")):
                        with self.subTest(delivered=delivered, error_type=type(error).__name__):
                            result = AsyncMock(return_value={"status": "delivered", "translated": "English"})
                            if not delivered:
                                result.side_effect = DiscordBackoff(300)
                            bot.service = SimpleNamespace(reply=result)
                            message.reply = AsyncMock(side_effect=error)
                            with self.assertLogs("trader.discord_bot", level="WARNING") as logs:
                                await bot.on_message(message)
                            bot.service.reply.assert_awaited_once()
                            message.reply.assert_awaited_once()
                            self.assertIn("message=300", logs.output[0])

    async def test_sdk_trace_counts_responses_without_retaining_private_urls_or_bodies(self):
        """Существующая сессия получает два ответа; счётчик не делает своих запросов."""
        async def reply(request):
            """Отдаёт управляемый ответ вместо обращения к Discord."""
            return web.Response(status=429 if request.path.startswith("/webhooks/") else 200,
                                text="private-fixture-body", content_type="text/html",
                                headers={"Retry-After": "123.5"})

        app = web.Application()
        app.router.add_get("/{path:.*}", reply)
        async with TraderBot(Settings(), Mock()) as bot, TestServer(app) as server:
            health = bot.http_health
            self.assertIs(bot.http.http_trace, health.trace)
            with self.assertLogs("trader.discord_health", level="WARNING") as logs:
                async with aiohttp.ClientSession(trace_configs=[health.trace]) as session:
                    for path in ("/webhooks/123/private-fixture-token", "/ok"):
                        async with session.get(server.make_url(path)) as response:
                            await response.read()
            report = health.snapshot()
            self.assertEqual((report["requests"], report["errors"]), (2, {"429": 1}))
            self.assertEqual(report["recent_requests"], 2)
            self.assertEqual(report["last_error"]["retry_after"], 123.5)
            self.assertEqual(report["last_error"]["source"], "webhook")
            self.assertNotIn("private-fixture", json.dumps(report) + str(logs.output))
            self.assertEqual(len(logs.output), 1)
            with patch("trader.discord_health.time.time", return_value=report["last_error"]["at"] + 1):
                with self.assertNoLogs("trader.discord_health", level="WARNING"):
                    for _ in range(50):
                        await health._connection_error(None, None, SimpleNamespace(url=server.make_url("/ok")))
            self.assertEqual(health.snapshot()["errors"], {"429": 1, "network": 50})
            self.assertGreater(health.snapshot()["paused_until"], time.time())
            with patch("trader.discord_health.time.monotonic", return_value=time.monotonic() + 661):
                self.assertEqual(health.snapshot()["recent_requests"], 0)
                self.assertEqual(health.snapshot()["requests"], 52)

    async def test_worker_does_not_hide_http_failure_behind_connected_gateway(self):
        """HTTP-отказ держит degraded пять минут, даже после успешного ответа другого маршрута."""
        async def wait_for_shutdown(*args):
            """Заменяет Gateway ожиданием отмены фоновой задачи."""
            await asyncio.Event().wait()

        with tempfile.TemporaryDirectory() as folder:
            with (patch.object(TraderBot, "start", new=wait_for_shutdown),
                  patch.object(TraderBot, "is_ready", return_value=True),
                  patch("trader.runtime.ListingService.prepare_catalog", new_callable=AsyncMock)):
                async with open_runtime(Settings(mode="live", data_dir=Path(folder), translator="groq")) as runtime:
                    self.assertEqual(runtime.status_provider()["state"], "ok")
                    with self.assertLogs("trader.discord_health", level="WARNING"):
                        runtime.bot.http_health._error("429", "/webhooks/123/private-fixture-token", "http", None)
                    before = runtime.status_provider()
                    self.assertTrue(before["discord_connected"])
                    self.assertEqual(before["state"], "degraded")
                    self.assertEqual(before["discord_http"]["errors"], {"429": 1})
                    with patch("trader.runtime.time.time", return_value=time.time() + 301):
                        self.assertEqual(runtime.status_provider()["state"], "ok")
                    with patch.object(runtime.bot.http_health, "snapshot", return_value={
                        **before["discord_http"], "paused_until": time.time() + 3600}):
                        with patch("trader.runtime.time.time", return_value=time.time() + 301):
                            self.assertEqual(runtime.status_provider()["state"], "degraded")

    async def test_sdk_429_pauses_network_and_recovers_with_fresh_role_check(self):
        """Реальный SDK уважает часовой отказ без повтора сети и заново проверяет роль после паузы."""
        for global_limit in (False, True):
            with self.subTest(global_limit=global_limit):
                calls = []
                limited = True
                roles = []

                async def reply(request):
                    """Даёт ненормативный429, который SDK сам не ждёт; реального Discord нет."""
                    calls.append(request.path)
                    if "/members/" in request.path and limited:
                        return web.Response(body=json.dumps({"message": "private-fixture-body", "code": 0}).encode(),
                            status=429, content_type="application/json",
                            headers={"Retry-After": "3600", "X-RateLimit-Scope": "global" if global_limit else "user",
                                     "X-RateLimit-Limit": "5", "X-RateLimit-Remaining": "0",
                                     "X-RateLimit-Reset-After": "3600"})
                    return web.Response(body=json.dumps({"id": "100", "roles": roles}).encode(),
                                        content_type="application/json")

                app = web.Application()
                app.router.add_route("*", "/{path:.*}", reply)
                async with TraderBot(Settings(guild_id=1, role_id=2), Mock()) as bot, TestServer(app) as server:
                    guild = Mock(spec=discord.Guild)

                    async def member(owner):
                        """Использует настоящий HTTP-клиент SDK, возвращая проверяемые роли из ответа."""
                        data = await bot.http.get_member(1, owner)
                        return SimpleNamespace(roles=[SimpleNamespace(id=int(value)) for value in data["roles"]])

                    guild.fetch_member = AsyncMock(side_effect=member)
                    bot.get_guild = Mock(return_value=guild)
                    with patch("discord.http.Route.BASE", str(server.make_url("/api/v10"))):
                        await bot.http.static_login("private-fixture-token")
                        with self.assertLogs("trader.discord_health", level="WARNING") as logs:
                            with self.assertRaises(DiscordBackoff):
                                await bot.allowed("123")
                        error = bot.http_health.snapshot()["last_error"]
                        self.assertEqual(error["route"], "/guilds/{id}/members/{id}")
                        self.assertEqual(error["method"], "GET")
                        self.assertEqual(error["scope"], "global" if global_limit else "user")
                        self.assertEqual((error["limit"], error["remaining"], error["reset_after"]), (5, 0, 3600))
                        self.assertEqual((error["response_type"], error["via"]), ("json", False))
                        wire_calls = len(calls)
                        for _ in range(3):
                            with self.assertRaises(DiscordBackoff):
                                await bot.allowed("123")
                        self.assertEqual(len(calls), wire_calls)
                        if global_limit:
                            with self.assertRaises(DiscordBackoff):
                                await bot.http.get_channel(7)
                        else:
                            await bot.http.get_channel(7)
                        async with aiohttp.ClientSession(trace_configs=[bot.http_health.trace]) as session:
                            for path in ("/interactions/123/private-fixture-token/callback",
                                         "/webhooks/123/private-fixture-token"):
                                async with session.post(server.make_url("/api/v10" + path)) as response:
                                    self.assertEqual(response.status, 200)
                        self.assertEqual(bot.http_health.snapshot()["errors"], {"429": 1})
                        self.assertEqual(bot.http_health.snapshot()["requests"], len(calls))
                        self.assertNotIn("private-fixture", json.dumps(bot.http_health.snapshot()) + str(logs.output))
                        limited = False
                        clock = time.monotonic
                        with patch("trader.discord_health.time", SimpleNamespace(monotonic=lambda: clock() + 3601,
                                                                                time=time.time)):
                            self.assertFalse(await bot.allowed("123"))
                            roles = ["2"]
                            self.assertTrue(await bot.allowed("123"))
                            self.assertNotIn("paused_until", bot.http_health.snapshot())
                        self.assertGreater(len(calls), wire_calls)

    async def test_interaction_trace_separates_age_before_request_and_http_duration(self):
        """Реальные callback-запросы сохраняют оба замера при HTTP- и сетевом отказе."""
        async def reply(request):
            """Имитирует задержанный отказ Discord и потерю соединения на loopback."""
            await asyncio.sleep(0.03)
            if request.match_info["token"] == "private-fixture-network":
                request.transport.close()
                return web.Response()
            return web.json_response({"code": 10062, "message": "private-fixture-body"}, status=404)

        created_at = discord.utils.utcnow() - timedelta(seconds=2)
        interaction_id = discord.utils.time_snowflake(created_at)
        app = web.Application()
        app.router.add_post("/api/v10/interactions/{interaction_id}/{token}/callback", reply)
        async with TraderBot(Settings(), Mock()) as bot, TestServer(app) as server:
            health = bot.http_health
            with self.assertLogs("trader.discord_health", level="WARNING") as logs:
                async with aiohttp.ClientSession(trace_configs=[health.trace]) as session:
                    for token, status in (("private-fixture-token", "404"), ("private-fixture-network", "network")):
                        before_age = (time.time() - created_at.timestamp()) * 1000
                        url = server.make_url(f"/api/v10/interactions/{interaction_id}/{token}/callback")
                        if status == "network":
                            with self.assertRaises(aiohttp.ClientConnectionError):
                                await session.post(url)
                        else:
                            async with session.post(url) as response:
                                self.assertEqual(response.status, 404)
                                await response.read()
                        error = health.snapshot()["last_error"]
                        self.assertEqual((error["status"], error["source"]), (status, "interaction"))
                        self.assertGreaterEqual(error["request_ms"], 20)
                        self.assertGreaterEqual(error["interaction_age_ms"], before_age - 2)
                        self.assertLessEqual(error["interaction_age_ms"],
                                             (time.time() - created_at.timestamp()) * 1000 + 2)
            self.assertEqual(health.snapshot()["errors"], {"404": 1, "network": 1})
            self.assertEqual(health.snapshot()["requests"], 2)
            self.assertIn("request_ms=", logs.output[0])
            self.assertIn("interaction_age_ms=", logs.output[0])
            self.assertNotIn("private-fixture", json.dumps(health.snapshot()) + str(logs.output))
            self.assertNotIn(str(interaction_id), json.dumps(health.snapshot()) + str(logs.output))

    async def test_sdk_error_log_keeps_code_without_html_or_webhook_token(self):
        """Прямой и обёрнутый HTTP-отказ сохраняет причину без большого приватного traceback."""
        error = discord.HTTPException(SimpleNamespace(status=429, reason="Too Many Requests"),
                                      "<html>private-fixture-token private-fixture-body</html>")
        wrapped = discord.app_commands.CommandInvokeError(Mock(), error)
        for exception in (error, wrapped):
            record = logging.LogRecord("discord.app_commands.tree", logging.ERROR, __file__, 1,
                                       "SDK error", (), (type(exception), exception, None))
            record.exc_text = "private-fixture-cached-traceback"
            DiscordHttpErrorFilter().filter(record)
            output = logging.Formatter("%(name)s %(message)s").format(record)
            self.assertIn("status=429", output)
            self.assertIn("code=0", output)
            self.assertNotIn("private-fixture", output)
        ordinary = ValueError("useful failure")
        record = logging.LogRecord("discord.client", logging.ERROR, __file__, 1,
                                   "SDK error", (), (type(ordinary), ordinary, None))
        DiscordHttpErrorFilter().filter(record)
        self.assertIs(record.exc_info[1], ordinary)
