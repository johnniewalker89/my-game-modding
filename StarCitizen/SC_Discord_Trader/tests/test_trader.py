"""Проверки изоляции участников, доставки, восстановления и внешних контрактов."""

import asyncio
import json
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import discord
import httpx

from trader.app import create_app
from trader.config import Settings
from trader.discord_bot import ArchivedDealView, ConnectGuideView, DealView, DealsView, OriginalView, PanelView, TraderBot, chunks, trade_thread_name
from trader.marketplace import DemoMarketplace, MarketError, UexMarketplace
from trader.service import DemoSink, TraderService, owner_trade_type, stable_id
from trader.store import Store, Vault
from trader.translation import TranslationError, Translator, expand_trade_terms


class RecordingSink(DemoSink):
    """Запоминает доставки, позволяя снять роль во время длительной операции."""

    def __init__(self):
        self.denied = set()
        self.received = []
        self.archived = []
        self.archive_modes = []
        self.events = []

    async def allowed(self, owner_id, *, refresh=True):
        """Учитывает снятую роль; refresh принимает тот же режим, что и живой адаптер."""
        return owner_id not in self.denied and await super().allowed(owner_id, refresh=refresh)

    async def incoming(self, deal, message):
        self.received.append((deal["id"], message["id"]))
        self.events.append(("incoming", deal["id"]))
        return await super().incoming(deal, message)

    async def archive(self, deal, *, locked=True):
        self.archived.append(deal["id"])
        self.archive_modes.append((deal["id"], locked))
        self.events.append(("archive", deal["id"]))


class CountingMarket(DemoMarketplace):
    """Считает фактические попытки отправки и умеет потерять подтверждение."""

    def __init__(self, store):
        super().__init__(store)
        self.sends = 0
        self.uncertain = False

    async def send(self, account, secret, negotiation_id, text):
        self.sends += 1
        result = await super().send(account, secret, negotiation_id, text)
        if self.uncertain:
            raise MarketError("uex_network", uncertain=True)
        return result


class StubTranslator:
    """Управляемый переводчик сценарных тестов; качество проверяется отдельно на модели."""

    def __init__(self):
        self.fail = False
        self.after = None

    async def translate(self, text, source, target, protected=(), *, context=None):
        """Имитирует перевод text; принимает необязательные данные сделки context."""
        if self.fail:
            raise TranslationError("test_unavailable")
        if self.after:
            self.after()
        return f"{target}: {text}"


class ServiceTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет общие сценарии без отправок реальным участникам."""

    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.store = Store(self.path / "state.sqlite3")
        self.vault = Vault(self.path / "master.key")
        self.market = CountingMarket(self.store)
        self.sink = RecordingSink()
        self.translator = StubTranslator()
        self.core = TraderService(self.store, self.vault, self.market, self.translator, self.sink)
        await self.core.connect("demo-1", "secret-one")
        await self.core.connect("demo-2", "secret-two")

    async def asyncTearDown(self):
        self.store.close()
        self.temp.cleanup()

    async def make_deal(self, owner="demo-1", direction="sell", peer="SpaceBuyer"):
        row = self.market.add_deal(owner, direction, "Karna Rifle", peer)
        await self.core.scan(owner, force=True)
        deal_id = stable_id(owner, "DemoTrader", row["id"])
        return self.store.get("deal", deal_id)

    async def test_sale_purchase_separate_peers_and_owners(self):
        sale = await self.make_deal()
        another = await self.make_deal(peer="AnotherBuyer")
        purchase = await self.make_deal("demo-2", "buy", "SpaceSeller")
        for deal in (sale, another, purchase):
            self.market.add_message(deal["owner_id"], deal["external_id"], deal["peer"], "Still available?")
            self.assertEqual(await self.core.scan(deal["owner_id"], force=True), 1)
        self.assertEqual(len(self.sink.received), 3)
        self.assertEqual(len({self.store.get("deal", d["id"])["thread_id"] for d in (sale, another, purchase)}), 3)
        self.assertEqual(purchase["direction"], "buy")
        self.assertEqual(len(self.store.all("deal", "demo-2")), 1)
        with self.assertRaises(PermissionError):
            await self.core.reply("demo-2", sale["id"], "cross-owner", "Куплю")
        self.assertEqual(self.market.sends, 0)

    async def test_replayed_incoming_outgoing_and_self_echo(self):
        deal = await self.make_deal()
        self.sink.thread = AsyncMock(wraps=self.sink.thread)
        self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Hello")
        self.assertEqual(await self.core.scan("demo-1", force=True), 1)
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        results = await asyncio.gather(*[
            self.core.reply("demo-1", deal["id"], "same-discord-message", "Да, продаю") for _ in range(3)
        ])
        self.assertTrue(all(r["status"] == "delivered" for r in results))
        self.assertEqual(self.market.sends, 1)
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        self.assertEqual(len(self.sink.received), 1)
        self.sink.thread.assert_awaited_once()

    async def test_own_site_message_is_displayed_without_replaying_history_or_api_echo(self):
        """Своя новая фраза с сайта видна один раз, старая история и эхо бота не дублируются."""
        deal = await self.make_deal(direction="buy")
        old = self.market.add_message("demo-1", deal["external_id"], "DemoTrader", "Old own message")
        old["date_added"] = self.store.get("account", "demo-1")["since"] - 1
        self.store.put("remote_message", old)
        first = self.market.add_message("demo-1", deal["external_id"], "DemoTrader", "I want to buy")
        self.assertEqual(await self.core.scan("demo-1", force=True), 1)
        saved = self.store.get("message", stable_id(deal["id"], "incoming", first["id"]))
        self.assertEqual(saved["sender"], "DemoTrader")
        self.assertEqual(saved["status"], "delivered")
        self.assertTrue((await self.core.deal("demo-1", deal["id"]))["thread_id"])
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        reply = await self.core.reply("demo-1", deal["id"], "from-discord", "Ответ")
        self.assertEqual(reply["status"], "delivered")
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        self.market.add_message("demo-1", deal["external_id"], "DemoTrader", reply["translated"])
        self.assertEqual(await self.core.scan("demo-1", force=True), 1)
        self.assertEqual(len(self.sink.received), 2)
        self.assertEqual(self.market.sends, 1)

    async def test_previously_hidden_new_own_site_message_is_recovered_once(self):
        """Старая baseline-запись своего нового сообщения восстанавливается без повторной отправки UEX."""
        deal = await self.make_deal(direction="buy")
        remote = self.market.add_message("demo-1", deal["external_id"], "DemoTrader", "First from site")
        record_id = stable_id(deal["id"], "incoming", remote["id"])
        self.store.put("message", {"id": record_id, "owner_id": "demo-1", "deal_id": deal["id"],
                                  "source": "incoming", "external_id": remote["id"],
                                  "original": remote["message"], "translated": "",
                                  "created_at": remote["date_added"], "status": "baseline"})
        self.assertEqual(await self.core.scan("demo-1", force=True), 1)
        self.assertEqual(self.store.get("message", record_id)["status"], "delivered")
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        self.assertEqual(len(self.sink.received), 1)
        self.assertEqual(self.market.sends, 0)

    async def test_recent_empty_deal_checks_first_message_without_waiting_for_full_sync(self):
        """Свежий пустой диалог проверяется без изменения даты, старые пустые записи не опрашиваются чаще."""
        row = self.market.add_deal("demo-1", "buy", "Copper", "Seller")
        row.update(date_added=time.time(), date_modified=0)
        self.store.put("remote_deal", row)
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        self.market.add_message("demo-1", row["id"], "DemoTrader", "First from site")
        self.store.put("remote_deal", row)
        self.assertEqual(await self.core.scan("demo-1"), 1)
        self.assertEqual(len(self.sink.received), 1)
        old = self.market.add_deal("demo-1", "buy", "Old empty", "Seller")
        old["date_added"] = self.store.get("account", "demo-1")["since"] - 1
        self.store.put("remote_deal", old)
        await self.core.scan("demo-1", force=True)
        self.market.messages = AsyncMock(wraps=self.market.messages)
        self.assertEqual(await self.core.scan("demo-1"), 0)
        self.market.messages.assert_not_awaited()
        self.assertEqual(self.market.sends, 0)

    async def test_only_current_visible_open_deals_are_listed_without_deleting_history(self):
        active = await self.make_deal()
        inactive = await self.make_deal(peer="HiddenListing")
        own_closed = await self.make_deal(peer="OwnClosed")
        peer_closed = await self.make_deal(peer="PeerClosed")
        await self.make_deal("demo-2")
        for deal in (active, inactive):
            self.market.add_message("demo-1", deal["external_id"], "DemoTrader", "Interested")
        row = self.store.get("remote_deal", inactive["external_id"])
        row["listing_active"] = False
        self.store.put("remote_deal", row)
        self.market.close_deal("demo-1", own_closed["external_id"])
        row = self.store.get("remote_deal", peer_closed["external_id"])
        row["date_closed_client"] = 1
        self.store.put("remote_deal", row)
        await self.core.scan("demo-1")
        self.assertEqual([d["id"] for d in await self.core.current_deals("demo-1")], [active["id"]])
        self.assertEqual(len(self.store.all("deal", "demo-1")), 4)
        for deal in (inactive, own_closed, peer_closed):
            with self.assertRaises(PermissionError):
                await self.core.open_thread("demo-1", deal["id"])
        row = self.store.get("remote_deal", inactive["external_id"])
        row["listing_active"] = True
        self.store.put("remote_deal", row)
        await self.core.scan("demo-1", force=True)
        self.assertEqual({d["id"] for d in await self.core.current_deals("demo-1")}, {active["id"], inactive["id"]})

    async def test_unknown_listing_status_is_not_treated_as_visible_or_deleted(self):
        deal = await self.make_deal()
        self.market.add_message("demo-1", deal["external_id"], "DemoTrader", "Interested")
        self.market.listing_active = AsyncMock(side_effect=MarketError("uex_network"))
        await self.core.scan("demo-1", force=True)
        self.assertEqual(await self.core.current_deals("demo-1"), [])
        self.assertIsNone(self.store.get("deal", deal["id"])["current"])
        self.assertEqual(self.core.last_error, "UEX: listing_status_unavailable")
        self.market.listing_active = AsyncMock(return_value=True)
        await self.core.scan("demo-1", force=True)
        self.assertEqual([d["id"] for d in await self.core.current_deals("demo-1")], [deal["id"]])

    async def test_empty_negotiation_hidden_until_message_without_merging_real_conversations(self):
        first = await self.make_deal()
        empty = await self.make_deal()
        row = self.store.get("remote_deal", empty["external_id"])
        row["id_listing"] = first["listing_id"]
        self.store.put("remote_deal", row)
        await self.core.scan("demo-1", force=True)
        self.assertEqual(await self.core.current_deals("demo-1"), [])
        self.market.add_message("demo-1", first["external_id"], "DemoTrader", "I want to buy")
        await self.core.scan("demo-1", force=True)
        self.assertEqual([d["id"] for d in await self.core.current_deals("demo-1")], [first["id"]])
        self.assertIsNotNone(self.store.get("deal", empty["id"]))
        first = await self.core.open_thread("demo-1", first["id"])
        await self.core.archive_thread("demo-1", first["id"], first["thread_id"])
        self.assertTrue((await self.core.current_deals("demo-1"))[0]["paused"])
        self.market.add_message("demo-1", empty["external_id"], empty["peer"], "Available now")
        self.assertEqual(await self.core.scan("demo-1", force=True), 1)
        self.assertEqual({d["id"] for d in await self.core.current_deals("demo-1")}, {first["id"], empty["id"]})
        self.assertTrue(self.store.get("deal", empty["id"])["thread_id"])
        self.assertTrue(self.store.get("deal", first["id"])["paused"])
        self.assertEqual(self.market.sends, 0)

    async def test_old_history_allows_manual_thread_and_reply_without_new_incoming(self):
        """Старая переписка открывается вручную и принимает ответ без нового входящего."""
        deal = await self.make_deal(direction="buy", peer="SpaceSeller")
        remote = self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Old message")
        remote["date_added"] = self.store.get("account", "demo-1")["since"] - 1
        self.store.put("remote_message", remote)
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        self.assertEqual(self.store.all("message", "demo-1")[0]["original"], "Old message")
        self.assertEqual(self.sink.received, [])
        self.assertFalse((await self.core.deal("demo-1", deal["id"])).get("thread_id"))
        self.assertEqual([d["id"] for d in await self.core.current_deals("demo-1")], [deal["id"]])
        history = self.store.all("message", "demo-1")
        opened = await self.core.open_thread("demo-1", deal["id"])
        reopened = await self.core.open_thread("demo-1", deal["id"])
        self.assertTrue(opened["thread_id"])
        self.assertEqual(opened["thread_id"], reopened["thread_id"])
        self.assertEqual(self.store.all("message", "demo-1"), history)
        self.assertEqual(self.market.sends, 0)
        result = await self.core.reply("demo-1", deal["id"], "first-discord-reply", "Ещё продаёшь?")
        self.assertEqual(result["status"], "delivered")
        self.assertEqual(self.market.sends, 1)
        sent = self.store.get("remote_message", result["remote_id"])
        self.assertEqual(sent["id_negotiation"], deal["external_id"])
        self.assertEqual(sent["message"], "en: Ещё продаёшь?")
        self.assertEqual(await self.core.scan("demo-1", force=True), 0)
        self.assertEqual(self.sink.received, [])
        self.assertEqual((await self.core.deal("demo-1", deal["id"]))["thread_id"], opened["thread_id"])

    async def test_trade_type_is_relative_to_owner_including_buy_advertisements(self):
        deal = await self.make_deal()
        row = self.store.get("remote_deal", deal["external_id"])
        row["operation"] = "buy"
        row["quality"] = 964
        self.store.put("remote_deal", row)
        await self.core.scan("demo-1", force=True)
        updated = self.store.get("deal", deal["id"])
        self.assertEqual(updated["trade_type"], "WTB")
        self.assertEqual(updated["direction"], "buy")
        self.assertEqual(updated["quality"], 964)
        row["operation"] = "trade"
        row["quality"] = None
        self.store.put("remote_deal", row)
        await self.core.scan("demo-1", force=True)
        self.assertEqual(self.store.get("deal", deal["id"])["trade_type"], "WTT")
        self.assertIsNone(self.store.get("deal", deal["id"])["quality"])

    async def test_role_loss_during_translation_blocks_send(self):
        deal = await self.make_deal()
        self.translator.after = lambda: self.sink.denied.add("demo-1")
        result = await self.core.reply("demo-1", deal["id"], "removed-role", "Цена прежняя")
        self.assertEqual(result["status"], "failed")
        self.assertEqual(self.market.sends, 0)
        with self.assertRaises(PermissionError):
            await self.core.open_thread("demo-1", deal["id"])

    async def test_translation_failure_never_sends_original(self):
        """Отказ перевода не отправляет оригинал и оставляет безопасную причину в записи и журнале."""
        deal = await self.make_deal()
        self.translator.translate = AsyncMock(side_effect=TranslationError("private fixture message", code="protected_values_changed"))
        with self.assertLogs("trader.service", level="WARNING") as captured:
            result = await self.core.reply("demo-1", deal["id"], "no-translation", "Цена прежняя")
        self.assertEqual(result["status"], "translation_failed")
        self.assertEqual(result["error"], "protected_values_changed")
        self.assertIn("reason=protected_values_changed", " ".join(captured.output))
        self.assertNotIn("Цена прежняя", " ".join(captured.output))
        self.assertNotIn("private fixture message", " ".join(captured.output))
        self.assertEqual(self.market.sends, 0)

    async def test_unknown_delivery_never_auto_repeats_after_restart(self):
        deal = await self.make_deal()
        self.market.uncertain = True
        first = await self.core.reply("demo-1", deal["id"], "lost-ack", "Договорились")
        self.assertEqual(first["status"], "unknown")
        crashed = {**first, "id": "crashed-operation", "status": "sending"}
        self.store.put("message", crashed)
        encrypted = self.store.get("account", "demo-1")["secret"]
        self.assertNotIn("secret-one", encrypted)
        self.store.close()
        self.store = Store(self.path / "state.sqlite3")
        self.vault = Vault(self.path / "master.key")
        self.market.store = self.store
        self.core = TraderService(self.store, self.vault, self.market, self.translator, self.sink)
        self.assertEqual(self.vault.decrypt(self.store.get("account", "demo-1")["secret"]), "secret-one")
        self.assertEqual(self.store.get("message", "crashed-operation")["status"], "unknown")
        repeated = await self.core.reply("demo-1", deal["id"], "lost-ack", "Договорились")
        self.assertEqual(repeated["id"], first["id"])
        self.assertEqual(self.market.sends, 1)

    async def test_changed_account_and_disconnect_block_old_conversations(self):
        deal = await self.make_deal()
        account = self.store.get("account", "demo-1")
        account["username"] = "DifferentTrader"
        self.store.put("account", account)
        with self.assertRaises(PermissionError):
            await self.core.reply("demo-1", deal["id"], "changed-key", "Ответ")
        self.core.disconnect("demo-1")
        with self.assertRaises(PermissionError):
            await self.core.account("demo-1")
        self.assertIsNone(self.store.get("account", "demo-1")["secret"])

    async def test_either_side_closes_sale_or_purchase_preserving_final_message_and_history(self):
        for direction in ("sell", "buy"):
            for side in ("own", "peer", "both"):
                with self.subTest(direction=direction, side=side):
                    deal = await self.make_deal(direction=direction, peer=f"{direction}-{side}")
                    self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Hello")
                    self.assertEqual(await self.core.scan("demo-1"), 1)
                    before = self.store.get("deal", deal["id"])
                    self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Thank you!")
                    row = self.store.get("remote_deal", deal["external_id"])
                    own_field = "date_closed" if row["is_listing_advertiser"] else "date_closed_client"
                    peer_field = "date_closed_client" if row["is_listing_advertiser"] else "date_closed"
                    if side in {"own", "both"}:
                        row[own_field] = 1
                    if side in {"peer", "both"}:
                        row[peer_field] = 1
                    row["date_modified"] = before["modified"]
                    self.store.put("remote_deal", row)
                    self.assertEqual(await self.core.scan("demo-1"), 1)
                    saved = self.store.get("deal", deal["id"])
                    self.assertTrue(saved["archived"])
                    self.assertEqual(saved["thread_id"], before["thread_id"])
                    self.assertEqual(self.sink.events[-2:], [("incoming", deal["id"]), ("archive", deal["id"])])
                    history = [m for m in self.store.all("message", "demo-1") if m["deal_id"] == deal["id"]]
                    self.assertEqual([m["original"] for m in sorted(history, key=lambda m: m["created_at"])],
                                     ["Hello", "Thank you!"])
                    self.assertTrue(all(m["status"] == "delivered" for m in history))
                    events = list(self.sink.events)
                    self.assertEqual(await self.core.scan("demo-1", force=True), 0)
                    self.assertEqual(self.sink.events, events)
                    with self.assertRaises(ValueError):
                        await self.core.reply("demo-1", deal["id"], "already-closed", "Ответ")
        self.assertEqual(self.market.sends, 0)

    async def test_previously_known_peer_closure_is_archived_without_waiting_for_stale_scan(self):
        deal = await self.make_deal()
        self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Hello")
        await self.core.scan("demo-1")
        row = self.store.get("remote_deal", deal["external_id"])
        row["date_closed_client"] = 1
        self.store.put("remote_deal", row)
        old = self.store.get("deal", deal["id"])
        old.update(peer_closed=True, current=False)
        self.store.put("deal", old)
        history = self.store.all("message", "demo-1")
        self.market.messages = AsyncMock(wraps=self.market.messages)
        self.assertEqual(await self.core.scan("demo-1"), 0)
        self.assertEqual(self.sink.archived, [deal["id"]])
        self.assertTrue(self.store.get("deal", deal["id"])["archived"])
        self.assertEqual(self.store.all("message", "demo-1"), history)
        await self.core.scan("demo-1")
        self.market.messages.assert_awaited_once()
        self.assertEqual(self.sink.archived, [deal["id"]])

    async def test_failed_peer_archive_retries_without_repeating_messages(self):
        deal = await self.make_deal()
        self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Thank you!")
        row = self.store.get("remote_deal", deal["external_id"])
        row["date_closed_client"] = 1
        self.store.put("remote_deal", row)
        self.sink.archive = AsyncMock(side_effect=[RuntimeError("discord unavailable"), None])
        with self.assertRaises(RuntimeError):
            await self.core.scan("demo-1")
        self.assertFalse(self.store.get("deal", deal["id"]).get("archived", False))
        self.assertEqual(await self.core.scan("demo-1"), 0)
        self.assertTrue(self.store.get("deal", deal["id"])["archived"])
        self.assertEqual(len(self.sink.received), 1)
        self.assertEqual(self.sink.archive.await_count, 2)

    async def test_manual_archive_stays_paused_until_new_incoming_even_after_restart(self):
        deal = await self.make_deal()
        self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Hello")
        await self.core.scan("demo-1")
        deal = self.store.get("deal", deal["id"])
        self.sink.thread = AsyncMock(wraps=self.sink.thread)
        await self.core.archive_thread("demo-1", deal["id"], deal["thread_id"])
        self.assertEqual(self.sink.archive_modes, [(deal["id"], False)])
        self.assertTrue(self.store.get("deal", deal["id"])["paused"])
        await self.core.scan("demo-1", force=True)
        await self.core.open_thread("demo-1", deal["id"])
        self.sink.thread.assert_not_awaited()
        reopened = Store(self.path / "state.sqlite3")
        try:
            restarted = TraderService(reopened, self.vault, self.market, self.translator, self.sink)
            self.assertEqual(await restarted.scan("demo-1", force=True), 0)
            self.assertTrue(reopened.get("deal", deal["id"])["paused"])
        finally:
            reopened.close()
        self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Still interested?")
        self.assertEqual(await self.core.scan("demo-1"), 1)
        self.assertFalse(self.store.get("deal", deal["id"])["paused"])
        self.sink.thread.assert_awaited_once()
        history = [m for m in self.store.all("message") if m["deal_id"] == deal["id"]]
        self.assertEqual(len(history), 2)
        row = self.store.get("remote_deal", deal["external_id"])
        self.assertFalse(row["date_closed"] or row["date_closed_client"])
        self.market.close_deal("demo-1", deal["external_id"])
        await self.core.scan("demo-1")
        self.assertEqual(self.sink.archive_modes[-1], (deal["id"], True))

    async def test_manual_archive_requires_own_thread_and_role_and_keeps_closed_deals_terminal(self):
        deal = await self.make_deal()
        deal = await self.core.open_thread("demo-1", deal["id"])
        for owner, thread in (("demo-2", deal["thread_id"]), ("demo-1", "another-thread")):
            with self.assertRaises(PermissionError):
                await self.core.archive_thread(owner, deal["id"], thread)
        self.sink.denied.add("demo-1")
        with self.assertRaises(PermissionError):
            await self.core.archive_thread("demo-1", deal["id"], deal["thread_id"])
        self.assertEqual(self.sink.archived, [])
        self.sink.denied.clear()
        self.market.close_deal("demo-1", deal["external_id"])
        await self.core.scan("demo-1")
        with self.assertRaises(ValueError):
            await self.core.archive_thread("demo-1", deal["id"], deal["thread_id"])
        self.assertEqual(self.sink.archive_modes, [(deal["id"], True)])

    async def test_manual_archive_needs_no_uex_key_and_does_not_claim_failed_archive(self):
        deal = await self.make_deal()
        deal = await self.core.open_thread("demo-1", deal["id"])
        self.core.disconnect("demo-1")
        self.sink.archive = AsyncMock(side_effect=RuntimeError("Discord unavailable"))
        with self.assertRaises(RuntimeError):
            await self.core.archive_thread("demo-1", deal["id"], deal["thread_id"])
        self.assertFalse(self.store.get("deal", deal["id"]).get("paused", False))
        self.sink.archive = AsyncMock()
        await self.core.archive_thread("demo-1", deal["id"], deal["thread_id"])
        self.assertTrue(self.store.get("deal", deal["id"])["paused"])
        self.assertEqual(self.market.sends, 0)

    async def test_explicit_restore_preserves_thread_history_and_clears_pause_after_confirmation(self):
        deal = await self.make_deal()
        self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Hello")
        await self.core.scan("demo-1")
        deal = self.store.get("deal", deal["id"])
        await self.core.archive_thread("demo-1", deal["id"], deal["thread_id"])
        history = self.store.all("message")
        self.sink.restore = AsyncMock(side_effect=RuntimeError("Discord unavailable"))
        with self.assertRaises(RuntimeError):
            await self.core.restore_thread("demo-1", deal["id"])
        self.assertTrue(self.store.get("deal", deal["id"])["paused"])
        self.sink.restore = AsyncMock()
        self.sink.thread = AsyncMock()
        restored = await self.core.restore_thread("demo-1", deal["id"])
        self.assertEqual(restored["thread_id"], deal["thread_id"])
        self.assertFalse(restored["paused"])
        self.sink.restore.assert_awaited_once()
        self.sink.thread.assert_not_awaited()
        self.assertEqual(self.store.all("message"), history)
        self.assertEqual(self.market.sends, 0)
        restarted = TraderService(self.store, self.vault, self.market, self.translator, self.sink)
        self.assertFalse((await restarted.deal("demo-1", deal["id"]))["paused"])

    async def test_restore_rejects_foreign_role_revoked_missing_thread_and_closed_deals(self):
        deal = await self.make_deal()
        self.sink.restore = AsyncMock()
        with self.assertRaises(ValueError):
            await self.core.restore_thread("demo-1", deal["id"])
        deal = await self.core.open_thread("demo-1", deal["id"])
        await self.core.archive_thread("demo-1", deal["id"], deal["thread_id"])
        with self.assertRaises(PermissionError):
            await self.core.restore_thread("demo-2", deal["id"])
        self.sink.denied.add("demo-1")
        with self.assertRaises(PermissionError):
            await self.core.restore_thread("demo-1", deal["id"])
        self.sink.denied.clear()
        for field in ("own_closed", "peer_closed"):
            changed = {**self.store.get("deal", deal["id"]), field: True}
            self.store.put("deal", changed)
            with self.assertRaises(PermissionError):
                await self.core.restore_thread("demo-1", deal["id"])
            self.store.put("deal", {**changed, field: False})
        self.store.put("deal", {**self.store.get("deal", deal["id"]), "current": False})
        with self.assertRaises(PermissionError):
            await self.core.restore_thread("demo-1", deal["id"])
        self.sink.restore.assert_not_awaited()
        self.assertTrue(self.store.get("deal", deal["id"])["paused"])

    async def test_closed_final_translation_failure_retries_before_archive(self):
        """Ошибка перевода финального ответа не делает архив окончательным до безопасной доставки."""
        for closer in ("owner", "peer"):
            with self.subTest(closer=closer):
                self.translator.fail = False
                deal = await self.make_deal(peer=f"Buyer-{closer}")
                self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Initial")
                await self.core.scan("demo-1", force=True)
                final = self.market.add_message("demo-1", deal["external_id"], deal["peer"], "Final")
                if closer == "owner":
                    self.market.close_deal("demo-1", deal["external_id"])
                else:
                    remote_deal = self.store.get("remote_deal", deal["external_id"])
                    remote_deal["date_closed_client"] = time.time()
                    self.store.put("remote_deal", remote_deal)
                archive_count = len(self.sink.archived)
                self.translator.fail = True
                with self.assertLogs("trader.service", level="WARNING") as logs:
                    self.assertEqual(await self.core.scan("demo-1", force=True), 0)
                self.assertIn("reason=translation_failed", " ".join(logs.output))
                self.assertNotIn("Final", " ".join(logs.output))
                saved = self.store.get("deal", deal["id"])
                self.assertTrue(saved["own_closed"] or saved["peer_closed"])
                self.assertFalse(saved.get("archived", False))
                self.assertEqual(len(self.sink.archived), archive_count)
                message_id = stable_id(deal["id"], "incoming", final["id"])
                self.assertEqual(self.store.get("message", message_id)["status"], "translation_failed")
                self.translator.fail = False
                self.assertEqual(await self.core.scan("demo-1"), 1)
                self.assertEqual(self.store.get("message", message_id)["status"], "delivered")
                self.assertTrue(self.store.get("deal", deal["id"])["archived"])
                self.assertEqual(self.sink.events[-2:], [("incoming", deal["id"]), ("archive", deal["id"])])
                self.assertEqual(await self.core.scan("demo-1", force=True), 0)

    async def test_missing_sender_not_treated_as_counterparty(self):
        deal = await self.make_deal()
        self.market.add_message("demo-1", deal["external_id"], "", "Missing author")
        with self.assertRaises(MarketError):
            await self.core.scan("demo-1", force=True)
        self.assertEqual(self.sink.received, [])

    async def test_owner_invariant_unique_ids_and_query_plans(self):
        row = {"id": "unique", "owner_id": "demo-1", "text": "first"}
        self.assertTrue(self.store.put("proof", row, new_only=True))
        self.assertFalse(self.store.put("proof", row, new_only=True))
        for new_only in (False, True):
            with self.assertRaises(PermissionError):
                self.store.put("proof", {**row, "owner_id": "demo-2"}, new_only=new_only)
        self.assertEqual(self.store.all("proof", "demo-2"), [])
        plans = self.store.db.execute(
            "EXPLAIN QUERY PLAN SELECT payload FROM documents WHERE kind = ? AND owner_id = ?",
            ("proof", "demo-1"),
        ).fetchall()
        self.assertTrue(any("documents_owner" in p[3] for p in plans))
        plans = self.store.db.execute(
            "EXPLAIN QUERY PLAN SELECT payload FROM documents WHERE kind = ? AND id = ?",
            ("proof", "unique"),
        ).fetchall()
        self.assertTrue(any("INDEX" in p[3] for p in plans))


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет HTTP-контракты и обработку неполных подтверждений."""


    def make_bot(self):
        """Создаёт локальный бот с базой; unittest закроет ресурсы после сценария."""
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        store = Store(Path(temp.name) / "state.sqlite3")
        self.addCleanup(store.close)
        bot = TraderBot(Settings(guild_id=123, channel_id=456, role_id=789), store)
        self.addAsyncCleanup(bot.close)
        return bot

    async def test_original_is_private_text_with_full_file_fallback_at_discord_limit(self):
        """Короткий оригинал читается в чате, длинный сохраняется целиком с учётом UTF-16."""
        header = "**Оригинал**\n"
        maximum_body = 2000 - len(header.encode("utf-16-le")) // 2
        for original, as_file in (("WTB all (5)", False), ("x" * maximum_body, False),
                                  ("x" * (maximum_body + 1), True), ("🛸" * 1000, True)):
            with self.subTest(as_file=as_file, length=len(original)):
                record = {"owner_id": "1234", "original": original}
                bot = SimpleNamespace(store=SimpleNamespace(get=Mock(return_value=record)),
                                      allowed=AsyncMock(return_value=True))
                interaction = SimpleNamespace(user=SimpleNamespace(id=1234),
                    response=SimpleNamespace(defer=AsyncMock()), followup=SimpleNamespace(send=AsyncMock()))
                await OriginalView(bot, "message").show_original(interaction)
                interaction.response.defer.assert_awaited_once_with(ephemeral=True)
                call = interaction.followup.send.await_args
                self.assertTrue(call.kwargs["ephemeral"])
                if as_file:
                    attachment = call.kwargs["file"]
                    self.assertEqual(attachment.fp.getvalue().decode("utf-8"), original)
                    attachment.close()
                else:
                    self.assertEqual(call.args[0], header + original)
                    self.assertNotIn("file", call.kwargs)
                    self.assertTrue(call.kwargs["suppress_embeds"])
                    self.assertEqual(call.kwargs["allowed_mentions"].to_dict(), {"parse": []})

    async def test_original_cannot_be_read_by_another_owner_or_without_role(self):
        """Новый текстовый показ не раскрывает оригинал чужому участнику или без роли."""
        for actor, allowed in ((9999, True), (1234, False)):
            with self.subTest(actor=actor, allowed=allowed):
                bot = SimpleNamespace(store=SimpleNamespace(get=Mock(return_value={
                    "owner_id": "1234", "original": "private-original"})), allowed=AsyncMock(return_value=allowed))
                interaction = SimpleNamespace(user=SimpleNamespace(id=actor),
                    response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                    followup=SimpleNamespace(send=AsyncMock()))
                await OriginalView(bot, "message").show_original(interaction)
                call = interaction.followup.send.await_args
                self.assertNotIn("private-original", call.args[0])
                self.assertNotIn("file", call.kwargs)
                self.assertTrue(call.kwargs["ephemeral"])

    async def test_panel_is_registered_for_admins_and_runtime_denies_other_actors(self):
        """Панель требует Administrator при регистрации и выполнении, включая bot-участника."""
        bot = self.make_bot()
        bot.tree.sync = AsyncMock(return_value=[])
        channel = Mock(spec=discord.TextChannel)
        channel.id = 456
        channel.guild.id = 123
        channel.send = AsyncMock(return_value=SimpleNamespace(id=999))

        async def empty_history(**kwargs):
            """Даёт пустую историю для размещения первой панели администратором."""
            for message in ():
                yield message

        channel.history = Mock(side_effect=empty_history)
        bot.fetch_channel = AsyncMock(return_value=channel)
        await bot.setup_hook()
        command = bot.tree.get_command("панель", guild=discord.Object(id=123))
        self.assertEqual(command.default_permissions.value, 8)
        for permissions, guild_id, is_bot in ((discord.Permissions.none(), 123, False),
                (discord.Permissions(manage_guild=True), 123, False),
                (discord.Permissions.none(), 123, True),
                (discord.Permissions(administrator=True), 999, False)):
            member = Mock(spec=discord.Member)
            member.guild_permissions, member.bot = permissions, is_bot
            interaction = SimpleNamespace(guild_id=guild_id, user=member,
                response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                followup=SimpleNamespace(send=AsyncMock()))
            await command.callback(interaction)
            self.assertIn("только администратор", interaction.followup.send.await_args.args[0])
            bot.fetch_channel.assert_not_awaited()
        member.guild_permissions = discord.Permissions(administrator=True)
        interaction.guild_id = 123
        await command.callback(interaction)
        channel.send.assert_awaited_once()
        self.assertIsInstance(channel.send.await_args.kwargs["view"], PanelView)

    async def test_legacy_public_panel_is_updated_in_place_and_saved_without_repeated_patch(self):
        """Старая панель мигрирует по своим кнопкам; чужие сообщения и повторный запуск безопасны."""
        bot = self.make_bot()
        bot._connection.user = SimpleNamespace(id=900)
        legacy = discord.ActionRow({"type": 1, "components": [
            {"type": 2, "style": 1, "custom_id": "scdt:connect", "label": "Подключить UEX"},
            {"type": 2, "style": 2, "custom_id": "scdt:deals", "label": "Мои сделки"},
            {"type": 2, "style": 2, "custom_id": "scdt:listings", "label": "Объявления"}]})
        panel = SimpleNamespace(id=111, author=bot.user, content="Старые подсказки",
                                components=[legacy], edit=AsyncMock())
        foreign = SimpleNamespace(id=222, author=SimpleNamespace(id=901),
                                  content="Не трогать", components=[legacy], edit=AsyncMock())
        own_other = SimpleNamespace(id=333, author=bot.user, content="Другая карточка",
                                    components=[], edit=AsyncMock())
        channel = Mock(spec=discord.TextChannel, id=456)
        channel.guild.id = 123
        channel.send = AsyncMock()

        async def history(**kwargs):
            """Возвращает чужую панель и своё другое сообщение перед старой панелью."""
            for message in (foreign, own_other, panel):
                yield message

        channel.history = Mock(side_effect=history)
        channel.fetch_message = AsyncMock(return_value=panel)
        bot.fetch_channel = AsyncMock(return_value=channel)
        self.assertTrue(await bot.refresh_panel())
        panel.edit.assert_awaited_once()
        update = panel.edit.await_args.kwargs
        self.assertIn("**Отключить UEX**", update["content"])
        self.assertIn("**Найти товар**", update["content"])
        self.assertEqual(update["allowed_mentions"].to_dict(), {"parse": []})
        self.assertEqual(bot.store.get("discord_panel", "456"),
                         {"id": "456", "owner_id": "123", "message_id": "111"})
        panel.content = update["content"]
        panel.components = [discord.ActionRow(row) for row in update["view"].to_components()]
        channel.history.reset_mock()
        self.assertTrue(await bot.refresh_panel(create=True))
        channel.fetch_message.assert_awaited_once_with(111)
        channel.history.assert_not_called()
        panel.edit.assert_awaited_once()
        channel.send.assert_not_awaited()
        foreign.edit.assert_not_awaited()
        own_other.edit.assert_not_awaited()

    async def test_startup_does_not_publish_missing_panel_or_retry_failed_refresh_on_ready(self):
        """Без панели старт ничего не публикует; reconnect не повторяет отказавший PATCH."""
        bot = self.make_bot()
        bot._connection.user = SimpleNamespace(id=900)
        channel = Mock(spec=discord.TextChannel, id=456)
        channel.guild.id = 123
        channel.send = AsyncMock()

        async def empty_history(**kwargs):
            """Возвращает пустую историю без внешнего Discord."""
            for message in ():
                yield message

        channel.history = Mock(side_effect=empty_history)
        bot.fetch_channel = AsyncMock(return_value=channel)
        self.assertFalse(await bot.refresh_panel())
        channel.send.assert_not_awaited()
        self.assertIsNone(bot.store.get("discord_panel", "456"))
        bot.refresh_panel = AsyncMock(side_effect=RuntimeError("synthetic failure"))
        with self.assertLogs("trader.discord_bot", level="WARNING"):
            await bot.on_ready()
        await bot.on_ready()
        bot.refresh_panel.assert_awaited_once_with()

    async def test_manual_archive_button_uses_private_ack_and_actual_actor_and_channel(self):
        core = SimpleNamespace(archive_thread=AsyncMock())
        bot = SimpleNamespace(service=core, settings=Settings(guild_id=123))
        view = DealView(bot, {"id": "deal", "own_closed": False})
        self.assertTrue(view.is_persistent())
        interaction = SimpleNamespace(guild_id=123, channel_id=888, user=SimpleNamespace(id=1234),
                                      response=SimpleNamespace(defer=AsyncMock()),
                                      edit_original_response=AsyncMock())
        button = next(b for b in view.children if b.custom_id == "scdt:archive:deal")
        await button.callback(interaction)
        interaction.response.defer.assert_awaited_once_with(ephemeral=True, thinking=True)
        core.archive_thread.assert_awaited_once_with("1234", "deal", "888")
        self.assertIn("не закрыта", interaction.edit_original_response.await_args.kwargs["content"])
        core.archive_thread.reset_mock()
        interaction.guild_id = 999
        await button.callback(interaction)
        core.archive_thread.assert_not_awaited()

    async def test_incoming_reopens_paused_thread_but_not_closed_thread(self):
        for peer_closed in (False, True):
            bot = self.make_bot()
            owner = SimpleNamespace(roles=[SimpleNamespace(id=789)])
            parent = Mock(spec=discord.TextChannel)
            parent.id = 456
            parent.guild = SimpleNamespace(id=123, fetch_member=AsyncMock(return_value=owner))
            thread = Mock(spec=discord.Thread)
            thread.id, thread.parent_id = 888, 456
            thread.is_private.return_value = True
            thread.archived, thread.locked = True, False
            thread.edit, thread.add_user = AsyncMock(), AsyncMock()
            thread.send = AsyncMock()
            deal = {"id": "d", "owner_id": "1234", "title": "Janalite", "peer": "Seller",
                    "own_closed": False, "peer_closed": peer_closed, "paused": True,
                    "thread_id": "888", "card_sent": True}
            thread.name = trade_thread_name(deal)
            bot.fetch_channel = AsyncMock(side_effect=[parent, thread])
            await bot.thread(deal)
            if peer_closed:
                thread.edit.assert_not_awaited()
                thread.send.assert_not_awaited()
            else:
                thread.edit.assert_awaited_once_with(archived=False)
                self.assertIn("Ветка возвращена из архива", thread.send.await_args.args[0])

    async def test_archived_thread_with_changed_title_opens_before_rename_and_delivery(self):
        """Контракт Discord отклоняет rename архивной ветки; SDK edit не меняет прежний объект."""
        bot = self.make_bot()
        owner = SimpleNamespace(roles=[SimpleNamespace(id=789)])
        parent = Mock(spec=discord.TextChannel, id=456)
        parent.guild = SimpleNamespace(id=123, fetch_member=AsyncMock(return_value=owner))
        thread = Mock(spec=discord.Thread, id=888, parent_id=456)
        thread.is_private.return_value = True
        thread.archived, thread.locked, thread.name = True, False, "Old title"
        remote = {"archived": True, "name": thread.name}
        edits = []

        async def edit(**changes):
            """Повторяет реальный отказ API без записи в Discord."""
            if remote["archived"] and "name" in changes and changes.get("archived") is not False:
                raise discord.HTTPException(SimpleNamespace(status=400, reason="Bad Request"),
                                            {"code": 50083, "message": "Thread is archived"})
            edits.append(changes)
            remote.update(changes)
            return Mock(spec=discord.Thread, id=888, parent_id=456, **remote)

        thread.edit = AsyncMock(side_effect=edit)
        thread.add_user, thread.send = AsyncMock(), AsyncMock()
        bot.fetch_channel = AsyncMock(side_effect=lambda channel_id: parent if channel_id == 456 else thread)
        deal = {"id": "d", "owner_id": "1234", "title": "Janalite", "peer": "Seller",
                "own_closed": False, "peer_closed": False, "paused": True,
                "thread_id": "888", "card_sent": True}
        self.assertEqual(await bot.thread(deal), "888")
        self.assertEqual(edits, [{"archived": False}, {"name": trade_thread_name(deal)}])
        self.assertFalse(remote["archived"])
        self.assertTrue(thread.archived)
        deal["account"] = "Owner"
        await bot.incoming(deal, {"id": "incoming-fixture", "translated": "Перевод"})
        self.assertIn("Перевод", thread.send.await_args.args[0])

    async def test_closed_or_locked_archive_is_not_renamed_or_given_new_members(self):
        """Обновление заголовка закрытой/заблокированной архивной ветки не вызывает PATCH или add-user."""
        for closed, locked in ((True, False), (False, True)):
            bot = self.make_bot()
            owner = SimpleNamespace(roles=[SimpleNamespace(id=789)])
            parent = Mock(spec=discord.TextChannel, id=456)
            parent.guild = SimpleNamespace(id=123, fetch_member=AsyncMock(return_value=owner))
            thread = Mock(spec=discord.Thread, id=888, parent_id=456)
            thread.is_private.return_value = True
            thread.archived, thread.locked, thread.name = True, locked, "Old title"
            thread.edit, thread.add_user, thread.send = AsyncMock(), AsyncMock(), AsyncMock()
            bot.fetch_channel = AsyncMock(side_effect=[parent, thread])
            deal = {"id": "d", "owner_id": "1234", "title": "Janalite", "peer": "Seller",
                    "own_closed": closed, "peer_closed": False, "thread_id": "888", "card_sent": True}
            await bot.thread(deal)
            thread.edit.assert_not_awaited()
            thread.add_user.assert_not_awaited()
            thread.send.assert_not_awaited()

    async def test_failed_cosmetic_rename_does_not_block_messages_or_repeat_same_bad_request(self):
        """Недоступное название не блокирует переписку; одинаковый400 не отправляется каждый опрос."""
        bot = self.make_bot()
        owner = SimpleNamespace(roles=[SimpleNamespace(id=789)])
        parent = Mock(spec=discord.TextChannel, id=456)
        parent.guild = SimpleNamespace(id=123, fetch_member=AsyncMock(return_value=owner))
        thread = Mock(spec=discord.Thread, id=888, parent_id=456)
        thread.is_private.return_value = True
        thread.archived, thread.locked, thread.name = False, False, "Old title"
        thread.edit = AsyncMock(side_effect=discord.HTTPException(SimpleNamespace(status=400, reason="Bad Request"),
                                                                 {"code": 50035, "message": "private-fixture"}))
        thread.add_user, thread.send = AsyncMock(), AsyncMock()
        bot.fetch_channel = AsyncMock(side_effect=lambda channel_id: parent if channel_id == 456 else thread)
        deal = {"id": "d", "owner_id": "1234", "title": "Janalite", "peer": "Seller",
                "own_closed": False, "thread_id": "888", "card_sent": True}
        with self.assertLogs("trader.discord_bot", level="WARNING") as logs:
            self.assertEqual(await bot.thread(deal), "888")
        self.assertNotIn("private-fixture", str(logs.output))
        self.assertEqual(await bot.thread(deal), "888")
        thread.edit.assert_awaited_once()
        deal["account"] = "Owner"
        await bot.incoming(deal, {"id": "incoming-fixture", "translated": "Перевод"})
        self.assertIn("Перевод", thread.send.await_args.args[0])

    async def test_archive_locks_private_thread_without_deleting_or_recreating_it(self):
        bot = self.make_bot()
        thread = Mock(spec=discord.Thread)
        thread.parent_id = 456
        thread.is_private.return_value = True
        thread.archived = False
        thread.locked = False
        thread.edit = AsyncMock()
        thread.delete = AsyncMock()
        bot.fetch_channel = AsyncMock(return_value=thread)
        await bot.archive({"thread_id": "888"})
        thread.edit.assert_awaited_once_with(archived=True, locked=True)
        thread.delete.assert_not_awaited()
        thread.edit.reset_mock()
        await bot.archive({"thread_id": "888"}, locked=False)
        thread.edit.assert_awaited_once_with(archived=True, locked=False)
        thread.locked = True
        with self.assertRaises(PermissionError):
            await bot.archive({"thread_id": "888"}, locked=False)
        thread.parent_id = 999
        with self.assertRaises(PermissionError):
            await bot.archive({"thread_id": "888"})
        for failure_type, status in ((discord.NotFound, 404), (discord.Forbidden, 403)):
            error = failure_type(SimpleNamespace(status=status, reason="test"), "test")
            bot.fetch_channel = AsyncMock(side_effect=error)
            if failure_type is discord.NotFound:
                await bot.archive({"thread_id": "888"})
            else:
                with self.assertRaises(discord.Forbidden):
                    await bot.archive({"thread_id": "888"})
            bot.fetch_channel.assert_awaited_once_with(888)

    async def test_already_archived_thread_is_left_untouched_when_deal_closes(self):
        """Закрытие сделки не открывает ручной архив и не вызывает запрещённый PATCH50083."""
        for locked in (False, True):
            bot = self.make_bot()
            thread = Mock(spec=discord.Thread, id=888, parent_id=456)
            thread.is_private.return_value = True
            thread.archived, thread.locked = True, locked
            thread.edit = AsyncMock(side_effect=discord.HTTPException(SimpleNamespace(status=400, reason="Bad Request"),
                                        {"code": 50083, "message": "Thread is archived"}))
            bot.fetch_channel = AsyncMock(return_value=thread)
            await bot.archive({"thread_id": "888"})
            thread.edit.assert_not_awaited()

    async def test_restore_only_unarchives_existing_unlocked_own_parent_thread(self):
        bot = self.make_bot()
        thread = Mock(spec=discord.Thread)
        thread.parent_id = 456
        thread.is_private.return_value = True
        thread.archived, thread.locked = True, False
        thread.edit, thread.delete = AsyncMock(), AsyncMock()
        thread.send = AsyncMock()
        bot.fetch_channel = AsyncMock(return_value=thread)
        bot.allowed = AsyncMock(return_value=True)
        deal = {"thread_id": "888", "owner_id": "1234"}
        await bot.restore(deal)
        thread.edit.assert_awaited_once_with(archived=False)
        self.assertIn("Ветка возвращена из архива", thread.send.await_args.args[0])
        thread.delete.assert_not_awaited()
        bot.allowed.assert_awaited_once_with("1234")
        thread.edit.reset_mock()
        thread.archived = False
        await bot.restore(deal)
        thread.edit.assert_not_awaited()
        thread.send.assert_awaited_once()
        thread.archived, thread.locked = True, True
        with self.assertRaises(PermissionError):
            await bot.restore(deal)
        thread.locked, thread.parent_id = False, 999
        with self.assertRaises(PermissionError):
            await bot.restore(deal)
        thread.parent_id = 456
        bot.allowed = AsyncMock(return_value=False)
        with self.assertRaises(PermissionError):
            await bot.restore(deal)
        thread.edit.assert_not_awaited()
        bot.fetch_channel = AsyncMock(side_effect=discord.NotFound(
            SimpleNamespace(status=404, reason="test"), "test"))
        with self.assertRaises(discord.NotFound):
            await bot.restore(deal)
        bot.fetch_channel.assert_awaited_once_with(888)

    async def test_archived_selection_replaces_private_menu_with_restore_button(self):
        deal = {"id": "d", "owner_id": "1234", "title": "Janalite", "peer": "Seller",
                "thread_id": "888", "own_closed": False, "paused": True}
        core = SimpleNamespace(deal=AsyncMock(return_value=deal), open_thread=AsyncMock(return_value=deal))
        view = DealsView(SimpleNamespace(service=core, settings=Settings(guild_id=123)), "1234", [deal])
        view.selection = SimpleNamespace(values=["d"])
        interaction = SimpleNamespace(response=SimpleNamespace(defer=AsyncMock(), is_done=Mock(return_value=True)),
                                      edit_original_response=AsyncMock(), followup=SimpleNamespace(send=AsyncMock()))
        await view.open_selected(interaction)
        interaction.followup.send.assert_not_awaited()
        values = interaction.edit_original_response.await_args.kwargs
        self.assertIn("Ветка в архиве", values["content"])
        self.assertIsInstance(values["view"], ArchivedDealView)
        self.assertFalse(values["view"].restore_button.disabled)
        self.assertIn("Janalite", values["content"])
        link = next(item for item in values["view"].children if item.label == "Открыть ветку")
        self.assertEqual(link.url, "https://discord.com/channels/123/888")

    async def test_restore_button_uses_actual_actor_private_update_and_confirms_after_success(self):
        deal = {"id": "d", "owner_id": "1234", "thread_id": "888"}
        core = SimpleNamespace(restore_thread=AsyncMock(return_value=deal))
        bot = SimpleNamespace(service=core, interaction_allowed=Mock(return_value=True), settings=Settings(guild_id=123))
        view = ArchivedDealView(bot, deal)
        response = SimpleNamespace(defer=AsyncMock(), is_done=Mock(return_value=True), send_message=AsyncMock())
        interaction = SimpleNamespace(user=SimpleNamespace(id=1234), response=response,
                                      edit_original_response=AsyncMock())
        self.assertTrue(await view.interaction_check(interaction))
        await view.restore_button.callback(interaction)
        response.defer.assert_awaited_once_with()
        core.restore_thread.assert_awaited_once_with("1234", "d")
        values = interaction.edit_original_response.await_args.kwargs
        self.assertIn("История сохранена", values["content"])
        self.assertTrue(values["view"].restore_button.disabled)
        core.restore_thread = AsyncMock(side_effect=PermissionError("Ветка заблокирована"))
        await view.restore_button.callback(interaction)
        self.assertEqual(interaction.edit_original_response.await_args.kwargs["content"], "Ветка заблокирована")
        response.is_done.return_value = False
        interaction.user.id = 9999
        self.assertFalse(await view.interaction_check(interaction))
        response.send_message.assert_awaited_once()

    async def test_player_onboarding_is_private_and_automatic_scan_has_no_panel_button(self):
        bot = self.make_bot()
        store = bot.store
        bot.interaction_allowed = Mock(return_value=True)
        bot.service = SimpleNamespace(scan=AsyncMock(), last_error=None)
        response = SimpleNamespace(send_message=AsyncMock(), send_modal=AsyncMock(),
                                   is_done=lambda: False)
        interaction = SimpleNamespace(user=SimpleNamespace(id=1234), response=response, message=None, extras={})
        await bot.begin_connect(interaction)
        call = response.send_message.await_args
        self.assertTrue(call.kwargs["ephemeral"])
        self.assertIn("Secret Key", call.kwargs["content"])
        guide = call.kwargs["view"]
        self.assertIsInstance(guide, ConnectGuideView)
        self.assertEqual([b.url for b in guide.children if b.url],
                         ["https://uexcorp.space/account/", "https://uexcorp.space/api/apps"])
        self.assertTrue(await guide.interaction_check(interaction))
        key_button = next(b for b in guide.children if b.label == "3. Ввести ключи")
        await key_button.callback(interaction)
        response.send_modal.assert_awaited_once()
        modal = response.send_modal.await_args.args[0]
        self.assertEqual(len(modal.children), 2)
        self.assertTrue(modal.secret.required)
        self.assertTrue(modal.app_token.required)
        self.assertIsNone(modal.secret.default)
        self.assertIsNone(modal.app_token.default)
        stranger = SimpleNamespace(user=SimpleNamespace(id=9999), response=response)
        self.assertFalse(await guide.interaction_check(stranger))
        self.assertIsNone(store.get("account", "1234"))
        self.assertEqual([b.custom_id for b in PanelView(bot).children],
                         ["scdt:connect", "scdt:disconnect", "scdt:deals", "scdt:search", "scdt:listings"])
        bot.start_account_scan("1234")
        bot.start_account_scan("1234")
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        bot.service.scan.assert_awaited_once_with("1234")

    async def test_deal_menu_opens_private_thread_for_existing_and_waiting_conversation(self):
        """Выбор сделки даёт личный переход в ветку даже до нового сообщения продавца."""
        for thread_id in (None, "888"):
            with self.subTest(thread_id=thread_id):
                deal = {"id": "d", "title": "Janalite", "peer": "Seller", "own_closed": False,
                        "trade_type": "WTB", "thread_id": thread_id}
                core = SimpleNamespace(open_thread=AsyncMock(return_value={**deal, "thread_id": "888"}))
                view = DealsView(SimpleNamespace(service=core), "1234", [deal])
                view.selection = SimpleNamespace(values=["d"])
                interaction = SimpleNamespace(response=SimpleNamespace(defer=AsyncMock(), is_done=lambda: True),
                                              followup=SimpleNamespace(send=AsyncMock()))
                await view.open_selected(interaction)
                core.open_thread.assert_awaited_once_with("1234", "d")
                interaction.response.defer.assert_awaited_once_with(ephemeral=True)
                message = interaction.followup.send.await_args
                self.assertTrue(message.kwargs["ephemeral"])
                self.assertIn("<#888>", message.args[0])
                self.assertIn("по-русски", message.args[0])

    async def test_thread_prefix_uses_player_action_and_keeps_remaining_name(self):
        for advertiser, operation, expected in [(True, "buy", "WTB"), (False, "buy", "WTS"),
                                                  (True, "sell", "WTS"), (False, "sell", "WTB"),
                                                  (True, "trade", "WTT"), (False, "trade", "WTT")]:
            trade_type = owner_trade_type(advertiser, operation)
            self.assertEqual(trade_type, expected)
            self.assertEqual(trade_thread_name({"trade_type": trade_type, "title": "Janalite", "peer": "Seller"}),
                             f"{expected} · UEX · Janalite · Seller")
        self.assertIsNone(owner_trade_type(True, None))

    async def test_deleted_private_thread_is_recreated_but_forbidden_is_not(self):
        for failure_type in (discord.NotFound, discord.Forbidden):
            bot = self.make_bot()
            store = bot.store
            owner = SimpleNamespace(roles=[SimpleNamespace(id=789)])
            parent = Mock(spec=discord.TextChannel)
            parent.id = 456
            parent.guild = SimpleNamespace(id=123, fetch_member=AsyncMock(return_value=owner))
            replacement = Mock(spec=discord.Thread)
            replacement.id = 999
            replacement.add_user = AsyncMock()
            replacement.send = AsyncMock()
            parent.create_thread = AsyncMock(return_value=replacement)
            response = SimpleNamespace(status=404 if failure_type is discord.NotFound else 403,
                                       reason="test")
            error = failure_type(response, "test")
            bot.fetch_channel = AsyncMock(side_effect=[parent, error])
            deal = {"id": "d", "owner_id": "1234", "title": "Janalite", "peer": "Seller",
                    "trade_type": "WTB", "own_closed": False, "thread_id": "888", "card_sent": True}
            store.put("deal", deal)
            if failure_type is discord.NotFound:
                self.assertEqual(await bot.thread(deal), "999")
                self.assertEqual(parent.create_thread.await_args.kwargs["name"], "WTB · UEX · Janalite · Seller")
                self.assertEqual(store.get("deal", "d")["thread_id"], "999")
                replacement.send.assert_awaited_once()
            else:
                with self.assertRaises(discord.Forbidden):
                    await bot.thread(deal)
                parent.create_thread.assert_not_awaited()

    async def test_active_listing_object_inactive_false_cache_and_explicit_refresh(self):
        calls = []
        active = True
        quality = "964"

        def respond(request):
            self.assertNotIn("secret-key", request.headers)
            calls.append(request)
            data = {"id": 123, "quality": quality} if active else False
            return httpx.Response(200, json={"status": "ok", "data": data})

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            market = UexMarketplace(client, "app-secret", "test", interval=0)
            self.assertTrue(await market.listing_active("123"))
            self.assertEqual(market.listing_quality("123"), 964)
            active = False
            self.assertTrue(await market.listing_active("123"))
            self.assertEqual(len(calls), 1)
            self.assertFalse(await market.listing_active("123", refresh=True))
            self.assertIsNone(market.listing_quality("123"))
            self.assertFalse(await market.listing_active("123"))
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[-1].url.params["id"], "123")
            active = True
            for quality in (None, 0, "", False, 1001, "unknown", "964"):
                self.assertTrue(await market.listing_active("123", refresh=True))
                self.assertEqual(market.listing_quality("123"), 964 if quality == "964" else None)

    async def test_existing_thread_card_updates_quality_in_place_without_reposting(self):
        """Карточка остаётся тем же сообщением, убирает пояснения и скрывает отсутствующее качество."""
        bot = self.make_bot()
        owner = SimpleNamespace(roles=[SimpleNamespace(id=789)])
        parent = Mock(spec=discord.TextChannel)
        parent.id = 456
        parent.guild = SimpleNamespace(id=123, fetch_member=AsyncMock(return_value=owner))
        parent.create_thread = AsyncMock()
        thread = Mock(spec=discord.Thread)
        thread.id, thread.parent_id = 888, 456
        thread.archived, thread.locked = False, False
        thread.is_private.return_value = True
        thread.add_user, thread.send, thread.edit = AsyncMock(), AsyncMock(), AsyncMock()
        card = SimpleNamespace(content="Старое подробное пояснение", edit=AsyncMock())
        thread.fetch_message = AsyncMock(return_value=card)
        bot.fetch_channel = AsyncMock(side_effect=lambda channel_id: parent if channel_id == 456 else thread)
        deal = {"id": "d", "owner_id": "1234", "title": "Janalite", "peer": "Seller",
                "trade_type": "WTB", "quality": 964, "own_closed": False, "peer_closed": False,
                "thread_id": "888", "card_sent": True, "card_message_id": "777"}
        thread.name = trade_thread_name(deal)
        self.assertEqual(await bot.thread(deal), "888")
        thread.fetch_message.assert_awaited_once_with(777)
        card.edit.assert_awaited_once()
        content = card.edit.await_args.kwargs["content"]
        self.assertEqual(content, "**WTB · Janalite**\nСобеседник: Seller\nКачество: 964")
        card.content = content
        card.edit.reset_mock()
        await bot.thread(deal)
        card.edit.assert_not_awaited()
        deal["price"] = {"amount": "6500000.00", "currency": "UEC", "unit": "scu"}
        await bot.thread(deal)
        self.assertEqual(card.edit.await_args.kwargs["content"], content + "\nЦена: 6 500 000 UEC / SCU")
        deal.pop("price")
        deal["quality"] = None
        await bot.thread(deal)
        self.assertEqual(card.edit.await_args.kwargs["content"], "**WTB · Janalite**\nСобеседник: Seller")
        card.edit.side_effect = discord.Forbidden(SimpleNamespace(status=403, reason="test"), "test")
        self.assertEqual(await bot.thread(deal), "888")
        thread.send.assert_not_awaited()
        parent.create_thread.assert_not_awaited()
        thread.edit.assert_not_awaited()

    async def test_listing_price_uses_existing_listing_read_and_omits_invalid_values(self):
        """Цена берётся без второго запроса; отсутствие, нечисловые и небезопасно длинные цены не показываются."""
        price = "6500000"
        calls = []

        def respond(request):
            """Возвращает только тестовую карточку с регулируемой ценой."""
            calls.append(request)
            return httpx.Response(200, json={"status": "ok", "data": {"id": 123, "price": price, "currency": "UEC", "unit": "scu"}})

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            market = UexMarketplace(client, "fixture", "test", interval=0)
            await market.listing_active("123")
            self.assertEqual(market.listing_price("123"), {"amount": "6500000", "currency": "UEC", "unit": "scu"})
            self.assertEqual(len(calls), 1)
            for price in (None, "", "unknown", -1, "NaN", "Infinity", "1e999999", "1e-999999"):
                await market.listing_active("123", refresh=True)
                self.assertIsNone(market.listing_price("123"))

    async def test_invalid_listing_response_not_cached_as_hidden(self):
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, json={"status": "ok", "data": {"unexpected": True}})
        )) as client:
            market = UexMarketplace(client, "app-secret", "test", interval=0)
            with self.assertRaises(MarketError):
                await market.listing_active("123")

    async def test_trade_abbreviations_are_expanded_before_translation(self):
        for abbreviation, meaning in (("WTB", "buy"), ("WTS", "sell"), ("WTT", "exchange")):
            def respond(request):
                text = json.loads(request.content)["q"][0]
                self.assertIn("I want to " + meaning, text)
                self.assertNotIn(abbreviation, text)
                return httpx.Response(200, json={"translatedText": [text]})

            async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
                result = await Translator(client, "libretranslate", "http://translator").translate(
                    f"{abbreviation.lower()}: 2 Karna Rifle for 50000 aUEC", "en", "ru", ("Karna Rifle",))
                self.assertIn("2 Karna Rifle", result)
                self.assertIn("50000 aUEC", result)

    async def test_abbreviations_in_nicknames_and_protected_names_are_kept(self):
        self.assertEqual(expand_trade_terms("WTBman WTS_Clan myWTT", "en"), "WTBman WTS_Clan myWTT")
        self.assertEqual(expand_trade_terms("WTB: 2 штуки", "ru"), "хочу купить 2 штуки")
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, json={"translatedText": json.loads(request.content)["q"]})
        )) as client:
            result = await Translator(client, "libretranslate", "http://translator").translate(
                "Hello WTB, WTS 2 Karna Rifle", "en", "ru", ("WTB", "Karna Rifle"))
            self.assertIn("Hello WTB", result)
            self.assertIn("I want to sell 2 Karna Rifle", result)

    async def test_site_message_renderer_uses_prepared_thread_and_distinguishes_owner_and_peer(self):
        """Отправляет в подготовленную сервисом ветку без повторного открытия; сохраняет авторство."""
        thread = SimpleNamespace(send=AsyncMock(return_value=SimpleNamespace(id=999)))
        bot = SimpleNamespace(thread=AsyncMock(return_value="888"),
                              fetch_channel=AsyncMock(return_value=thread))
        for sender, heading in (("DemoTrader", "Вы · сообщение с UEX"),
                                ("Seller", "Входящее · перевод на русский")):
            with self.subTest(sender=sender):
                message = {"id": "message", "sender": sender, "translated": "Текст"}
                result = await TraderBot.incoming(bot, {"account": "DemoTrader", "thread_id": "888"}, message)
                self.assertEqual(result, "999")
                self.assertEqual(thread.send.await_args.args[0], f"**{heading}**\nТекст")
                self.assertEqual(thread.send.await_args.kwargs["view"].children[0].label, "Оригинал")
                bot.fetch_channel.assert_awaited_with(888)
                bot.thread.assert_not_awaited()

    async def test_real_uex_empty_history_http400_is_empty_result(self):
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(400, json={"status": "no_messages_found", "data": []})
        )) as client:
            market = UexMarketplace(client, "app-secret", "test", interval=0)
            self.assertEqual(await market.messages({}, "user-secret", "123"), [])
            with self.assertRaises(MarketError):
                await market.profile("user-secret")

    async def test_uex_headers_and_test_send_contract(self):
        captured = []

        def respond(request):
            captured.append(request)
            self.assertEqual(request.headers["secret-key"], "user-secret")
            self.assertEqual(request.headers["Authorization"], "Bearer app-secret")
            if request.method == "POST":
                self.assertEqual(json.loads(request.content),
                                 {"id_negotiation": 123, "message": "Hello", "is_production": 0})
                data = {"id_message": 456}
            elif request.url.path.endswith("/user/"):
                data = {"username": "Trader", "email": "discard@example.invalid"}
            else:
                data = []
            return httpx.Response(200, json={"status": "ok", "data": data})

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            market = UexMarketplace(client, "app-secret", "test", interval=0)
            self.assertEqual(await market.profile("user-secret"), "Trader")
            self.assertEqual(await market.messages({}, "user-secret", "123"), [])
            self.assertEqual(captured[-1].url.params["id_negotiation"], "123")
            self.assertEqual(await market.send({}, "user-secret", "123", "Hello"), "456")

    async def test_post_timeout_server_error_and_bad_ack_are_not_retried(self):
        for failure in ("timeout", "server", "malformed", "missing_id"):
            calls = []

            def respond(request):
                calls.append(request)
                if failure == "timeout":
                    raise httpx.ReadTimeout("test", request=request)
                if failure == "server":
                    return httpx.Response(503)
                if failure == "malformed":
                    return httpx.Response(200, text="invalid")
                return httpx.Response(200, json={"status": "ok", "data": {}})

            async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
                market = UexMarketplace(client, "app-secret", "test", interval=0)
                with self.assertRaises(MarketError) as raised:
                    await market.send({}, "user-secret", "123", "Hello")
                self.assertTrue(raised.exception.uncertain)
                self.assertEqual(len(calls), 1)

    async def test_translation_preserves_context_names_prices_and_units(self):
        """Имена, суммы, единицы, время и пунктуация сохраняются в полном переводе фразы."""
        def respond(request):
            """Проверяет направление и возвращает текст запроса с тестовым префиксом."""
            body = json.loads(request.content)
            self.assertEqual((body["source"], body["target"], len(body["q"])), ("en", "ru", 1))
            return httpx.Response(200, json={"translatedText": ["Перевод: " + body["q"][0]]})

        cases = (("SpaceBuyer, karna rifle costs 25,000 aUEC for 2 SCU at 19:30.", ("Karna Rifle", "SpaceBuyer")),
                 ("Price 120000 aUEC. Can we meet at 19:30?", ()))
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            translator = Translator(client, "libretranslate", "http://translator")
            for text, protected in cases:
                with self.subTest(text=text):
                    self.assertEqual(await translator.translate(text, "en", "ru", protected), "Перевод: " + text)

    async def test_numeric_format_restored_but_changed_amount_is_rejected(self):
        for value, valid in (("25,000", True), ("25001", False), ("250000", False)):
            output = f"Price {value} ZXQ0QXZ. Meet at 19:30."
            async with httpx.AsyncClient(transport=httpx.MockTransport(
                lambda request: httpx.Response(200, json={"translatedText": [output]})
            )) as client:
                translator = Translator(client, "libretranslate", "http://translator")
                if valid:
                    result = await translator.translate("Цена 25000 aUEC. Встреча в 19:30.", "ru", "en")
                    self.assertEqual(result, "Price 25000 aUEC. Meet at 19:30.")
                else:
                    with self.assertRaises(TranslationError):
                        await translator.translate("Цена 25000 aUEC. Встреча в 19:30.", "ru", "en")

    async def test_damaged_or_incomplete_translation_rejected(self):
        """Потерянные, повторённые или переставленные маркеры и пустой ответ отклоняются."""
        priced = "Цена 25000 aUEC. Встреча в 19:30."
        cases = (([], "Hello", "en", "ru"),
                 (["Price ZXQ0QXZ"], priced, "ru", "en"),
                 (["Price ZXQ0QXZ ZXQ0QXZ ZXQ1QXZ"], priced, "ru", "en"),
                 (["Price ZXQ1QXZ ZXQ0QXZ"], priced, "ru", "en"))
        for translated, text, source, target in cases:
            with self.subTest(translated=translated):
                async with httpx.AsyncClient(transport=httpx.MockTransport(
                    lambda request: httpx.Response(200, json={"translatedText": translated})
                )) as client:
                    with self.assertRaises(TranslationError):
                        await Translator(client, "libretranslate", "http://translator").translate(text, source, target)

    async def test_discord_commands_and_long_unicode_chunks(self):
        original = "Привет 🛸 " * 700
        pieces = chunks(original)
        self.assertEqual("".join(pieces), original)
        self.assertTrue(all(len(piece.encode("utf-16-le")) // 2 <= 2000 for piece in pieces))
        bot = self.make_bot()
        store = bot.store
        bot.tree.sync = AsyncMock(return_value=[])
        store.put("deal", {"id": "persistent-deal", "owner_id": "1234", "thread_id": "888"})
        await bot.setup_hook()
        import discord
        self.assertEqual({c.name for c in bot.tree.get_commands(guild=discord.Object(id=123))},
                         {"подключить", "сделки", "отключить", "панель", "меню", "объявления", "поиск", "статус", "подписка"})
        self.assertTrue(any(item.custom_id == "scdt:archive:persistent-deal"
                            for view in bot.persistent_views for item in view.children))


class HttpTests(unittest.IsolatedAsyncioTestCase):
    """Проводит оба направления обмена через реальный HTTP-обработчик приложения."""

    async def test_background_quota_failure_has_readable_health_and_log(self):
        """Квота фоновой сверки отличается от общей ошибки, а ключи не попадают в журнал."""
        with tempfile.TemporaryDirectory() as temp:
            app = create_app(Settings(data_dir=Path(temp)))
            async with app.router.lifespan_context(app):
                app.state.service.scan = AsyncMock(side_effect=MarketError("requests_limit_reached"))
                with self.assertLogs("trader.app", level="WARNING") as captured:
                    await asyncio.sleep(0)
                self.assertTrue(any("квота приложения" in line for line in captured.output))
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                    health = (await client.get("/health")).json()
                self.assertEqual(health["last_error"], "UEX: requests_limit_reached")

    async def test_demo_http_flow_idempotence_owner_isolation_and_archive(self):
        def translate(request):
            body = json.loads(request.content)
            return httpx.Response(200, json={"translatedText": ["Перевод: " + item for item in body["q"]]})

        with tempfile.TemporaryDirectory() as temp:
            app = create_app(Settings(data_dir=Path(temp)), http_transport=httpx.MockTransport(translate))
            async with app.router.lifespan_context(app):
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
                    self.assertEqual((await client.get("/")).status_code, 200)
                    deal = (await client.post("/demo/deals", json={"direction": "buy"})).json()
                    base = f"/demo/deals/{deal['id']}"
                    incoming = {"text": "Still available for 25000 aUEC?", "request_id": "once"}
                    for _ in range(2):
                        self.assertEqual((await client.post(base + "/incoming", json=incoming)).status_code, 200)
                        reply = await client.post(base + "/reply", json={"text": "Готов купить", "request_id": "once"})
                        self.assertEqual(reply.json()["status"], "delivered")
                    own = (await client.get("/demo/state")).json()
                    self.assertEqual(len([m for m in own["messages"] if m["status"] == "delivered"]), 2)
                    other = (await client.get("/demo/state?owner=demo-2")).json()
                    self.assertEqual(other, {"deals": [], "messages": []})
                    self.assertEqual((await client.post(base + "/reply", json={"owner": "demo-2", "text": "Чужое"})).status_code, 403)
                    self.assertEqual((await client.post(base + "/close")).status_code, 200)
                    self.assertEqual((await client.post(base + "/reply", json={"text": "Закрыто"})).status_code, 400)
                    self.assertTrue((await client.get("/demo/state")).json()["deals"][0]["archived"])

    async def test_demo_actions_forbidden_in_live(self):
        app = create_app(Settings(mode="live"))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            self.assertEqual((await client.get("/demo/state")).status_code, 403)
            self.assertEqual((await client.post("/demo/deals", json={})).status_code, 403)


if __name__ == "__main__":
    unittest.main()
