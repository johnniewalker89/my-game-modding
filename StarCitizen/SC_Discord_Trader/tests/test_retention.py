"""Регрессии TTL: границы срока, незавершённые операции, дедупликация и старые оригиналы."""

import asyncio
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from trader.config import Settings
from trader.discord_bot import OriginalView
from trader.marketplace import DemoMarketplace, MarketError
from trader.runtime import open_runtime
from trader.service import DemoSink, TraderService, stable_id
from trader.store import Store, Vault

DAY = 86400


class RetentionTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет настоящую SQLite и сценарии бота без сети и рабочих данных."""

    async def asyncSetUp(self):
        """Открывает отдельную базу и только фиктивный аккаунт."""
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "state.sqlite3")
        self.market = DemoMarketplace(self.store)
        self.sink = DemoSink()
        self.sink.incoming = AsyncMock(wraps=self.sink.incoming)
        self.translator = SimpleNamespace(translate=AsyncMock(side_effect=lambda text, *args, **kwargs: text))
        self.core = TraderService(self.store, Vault(Path(self.temp.name) / "key"),
                                  self.market, self.translator, self.sink)
        await self.core.connect("demo-1", "fixture")

    async def asyncTearDown(self):
        """Закрывает и удаляет только собственную временную базу."""
        self.store.close()
        self.temp.cleanup()

    def add_record(self, kind, record_id, **fields):
        """Сохраняет тестовую запись с устойчивым владельцем и заданными полями."""
        row = {"id": record_id, "owner_id": "demo-1", **fields}
        self.store.put(kind, row)
        return row

    async def test_cutoff_preserves_active_recent_uncertain_and_cross_owner_records(self):
        """Текст исчезает только у подтверждённых исходов закрытой сделки на границе 14 дней."""
        now = 2_000_000_000.0
        self.add_record("deal", "closed", own_closed=True, closed_at=now - 14 * DAY)
        self.add_record("deal", "recent", peer_closed=True, closed_at=now - 14 * DAY + 1)
        self.add_record("deal", "paused", own_closed=False, peer_closed=False,
                        paused=True, closed_at=now - 100 * DAY)
        for status in ("delivered", "baseline", "failed", "pending", "sending", "unknown", "translation_failed"):
            self.add_record("message", status, deal_id="closed", status=status,
                            original="English", translated="Русский", external_id=status,
                            display_id="discord-id", remote_id="uex-id")
        for deal_id in ("recent", "paused"):
            self.add_record("message", deal_id, deal_id=deal_id, status="delivered", original="Keep")
        self.add_record("message", "foreign", owner_id="demo-2", deal_id="closed",
                        status="delivered", original="Keep private")
        self.assertEqual(self.store.prune_expired(now), (3, 0))
        for status in ("delivered", "baseline", "failed"):
            row = self.store.get("message", status)
            self.assertNotIn("original", row)
            self.assertNotIn("translated", row)
            self.assertEqual((row["external_id"], row["display_id"], row["remote_id"]),
                             (status, "discord-id", "uex-id"))
        for record_id in ("pending", "sending", "unknown", "translation_failed", "recent", "paused", "foreign"):
            self.assertIn("original", self.store.get("message", record_id))
        self.assertEqual(self.store.prune_expired(now), (0, 0))

    async def test_legacy_closed_deal_gets_full_retention_and_drafts_do_not_delete_uncertain_results(self):
        """Старая закрытая сделка получает 14 дней; фото и безопасные черновики удаляются через 3 дня."""
        now = 2_000_000_000.0
        self.add_record("deal", "legacy", peer_closed=True)
        self.add_record("message", "legacy-message", deal_id="legacy", status="delivered", original="Keep")
        for status in ("draft", "cancelled", "created", "tested", "failed", "sending", "unknown"):
            self.add_record("listing_draft", status, status=status,
                            created_at=now - 3 * DAY, photo="temporary-photo")
        self.add_record("listing_draft", "recent", status="draft", created_at=now - 3 * DAY + 1)
        published = self.add_record("advertisement", "published", status="created", created_at=0)
        self.assertEqual(self.store.prune_expired(now), (0, 5))
        self.assertEqual(self.store.get("deal", "legacy")["closed_at"], now)
        self.assertEqual(self.store.get("advertisement", "published"), published)
        self.assertEqual({row["id"] for row in self.store.all("listing_draft")}, {"sending", "unknown", "recent"})
        self.assertEqual(self.store.prune_expired(now + 14 * DAY - 1), (0, 1))
        self.assertEqual(self.store.prune_expired(now + 14 * DAY), (1, 0))

    async def test_expired_text_can_be_read_on_demand_without_retranslation_cache_or_redelivery(self):
        """Оригинал берётся с площадки только по запросу; повторная сверка не дублирует историю."""
        remote_deal = self.market.add_deal("demo-1", "buy", "Copper", "Seller")
        remote = self.market.add_message("demo-1", remote_deal["id"], "Seller", "MIC L-5 works")
        await self.core.scan("demo-1", force=True)
        deal_id = stable_id("demo-1", "DemoTrader", remote_deal["id"])
        message_id = stable_id(deal_id, "incoming", remote["id"])
        self.market.close_deal("demo-1", remote_deal["id"])
        await self.core.scan("demo-1", force=True)
        closed_at = self.store.get("deal", deal_id)["closed_at"]
        await self.core.scan("demo-1", force=True)
        self.assertEqual(self.store.get("deal", deal_id)["closed_at"], closed_at)
        self.market.messages = AsyncMock(wraps=self.market.messages)
        translations = self.translator.translate.await_count
        self.assertEqual(self.store.prune_expired(closed_at + 14 * DAY), (1, 0))
        self.market.messages.assert_not_awaited()
        self.assertEqual(await self.core.original("demo-1", message_id), remote["message"])
        self.market.messages.assert_awaited_once()
        self.assertNotIn("original", self.store.get("message", message_id))
        self.assertEqual(self.translator.translate.await_count, translations)
        remote_deal = self.store.get("remote_deal", remote_deal["id"])
        remote_deal.update(date_closed=0, date_closed_client=0)
        self.store.put("remote_deal", remote_deal)
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        self.assertEqual(self.sink.incoming.await_count, 1)
        self.assertNotIn("closed_at", self.store.get("deal", deal_id))
        self.assertEqual(self.translator.translate.await_count, translations)

    async def test_original_checks_owner_role_account_and_unavailable_remote_history(self):
        """Загрузка оригинала не обходит владельца и роль, не скрывает потерю истории UEX."""
        self.add_record("deal", "deal", account="DemoTrader", external_id="remote")
        self.add_record("message", "message", deal_id="deal", source="incoming", external_id="remote-message")
        self.market.messages = AsyncMock(return_value=[])
        with self.assertRaises(PermissionError):
            await self.core.original("demo-2", "message")
        self.market.messages.assert_not_awaited()
        self.sink.allowed = AsyncMock(return_value=False)
        with self.assertRaises(PermissionError):
            await self.core.original("demo-1", "message")
        self.market.messages.assert_not_awaited()
        self.sink.allowed = AsyncMock(return_value=True)
        with self.assertRaisesRegex(ValueError, "UEX больше не отдаёт"):
            await self.core.original("demo-1", "message")

        async def account_changed(*args):
            """Меняет подключённый аккаунт во время ожидания ответа площадки."""
            account = self.store.get("account", "demo-1")
            account["username"] = "AnotherAccount"
            self.store.put("account", account)
            return [{"id": "remote-message", "message": "Do not disclose"}]

        self.market.messages.side_effect = account_changed
        with self.assertRaises(PermissionError):
            await self.core.original("demo-1", "message")

    async def test_purged_own_baseline_is_not_recovered_as_new_message(self):
        """Удалённая baseline-запись остаётся маркером дедупликации даже для своего сообщения с сайта."""
        deal = self.add_record("deal", "deal", account="DemoTrader")
        remote = {"id": "remote", "message": "First from site", "user_username": "DemoTrader", "date_added": time.time() + 1}
        message_id = stable_id("deal", "incoming", "remote")
        self.add_record("message", message_id, deal_id="deal", source="incoming", status="baseline", text_purged_at=time.time())
        self.assertEqual(await self.core._incoming(self.store.get("account", "demo-1"), deal, remote, set()), 0)
        self.translator.translate.assert_not_awaited()
        self.sink.incoming.assert_not_awaited()

    async def test_runtime_does_not_cleanup_on_every_poll(self):
        """Два прохода poll используют одну очистку; отдельной фоновой службы нет."""
        original_sleep = asyncio.sleep
        polled = asyncio.Event()
        delays = []

        async def quick_sleep(delay):
            """Ускоряет только тестовые паузы, сохраняя уступку циклу событий."""
            if delay == 10:
                delays.append(delay)
            if len(delays) >= 2:
                polled.set()
            await original_sleep(0.001)

        settings = Settings(data_dir=Path(self.temp.name) / "runtime", translator="groq")
        with patch.object(Store, "prune_expired", return_value=(0, 0)) as prune:
            with patch("trader.runtime.asyncio.sleep", quick_sleep):
                async with open_runtime(settings):
                    await asyncio.wait_for(polled.wait(), 2)
                    self.assertEqual(prune.call_count, 1)

    async def test_original_button_handles_expiry_and_missing_provider_history_privately(self):
        """Старая кнопка показывает дозагруженный текст или понятное личное сообщение об отказе."""
        for outcome in ("MIC L-5 works", ValueError("UEX больше не отдаёт оригинал."), MarketError("uex_http_429")):
            with self.subTest(outcome=type(outcome).__name__):
                original = AsyncMock(return_value=outcome) if isinstance(outcome, str) else AsyncMock(side_effect=outcome)
                bot = SimpleNamespace(store=self.store, allowed=AsyncMock(return_value=True),
                                      service=SimpleNamespace(original=original))
                self.add_record("message", "button", owner_id="1234", text_purged_at=time.time())
                interaction = SimpleNamespace(user=SimpleNamespace(id=1234),
                    response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                    followup=SimpleNamespace(send=AsyncMock()))
                await OriginalView(bot, "button").show_original(interaction)
                original.assert_awaited_once_with("1234", "button")
                call = interaction.followup.send.await_args
                self.assertTrue(call.kwargs["ephemeral"])
                self.assertIn("MIC L-5" if isinstance(outcome, str) else "оригинал", call.args[0])
