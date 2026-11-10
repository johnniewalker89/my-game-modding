"""Личный поиск покупок: пять карточек, список сортировки и навигация."""

import logging
from typing import TYPE_CHECKING, Any

import discord

from trader.discord_health import DiscordBackoff
from trader.discord_ui import render
from trader.listing_ui import PersonalModal, PersonalView
from trader.listings import UNITS
from trader.marketplace import MarketError
from trader.search import PAGE_SIZE, SORT_LABELS, UEX_ROWS_LIMIT, Offer, SearchResult, find_offers, minimum_quality

if TYPE_CHECKING:
    from trader.discord_bot import TraderBot

LOGGER = logging.getLogger(__name__)


async def report_search_error(interaction: discord.Interaction, error: Exception) -> None:
    """Сообщает безопасную причину сбоя поиска лично пользователю, без тел ответов UEX."""
    if isinstance(error, discord.RateLimited):
        text = str(DiscordBackoff(error.retry_after))
    elif isinstance(error, (ValueError, PermissionError, DiscordBackoff)):
        text = str(error)
    else:
        text = "Не удалось загрузить предложения UEX. Попробуй поиск ещё раз чуть позже через /поиск."
    LOGGER.warning("Поиск UEX отклонён owner=%s error_type=%s code=%s", interaction.user.id,
                   type(error).__name__, str(error) if isinstance(error, MarketError) else "validation_or_discord")
    sender = interaction.followup.send if interaction.response.is_done() else interaction.response.send_message
    await sender(text, ephemeral=True, allowed_mentions=discord.AllowedMentions.none())


class SearchView(PersonalView):
    """Сохраняет штатную проверку владельца/роли и собственную диагностику поиска."""

    async def on_error(self, interaction: discord.Interaction, error: Exception, item: discord.ui.Item) -> None:
        """Обрабатывает отказ кнопки поиска без сообщений о публикации объявления."""
        await report_search_error(interaction, error)


class FindModal(PersonalModal):
    """Спрашивает название товара и необязательный нижний порог качества."""

    def __init__(self, bot: "TraderBot", owner: str, query: str = "", quality: str = ""):
        """Подставляет прежний query и quality при повторном поиске."""
        super().__init__(bot, owner, "Найти товар на UEX")
        self.query = discord.ui.TextInput(label="Название товара", max_length=80, default=query[:80] or None,
                                         placeholder="Например Helix, Karna или Copper")
        self.quality = discord.ui.TextInput(label="Минимальное качество (необязательно)", required=False,
                                           max_length=4, default=quality or None, placeholder="1–1000; пусто — любое качество")
        self.add_item(self.query)
        self.add_item(self.quality)

    async def on_submit(self, interaction: discord.Interaction) -> None:
        """Подтверждает форму сразу; результаты и ожидание всегда остаются приватными."""
        quality = minimum_quality(str(self.quality))
        query = str(self.query).strip()
        if not query:
            raise ValueError("Введи название товара.")
        await interaction.response.defer(ephemeral=True, thinking=True)
        if not self.bot.listings.catalog_ready:
            await interaction.edit_original_response(content="Загружаю каталог UEX… При первом поиске это может занять пару минут.",
                                                      view=None, embeds=[], attachments=[], allowed_mentions=discord.AllowedMentions.none())
        rows = await self.bot.listings.items(self.owner, None, query)
        if not rows:
            await render(interaction, content="Товар не найден. Попробуй оригинальное название UEX или другую часть названия.",
                         embeds=[], view=FindAgain(self.bot, self.owner, query, str(self.quality)))
        elif len(rows) == 1:
            await show_offers(self.bot, interaction, self.owner, rows[0], quality)
        else:
            await render(interaction, content="Выбери точный товар из каталога UEX.", embeds=[],
                         view=ItemPicker(self.bot, self.owner, rows, quality))

    async def on_error(self, interaction: discord.Interaction, error: Exception) -> None:
        """Поясняет отказ формы через тот же безопасный обработчик поиска."""
        await report_search_error(interaction, error)


