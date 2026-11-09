"""Регрессии срока жизни личных окон и гонок при переключении экранов."""

import asyncio
import unittest
from datetime import timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import discord

from trader.config import Settings
from trader.discord_bot import DisconnectView, PanelView, TraderBot
from trader.discord_health import DiscordBackoff
from trader.discord_ui import EphemeralView, close_private_views, render
from trader.listing_ui import DraftView, ListingsHome, show_draft


class EphemeralWindowTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет очистку через настоящий таймер discord.py без внешних запросов."""

    async def asyncSetUp(self):
        """Создаёт локальный ViewStore и записи видимых изменений сообщения."""
        self.client = discord.Client(intents=discord.Intents.none())
        self.views = []
        self.visible = {}
        self.cleared = asyncio.Event()

    async def test_backoff_is_explained_privately_for_buttons_and_commands(self):
        """Временный отказ не выдаётся за снятую роль; кнопка и slash дают понятный срок."""
        error = DiscordBackoff(61)
        interaction = SimpleNamespace(response=SimpleNamespace(is_done=lambda: False, send_message=AsyncMock()),
                                      followup=SimpleNamespace(send=AsyncMock()))
        view = EphemeralView()
        await view.on_error(interaction, error, Mock())
        view.stop()
        self.assertIn("2 мин.", interaction.response.send_message.await_args.args[0])
        self.assertTrue(interaction.response.send_message.await_args.kwargs["ephemeral"])
        interaction.response.is_done = lambda: True
        async with TraderBot(Settings(), Mock()) as bot:
            wrapped = discord.app_commands.CommandInvokeError(Mock(), error)
            await bot.tree.on_error(interaction, wrapped)
        self.assertIn("Discord временно", interaction.followup.send.await_args.args[0])
        self.assertTrue(interaction.followup.send.await_args.kwargs["ephemeral"])

    async def asyncTearDown(self):
        """Снимает таймеры созданных окон и закрывает локальный SDK-клиент."""
        for view in self.views:
            view.stop()
        await self.client.close()

    def view(self, *, timeout=600, bot=None):
        """Создаёт личное окно с действием и заданным простоем в секундах."""
        view = EphemeralView(timeout=timeout)
        view.bot = bot
        view.add_item(discord.ui.Button(label="Действие"))
        self.views.append(view)
        return view

    def interaction(self, message_id=10, *, source=False, deferred=False):
        """Подменяет транспорт Discord, сохраняя настоящий ViewStore и его таймеры."""
        async def response(**values):
            """Регистрирует успешно отправленное окно, как это делает SDK после HTTP."""
            self.visible[message_id] = values["view"]
            self.client._connection.store_view(values["view"], message_id)
            return SimpleNamespace(resource=SimpleNamespace(id=message_id))

        async def edit(**values):
            """Запоминает редактирование и сигнализирует об удалении компонентов."""
            self.visible[message_id] = values["view"]
            if values["view"] is None:
                self.cleared.set()
            else:
                self.client._connection.store_view(values["view"], message_id)
            return SimpleNamespace(id=message_id)

        return SimpleNamespace(
            extras={},
            message=SimpleNamespace(id=message_id, flags=SimpleNamespace(ephemeral=True)) if source else None,
            response=SimpleNamespace(is_done=Mock(return_value=deferred),
                                     send_message=AsyncMock(side_effect=response), edit_message=AsyncMock(side_effect=response)),
            edit_original_response=AsyncMock(side_effect=edit),
            expires_at=discord.utils.utcnow() + timedelta(minutes=15),
        )

    async def test_sdk_timeout_removes_buttons_and_preserves_message_content(self):
        """Настоящий таймер SDK сам удаляет компоненты, не перезаписывая текст."""
        interaction = self.interaction()
        view = self.view(timeout=0.02)
        await render(interaction, content="Объявление создано", view=view)
        await asyncio.wait_for(self.cleared.wait(), timeout=1)
        interaction.edit_original_response.assert_awaited_once_with(view=None)
        self.assertIsNone(self.visible[10])
        self.assertNotIn(10, EphemeralView._active)

    async def test_replaced_view_cannot_remove_new_screen(self):
        """Таймер старого экрана отменяется и не удаляет новую панель."""
        first, second = self.interaction(), self.interaction(source=True)
        old, new = self.view(), self.view()
        await render(first, view=old)
        await render(second, view=new)
        self.assertTrue(old.is_finished())
        await old.on_timeout()
        first.edit_original_response.assert_not_awaited()
        self.assertIs(self.visible[10], new)
        self.assertIs(EphemeralView._active[10], new)
        self.assertTrue(set(item.custom_id for item in old.children).isdisjoint(
            item.custom_id for item in new.children))
        clicked = asyncio.Event()
        new.children[0].callback = AsyncMock(side_effect=lambda interaction: clicked.set())
        second.data = {"custom_id": new.children[0].custom_id}
        self.client._connection._view_store.dispatch_view(2, new.children[0].custom_id, second)
        await asyncio.wait_for(clicked.wait(), 1)
        new.children[0].callback.assert_awaited_once_with(second)

    async def test_stale_component_gets_private_notice_without_replaying_or_double_acknowledgement(self):
        """SDK молча теряет старый custom_id; бот поясняет смену экрана и не исполняет действие повторно."""
        async with TraderBot(Settings(), Mock()) as bot:
            bot.interaction_allowed = Mock(return_value=True)
            old, new = self.view(bot=bot), self.view(bot=bot)
            old.children[0].callback = AsyncMock()
            await render(self.interaction(), view=old)
            await render(self.interaction(source=True), view=new)
            click = self.interaction(source=True)
            click.type = discord.InteractionType.component
            click.data = {"custom_id": old.children[0].custom_id}
            click.response.send_message = AsyncMock()
            self.client._connection._view_store.dispatch_view(2, click.data["custom_id"], click)
            await asyncio.sleep(0)
            old.children[0].callback.assert_not_awaited()
            click.response.send_message.assert_not_awaited()
            with self.assertLogs("trader.discord_bot", level="WARNING"):
                await bot.on_interaction(click)
            click.response.send_message.assert_awaited_once()
            self.assertTrue(click.response.send_message.await_args.kwargs["ephemeral"])
            self.assertIn("обновилось", click.response.send_message.await_args.args[0])
            click.response.send_message.reset_mock()
            click.data["custom_id"] = new.children[0].custom_id
            await bot.on_interaction(click)
            click.response.send_message.assert_not_awaited()
            click.data["custom_id"] = old.children[0].custom_id
            click.extras["scdt_private_handled"] = True
            await bot.on_interaction(click)
            click.response.send_message.assert_not_awaited()
            click.extras.clear()
            bot.interaction_allowed.return_value = False
            await bot.on_interaction(click)
            click.response.send_message.assert_not_awaited()
            bot.interaction_allowed.return_value = True
            new.stop()
            with self.assertLogs("trader.discord_bot", level="WARNING"):
                await bot.on_interaction(click)
            self.assertIn("/меню", click.response.send_message.await_args.args[0])

    async def test_draft_refresh_keeps_visible_buttons_dispatchable(self):
        """Условия, фото и предпросмотр принимают первое нажатие по кнопкам до обновления черновика."""
        draft = {"id": "draft-fixture", "owner_id": "123", "revision": 0,
                 "item": {"id": 1, "id_category": 3, "name": "TAU Plus LL 4x Telescopic"},
                 "operation": "sell", "unit": "unit",
                 "hours": 0, "quantity": 5, "price": 100, "quality": None, "location": "Area18",
                 "hidden": False, "photo": None, "description_ru": "", "description_en": ""}
        async with TraderBot(Settings(), Mock()) as bot:
            bot.interaction_allowed = Mock(return_value=True)
            bot.listings = SimpleNamespace(draft_snapshot=Mock(), review=AsyncMock(), mode="production")
            view = DraftView(bot, draft)
            self.views.append(view)
            await render(self.interaction(), view=view)
            visible_ids = {item.label: item.custom_id for item in view.children if isinstance(item, discord.ui.Button)}
            for revision, label in enumerate(("Условия", "Фото"), start=1):
                with self.subTest(button=label):
                    current = {**draft, "revision": revision, "hours": 24, "hidden": True}
                    bot.listings.draft_snapshot.return_value = current
                    await show_draft(bot, self.interaction(source=True), current)
                    self.views.append(self.visible[10])
                    click = self.interaction(source=True)
                    click.user = SimpleNamespace(id=123)
                    click.type = discord.InteractionType.component
                    click.data = {"custom_id": visible_ids[label], "component_type": 2}
                    opened = asyncio.Event()
                    click.response.send_modal = AsyncMock(side_effect=lambda modal: opened.set())
                    click.response.send_message = AsyncMock()
                    self.client._connection._view_store.dispatch_view(2, click.data["custom_id"], click)
                    await bot.on_interaction(click)
                    await asyncio.wait_for(opened.wait(), 1)
                    click.response.send_modal.assert_awaited_once()
                    self.assertEqual(click.response.send_modal.await_args.args[0].draft["revision"], revision)
                    click.response.send_message.assert_not_awaited()
                    active = self.visible[10]
                    self.assertTrue(next(item for item in active.children if isinstance(item, discord.ui.Select)).options[1].default)
                    self.assertIn("Сделать обычным", [getattr(item, "label", "") for item in active.children])
            bot.listings.review.return_value = current
            preview_click = self.interaction(source=True, deferred=True)
            preview_click.user = SimpleNamespace(id=123)
            preview_click.type = discord.InteractionType.component
            preview_click.data = {"custom_id": visible_ids["Предпросмотр"], "component_type": 2}
            preview_click.response.defer = AsyncMock()
            preview_shown = asyncio.Event()
            original_edit = preview_click.edit_original_response.side_effect

            async def show_preview(**values):
                """Сигнализирует о показе предпросмотра после регистрации его компонентов SDK."""
                result = await original_edit(**values)
                preview_shown.set()
                return result

            preview_click.edit_original_response.side_effect = show_preview
            self.client._connection._view_store.dispatch_view(2, preview_click.data["custom_id"], preview_click)
            await bot.on_interaction(preview_click)
            await asyncio.wait_for(preview_shown.wait(), 1)
            bot.listings.review.assert_awaited_once_with("123", draft["id"], current["revision"])
            self.views.append(self.visible[10])

    async def test_render_waits_for_cleanup_already_in_flight(self):
        """Если очистка началась первой, новый экран устанавливается после неё."""
        first, second = self.interaction(), self.interaction(source=True)
        old, new = self.view(), self.view()
        await render(first, view=old)
        entered, release = asyncio.Event(), asyncio.Event()
        original_edit = first.edit_original_response.side_effect

        async def slow_edit(**values):
            """Задерживает очистку до разрешения тестом, не меняя её результата."""
            entered.set()
            await release.wait()
            return await original_edit(**values)

        first.edit_original_response.side_effect = slow_edit
        cleanup = asyncio.create_task(old.on_timeout())
        await asyncio.wait_for(entered.wait(), 1)
        update = asyncio.create_task(render(second, view=new))
        await asyncio.sleep(0)
        second.response.edit_message.assert_not_awaited()
        release.set()
        await asyncio.wait_for(asyncio.gather(cleanup, update), 1)
        self.assertIs(self.visible[10], new)

    async def test_cleanup_waits_for_replacement_already_in_flight(self):
        """Если новый экран отправляется первым, старый таймер больше его не трогает."""
        first, second = self.interaction(), self.interaction(source=True)
        old, new = self.view(), self.view()
        await render(first, view=old)
        entered, release = asyncio.Event(), asyncio.Event()
        original_edit = second.response.edit_message.side_effect

        async def slow_edit(**values):
            """Удерживает замену окна, чтобы запустить старый таймер одновременно."""
            entered.set()
            await release.wait()
            return await original_edit(**values)

        second.response.edit_message.side_effect = slow_edit
        update = asyncio.create_task(render(second, view=new))
        await asyncio.wait_for(entered.wait(), 1)
        cleanup = asyncio.create_task(old.on_timeout())
        await asyncio.sleep(0)
        first.edit_original_response.assert_not_awaited()
        release.set()
        await asyncio.wait_for(asyncio.gather(update, cleanup), 1)
        first.edit_original_response.assert_not_awaited()
        self.assertIs(self.visible[10], new)

    async def test_expired_webhook_is_reported_without_leaking_error_body(self):
        """Удалённое или уже недоступное окно не вызывает необработанное исключение."""
        interaction, view = self.interaction(), self.view()
        await render(interaction, view=view)
        interaction.edit_original_response.side_effect = discord.NotFound(
            SimpleNamespace(status=404, reason="Not Found"), {"code": 10015, "message": "private-fixture"})
        with self.assertLogs("trader.discord_ui", level="WARNING") as captured:
            await view.on_timeout()
        self.assertNotIn("private-fixture", " ".join(captured.output))
        self.assertTrue(view.is_finished())
        self.assertNotIn(10, EphemeralView._active)

    async def test_owner_check_refreshes_cleanup_token(self):
        """Разрешённое нажатие продлевает окно и даёт очистке свежий токен."""
        bot = SimpleNamespace(interaction_allowed=Mock(return_value=True))
        view = ListingsHome(bot, "123")
        self.views.append(view)
        first, second = self.interaction(), self.interaction(source=True)
        second.user = SimpleNamespace(id=123)
        await render(first, view=view)
        self.assertTrue(await view.interaction_check(second))
        self.assertTrue(second.extras["scdt_private_handled"])
        await view.on_timeout()
        first.edit_original_response.assert_not_awaited()
        second.edit_original_response.assert_awaited_once_with(view=None)

    async def test_cleanup_respects_token_deadline(self):
        """Очистка назначается раньше окончания токена, даже после долгого запроса."""
        interaction, view = self.interaction(), self.view()
        interaction.expires_at = discord.utils.utcnow() + timedelta(seconds=60)
        await render(interaction, view=view)
        self.assertGreater(view.timeout, 25)
        self.assertLessEqual(view.timeout, 30)

    async def test_shutdown_cleans_only_this_bots_private_views(self):
        """Остановка убирает личные кнопки своего бота, общая панель остаётся постоянной."""
        own_bot, other_bot = object(), object()
        own, other = self.view(bot=own_bot), self.view(bot=other_bot)
        public = PanelView(own_bot)
        self.views.append(public)
        first, second = self.interaction(10), self.interaction(20)
        await render(first, view=own)
        await render(second, view=other)
        await close_private_views(own_bot)
        first.edit_original_response.assert_awaited_once_with(view=None)
        second.edit_original_response.assert_not_awaited()
        self.assertTrue(public.is_persistent())
        self.assertEqual([item.custom_id for item in public.children],
                         ["scdt:connect", "scdt:deals", "scdt:listings", "scdt:search"])
        self.assertIs(EphemeralView._active[20], other)

    async def test_commands_and_panel_use_only_configured_channel_and_its_threads(self):
        """Старое меню другого канала не открывает действия боевого бота."""
        bot = TraderBot(Settings(guild_id=1, channel_id=10, role_id=99), Mock())
        self.addAsyncCleanup(bot.close)
        view = PanelView(bot)
        self.views.append(view)
        member = Mock(spec=discord.Member, roles=[SimpleNamespace(id=99)])
        own_thread = Mock(spec=discord.Thread, parent_id=10)
        other_thread = Mock(spec=discord.Thread, parent_id=20)
        for guild_id, channel_id, channel, accepted in (
            (1, 10, None, True),
            (1, 11, own_thread, True),
            (1, 20, None, False),
            (1, 21, other_thread, False),
            (2, 10, None, False),
            (None, 10, None, False),
        ):
            with self.subTest(guild=guild_id, channel=channel_id):
                interaction = SimpleNamespace(
                    guild_id=guild_id, channel_id=channel_id, channel=channel,
                    user=member, response=SimpleNamespace(
                        is_done=Mock(return_value=False), send_message=AsyncMock(), defer=AsyncMock()),
                    delete_original_response=AsyncMock())
                self.assertEqual(await bot.tree.interaction_check(interaction), accepted)
                self.assertEqual(await view.interaction_check(interaction), accepted)
                self.assertEqual(bot.interaction_allowed(interaction), accepted)
                interaction.response.send_message.assert_not_awaited()
                if accepted:
                    interaction.response.defer.assert_not_awaited()
                    interaction.delete_original_response.assert_not_awaited()
                else:
                    interaction.response.defer.assert_awaited_with(ephemeral=True, thinking=True)
                    interaction.delete_original_response.assert_awaited()

    async def test_personal_disconnect_requires_confirmation_and_cancel_keeps_connection(self):
        """Личная кнопка и команда ведут к подтверждению; только согласие отключает владельца."""
        store = Mock()
        store.all.return_value = []
        bot = TraderBot(Settings(guild_id=1, channel_id=10, role_id=99), store)
        self.addAsyncCleanup(bot.close)
        bot.interaction_allowed = Mock(return_value=True)
        bot.allowed = AsyncMock(return_value=True)
        bot.service = SimpleNamespace(disconnect=Mock())
        bot.tree.sync = AsyncMock(return_value=[])
        await bot.setup_hook()

        interaction = self.interaction()
        interaction.user = SimpleNamespace(id=123)
        await bot.show_menu(interaction)
        panel = self.visible[10]
        self.views.append(panel)
        self.assertNotIn("Отключить UEX", [item.label for item in PanelView(bot).children])
        disconnect = next(item for item in panel.children if item.label == "Отключить UEX")

        interaction = self.interaction(source=True)
        interaction.user = SimpleNamespace(id=123)
        await disconnect.callback(interaction)
        confirmation = self.visible[10]
        self.views.append(confirmation)
        self.assertIsInstance(confirmation, DisconnectView)
        bot.service.disconnect.assert_not_called()
        await confirmation.cancel.callback(interaction)
        bot.service.disconnect.assert_not_called()
        self.views.append(self.visible[10])

        command = bot.tree.get_command("отключить", guild=discord.Object(id=1))
        await command.callback(interaction)
        confirmation = self.visible[10]
        self.views.append(confirmation)
        self.assertIsInstance(confirmation, DisconnectView)
        interaction = self.interaction(source=True, deferred=True)
        interaction.user = SimpleNamespace(id=123)
        interaction.response.defer = AsyncMock()
        self.assertTrue(await confirmation.interaction_check(interaction))
        await confirmation.confirm.callback(interaction)
        bot.allowed.assert_awaited_once_with("123")
        bot.service.disconnect.assert_called_once_with("123")
        self.assertIn("история сохранена", interaction.edit_original_response.await_args.kwargs["content"])
        self.views.append(self.visible[10])

    async def test_disconnect_denies_another_owner_and_revoked_role(self):
        """Чужое окно и снятая роль не позволяют удалять ключи, в том числе после подтверждения."""
        bot = SimpleNamespace(interaction_allowed=Mock(return_value=True),
            check_channel=AsyncMock(return_value=True), allowed=AsyncMock(return_value=False),
            begin_disconnect=AsyncMock(), service=SimpleNamespace(disconnect=Mock()))
        panel, confirmation = PanelView(bot, "123"), DisconnectView(bot, "123")
        self.views.extend((panel, confirmation))
        interaction = self.interaction(source=True)
        interaction.response.send_message = AsyncMock()
        interaction.user = SimpleNamespace(id=456)
        self.assertFalse(await panel.interaction_check(interaction))
        self.assertFalse(await confirmation.interaction_check(interaction))
        interaction.user.id = 123
        bot.interaction_allowed.return_value = False
        self.assertFalse(await confirmation.interaction_check(interaction))
        bot.interaction_allowed.return_value = True
        self.assertTrue(await confirmation.interaction_check(interaction))
        interaction.response.defer = AsyncMock()
        interaction.followup = SimpleNamespace(send=AsyncMock())
        interaction.response.is_done.return_value = True
        await confirmation.confirm.callback(interaction)
        bot.service.disconnect.assert_not_called()
        interaction.followup.send.assert_awaited_once()
