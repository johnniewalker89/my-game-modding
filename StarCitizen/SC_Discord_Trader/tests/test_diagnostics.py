"""Диагностика worker: heartbeat, права администратора, квоты и аварии фоновых задач."""

import asyncio
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import discord

from trader.config import Settings
from trader.diagnostics import read_status, status_path, status_text, write_status
from trader.discord_bot import TraderBot
from trader.marketplace import DemoMarketplace, MarketError
from trader.runtime import open_runtime
from trader.service import DemoSink, TraderService
from trader.store import Store, Vault


class DiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    """Использует только временные данные и тестовые аккаунты без внешней сети."""

    async def asyncSetUp(self):
        """Создаёт собственную папку для файлов состояния и SQLite."""
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)

    async def asyncTearDown(self):
        """Удаляет только временные файлы текущего теста."""
        self.temp.cleanup()

    async def test_status_file_freshness_format_and_cli_without_network_dependencies(self):
        """CLI различает живой процесс, внешние ошибки, устаревший файл и остановку без Discord/FastAPI."""
        path = status_path(self.path, "live")
        snapshot = {"schema_version": 1, "updated_at": 1000, "state": "degraded", "uex_errors": ["requests_limit_reached"]}
        write_status(path, snapshot)
        self.assertEqual(read_status(path, now=1180)["state"], "degraded")
        self.assertEqual(read_status(path, now=1181)["state"], "stale")
        self.assertFalse(path.with_suffix(".tmp").exists())
        environment = dict(os.environ, TRADER_DATA_DIR=str(self.path), TRADER_MODE="live")
        for state, age, expected in (("ok", 0, 0), ("degraded", 0, 0), ("stopped", 0, 1), ("ok", 181, 1)):
            write_status(path, {**snapshot, "state": state, "updated_at": time.time() - age})
            result = subprocess.run([sys.executable, "-m", "trader.diagnostics", "--check"],
                                    env=environment, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, expected, result.stderr.decode())
            self.assertEqual(result.stdout, b"")
        result = subprocess.run([sys.executable, "-c", "import sys,trader.diagnostics; assert 'discord' not in sys.modules; assert 'fastapi' not in sys.modules"],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        path.write_text('{"schema_version": 42}', encoding="utf-8")
        with self.assertRaises(ValueError):
            read_status(path)

    async def test_scan_diagnostics_keeps_each_accounts_last_error_and_ignores_busy_scan(self):
        """Ошибка одного аккаунта не скрывается успехом другого; занятый lock не выдаёт ложный успех."""
        store = Store(self.path / "state.sqlite3")
        market = DemoMarketplace(store)
        service = TraderService(store, Vault(self.path / "key"), market, SimpleNamespace(), DemoSink())
        try:
            await service.connect("demo-1", "private-fixture-one")
            await service.connect("demo-2", "private-fixture-two")
            await service.scan("demo-1")
            market.negotiations = AsyncMock(side_effect=MarketError("requests_limit_reached"))
            with self.assertRaises(MarketError):
                await service.scan("demo-2")
            market.negotiations = AsyncMock(return_value=[])
            await service.scan("demo-1")
            snapshot = service.diagnostics()
            self.assertEqual((snapshot["uex_checked"], snapshot["uex_accounts"]), (1, 2))
            self.assertEqual(snapshot["uex_errors"], ["requests_limit_reached"])
            for hidden in ("private-fixture", "demo-1", "demo-2", "DemoTrader", "secret", "app_token"):
                self.assertNotIn(hidden, json.dumps(snapshot))
            async with service._scan_locks["demo-2"]:
                self.assertEqual(await service.scan("demo-2"), 0)
                self.assertEqual(service.diagnostics()["uex_checked"], 1)
            await service.scan("demo-2")
            self.assertEqual(service.diagnostics()["uex_errors"], [])
            self.assertEqual(service.diagnostics()["uex_checked"], 2)
            await service.connect("demo-1", "private-fixture-reconnected")
            self.assertEqual(service.diagnostics()["uex_checked"], 1)
        finally:
            store.close()

    async def test_runtime_publishes_live_progress_and_marks_orderly_shutdown(self):
        """Настоящий reporter обновляет файл и не останавливает poll из-за квоты UEX."""
        settings = Settings(data_dir=self.path, translator="groq")
        path = status_path(self.path, "demo")
        with patch("trader.runtime.STATUS_SECONDS", 0.01), patch("trader.runtime.POLL_SECONDS", 0.01):
            async with open_runtime(settings) as runtime:
                for _ in range(100):
                    if read_status(path)["state"] == "ok":
                        break
                    await asyncio.sleep(0.01)
                self.assertEqual(read_status(path)["uex_checked"], 2)
                runtime.service.market.negotiations = AsyncMock(side_effect=MarketError("uex_http_429"))
                for _ in range(100):
                    if read_status(path)["uex_errors"]:
                        break
                    await asyncio.sleep(0.01)
                self.assertEqual(read_status(path)["state"], "degraded")
                self.assertTrue(all(not task.done() for task in runtime.background_tasks))
                self.assertNotIn("DemoTrader", path.read_text())
                reporter = next(task for task in runtime.background_tasks if task.get_name() == "status")
                reporter.cancel()
                await asyncio.gather(reporter, return_exceptions=True)
                self.assertEqual(runtime.status_provider()["state"], "failed")
            self.assertEqual(read_status(path)["state"], "stopped")

    async def test_admin_status_is_private_and_checks_guild_member_and_bot_permissions(self):
        """Команда закрыта от игроков/чужого сервера и разрешена администратору, включая MCP-бота."""
        store = Store(self.path / "commands.sqlite3")
        bot = TraderBot(Settings(guild_id=123), store)
        bot.tree.sync = AsyncMock(return_value=[])
        bot.status_provider = Mock(return_value={"state": "ok", "mode": "live", "discord_connected": True,
            "uex_accounts": 2, "uex_checked": 2, "uex_oldest_success_at": 1700000000, "translator": "groq"})
        try:
            await bot.setup_hook()
            command = bot.tree.get_command("статус", guild=discord.Object(id=123))
            self.assertEqual(command.default_permissions.value, 8)
            for admin, guild_id, is_bot in ((False, 123, False), (False, 123, True), (True, 999, False), (True, 123, True)):
                member = Mock(spec=discord.Member)
                member.guild_permissions = discord.Permissions(administrator=admin)
                member.bot = is_bot
                interaction = SimpleNamespace(guild_id=guild_id, user=member,
                    response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                    followup=SimpleNamespace(send=AsyncMock()))
                await command.callback(interaction)
                interaction.response.defer.assert_awaited_once_with(ephemeral=True)
                call = interaction.followup.send.await_args
                self.assertTrue(call.kwargs["ephemeral"])
                if admin and guild_id == 123:
                    self.assertIn("проверено после запуска 2/2", call.args[0])
                    self.assertEqual(call.args[0], status_text(bot.status_provider.return_value))
                else:
                    self.assertIn("только администратору", call.args[0])
            self.assertEqual(bot.status_provider.call_count, 1)
            bot.status_provider.side_effect = RuntimeError("private-fixture-must-not-be-disclosed")
            with self.assertLogs("trader.discord_bot", level="ERROR") as logs:
                await command.callback(interaction)
            self.assertIn("Проверь логи", interaction.followup.send.await_args.args[0])
            self.assertNotIn("private-fixture", str(logs.output))
        finally:
            await bot.close()
            store.close()

    async def test_status_includes_http_error_codes_without_private_request_data(self):
        """Администратор видит счётчики с запуска и время последнего HTTP-отказа."""
        text = status_text({"state": "degraded", "discord_connected": True,
            "discord_http": {"requests": 12, "recent_requests": 4, "errors": {"429": 2, "403": 1},
                             "last_error": {"at": 1000, "status": "429", "source": "webhook"}}})
        self.assertIn("запросов 12, ошибки — 403: 1, 429: 2", text)
        self.assertIn("Последний отказ: 429 · webhook · <t:1000:R>", text)
        self.assertIn("Запросов за ≈10 минут: 4", text)
