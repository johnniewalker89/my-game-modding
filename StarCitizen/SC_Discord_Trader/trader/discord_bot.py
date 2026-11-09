"""Discord: панель по роли, личные ветки и обычные ответы по-русски."""

import asyncio
import io
import logging
import time
from datetime import date
from decimal import Decimal
from typing import Any, Callable
from urllib.parse import quote

import aiohttp
import discord
from discord import app_commands

from trader.config import Settings
from trader.diagnostics import status_text
from trader.discord_health import DiscordBackoff, DiscordHttpHealth, retry_seconds
from trader.discord_ui import EphemeralView, close_private_views, render
from trader.listings import ListingService
from trader.listing_ui import ListingsHome, report_error
from trader.search_ui import FindModal
from trader.service import TraderService
from trader.store import Store

LOGGER = logging.getLogger(__name__)
UEX_MANAGE = "https://uexcorp.space/marketplace/manage/"
UEX_ACCOUNT = "https://uexcorp.space/account/"
UEX_APPS = "https://uexcorp.space/api/apps"
ACCESS_CACHE_SECONDS = 300


def panel_text(send_mode: str) -> str:
    """Даёт короткие подсказки к кнопкам без повтора имени бота."""
    text = ("**Подключить UEX** — подключить свой аккаунт.\n"
            "**Отключить UEX** — отключить свой аккаунт.\n"
            "**Мои сделки** — открыть свои переписки.\n"
            "**Найти товар** — посмотреть продажи на UEX.\n"
            "**Объявления** — создать или удалить своё объявление.\n\n"
            "Чтобы вернуть панель, введи **/меню**.")
    if send_mode == "test":
        text += "\n\nОтветы собеседникам на UEX пока отключены."
    return text


def trade_thread_name(deal: dict[str, Any]) -> str:
    """Именует ветку по действию владельца, товару и собеседнику."""
    kind = deal.get("trade_type")
    prefix = f"{kind} · " if kind in {"WTB", "WTS", "WTT", "WTR"} else ""
    return f"{prefix}UEX · {deal['title']} · {deal['peer']}"[:100]


def deal_card_text(deal: dict[str, Any]) -> str:
    """Показывает товар и собеседника; качество и цену за единицу добавляет только при наличии."""
    title = ((deal.get("trade_type") + " · ") if deal.get("trade_type") else "") + deal["title"]
    text = f"**{discord.utils.escape_markdown(title)}**\nСобеседник: {discord.utils.escape_markdown(deal['peer'])}"
    if deal.get("quality"):
        text += f"\nКачество: {deal['quality']}"
    if quote := deal.get("price"):
        amount = format(Decimal(quote["amount"]), ",f")
        if "." in amount:
            amount = amount.rstrip("0").rstrip(".")
        unit = {"scu": "SCU", "cscu": "cSCU", "unit": "шт."}.get(quote["unit"], quote["unit"])
        text += f"\nЦена: {amount.replace(',', ' ')} {quote['currency']} / {unit}"
    return text


def deal_links(deal: dict[str, Any]) -> discord.ui.View:
    """Открывает конкретную переписку и объявление на сайте, не меняя их статусы."""
    view = discord.ui.View(timeout=None)
    negotiation_hash = deal.get("negotiation_hash")
    url = (f"https://uexcorp.space/marketplace/negotiate/hash/{quote(str(negotiation_hash), safe='')}/"
           if negotiation_hash else UEX_MANAGE)
    view.add_item(discord.ui.Button(label="Сделка на UEX", url=url))
    if deal.get("listing_slug"):
        view.add_item(discord.ui.Button(label="Объявление на UEX", url=(
            f"https://uexcorp.space/marketplace/item/info/{quote(deal['listing_slug'], safe='')}/")))
    return view


def chunks(text: str, limit: int = 2000) -> list[str]:
    """Разбивает текст на сообщения, считая эмодзи как две UTF-16 единицы."""
    result: list[str] = []
    current: list[str] = []
    length = 0
    for character in text:
        width = len(character.encode("utf-16-le")) // 2
        if length + width > limit:
            result.append("".join(current))
            current, length = [], 0
        current.append(character)
        length += width
    if current:
        result.append("".join(current))
    return result


async def notice(interaction: discord.Interaction, text: str) -> None:
    """Отвечает только нажавшему участнику, учитывая уже отложенный ответ."""
    if interaction.response.is_done():
        await interaction.followup.send(text, ephemeral=True, allowed_mentions=discord.AllowedMentions.none())
    else:
        await interaction.response.send_message(text, ephemeral=True,
                                                allowed_mentions=discord.AllowedMentions.none())


class ConnectModal(discord.ui.Modal, title="Подключить свой UEX"):
    """Принимает два обязательных ключа в личном окне владельца."""

    secret = discord.ui.TextInput(label="Личный Secret Key UEX", min_length=20, max_length=300)
    app_token = discord.ui.TextInput(label="Токен своего API-приложения UEX", min_length=20, max_length=300)

    def __init__(self, bot: "TraderBot", owner_id: str):
        """Настраивает форму для owner_id, не подставляя сохранённые секреты в Discord."""
        super().__init__()
        self.bot, self.owner_id = bot, owner_id

    async def on_submit(self, interaction: discord.Interaction) -> None:
        """Проверяет роль повторно и подключает только аккаунт нажавшего участника."""
        await interaction.response.defer(ephemeral=True, thinking=True)
        if str(interaction.user.id) != self.owner_id:
            await notice(interaction, "Это не твоя форма подключения.")
            return
        if not await self.bot.check_channel(interaction):
            return
        try:
            username = await self.bot.service.connect(self.owner_id, str(self.secret), str(self.app_token))
        except Exception as exc:
            if isinstance(exc, DiscordBackoff):
                await notice(interaction, str(exc))
                return
            LOGGER.warning("Подключение не удалось owner=%s error_type=%s", interaction.user.id, type(exc).__name__)
            await notice(interaction, "Не удалось подключиться. Проверь Secret Key, токен API-приложения и доступность UEX.")
            return
        self.bot.start_account_scan(str(interaction.user.id))
        await render(interaction,
            content=f"Подключён **{discord.utils.escape_markdown(username)}** через своё API-приложение. Сделки подгрузятся автоматически. Старые сообщения не рассылаются уведомлениями.",
            view=PanelView(self.bot, self.owner_id))