class FindAgain(SearchView):
    """Предлагает уточнить неудачный поиск или вернуться в меню."""

    def __init__(self, bot: "TraderBot", owner: str, query: str = "", quality: str = ""):
        """Сохраняет поля для явного повторного ввода без автоматического ослабления фильтра."""
        super().__init__(bot, owner)
        self.query, self.quality = query, quality
        self.button("Другой поиск", self.again, row=0)
        self.menu_button(0)

    async def again(self, interaction: discord.Interaction) -> None:
        """Открывает форму с прежними значениями для редактирования."""
        await interaction.response.send_modal(FindModal(self.bot, self.owner, self.query, self.quality))


class ItemPicker(SearchView):
    """Листает совпадения каталога, не смешивая выбор товара с созданием объявления."""

    def __init__(self, bot: "TraderBot", owner: str, rows: list[dict[str, Any]],
                 quality: int | None, page: int = 0):
        """Показывает страницу page по 25 названий; сохраняет порог quality для выбранного товара."""
        super().__init__(bot, owner)
        self.rows, self.quality, self.page = rows, quality, page
        options = [discord.SelectOption(value=str(row["id"]), label=str(row["name"])[:100],
                                        description=str(row.get("category_label") or "")[:100] or None)
                   for row in rows[page * 25:(page + 1) * 25]]
        self.selection = discord.ui.Select(placeholder="Выбери точный товар", options=options, row=0)
        self.selection.callback = self.selected
        self.add_item(self.selection)
        if len(rows) > 25:
            self.button("← Назад", self.previous, row=1, disabled=page == 0)
            self.button(f"{page + 1}/{(len(rows) + 24) // 25}", self.ignore, row=1, disabled=True)
            self.button("Далее →", self.following, row=1, disabled=(page + 1) * 25 >= len(rows))
        self.button("Другой поиск", self.again, row=2)
        self.menu_button(2)

    async def selected(self, interaction: discord.Interaction) -> None:
        """Читает продажи только товара из предложенного каталога, без публикаций и новых сделок."""
        item = next((row for row in self.rows if str(row["id"]) == self.selection.values[0]), None)
        if item is None:
            raise ValueError("Выбери товар из списка.")
        await interaction.response.defer()
        await show_offers(self.bot, interaction, self.owner, item, self.quality)

    async def previous(self, interaction: discord.Interaction) -> None:
        """Возвращает предыдущую страницу совпадений, сохраняя минимальное качество."""
        await render(interaction, content="Выбери точный товар из каталога UEX.", embeds=[],
                     view=ItemPicker(self.bot, self.owner, self.rows, self.quality, self.page - 1))

    async def following(self, interaction: discord.Interaction) -> None:
        """Открывает следующую страницу совпадений с тем же порогом качества."""
        await render(interaction, content="Выбери точный товар из каталога UEX.", embeds=[],
                     view=ItemPicker(self.bot, self.owner, self.rows, self.quality, self.page + 1))

    async def again(self, interaction: discord.Interaction) -> None:
        """Позволяет изменить название товара до загрузки предложений."""
        await interaction.response.send_modal(FindModal(self.bot, self.owner, quality=str(self.quality or "")))

    async def ignore(self, interaction: discord.Interaction) -> None:
        """Подтверждает служебную отключённую кнопку номера страницы."""
        await interaction.response.defer()


def offer_embed(name: str, offer: Offer) -> discord.Embed:
    """Собирает компактную карточку: название открывает объявление, ник — магазин продавца."""
    quality = f" · Q{offer.quality}" if offer.quality is not None else ""
    if offer.price is None:
        price = "Цена не указана"
    else:
        amount = format(offer.price, ",f")
        if "." in amount:
            amount = amount.rstrip("0").rstrip(".")
        amount = amount.replace(",", " ").replace(".", ",")
        price = f"{amount} {offer.currency} / {UNITS.get(offer.unit, offer.unit)}"
    details = []
    if offer.stock is not None:
        details.append(f"Запас: {offer.stock}")
    if offer.location:
        details.append(discord.utils.escape_markdown(offer.location))
    seller = discord.utils.escape_markdown(offer.seller[:60]).replace("[", r"\[").replace("]", r"\]")
    lines = [f"**{price}**", " · ".join(details), f"[{seller}]({offer.store_url})"]
    embed = discord.Embed(title=discord.utils.escape_markdown(name)[:200] + quality, url=offer.url,
                          description="\n".join(line for line in lines if line), colour=discord.Colour.blurple())
    if offer.photo:
        embed.set_thumbnail(url=offer.photo)
    return embed


