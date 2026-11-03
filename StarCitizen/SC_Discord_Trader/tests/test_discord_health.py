"""HTTP-диагностика Discord: реальные ответы, состояние worker и безопасный журнал."""

import asyncio
import json
import logging
import tempfile
import time
import unittest
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
from trader.discord_health import DiscordHttpErrorFilter
from trader.runtime import open_runtime


class DiscordHealthTests(unittest.IsolatedAsyncioTestCase):
    """Не подключается к Discord/UEX; HTTP-сервер доступен только на loopback."""

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
            self.assertEqual(set(health.snapshot()), {"requests", "recent_requests", "errors", "last_error"})
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