class ConnectGuideView(EphemeralView):
    """Личный мастер получения Secret Key и токена API-приложения в существующем UEX."""

    def __init__(self, bot: "TraderBot", owner_id: str):
        """Даёт owner_id ссылки для получения двух ключей и личную форму ввода."""
        super().__init__(timeout=600)
        self.bot, self.owner_id = bot, owner_id
        self.add_item(discord.ui.Button(label="1. Secret Key профиля", url=UEX_ACCOUNT, row=0))
        self.add_item(discord.ui.Button(label="2. API-приложение UEX", url=UEX_APPS, row=0))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        allowed = str(interaction.user.id) == self.owner_id and self.bot.interaction_allowed(interaction)
        if not allowed:
            await notice(interaction, "Подключать аккаунт можно только из своего личного меню с разрешённой ролью.")
            return False
        return await super().interaction_check(interaction)

    @discord.ui.button(label="3. Ввести ключи", style=discord.ButtonStyle.primary,
                       custom_id="scdt:connect:key", row=1)
    async def enter_key(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Открывает форму двух ключей только для владельца этого мастера."""
        await interaction.response.send_modal(ConnectModal(self.bot, self.owner_id))

    @discord.ui.button(label="В меню", row=2)
    async def menu(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Возвращает личную панель вместо поиска исходного сообщения в истории."""
        await self.bot.show_menu(interaction, replace=True)


class PanelView(EphemeralView):
    """Общая панель и личное меню участника с отключением UEX."""

    def __init__(self, bot: "TraderBot", owner_id: str | None = None):
        """Создаёт общую панель либо личное меню owner_id с отключением UEX."""
        super().__init__(timeout=None)
        self.bot, self.owner_id = bot, owner_id

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Проверяет рабочий канал и владельца личного меню."""
        if not await self.bot.check_channel(interaction):
            return False
        if self.owner_id is not None and str(interaction.user.id) != self.owner_id:
            await notice(interaction, "Это личное меню другого участника.")
            return False
        return await super().interaction_check(interaction)

    @discord.ui.button(label="Подключить UEX", style=discord.ButtonStyle.primary,
                       custom_id="scdt:connect", row=0)
    async def connect_button(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Открывает подключение личного аккаунта после проверки роли."""
        await self.bot.begin_connect(interaction)

    @discord.ui.button(label="Отключить UEX", style=discord.ButtonStyle.secondary,
                       custom_id="scdt:disconnect", row=0)
    async def disconnect_button(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Открывает личное подтверждение, не отключая аккаунт одним нажатием."""
        await self.bot.begin_disconnect(interaction)

    @discord.ui.button(label="Мои сделки", custom_id="scdt:deals", row=1)
    async def deals_button(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Показывает только список сделок нажавшего участника."""
        await self.bot.show_deals(interaction)

    @discord.ui.button(label="Найти товар", custom_id="scdt:search", row=1)
    async def search_button(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Сразу открывает личную форму поиска чужих предложений."""
        await self.bot.begin_search(interaction)

    @discord.ui.button(label="Объявления", custom_id="scdt:listings", row=1)
    async def listings_button(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Открывает личный мастер объявлений после проверки подключения."""
        await self.bot.show_listings(interaction)


class DisconnectView(EphemeralView):
    """Подтверждает отключение только своего UEX, сохраняя историю переписок."""

    def __init__(self, bot: "TraderBot", owner_id: str):
        """Привязывает подтверждение к Discord ID владельца личного меню."""
        super().__init__(timeout=300)
        self.bot, self.owner_id = bot, owner_id

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Проверяет владельца, рабочий канал и роль перед действием."""
        if str(interaction.user.id) != self.owner_id or not self.bot.interaction_allowed(interaction):
            await notice(interaction, "Это чужое личное меню или у тебя нет нужной роли.")
            return False
        return await super().interaction_check(interaction)

    @discord.ui.button(label="Отключить", style=discord.ButtonStyle.danger)
    async def confirm(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """После актуальной проверки роли удаляет оба ключа владельца."""
        await interaction.response.defer()
        if not await self.bot.allowed(self.owner_id):
            await notice(interaction, "Нужна разрешённая роль.")
            return
        self.bot.service.disconnect(self.owner_id)
        await render(interaction, content="UEX отключён. Оба ключа удалены, история сохранена.\n"
                     "Чтобы снова получать сообщения, нажми «Подключить UEX».",
                     view=PanelView(self.bot, self.owner_id))

    @discord.ui.button(label="Отмена")
    async def cancel(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Возвращает личное меню без изменения подключения."""
        await self.bot.show_menu(interaction, replace=True)


class OriginalView(discord.ui.View):
    """Возвращает полный оригинал только владельцу сообщения с нужной ролью."""

    def __init__(self, bot: "TraderBot", message_id: str):
        """Привязывает кнопку к устойчивому локальному id сообщения."""
        super().__init__(timeout=None)
        self.bot, self.message_id = bot, message_id
        button = discord.ui.Button(label="Оригинал", custom_id=f"scdt:original:{message_id}")
        button.callback = self.show_original
        self.add_item(button)

    async def show_original(self, interaction: discord.Interaction) -> None:
        """Показывает оригинал лично владельцу; длинный текст сохраняет целиком в файле."""
        await interaction.response.defer(ephemeral=True)
        record = self.bot.store.get("message", self.message_id)
        owner_id = str(interaction.user.id)
        if not record or record["owner_id"] != owner_id or not await self.bot.allowed(owner_id):
            await notice(interaction, "Это не твоя переписка или нет разрешённой роли.")
            return
        original = record.get("original")
        if original is None:
            try:
                original = await self.bot.service.original(owner_id, self.message_id)
            except (PermissionError, ValueError) as exc:
                await notice(interaction, str(exc))
                return
            except Exception as exc:
                LOGGER.warning("Оригинал UEX не загружен message=%s error_type=%s", self.message_id, type(exc).__name__)
                await notice(interaction, "Срок локального хранения истёк. Сейчас не удалось получить оригинал с UEX.")
                return
        text = "**Оригинал**\n" + discord.utils.escape_markdown(original)
        if len(chunks(text)) == 1:
            await interaction.followup.send(text, ephemeral=True, suppress_embeds=True,
                                            allowed_mentions=discord.AllowedMentions.none())
            return
        attachment = discord.File(io.BytesIO(original.encode("utf-8")), filename="original.txt")
        await interaction.followup.send("Оригинал длиннее лимита сообщения Discord. Полный текст — в файле.",
                                        file=attachment, ephemeral=True)


class DealView(discord.ui.View):
    """Ссылки сделки и постоянная кнопка личного архива без завершения на UEX."""

    def __init__(self, bot: "TraderBot", deal: dict[str, Any]):
        """Привязывает управление к локальному id сделки, а не к правам администратора."""
        super().__init__(timeout=None)
        self.bot, self.deal_id = bot, deal["id"]
        links = deal_links(deal)
        for item in list(links.children):
            links.remove_item(item)
            self.add_item(item)
        button = discord.ui.Button(label="В архив", custom_id=f"scdt:archive:{deal['id']}",
                                   disabled=bool(deal.get("own_closed") or deal.get("peer_closed")))
        button.callback = self.archive_thread
        self.add_item(button)

    async def archive_thread(self, interaction: discord.Interaction) -> None:
        """Архивирует только свою ветку и отвечает лично без нового сообщения в ней."""
        await interaction.response.defer(ephemeral=True, thinking=True)
        if interaction.guild_id != self.bot.settings.guild_id:
            await interaction.edit_original_response(content="Управление доступно только на своём сервере.")
            return
        try:
            await self.bot.service.archive_thread(str(interaction.user.id), self.deal_id,
                                                  str(interaction.channel_id))
        except (PermissionError, ValueError, DiscordBackoff) as exc:
            await interaction.edit_original_response(content=str(exc))
        except Exception as exc:
            LOGGER.warning("Ветка не архивирована deal=%s error_type=%s", self.deal_id, type(exc).__name__)
            await interaction.edit_original_response(content="Не удалось отправить ветку в архив. Попробуй ещё раз.")
        else:
            await interaction.edit_original_response(
                content="Ветка отправлена в архив. История сохранена. Новое входящее на UEX вернёт её автоматически. Сделка на UEX не закрыта.")


class ArchivedDealView(EphemeralView):
    """Предлагает владельцу явно вернуть выбранную архивную ветку."""

    def __init__(self, bot: "TraderBot", deal: dict[str, Any], *, restored: bool = False):
        """Привязывает личную кнопку к устойчивой сделке, сохраняя ссылки на UEX."""
        super().__init__(timeout=300)
        self.bot, self.owner_id, self.deal_id = bot, deal["owner_id"], deal["id"]
        self.restore_button.disabled = restored
        if restored:
            self.restore_button.label = "Ветка активна"
        self.add_item(discord.ui.Button(label="Открыть ветку", row=1,
                      url=f"https://discord.com/channels/{bot.settings.guild_id}/{deal['thread_id']}"))
        links = deal_links(deal)
        for item in list(links.children):
            links.remove_item(item)
            item.row = 1
            self.add_item(item)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Не разрешает восстанавливать чужую ветку или действовать без роли."""
        allowed = str(interaction.user.id) == self.owner_id and self.bot.interaction_allowed(interaction)
        if not allowed:
            await notice(interaction, "Это личное меню другого участника или роль недоступна.")
            return False
        return await super().interaction_check(interaction)

    @discord.ui.button(label="Вернуть из архива", style=discord.ButtonStyle.primary, row=0)
    async def restore_button(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Подтверждает возврат только после успешного изменения существующей ветки."""
        await interaction.response.defer()
        try:
            deal = await self.bot.service.restore_thread(str(interaction.user.id), self.deal_id)
        except (PermissionError, ValueError, DiscordBackoff) as exc:
            await interaction.edit_original_response(content=str(exc))
        except Exception as exc:
            LOGGER.warning("Ветка не возвращена из архива deal=%s error_type=%s", self.deal_id, type(exc).__name__)
            await interaction.edit_original_response(
                content="Не удалось вернуть ветку из архива. Проверь права бота и попробуй ещё раз.")
        else:
            await render(interaction, content="Ветка возвращена из архива. История сохранена.\nНажми «Открыть ветку», чтобы перейти к переписке.",
                         view=ArchivedDealView(self.bot, deal, restored=True))

    @discord.ui.button(label="В меню", row=0)
    async def menu(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Возвращает личную панель на месте архивной карточки."""
        await self.bot.show_menu(interaction, replace=True)


class DealsView(EphemeralView):
    """Личный список с пагинацией по десять сделок."""

    def __init__(self, bot: "TraderBot", owner_id: str,
                 deals: list[dict[str, Any]], page: int = 0):
        """Сохраняет владельца и строит одну страницу списка."""
        super().__init__(timeout=300)
        self.bot, self.owner_id, self.deals, self.page = bot, owner_id, deals, page
        page_deals = deals[page * 10:(page + 1) * 10]
        selection = discord.ui.Select(placeholder="Выбери сделку", options=[
            discord.SelectOption(label=((deal.get("trade_type") + " · ") if deal.get("trade_type") else "")
                                 + deal["title"][:90], value=deal["id"],
                                 description=(deal["peer"] + (" · в архиве" if deal.get("paused") else " · открыта"))[:100])
            for deal in page_deals
        ])
        selection.callback = self.open_selected
        self.selection = selection
        self.add_item(selection)
        if len(deals) > 10:
            previous = discord.ui.Button(label="←", disabled=page == 0)
            following = discord.ui.Button(label="→", disabled=(page + 1) * 10 >= len(deals))
            previous.callback = self.previous
            following.callback = self.following
            self.add_item(previous)
            self.add_item(following)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Не позволяет другому участнику использовать персональное меню."""
        allowed = str(interaction.user.id) == self.owner_id and self.bot.interaction_allowed(interaction)
        if not allowed:
            await notice(interaction, "Это личное меню другого участника или роль недоступна.")
            return False
        return await super().interaction_check(interaction)

    async def open_selected(self, interaction: discord.Interaction) -> None:
        """Открывает выбранную сделку участника, создавая приватную ветку при необходимости."""
        await interaction.response.defer(ephemeral=True)
        try:
            deal = await self.bot.service.open_thread(self.owner_id, self.selection.values[0])
            if deal.get("paused"):
                title = ((deal.get("trade_type") + " · ") if deal.get("trade_type") else "") + deal["title"]
                await render(interaction, content=f"**{discord.utils.escape_markdown(title)}**\nВетка в архиве.\n"
                             "Можно посмотреть историю или вернуть ветку в активные.",
                             view=ArchivedDealView(self.bot, deal))
                return
            await notice(interaction, f"Твоя ветка: <#{deal['thread_id']}>\nОткрой её и напиши сообщение по-русски.")
        except Exception as exc:
            if isinstance(exc, DiscordBackoff):
                await notice(interaction, str(exc))
                return
            LOGGER.warning("Ветка не открыта owner=%s error_type=%s", self.owner_id, type(exc).__name__)
            await notice(interaction, "Не удалось открыть ветку. Обнови «Мои сделки»; проверь актуальность сделки и права бота.")

    async def previous(self, interaction: discord.Interaction) -> None:
        """Переключает меню на предыдущую страницу."""
        await render(interaction, content=interaction.message.content,
                     view=DealsView(self.bot, self.owner_id, self.deals, self.page - 1))

    async def following(self, interaction: discord.Interaction) -> None:
        """Переключает меню на следующую страницу."""
        await render(interaction, content=interaction.message.content,
                     view=DealsView(self.bot, self.owner_id, self.deals, self.page + 1))

    @discord.ui.button(label="В меню", row=2)
    async def menu(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        """Возвращает личную стартовую панель на месте списка сделок."""
        await self.bot.show_menu(interaction, replace=True)


class TraderCommandTree(app_commands.CommandTree):
    """Принимает команды только в рабочем канале и его ветках."""

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Проверяет канал до запуска любой команды interaction."""
        return await self.client.check_channel(interaction)

    async def on_error(self, interaction: discord.Interaction, error: app_commands.AppCommandError) -> None:
        """Объясняет временную паузу Discord; остальные ошибки оставляет штатному обработчику."""
        original = getattr(error, "original", error)
        if isinstance(original, (DiscordBackoff, discord.RateLimited)):
            await notice(interaction, str(DiscordBackoff(original.retry_after)))
            return
        await super().on_error(interaction, error)


class TraderBot(discord.Client):
    """Получает сообщения Discord и реализует приватную доставку сервиса."""

    def __init__(self, settings: Settings, store: Store):
        """Включает содержимое сообщений; историю хранит в SQLite вместо кэша сообщений SDK."""
        intents = discord.Intents.default()
        intents.message_content = True
        self.http_health = DiscordHttpHealth()
        super().__init__(intents=intents, max_messages=None, allowed_mentions=discord.AllowedMentions.none(),
                         http_trace=self.http_health.trace, max_ratelimit_timeout=30)
        self.settings, self.store = settings, store
        self.service: TraderService
        self.listings: ListingService
        self.tree = TraderCommandTree(self)
        self._account_scan_tasks: dict[str, asyncio.Task] = {}
        self._access_cache: dict[str, tuple[float, bool]] = {}
        self._thread_name_failures: dict[int, tuple[str, str, float]] = {}
        self._panel_lock = asyncio.Lock()
        self._panel_ready_attempted = False
        self.status_provider: Callable[[], dict[str, Any]] | None = None
        self._hosting_reminder = None
        if settings.hosting_reminder_user_id:
            owner = str(settings.hosting_reminder_user_id)
            self._hosting_reminder = store.get("hosting_reminder", owner) or {
                "id": owner, "owner_id": owner,
            }

    async def on_interaction(self, interaction: discord.Interaction) -> None:
        """Подтверждает потерявшее обработчик личное нажатие, не повторяя его действие."""
        if interaction.type != discord.InteractionType.component:
            return
        custom_id = (interaction.data or {}).get("custom_id", "")
        if (not custom_id.startswith("scdt:private:") or interaction.response.is_done()
                or interaction.extras.get("scdt_private_handled")):
            return
        message_id = interaction.message.id if interaction.message else None
        view = EphemeralView._active.get(message_id)
        if view and view.is_finished():
            view = None
        if view and any(getattr(child, "custom_id", None) == custom_id for child in view.children):
            return
        if not self.interaction_allowed(interaction) or (view and view.bot is not self):
            return
        LOGGER.warning("Нажатие устаревшего личного окна message=%s current_screen=%s", message_id,
                       type(view).__name__ if view else "expired")
        text = ("Это окно обновилось. Повтори нажатие на текущей карточке." if view else
                "Это окно устарело. Открой /меню заново.")
        await notice(interaction, text)

    async def remind_hosting(self) -> None:
        """Пишет владельцу за три, два и один день до указанной даты, не проверяя оплату хостинга."""
        reminder = self._hosting_reminder
        if not reminder or not reminder.get("expires_on") or not self.is_ready():
            return
        today = date.fromtimestamp(time.time())
        days_left = (date.fromisoformat(reminder["expires_on"]) - today).days
        if days_left not in {1, 2, 3} or reminder.get("last_attempt_on") == today.isoformat():
            return
        # До HTTP: перезапуск после отправки или неизвестного результата не повторяет DM сегодня.
        reminder["last_attempt_on"] = today.isoformat()
        self.store.put("hosting_reminder", reminder)
        try:
            user = await self.fetch_user(self.settings.hosting_reminder_user_id)
            remaining = {1: "1 день", 2: "2 дня", 3: "3 дня"}[days_left]
            await user.send(f"До продления хостинга осталось **{remaining}**.\n"
                            f"Указанная дата: **{reminder['expires_on']}**.\n"
                            f"{self.settings.hosting_reminder_url}\n\n"
                            "После оплаты обнови дату командой /подписка. Оплата автоматически не проверяется.",
                            suppress_embeds=True)
        except (discord.HTTPException, aiohttp.ClientError, OSError) as exc:
            LOGGER.warning("Напоминание о подписке не доставлено user=%s error_type=%s; повтор в следующий день окна", reminder["owner_id"], type(exc).__name__)
        else:
            LOGGER.info("Напоминание о подписке отправлено user=%s days_left=%s", reminder["owner_id"], days_left)

    async def set_subscription_date(self, interaction: discord.Interaction, date_text: str) -> None:
        """Сохраняет дату продления date_text только по команде администратора своего сервера."""
        await interaction.response.defer(ephemeral=True)
        if (interaction.guild_id != self.settings.guild_id or not isinstance(interaction.user, discord.Member)
                or not interaction.user.guild_permissions.administrator):
            await notice(interaction, "Дату подписки меняет только администратор сервера.")
            return
        if self._hosting_reminder is None:
            await notice(interaction, "Получатель напоминаний не настроен. Нужны ID владельца и ссылка на хостинг в конфигурации.")
            return
        try:
            expires_on = date.fromisoformat(date_text)
        except ValueError:
            await notice(interaction, "Введи дату в формате ГГГГ-ММ-ДД, например 2026-12-05.")
            return
        if expires_on < date.fromtimestamp(time.time()):
            await notice(interaction, "Эта дата уже прошла. Укажи текущую или будущую дату продления.")
            return
        old = self._hosting_reminder
        reminder = {"id": old["id"], "owner_id": old["owner_id"], "expires_on": expires_on.isoformat()}
        if old.get("expires_on") == reminder["expires_on"] and old.get("last_attempt_on"):
            reminder["last_attempt_on"] = old["last_attempt_on"]
        self.store.put("hosting_reminder", reminder)
        self._hosting_reminder = reminder
        LOGGER.info("Дата подписки обновлена expires_on=%s", reminder["expires_on"])
        await notice(interaction, f"Дата продления: **{reminder['expires_on']}**.\n"
                     "Напишу владельцу за 3, 2 и 1 день до неё. Оплата на хостинге автоматически не проверяется.")

    async def _member(self, guild: discord.Guild, owner_id: str) -> discord.Member:
        """Читает свежую роль owner_id; временный429 не выдаёт за потерю доступа."""
        try:
            return await guild.fetch_member(int(owner_id))
        except discord.RateLimited as exc:
            raise DiscordBackoff(exc.retry_after) from None
        except discord.HTTPException as exc:
            if exc.status == 429:
                delay = retry_seconds(exc.response.headers)
                raise DiscordBackoff(delay if delay is not None else 1) from None
            raise

    async def allowed(self, owner_id: str, *, refresh: bool = True) -> bool:
        """Проверяет роль; refresh=False использует до пяти минут кеша только в фоновом опросе."""
        now = time.monotonic()
        cached = self._access_cache.get(owner_id)
        if not refresh and cached and cached[0] > now:
            return cached[1]
        self._access_cache = {owner: entry for owner, entry in self._access_cache.items()
                              if owner != owner_id and entry[0] > now}
        guild = self.get_guild(self.settings.guild_id)
        if guild is None:
            return False
        try:
            member = await self._member(guild, owner_id)
        except (ValueError, discord.Forbidden, discord.NotFound):
            allowed = False
        else:
            allowed = any(role.id == self.settings.role_id for role in member.roles)
        self._access_cache[owner_id] = (time.monotonic() + ACCESS_CACHE_SECONDS, allowed)
        return allowed

    async def begin_connect(self, interaction: discord.Interaction) -> None:
        """Показывает участнику весь путь подключения, включая ссылку на свой UEX."""
        if not self.interaction_allowed(interaction):
            await notice(interaction, "Нужна разрешённая роль на нашем сервере.")
            return
        owner = str(interaction.user.id)
        account = self.store.get("account", owner)
        connected = (f"Сейчас подключён **{discord.utils.escape_markdown(account['username'])}**.\n\n"
                     if account and account.get("secret") else "")
        if connected:
            connected += ("Своё API-приложение подключено.\n\n" if account.get("app_token")
                          else "Для нового подключения введи оба ключа.\n\n")
        await render(interaction, content=connected + "**Подключение твоего UEX**\n"
            "1. Открой профиль UEX и скопируй свой **Secret Key**.\n"
            "2. В «API-приложениях UEX» создай своё приложение и скопируй его **токен**. "
            "Название будет видно собеседнику в переписке UEX. Например: SC Discord Trader.\n"
            "3. Нажми «Ввести ключи» и вставь оба ключа в личную форму.\n\n"
            "При каждом подключении вводятся оба ключа.\n"
            "После проверки ключей сообщения и новые ветки будут появляться автоматически.",
            view=ConnectGuideView(self, owner))

    def start_account_scan(self, owner_id: str) -> None:
        """Запускает первую сверку сразу после подключения без ручной кнопки участника."""
        if owner_id in self._account_scan_tasks and not self._account_scan_tasks[owner_id].done():
            return

        async def run() -> None:
            try:
                await self.service.scan(owner_id)
            except (PermissionError, DiscordBackoff):
                return
            except Exception as exc:
                self.service.last_error = type(exc).__name__
                LOGGER.warning("Начальная сверка не завершена owner=%s error_type=%s", owner_id, type(exc).__name__)

        task = asyncio.create_task(run())
        self._account_scan_tasks[owner_id] = task

        def finished(completed: asyncio.Task) -> None:
            if self._account_scan_tasks.get(owner_id) is completed:
                self._account_scan_tasks.pop(owner_id, None)

        task.add_done_callback(finished)

    async def close(self) -> None:
        """Завершает собственные фоновые сверки перед остановкой Discord-клиента."""
        tasks = list(self._account_scan_tasks.values())
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        await close_private_views(self)
        await super().close()

    def in_trade_channel(self, interaction: discord.Interaction) -> bool:
        """Принимает interaction только из настроенного канала или его ветки."""
        return (interaction.guild_id == self.settings.guild_id
                and (interaction.channel_id == self.settings.channel_id
                     or (isinstance(interaction.channel, discord.Thread)
                         and interaction.channel.parent_id == self.settings.channel_id)))

    async def check_channel(self, interaction: discord.Interaction) -> bool:
        """Отклоняет interaction вне рабочего канала без сообщения пользователю."""
        if self.in_trade_channel(interaction):
            return True
        if not interaction.response.is_done():
            await interaction.response.defer(ephemeral=True, thinking=True)
        await interaction.delete_original_response()
        return False

    def interaction_allowed(self, interaction: discord.Interaction) -> bool:
        """Проверяет канал и текущую роль; перед отправкой есть REST-проверка роли."""
        return (self.in_trade_channel(interaction)
                and isinstance(interaction.user, discord.Member)
                and any(role.id == self.settings.role_id for role in interaction.user.roles))

    async def show_menu(self, interaction: discord.Interaction, *, replace: bool = False) -> None:
        """Открывает личную панель по /меню или заменяет ею текущее личное окно."""
        if not self.interaction_allowed(interaction):
            await notice(interaction, "Нужна разрешённая роль на нашем сервере.")
            return
        await render(interaction, content=panel_text(self.settings.send_mode),
                     view=PanelView(self, str(interaction.user.id)), replace=replace)

    async def begin_disconnect(self, interaction: discord.Interaction) -> None:
        """Открывает личное подтверждение отключения UEX нажавшего участника."""
        if not self.interaction_allowed(interaction):
            await notice(interaction, "Нужна разрешённая роль на нашем сервере.")
            return
        await render(interaction, content="**Отключить твой аккаунт UEX?**\n"
                     "Бот удалит оба сохранённых ключа и перестанет получать и отправлять твои сообщения UEX.\n"
                     "История переписок останется. Подключиться заново можно в любой момент.",
                     view=DisconnectView(self, str(interaction.user.id)))

    async def show_listings(self, interaction: discord.Interaction) -> None:
        """Открывает личное управление объявлениями, не изменяя общую панель."""
        if not self.interaction_allowed(interaction):
            await notice(interaction, "Нужна разрешённая роль на нашем сервере.")
            return
        if interaction.message and interaction.message.flags.ephemeral:
            await interaction.response.defer()
        else:
            await interaction.response.defer(ephemeral=True, thinking=True)
        owner = str(interaction.user.id)
        try:
            account = await self.service.account(owner)
            mode = "Публикация на UEX — после твоего подтверждения." if self.settings.listing_mode == "production" else "Сейчас тест: реальные объявления не создаются и не удаляются."
            await render(interaction, content=f"**Твои объявления · {discord.utils.escape_markdown(account['username'])}**\n"
                         "**Создать объявление** — введи название и выбери товар.\n"
                         "Категория подставится автоматически.\n"
                         "**Подпись** — сохрани ссылку на магазин и текст для новых объявлений.\n\n" + mode,
                         view=ListingsHome(self, owner))
        except Exception as exc:
            await report_error(interaction, exc)

    async def begin_search(self, interaction: discord.Interaction) -> None:
        """Открывает форму без сетевого ожидания, проверив роль и наличие подключения."""
        if not self.interaction_allowed(interaction):
            await notice(interaction, "Нужна разрешённая роль на нашем сервере.")
            return
        owner = str(interaction.user.id)
        account = self.store.get("account", owner)
        if not account or not account.get("secret") or not account.get("app_token"):
            await notice(interaction, "Сначала подключи свой аккаунт через «Подключить UEX» в /меню.")
            return
        await interaction.response.send_modal(FindModal(self, owner))

    async def show_deals(self, interaction: discord.Interaction) -> None:
        """Возвращает личный список по текущему подключённому аккаунту."""
        if not self.interaction_allowed(interaction):
            await notice(interaction, "Нужна разрешённая роль на нашем сервере.")
            return
        if interaction.message and interaction.message.flags.ephemeral:
            await interaction.response.defer()
        else:
            await interaction.response.defer(ephemeral=True, thinking=True)
        owner = str(interaction.user.id)
        try:
            deals = await self.service.current_deals(owner)
        except (PermissionError, DiscordBackoff) as exc:
            await notice(interaction, str(exc))
            return
        if not deals:
            text = ("Сделки ещё загружаются. Проверка идёт автоматически. Открой «Мои сделки» чуть позже."
                    if self.service.is_scanning(owner) else
                    "Открытых переписок с сообщениями пока нет. Новые сообщения проверяются автоматически.")
            await render(interaction, content=text, view=PanelView(self, owner))
            return
        await render(interaction, content="Открытые переписки. Личное скрытие в UEX пока не учитывается.",
                     view=DealsView(self, owner, deals))

    async def setup_hook(self) -> None:
        """Регистрирует команды только своего сервера и восстанавливает кнопки оригиналов."""
        guild = discord.Object(id=self.settings.guild_id)

        @self.tree.command(name="меню", description="Показать личную панель SC Discord Trader", guild=guild)
        async def menu_command(interaction: discord.Interaction) -> None:
            """Возвращает панель нажавшему игроку внизу текущего чата."""
            await self.show_menu(interaction)

        @self.tree.command(name="объявления", description="Создать или удалить своё объявление UEX", guild=guild)
        async def listings_command(interaction: discord.Interaction) -> None:
            """Открывает личный мастер без поиска общей панели."""
            await self.show_listings(interaction)

        @self.tree.command(name="поиск", description="Найти продажи товара на UEX", guild=guild)
        async def search_command(interaction: discord.Interaction) -> None:
            """Открывает тот же личный поиск без обращения к общей панели."""
            await self.begin_search(interaction)

        @self.tree.command(name="подключить", description="Подключить свой личный аккаунт UEX", guild=guild)
        async def connect_command(interaction: discord.Interaction) -> None:
            """Вызывает личное подключение через окно ввода ключа."""
            await self.begin_connect(interaction)

        @self.tree.command(name="сделки", description="Открыть список своих сделок", guild=guild)
        async def deals_command(interaction: discord.Interaction) -> None:
            """Показывает личные сделки вызывающего участника."""
            await self.show_deals(interaction)

        @self.tree.command(name="отключить", description="Отключить свой аккаунт UEX", guild=guild)
        async def disconnect_command(interaction: discord.Interaction) -> None:
            """Открывает то же подтверждение, что кнопка в личном меню."""
            await self.begin_disconnect(interaction)

        @self.tree.command(name="панель", description="Разместить панель в настроенном канале", guild=guild)
        @app_commands.default_permissions(administrator=True)
        async def panel_command(interaction: discord.Interaction) -> None:
            """Размещает общую панель только по действию администратора настроенного сервера."""
            await interaction.response.defer(ephemeral=True)
            if (interaction.guild_id != self.settings.guild_id or not isinstance(interaction.user, discord.Member)
                    or not interaction.user.guild_permissions.administrator):
                await notice(interaction, "Размещать панель может только администратор сервера.")
                return
            await self.refresh_panel(create=True)
            await notice(interaction, "Панель готова.")

        @self.tree.command(name="статус", description="Показать техническое состояние бота администратору", guild=guild)
        @app_commands.default_permissions(administrator=True)
        async def status_command(interaction: discord.Interaction) -> None:
            """Показывает администратору состояние без токенов, участников и содержимого сделок."""
            await interaction.response.defer(ephemeral=True)
            if (interaction.guild_id != self.settings.guild_id or not isinstance(interaction.user, discord.Member)
                    or not interaction.user.guild_permissions.administrator):
                await notice(interaction, "Состояние доступно только администратору сервера.")
                return
            if self.status_provider is None:
                await notice(interaction, "Диагностика ещё запускается.")
                return
            try:
                text = status_text(self.status_provider())
            except Exception as exc:
                LOGGER.error("Диагностика недоступна error_type=%s", type(exc).__name__)
                await notice(interaction, "Не удалось прочитать состояние. Проверь логи процесса.")
                return
            await notice(interaction, text)

        @self.tree.command(name="подписка", description="Обновить дату продления хостинга", guild=guild)
        @app_commands.default_permissions(administrator=True)
        @app_commands.rename(date_text="дата")
        @app_commands.describe(date_text="Дата продления в формате ГГГГ-ММ-ДД")
        async def subscription_command(interaction: discord.Interaction, date_text: str) -> None:
            """Принимает новую дату администратора без перезапуска бота и обращения к хостингу."""
            await self.set_subscription_date(interaction, date_text)

        self.add_view(PanelView(self))
        for deal in self.store.all("deal"):
            if deal.get("thread_id"):
                self.add_view(DealView(self, deal))
        for record in self.store.all("message"):
            if record.get("display_id") and record["source"] == "incoming":
                self.add_view(OriginalView(self, record["id"]), message_id=int(record["display_id"]))
        await self.tree.sync(guild=guild)

    async def on_ready(self) -> None:
        """Обновляет существующую общую панель один раз за запуск без новых публикаций."""
        LOGGER.info("Discord подключён guild=%s bot=%s", self.settings.guild_id, self.user.id)
        if self._panel_ready_attempted:
            return
        self._panel_ready_attempted = True
        try:
            await self.refresh_panel()
        except Exception as exc:
            LOGGER.warning("Общая панель не обновлена error_type=%s", type(exc).__name__)

    @staticmethod
    def _panel_layout(message: discord.Message) -> list[list[tuple[str, str, int]]]:
        """Сравнивает значимые свойства кнопок без служебных ID компонентов Discord."""
        if any(not isinstance(row, discord.ActionRow) for row in message.components):
            return []
        return [[(getattr(child, "custom_id", None), getattr(child, "label", None),
                  getattr(getattr(child, "style", None), "value", None)) for child in row.children]
                for row in message.components]

    def _is_public_panel(self, message: discord.Message) -> bool:
        """Узнаёт только собственную панель с известным набором служебных кнопок."""
        if message.author.id != self.user.id:
            return False
        ids = [item[0] for row in self._panel_layout(message) for item in row]
        legacy = {"scdt:connect", "scdt:deals", "scdt:listings"}
        return (len(ids) == len(set(ids))
                and legacy <= set(ids) <= legacy | {"scdt:search", "scdt:disconnect"})

    async def refresh_panel(self, *, create: bool = False) -> bool:
        """Обновляет найденную панель; создавать новую разрешено только команде администратора."""
        async with self._panel_lock:
            channel = await self.fetch_channel(self.settings.channel_id)
            if not isinstance(channel, discord.TextChannel) or channel.guild.id != self.settings.guild_id:
                raise PermissionError("Неверно настроен канал панели")
            key, owner = str(channel.id), str(self.settings.guild_id)
            saved = self.store.get("discord_panel", key)
            message = None
            if saved and saved["owner_id"] == owner:
                try:
                    candidate = await channel.fetch_message(int(saved["message_id"]))
                except discord.NotFound:
                    pass
                else:
                    if self._is_public_panel(candidate):
                        message = candidate
            if message is None:
                # Миграция старой панели без ID: ограниченный поиск только в рабочем канале.
                async for candidate in channel.history(limit=100):
                    if self._is_public_panel(candidate):
                        message = candidate
                        break
            view, text = PanelView(self), panel_text(self.settings.send_mode)
            if message is None:
                if not create:
                    LOGGER.info("Общая панель не найдена среди последних 100 сообщений channel=%s", key)
                    return False
                message = await channel.send(text, view=view)
            else:
                expected = [[(item["custom_id"], item["label"], item["style"])
                             for item in row["components"]] for row in view.to_components()]
                if message.content != text or self._panel_layout(message) != expected:
                    await message.edit(content=text, view=view, allowed_mentions=discord.AllowedMentions.none())
                    LOGGER.info("Общая панель обновлена channel=%s message=%s", key, message.id)
            record = {"id": key, "owner_id": owner, "message_id": str(message.id)}
            if saved != record:
                self.store.put("discord_panel", record)
            return True

    async def on_disconnect(self) -> None:
        """Отмечает потерю связи; повторное подключение остаётся за Discord SDK."""
        if not self.is_closed():
            LOGGER.warning("Связь с Discord потеряна; SDK пробует подключиться повторно")

    async def on_resumed(self) -> None:
        """Отмечает успешное восстановление прежней Discord-сессии без её идентификаторов."""
        LOGGER.info("Связь с Discord восстановлена")

    async def thread(self, deal: dict[str, Any]) -> str:
        """Проверяет или создаёт private thread и приглашает только её владельца."""
        parent = await self.fetch_channel(self.settings.channel_id)
        if not isinstance(parent, discord.TextChannel) or parent.guild.id != self.settings.guild_id:
            raise PermissionError("Нужен текстовый канал настроенного сервера")
        owner = await self._member(parent.guild, deal["owner_id"])
        if not any(role.id == self.settings.role_id for role in owner.roles):
            raise PermissionError("Роль участника снята")
        thread = None
        if deal.get("thread_id"):
            try:
                thread = await self.fetch_channel(int(deal["thread_id"]))
            except discord.NotFound:
                for field in ("thread_id", "card_sent", "card_message_id", "archived"):
                    deal.pop(field, None)
                self.store.put("deal", deal)
        if thread is not None:
            if not isinstance(thread, discord.Thread) or not thread.is_private() or thread.parent_id != parent.id:
                raise PermissionError("Неверная приватная ветка")
            active = not thread.archived
            if thread.archived and not thread.locked and not (deal["own_closed"] or deal.get("peer_closed")):
                await self._unarchive_thread(thread)
                # SDK edit возвращает новый объект; прежний thread.archived не меняется.
                active = True
            if active:
                await self._refresh_thread_name(thread, deal)
        else:
            thread = await parent.create_thread(name=trade_thread_name(deal), type=discord.ChannelType.private_thread,
                                                invitable=False, auto_archive_duration=1440)
            deal["thread_id"] = str(thread.id)
            self.store.put("deal", deal)
            active = True
        if active and not deal.get("archived"):
            await thread.add_user(owner)
        if active and not deal.get("card_sent"):
            view = DealView(self, deal)
            for piece in chunks(deal_card_text(deal)):
                card = await thread.send(piece, view=view)
                if not deal.get("card_message_id"):
                    deal["card_message_id"] = str(card.id)
            deal["card_sent"] = True
            self.store.put("deal", deal)
        elif active and not thread.locked:
            await self._refresh_deal_card(thread, deal)
        return str(thread.id)

    async def _refresh_thread_name(self, thread: discord.Thread, deal: dict[str, Any]) -> None:
        """Обновляет только активную ветку; отказ названия не мешает доставке сообщений."""
        wanted = trade_thread_name(deal)
        failed = self._thread_name_failures.get(thread.id)
        if thread.name == wanted:
            self._thread_name_failures.pop(thread.id, None)
            return
        if failed and failed[:2] == (thread.name, wanted) and failed[2] > time.monotonic():
            return
        try:
            await thread.edit(name=wanted)
        except (discord.HTTPException, discord.RateLimited, DiscordBackoff) as exc:
            retry = getattr(exc, "retry_after", None)
            if retry is None and getattr(exc, "status", None) == 429:
                retry = retry_seconds(exc.response.headers)
            # Одинаковый ошибочный ввод400/403 не повторяется до изменения имени/перезапуска.
            delay = retry if retry is not None else (float("inf") if getattr(exc, "status", 0) in {400, 403} else 60)
            self._thread_name_failures[thread.id] = (thread.name, wanted, time.monotonic() + delay)
            LOGGER.warning("Название ветки не обновлено thread=%s http=%s code=%s error_type=%s; доставка продолжается",
                           thread.id, getattr(exc, "status", None), getattr(exc, "code", None), type(exc).__name__)
        else:
            self._thread_name_failures.pop(thread.id, None)

    async def _refresh_deal_card(self, thread: discord.Thread, deal: dict[str, Any]) -> None:
        """Обновляет прежнюю карточку в thread; отказ Discord не блокирует переписку."""
        if not deal.get("card_message_id"):
            return
        try:
            card = await thread.fetch_message(int(deal["card_message_id"]))
            content = deal_card_text(deal)
            if card.content != content:
                await card.edit(content=content, allowed_mentions=discord.AllowedMentions.none())
        except discord.NotFound:
            return
        except (discord.HTTPException, discord.RateLimited, DiscordBackoff) as exc:
            LOGGER.warning("Карточка не обновлена thread=%s http=%s error_type=%s",
                           thread.id, getattr(exc, "status", None), type(exc).__name__)

    async def incoming(self, deal: dict[str, Any], message: dict[str, Any]) -> str:
        """Отправляет message в уже подготовленную сервисом ветку deal, сохраняя авторство и оригинал."""
        thread = await self.fetch_channel(int(deal["thread_id"]))
        sent = []
        heading = ("Вы · сообщение с UEX" if message.get("sender") == deal["account"]
                   else "Входящее · перевод на русский")
        for index, piece in enumerate(chunks(f"**{heading}**\n" + message["translated"])):
            view = OriginalView(self, message["id"]) if index == 0 else None
            sent.append(await thread.send(piece, view=view))
        return str(sent[0].id)

    async def archive(self, deal: dict[str, Any], *, locked: bool = True) -> None:
        """Архивирует личную ветку; locked отличает завершение от ручной паузы."""
        try:
            thread = await self.fetch_channel(int(deal["thread_id"]))
        except discord.NotFound:
            if not locked:
                raise
            return
        if not isinstance(thread, discord.Thread) or not thread.is_private() or thread.parent_id != self.settings.channel_id:
            raise PermissionError("Неверная приватная ветка для архива")
        if not locked and thread.locked:
            raise PermissionError("Ветка заблокирована: снять блокировку может модератор")
        if thread.archived:
            # Уже архивная ветка не требует повторного PATCH или открытия ради locked.
            return
        await thread.edit(archived=True, locked=locked)

    async def _unarchive_thread(self, thread: discord.Thread) -> None:
        """Снимает архив и отмечает возврат в самой ветке, не пересылая заметку в UEX."""
        await thread.edit(archived=False)
        try:
            await thread.send("**Ветка возвращена из архива.** Можно продолжать переписку.",
                              allowed_mentions=discord.AllowedMentions.none())
        except Exception as exc:
            LOGGER.warning("Ветка возвращена, но уведомление не отправлено thread=%s error_type=%s",
                           thread.id, type(exc).__name__)

    async def restore(self, deal: dict[str, Any]) -> None:
        """Разархивирует прежнюю приватную ветку, сохраняя модераторскую блокировку."""
        thread = await self.fetch_channel(int(deal["thread_id"]))
        if not isinstance(thread, discord.Thread) or not thread.is_private() or thread.parent_id != self.settings.channel_id:
            raise PermissionError("Неверная приватная ветка для возврата из архива")
        if thread.locked:
            raise PermissionError("Ветка заблокирована: снять блокировку может модератор.")
        if not await self.allowed(deal["owner_id"]):
            raise PermissionError("Нет разрешённой роли на сервере")
        if thread.archived:
            await self._unarchive_thread(thread)
        await self._refresh_deal_card(thread, deal)

    async def _reply_feedback(self, message: discord.Message, text: str) -> None:
        """Отвечает на message; отказ Discord фиксирует без повторной отправки сообщения в UEX."""
        try:
            await message.reply(text, mention_author=False)
        except (DiscordBackoff, discord.RateLimited, discord.HTTPException) as exc:
            LOGGER.warning("Уведомление Discord не доставлено message=%s error_type=%s http=%s", message.id, type(exc).__name__, getattr(exc, "status", None))

    async def on_message(self, message: discord.Message) -> None:
        """Переводит обычный ответ владельца только в его активной приватной ветке."""
        if message.author.bot or not message.guild or message.guild.id != self.settings.guild_id:
            return
        if not isinstance(message.channel, discord.Thread) or message.channel.parent_id != self.settings.channel_id:
            return
        matches = [deal for deal in self.store.all("deal") if deal.get("thread_id") == str(message.channel.id)]
        if not matches:
            return
        deal = matches[0]
        if deal["owner_id"] != str(message.author.id):
            return
        if message.attachments and not message.content:
            await self._reply_feedback(message, "Пока поддерживаются текстовые ответы.")
            return
        try:
            result = await self.service.reply(str(message.author.id), deal["id"], str(message.id), message.content)
        except (PermissionError, ValueError, DiscordBackoff) as exc:
            await self._reply_feedback(message, str(exc))
            return
        except Exception as exc:
            LOGGER.error("Ошибка ответа message=%s error_type=%s", message.id, type(exc).__name__)
            await self._reply_feedback(message, "Ошибка обработки. Автоматически повторно не отправляю.")
            return
        labels = {"delivered": "UEX подтвердил запрос", "unknown": "Результат отправки неизвестен; автоповтор отключён",
                  "translation_failed": "Перевод недоступен, сообщение не отправлено", "failed": "UEX не подтвердил отправку"}
        label = labels.get(result["status"], "Обработка ещё не завершена")
        if result["status"] == "translation_failed" and result.get("error") in {
            "incomplete_result", "protected_values_changed", "numeric_values_changed", "output_truncated", "incomplete_completion"
        }:
            label = "Перевод не прошёл проверку точности, сообщение не отправлено"
        if self.settings.send_mode == "test":
            label = "🧪 Тестовый режим UEX · " + label
        feedback = label + ("\n" + result["translated"] if result["translated"] else "")
        for piece in chunks(feedback):
            await self._reply_feedback(message, piece)