class OffersView(SearchView):
    """Показывает пять объявлений, список сортировки и стрелки отдельной строкой."""

    def __init__(self, bot: "TraderBot", owner: str, result: SearchResult,
                 mode: str = "price_asc", page: int = 0):
        """Листает неизменный result без дополнительных GET; mode и page — состояние окна."""
        super().__init__(bot, owner)
        self.result = result
        self.mode = mode if mode in result.modes else result.modes[0]
        self.page = max(0, min(page, max(0, (len(result.offers) - 1) // PAGE_SIZE)))
        self.sorting = discord.ui.Select(placeholder="Сортировка", row=0,
            options=[discord.SelectOption(label=SORT_LABELS[mode], value=mode, default=mode == self.mode)
                     for mode in result.modes])
        self.sorting.callback = self.sort
        self.add_item(self.sorting)
        self.button("← Назад", self.previous, row=1, disabled=self.page == 0)
        self.button("Далее →", self.following, row=1, disabled=(self.page + 1) * PAGE_SIZE >= len(result.offers))

    async def show(self, interaction: discord.Interaction) -> None:
        """Заменяет то же личное сообщение, сохраняя ссылки, фильтр и группировку цен."""
        result = self.result
        page_count = max(1, (len(result.offers) + PAGE_SIZE - 1) // PAGE_SIZE)
        quality = f" · качество от {result.quality_from}" if result.quality_from is not None else ""
        content = (f"**{discord.utils.escape_markdown(result.item_name)}{quality}**\n"
                   f"Стр. {self.page + 1}/{page_count} · предложений: {len(result.offers)}")
        if self.mode.startswith("price") and len({(o.currency, o.unit) for o in result.offers}) > 1:
            content += "\nЦены отсортированы отдельно для каждой валюты и единицы."
        if result.received >= UEX_ROWS_LIMIT:
            content += "\nUEX вернул предельные 1000 строк: часть предложений может не попасть в ответ."
        offers = result.ordered(self.mode)[self.page * PAGE_SIZE:(self.page + 1) * PAGE_SIZE]
        await render(interaction, content=content, embeds=[offer_embed(result.item_name, offer) for offer in offers], view=self)

    async def previous(self, interaction: discord.Interaction) -> None:
        """Возвращает страницу назад с прежней сортировкой, не обращаясь к UEX."""
        await OffersView(self.bot, self.owner, self.result, self.mode, self.page - 1).show(interaction)

    async def following(self, interaction: discord.Interaction) -> None:
        """Открывает следующую пятёрку из того же снимка поиска."""
        await OffersView(self.bot, self.owner, self.result, self.mode, self.page + 1).show(interaction)

    async def sort(self, interaction: discord.Interaction) -> None:
        """Применяет выбранный режим и возвращает выдачу на первую страницу."""
        mode = self.sorting.values[0] if self.sorting.values else None
        if mode not in self.result.modes:
            raise ValueError("Выбери сортировку из списка.")
        await OffersView(self.bot, self.owner, self.result, mode).show(interaction)


async def show_offers(bot: "TraderBot", interaction: discord.Interaction, owner: str,
                      item: dict[str, Any], quality: int | None) -> None:
    """Загружает один снимок продаж либо предлагает явно исправить пустой поиск."""
    result = await find_offers(bot.service, owner, item, quality)
    if not result.offers:
        suffix = f" с качеством от {quality}" if quality is not None else ""
        await render(interaction, content=f"В ответе UEX нет непроданных предложений этого товара{suffix}.", embeds=[],
                     view=FindAgain(bot, owner, str(item.get("name") or ""), str(quality or "")))
        return
    await OffersView(bot, owner, result).show(interaction)
