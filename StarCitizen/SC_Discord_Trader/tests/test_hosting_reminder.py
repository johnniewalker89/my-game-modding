"""Напоминания о подписке и админская команда без внешних подключений."""

import asyncio
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import discord

from trader.config import Settings
from trader.discord_bot import TraderBot
from trader.runtime import open_runtime
from trader.store import Store


class HostingReminderTests(unittest.IsolatedAsyncioTestCase):
    """Использует временную базу и подменённый Discord вместо реальных DM."""

    async def test_worker_notifies_only_last_three_days_and_keeps_daily_mark_across_restart(self):
        """Цикл worker молчит заранее, пишет три дня подряд и не повторяет DM после перезапуска."""
        async def wait_for_shutdown(*args):
            """Подменяет подключение Discord ожиданием остановки worker."""
            await asyncio.Event().wait()

        now = datetime(2026, 12, 1, 12).timestamp()
        recipient = SimpleNamespace(send=AsyncMock())
        with tempfile.TemporaryDirectory() as folder:
            settings = Settings(mode="live", data_dir=Path(folder), translator="groq",
                                hosting_reminder_user_id=42, hosting_reminder_url="https://panel.example/")
            store = Store(Path(folder) / "trader-live.sqlite3")
            store.put("hosting_reminder", {"id": "42", "owner_id": "42", "expires_on": "2026-12-05"})
            store.close()
            with (patch.object(TraderBot, "start", new=wait_for_shutdown),
                  patch.object(TraderBot, "is_ready", return_value=True),
                  patch.object(TraderBot, "fetch_user", new_callable=AsyncMock, return_value=recipient),
                  patch("trader.runtime.ListingService.prepare_catalog", new_callable=AsyncMock),
                  patch("trader.runtime.STATUS_SECONDS", 0.01),
                  patch("trader.discord_bot.time.time", side_effect=lambda: now)):
                async with open_runtime(settings):
                    await asyncio.sleep(0.04)
                    recipient.send.assert_not_awaited()
                    now = datetime(2026, 12, 2, 12).timestamp()
                    for _ in range(100):
                        if recipient.send.await_count:
                            break
                        await asyncio.sleep(0.01)
                    recipient.send.assert_awaited_once()
                    self.assertIn("3 дня", recipient.send.call_args.args[0])
                    self.assertIn(settings.hosting_reminder_url, recipient.send.call_args.args[0])
                async with open_runtime(settings) as runtime:
                    await asyncio.sleep(0.04)
                    recipient.send.assert_awaited_once()
                    for day, expected_count, phrase in ((3, 2, "2 дня"), (4, 3, "1 день")):
                        now = datetime(2026, 12, day, 12).timestamp()
                        await runtime.bot.remind_hosting()
                        self.assertEqual(recipient.send.await_count, expected_count)
                        self.assertIn(phrase, recipient.send.call_args.args[0])
                        await runtime.bot.remind_hosting()
                        self.assertEqual(recipient.send.await_count, expected_count)
                    for day in (5, 6):
                        now = datetime(2026, 12, day, 12).timestamp()
                        await runtime.bot.remind_hosting()
                    self.assertEqual(recipient.send.await_count, 3)

    async def test_unconfigured_unready_and_failed_dm_do_not_flood(self):
        """Без даты или Discord отправки нет; отказ и перезапуск не повторяют попытку в тот же день."""
        with tempfile.TemporaryDirectory() as folder:
            store = Store(Path(folder) / "state.sqlite3")
            settings = Settings(hosting_reminder_user_id=42, hosting_reminder_url="https://panel.example/")
            denied = discord.Forbidden(SimpleNamespace(status=403, reason="Forbidden"), "DM closed")
            recipient = SimpleNamespace(send=AsyncMock(side_effect=denied))
            try:
                with patch("trader.discord_bot.time.time", return_value=datetime(2026, 12, 2, 12).timestamp()):
                    async with TraderBot(settings, store) as bot:
                        bot.fetch_user = AsyncMock(return_value=recipient)
                        with patch.object(bot, "is_ready", return_value=True):
                            await bot.remind_hosting()
                            bot.fetch_user.assert_not_awaited()
                        bot._hosting_reminder["expires_on"] = "2026-12-05"
                        with patch.object(bot, "is_ready", return_value=False):
                            await bot.remind_hosting()
                            bot.fetch_user.assert_not_awaited()
                        with patch.object(bot, "is_ready", return_value=True):
                            with self.assertLogs("trader.discord_bot", level="WARNING"):
                                await bot.remind_hosting()
                            await bot.remind_hosting()
                            recipient.send.assert_awaited_once()
                    async with TraderBot(settings, store) as bot:
                        bot.fetch_user = AsyncMock(return_value=recipient)
                        with patch.object(bot, "is_ready", return_value=True):
                            await bot.remind_hosting()
                            recipient.send.assert_awaited_once()
                            recipient.send.side_effect = None
                            with patch("trader.discord_bot.time.time", return_value=datetime(2026, 12, 3, 12).timestamp()):
                                await bot.remind_hosting()
                            self.assertEqual(recipient.send.await_count, 2)
            finally:
                store.close()

    async def test_subscription_command_checks_admin_and_updates_date_without_restart(self):
        """Только свой админ меняет срок; та же дата не дублирует DM, новый срок действует сразу."""
        with tempfile.TemporaryDirectory() as folder:
            store = Store(Path(folder) / "state.sqlite3")
            settings = Settings(guild_id=123, hosting_reminder_user_id=42,
                                hosting_reminder_url="https://panel.example/")
            now = datetime(2026, 12, 2, 12).timestamp()
            try:
                async with TraderBot(settings, store) as bot:
                    bot.tree.sync = AsyncMock(return_value=[])
                    await bot.setup_hook()
                    command = bot.tree.get_command("подписка", guild=discord.Object(id=123))
                    self.assertEqual(command.default_permissions.value, 8)
                    self.assertEqual(command.parameters[0].display_name, "дата")
                    member = Mock(spec=discord.Member)
                    member.guild_permissions = discord.Permissions.none()
                    interaction = SimpleNamespace(guild_id=123, user=member,
                        response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                        followup=SimpleNamespace(send=AsyncMock()))
                    with patch("trader.discord_bot.time.time", side_effect=lambda: now):
                        await command.callback(interaction, "2026-12-05")
                        self.assertIsNone(store.get("hosting_reminder", "42"))
                        self.assertIn("только администратор", interaction.followup.send.await_args.args[0])
                        member.guild_permissions = discord.Permissions(administrator=True)
                        interaction.guild_id = 999
                        await command.callback(interaction, "2026-12-05")
                        self.assertIsNone(store.get("hosting_reminder", "42"))
                        interaction.guild_id = 123
                        for invalid in ("05.12.2026", "2026-02-30", "2026-12-01"):
                            await command.callback(interaction, invalid)
                            self.assertIsNone(store.get("hosting_reminder", "42"))
                        await command.callback(interaction, "2026-12-05")
                        self.assertEqual(store.get("hosting_reminder", "42")["expires_on"], "2026-12-05")
                        self.assertIn("автоматически не проверяется", interaction.followup.send.await_args.args[0])
                        recipient = SimpleNamespace(send=AsyncMock())
                        bot.fetch_user = AsyncMock(return_value=recipient)
                        with patch.object(bot, "is_ready", return_value=True):
                            await bot.remind_hosting()
                            await command.callback(interaction, "2026-12-05")
                            await bot.remind_hosting()
                            recipient.send.assert_awaited_once()
                            await command.callback(interaction, "2026-12-06")
                            await bot.remind_hosting()
                            recipient.send.assert_awaited_once()
                            now = datetime(2026, 12, 3, 12).timestamp()
                            await bot.remind_hosting()
                            self.assertEqual(recipient.send.await_count, 2)
                            self.assertIn("2026-12-06", recipient.send.call_args.args[0])
            finally:
                store.close()
