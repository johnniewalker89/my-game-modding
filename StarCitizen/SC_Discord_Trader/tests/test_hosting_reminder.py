"""Личное напоминание владельцу: доставка, постоянный срок и отказ Discord без внешней сети."""

import asyncio
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import discord

from trader.config import Settings
from trader.discord_bot import TraderBot
from trader.runtime import open_runtime
from trader.store import Store


class HostingReminderTests(unittest.IsolatedAsyncioTestCase):
    """Использует временную базу и подменённый Discord, не отправляя настоящие сообщения."""

    async def test_minute_loop_delivers_to_owner_and_preserves_deadline_across_restart(self):
        """Цикл worker доставляет одно DM; перезапуск не повторяет его до десяти дней."""
        async def wait_for_shutdown(*args):
            """Подменяет подключение Discord ожиданием остановки worker."""
            await asyncio.Event().wait()

        recipient = SimpleNamespace(send=AsyncMock())
        with tempfile.TemporaryDirectory() as folder:
            settings = Settings(mode="live", data_dir=Path(folder), translator="groq",
                                hosting_reminder_user_id=42, hosting_reminder_url="https://panel.example/")
            with (patch.object(TraderBot, "start", new=wait_for_shutdown),
                  patch.object(TraderBot, "is_ready", return_value=True),
                  patch.object(TraderBot, "fetch_user", new_callable=AsyncMock, return_value=recipient) as fetch,
                  patch("trader.runtime.ListingService.prepare_catalog", new_callable=AsyncMock),
                  patch("trader.runtime.STATUS_SECONDS", 0.01)):
                async with open_runtime(settings) as runtime:
                    for _ in range(100):
                        if recipient.send.await_count:
                            break
                        await asyncio.sleep(0.01)
                    fetch.assert_awaited_once_with(42)
                    recipient.send.assert_awaited_once()
                    self.assertIn(settings.hosting_reminder_url, recipient.send.call_args.args[0])
                    state = runtime.bot.store.get("hosting_reminder", "42")
                    self.assertEqual(state["next_at"] - state["last_sent_at"], 10 * 86400)
                async with open_runtime(settings) as runtime:
                    await asyncio.sleep(0.04)
                    recipient.send.assert_awaited_once()
                    with patch("trader.discord_bot.time.time", return_value=state["next_at"]):
                        await runtime.bot.remind_hosting()
                    self.assertEqual(recipient.send.await_count, 2)

    async def test_unready_and_failed_dm_do_not_flood_or_advance_ten_day_delivery(self):
        """Без Discord доставки нет; отказ даёт суточную паузу, после восстановления — десять дней."""
        with tempfile.TemporaryDirectory() as folder:
            store = Store(Path(folder) / "state.sqlite3")
            settings = Settings(hosting_reminder_user_id=42, hosting_reminder_url="https://panel.example/")
            try:
                async with TraderBot(settings, store) as bot:
                    denied = discord.Forbidden(SimpleNamespace(status=403, reason="Forbidden"), "DM closed")
                    recipient = SimpleNamespace(send=AsyncMock(side_effect=denied))
                    bot.fetch_user = AsyncMock(return_value=recipient)
                    now = time.time()
                    with patch.object(bot, "is_ready", return_value=False):
                        await bot.remind_hosting()
                        bot.fetch_user.assert_not_awaited()
                    with patch.object(bot, "is_ready", return_value=True), patch("trader.discord_bot.time.time", return_value=now):
                        with self.assertLogs("trader.discord_bot", level="WARNING"):
                            await bot.remind_hosting()
                        await bot.remind_hosting()
                    recipient.send.assert_awaited_once()
                    state = store.get("hosting_reminder", "42")
                    self.assertEqual(state["next_at"], now + 86400)
                    self.assertNotIn("last_sent_at", state)
                    recipient.send.side_effect = None
                    with patch.object(bot, "is_ready", return_value=True), patch("trader.discord_bot.time.time", return_value=now + 86400):
                        await bot.remind_hosting()
                    state = store.get("hosting_reminder", "42")
                    self.assertEqual(state["last_sent_at"], now + 86400)
                    self.assertEqual(state["next_at"], now + 11 * 86400)
            finally:
                store.close()
