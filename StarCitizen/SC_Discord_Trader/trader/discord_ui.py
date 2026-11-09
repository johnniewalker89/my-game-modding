"""Срок жизни личных окон Discord без оставшихся нерабочих кнопок."""

import asyncio
import logging
import uuid
from datetime import datetime
from typing import Any
from weakref import WeakValueDictionary

import discord

from trader.discord_health import DiscordBackoff

LOGGER = logging.getLogger(__name__)


class EphemeralView(discord.ui.View):
    """Убирает компоненты личного окна по таймауту, сохраняя текст сообщения."""

    _active: WeakValueDictionary[int, "EphemeralView"] = WeakValueDictionary()

    def __init__(self, *, timeout: float | None = 600):
        """Задаёт простой в секундах; None сохраняет постоянную общую панель."""
        super().__init__(timeout=timeout)
        self._idle_timeout = timeout if timeout is not None else 600
        self._private = False
        self._interaction: discord.Interaction | None = None
        self._message_id: int | None = None
        self._edit_lock = asyncio.Lock()

    def prepare_private(self, interaction: discord.Interaction) -> None:
        """Привязывает очистку к свежему interaction и ограничивает её сроком токена."""
        if not self._private:
            for item in self.children:
                if getattr(item, "custom_id", None) is not None:
                    item.custom_id = f"scdt:private:{uuid.uuid4().hex}"
            self._private = True
        self._interaction = interaction
        timeout = self._idle_timeout
        expires_at = getattr(interaction, "expires_at", None)
        if isinstance(expires_at, datetime):
            remaining = (expires_at - discord.utils.utcnow()).total_seconds()
            timeout = min(timeout, max(0.01, remaining - 30))
        self.timeout = timeout

    def bind_message(self, message_id: int, lock: asyncio.Lock) -> None:
        """Передаёт владение окном новому экрану после успешного ответа Discord."""
        previous = self._active.get(message_id)
        self._message_id, self._edit_lock = message_id, lock
        self._active[message_id] = self
        if previous is not None and previous is not self:
            previous.stop()

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Обновляет токен очистки при нажатии на действующее личное окно."""
        if self._private:
            interaction.extras["scdt_private_handled"] = True
            self.prepare_private(interaction)
        return True

    async def on_error(self, interaction: discord.Interaction, error: Exception, item: discord.ui.Item) -> None:
        """Объясняет паузу без повторной отправки действия; прочие ошибки сохраняет в SDK."""
        if not isinstance(error, DiscordBackoff):
            await super().on_error(interaction, error, item)
            return
        sender = interaction.followup.send if interaction.response.is_done() else interaction.response.send_message
        await sender(str(error), ephemeral=True, allowed_mentions=discord.AllowedMentions.none())

    async def on_timeout(self) -> None:
        """Удаляет только свои текущие компоненты; новый экран не затрагивает."""
        async with self._edit_lock:
            if self._active.get(self._message_id) is not self or self._interaction is None:
                return
            try:
                await self._interaction.edit_original_response(view=None)
            except discord.HTTPException as exc:
                LOGGER.warning("Личное меню не очищено message=%s error_type=%s", self._message_id, type(exc).__name__)
            finally:
                self.stop()

    def stop(self) -> None:
        """Отменяет таймер и снимает только собственную регистрацию окна."""
        if self._active.get(self._message_id) is self:
            del self._active[self._message_id]
        self._interaction = None
        super().stop()


async def render(interaction: discord.Interaction, *, content: str = "", view: discord.ui.View,
                 embed: discord.Embed | None = None, embeds: list[discord.Embed] | None = None, attachments: list | None = None,
                 replace: bool = True) -> None:
    """Обновляет личное окно с одной или несколькими карточками; replace=False открывает новое."""
    if embed is not None and embeds is not None:
        raise ValueError("Передай одну карточку или список карточек.")
    source = getattr(interaction, "message", None)
    source_private = getattr(getattr(source, "flags", None), "ephemeral", False)
    editing = interaction.response.is_done() or (replace and source_private)
    source_id = getattr(source, "id", None) if editing and source_private else None
    previous = EphemeralView._active.get(source_id) if isinstance(source_id, int) else None
    lock = previous._edit_lock if previous is not None else (
        view._edit_lock if isinstance(view, EphemeralView) else asyncio.Lock())
    if isinstance(view, EphemeralView):
        view.prepare_private(interaction)
    values: dict[str, Any] = {"content": content, "view": view,
                              "attachments": attachments or [], "allowed_mentions": discord.AllowedMentions.none()}
    values.update({"embeds": embeds} if embeds is not None else {"embed": embed})
    async with lock:
        if interaction.response.is_done():
            result = await interaction.edit_original_response(**values)
        elif replace and source_private:
            result = await interaction.response.edit_message(**values)
        else:
            files = values.pop("attachments")
            result = await interaction.response.send_message(**values, files=files, ephemeral=True)
        message = getattr(result, "resource", result)
        message_id = getattr(message, "id", source_id)
        if isinstance(view, EphemeralView) and isinstance(message_id, int):
            view.bind_message(message_id, lock)


async def close_private_views(bot: Any) -> None:
    """Убирает личные кнопки указанного бота перед его штатным завершением."""
    views = [view for view in EphemeralView._active.values() if getattr(view, "bot", None) is bot]
    await asyncio.gather(*(view.on_timeout() for view in views))
