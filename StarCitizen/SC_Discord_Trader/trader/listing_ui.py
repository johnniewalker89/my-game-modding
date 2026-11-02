"""Личный мастер объявлений Discord: каталог, условия, фото и точное подтверждение."""

import base64
import hashlib
import io
import logging
from typing import TYPE_CHECKING, Any

import discord

from trader.discord_ui import EphemeralView, render
from trader.listings import DEFAULT_LOCATION, HOURS, MAX_PHOTO, OPERATIONS, UNITS, listing_payload
from trader.marketplace import MarketError

if TYPE_CHECKING:
    from trader.discord_bot import TraderBot

LOGGER = logging.getLogger(__name__)
MANAGE_URL = "https://uexcorp.space/marketplace/manage/tab/listings/"
STATUSES = {"created": "Создано · проверь модерацию", "active": "Активно на UEX",
            "unconfirmed": "Нет в активном списке · проверь UEX",
            "deleting": "Удаляется", "delete_unknown": "Удаление не подтверждено"}


async def report_error(interaction: discord.Interaction, error: Exception) -> None:
    """Показывает безопасную причину, отдельно предупреждая о неизвестном результате записи."""
    if isinstance(error, (ValueError, PermissionError)):
        text = str(error)
    elif isinstance(error, MarketError) and error.uncertain:
        text = "UEX не подтвердил результат. Запрос мог выполниться: проверь свои объявления на сайте. Автоматического повтора не будет."
    elif isinstance(error, MarketError):
        text = {"user_not_verified": "UEX требует подтвердить профиль RSI на сайте.",
                "listing_already_added": "UEX уже видит такое объявление. Проверь список на сайте.",
                "invalid_quality": "UEX отклонил качество. Допустимы значения 1–1000.",
                "invalid_image_data": "UEX не принял фото. Проверь JPG/PNG.",
                "invalid_secret_key": "Ключ UEX больше не работает. Переподключи аккаунт.",
                "user_active_listings_limit_reached": "Достигнут лимит объявлений UEX.",
                "uex_invalid_catalog": "Не удалось загрузить каталог UEX. Попробуй ещё раз чуть позже."}.get(str(error),
                "UEX не выполнил запрос. Попробуй ещё раз чуть позже.")
    else:
        text = "Не удалось завершить действие. Если нажимал публикацию или удаление, сначала проверь результат на UEX. Вызвать панель снова: /меню."
    LOGGER.warning("Действие с объявлением отклонено owner=%s error_type=%s code=%s", interaction.user.id,
                   type(error).__name__, str(error) if isinstance(error, MarketError) else "validation")
    if interaction.response.is_done():
        await interaction.followup.send(text, ephemeral=True, allowed_mentions=discord.AllowedMentions.none())
    else:
        await interaction.response.send_message(text, ephemeral=True, allowed_mentions=discord.AllowedMentions.none())


class PersonalView(EphemeralView):
    """Проверяет участника и роль для каждой кнопки личного мастера."""

    def __init__(self, bot: "TraderBot", owner: str):
        """Ограничивает срок окна десятью минутами; восстановление доступно через /меню."""
        super().__init__(timeout=600)
        self.bot, self.owner = bot, owner

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Не даёт другому участнику использовать личное окно или действовать без роли."""
        allowed = str(interaction.user.id) == self.owner and self.bot.interaction_allowed(interaction)
        if not allowed:
            await report_error(interaction, PermissionError("Это чужое личное меню или у тебя нет нужной роли."))
            return False
        return await super().interaction_check(interaction)

    async def on_error(self, interaction: discord.Interaction, error: Exception, item: discord.ui.Item) -> None:
        """Обрабатывает ошибки кнопок без публикации приватных данных и traceback в Discord."""
        await report_error(interaction, error)

    def button(self, label: str, callback, *, row: int, disabled: bool = False,
               style: discord.ButtonStyle = discord.ButtonStyle.secondary) -> None:
        """Добавляет кнопку действия в указанную строку мастера."""
        button = discord.ui.Button(label=label, row=row, disabled=disabled, style=style)
        button.callback = callback
        self.add_item(button)

    def menu_button(self, row: int = 4) -> None:
        """Возвращает личную панель в том же сообщении."""
        self.button("В меню", self.menu, row=row)

    async def menu(self, interaction: discord.Interaction) -> None:
        """Возвращает панель без создания нового публичного сообщения."""
        await self.bot.show_menu(interaction, replace=True)


class ListingsHome(PersonalView):
    """Начало работы с собственными объявлениями."""

    def __init__(self, bot: "TraderBot", owner: str):
        """Показывает создание, личный список и полный список площадки."""
        super().__init__(bot, owner)
        self.button("Создать объявление", self.create, row=0, style=discord.ButtonStyle.primary)
        self.button("Мои объявления", self.own, row=0)
        self.add_item(discord.ui.Button(label="Все объявления на UEX", url=MANAGE_URL, row=1))
        self.menu_button(1)

    async def create(self, interaction: discord.Interaction) -> None:
        """Сразу спрашивает название конкретного товара, без обязательного выбора категории."""
        await interaction.response.send_modal(SearchModal(self.bot, self.owner))

    async def own(self, interaction: discord.Interaction) -> None:
        """Показывает только объявления текущего подключённого аккаунта."""
        await show_own(self.bot, interaction, self.owner)


class CatalogView(PersonalView):
    """Листает найденные товары по 25 вариантов, сохраняя их исходные названия."""

    def __init__(self, bot: "TraderBot", owner: str, rows: list[dict[str, Any]],
                 page: int = 0):
        """Показывает страницу page списка товаров rows с подсказками их категорий."""
        super().__init__(bot, owner)
        self.rows, self.page = rows, page
        options = [discord.SelectOption(value=str(row["id"]), label=row["name"][:100],
            description=(row.get("category_label") or row.get("category") or "")[:100] or None)
            for row in rows[page * 25:(page + 1) * 25]]
        self.selection = discord.ui.Select(placeholder="Выбери конкретный товар", options=options, row=0)
        self.selection.callback = self.selected
        self.add_item(self.selection)
        if len(rows) > 25:
            self.button("←", self.previous, row=1, disabled=page == 0)
            self.button(f"{page + 1}/{(len(rows) + 24) // 25}", self.ignore, row=1, disabled=True)
            self.button("→", self.following, row=1, disabled=(page + 1) * 25 >= len(rows))
        self.button("Другой поиск", self.search, row=2)
        self.menu_button(2)

    async def selected(self, interaction: discord.Interaction) -> None:
        """Открывает черновик выбранного товара с его категорией."""
        selected = int(self.selection.values[0])
        if not any(int(row["id"]) == selected for row in self.rows):
            raise ValueError("Выбери товар из списка.")
        await interaction.response.defer()
        row = next(row for row in self.rows if int(row["id"]) == selected)
        draft = await self.bot.listings.start(self.owner, int(row["id_category"]), selected)
        await show_draft(self.bot, interaction, draft)

    async def search(self, interaction: discord.Interaction) -> None:
        """Возвращает общий поиск товара."""
        await interaction.response.send_modal(SearchModal(self.bot, self.owner))

    async def previous(self, interaction: discord.Interaction) -> None:
        """Показывает предыдущую страницу вариантов."""
        await render(interaction, content="Выбери вариант.", view=CatalogView(self.bot, self.owner, self.rows, self.page - 1))

    async def following(self, interaction: discord.Interaction) -> None:
        """Показывает следующую страницу вариантов."""
        await render(interaction, content="Выбери вариант.", view=CatalogView(self.bot, self.owner, self.rows, self.page + 1))

    async def ignore(self, interaction: discord.Interaction) -> None:
        """Подтверждает служебную отключённую кнопку номера страницы."""
        await interaction.response.defer()


class PersonalModal(discord.ui.Modal):
    """Повторно проверяет владельца и роль при отправке формы."""

    def __init__(self, bot: "TraderBot", owner: str, title: str):
        """Сохраняет владельца личного окна без секретов."""
        super().__init__(title=title, timeout=600)
        self.bot, self.owner = bot, owner

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Проверяет Discord-сервер, роль и владельца до чтения данных формы."""
        allowed = str(interaction.user.id) == self.owner and self.bot.interaction_allowed(interaction)
        if not allowed:
            await report_error(interaction, PermissionError("Нет доступа к этой форме."))
        return allowed

    async def on_error(self, interaction: discord.Interaction, error: Exception) -> None:
        """Показывает ошибку формы лично участнику."""
        await report_error(interaction, error)


class SearchModal(PersonalModal):
    """Ищет конкретный товар по всему каталогу UEX."""

    def __init__(self, bot: "TraderBot", owner: str):
        """Открывает обязательный ввод оригинального названия товара."""
        super().__init__(bot, owner, "Найти товар")
        self.query = discord.ui.TextInput(label="Название товара", required=True, max_length=80,
                                         placeholder="Оригинальное название: Sadaryx, Copper, Karna")
        self.add_item(self.query)

    async def on_submit(self, interaction: discord.Interaction) -> None:
        """Загружает совпадения, не публикуя текст поиска в канале."""
        await interaction.response.defer()
        if not self.bot.listings.catalog_ready:
            await interaction.edit_original_response(content="Ищу товар по всему каталогу UEX… При первой загрузке это может занять пару минут.",
                                                      view=None, embed=None, attachments=[], allowed_mentions=discord.AllowedMentions.none())
        rows = await self.bot.listings.items(self.owner, None, str(self.query))
        if not rows:
            await render(interaction, content="Товар не найден. Попробуй оригинальное название UEX или другую часть названия.",
                         view=SearchAgain(self.bot, self.owner))
            return
        await render(interaction, content="Выбери точный товар из каталога UEX.",
                     view=CatalogView(self.bot, self.owner, rows))


class SearchAgain(PersonalView):
    """Позволяет исправить поиск без выхода из личного окна."""

    def __init__(self, bot: "TraderBot", owner: str):
        """Предлагает повторить общий поиск в личном окне владельца."""
        super().__init__(bot, owner)
        self.button("Другой поиск", self.search, row=0)
        self.menu_button(0)

    async def search(self, interaction: discord.Interaction) -> None:
        """Открывает форму повторного поиска."""
        await interaction.response.send_modal(SearchModal(self.bot, self.owner))


def draft_embed(draft: dict[str, Any], *, preview: bool = False) -> discord.Embed:
    """Показывает условия и полный английский текст, который будет отправлен UEX."""
    payload = listing_payload(draft) if preview else None
    embed = discord.Embed(title=payload["title"] if payload else draft["item"]["name"][:200],
                          description=payload["description"] if payload else "Заполни условия, при желании добавь фото и проверь карточку.",
                          colour=discord.Colour.green())
    fields = [("Действие", OPERATIONS[draft["operation"]]), ("Количество", f"{draft['quantity']} {draft['unit']}"),
              ("Качество", str(draft["quality"]) if draft["quality"] is not None else "Не указано"),
              (f"Цена за 1 {draft['unit']}", f"{draft['price']:,} UEC".replace(",", " ") if draft["price"] is not None else "Не заполнена"),
              ("Всего", f"{draft['price'] * draft['quantity']:,} UEC".replace(",", " ") if draft["price"] is not None else "—"),
              ("Место", draft.get("location") or DEFAULT_LOCATION),
              ("Срок предложения", f"{draft['hours']} ч" if draft["hours"] else "Не указывать"),
              ("Видимость", "Скрытое" if draft["hidden"] else "Обычное, после модерации"),
              ("Фото", "Добавлено" if draft.get("photo") else "Без фото")]
    for name, value in fields:
        embed.add_field(name=name, value=discord.utils.escape_markdown(value), inline=True)
    embed.set_footer(text="Проверь цену за единицу и общую сумму. Модерация и общий срок размещения определяются UEX.")
    return embed


async def show_draft(bot: "TraderBot", interaction: discord.Interaction, draft: dict[str, Any], *, preview: bool = False) -> None:
    """Показывает черновик и сохраняет уже загруженное личное превью фото между шагами."""
    embed = draft_embed(draft, preview=preview)
    attachments: list = []
    if draft.get("photo"):
        data = base64.b64decode(draft["photo"])
        suffix = ".png" if data.startswith(b"\x89PNG") else ".jpg"
        filename = "listing-" + hashlib.sha256(data).hexdigest()[:16] + suffix
        existing = next((a for a in (interaction.message.attachments if interaction.message else []) if a.filename == filename), None)
        attachments = [existing or discord.File(io.BytesIO(data), filename=filename)]
        embed.set_image(url="attachment://" + filename)
    await render(interaction, content="Проверь карточку перед отправкой." if preview else "Твоё объявление · пока черновик",
                 embed=embed, attachments=attachments,
                 view=PreviewView(bot, draft) if preview else DraftView(bot, draft))


class DraftView(PersonalView):
    """Настройки карточки без записи на UEX."""

    def __init__(self, bot: "TraderBot", draft: dict[str, Any]):
        """Привязывает элементы к версии показанного черновика."""
        super().__init__(bot, draft["owner_id"])
        self.draft = draft
        for field, options, placeholder, row in (
            ("operation", OPERATIONS, "Купить / продать / обменять", 0),
            ("unit", UNITS, "Единицы количества и цены", 1),
            ("hours", {str(hour): f"Срок предложения: {hour} ч" if hour else "Не указывать срок" for hour in HOURS}, "Срок предложения", 2),
        ):
            select = discord.ui.Select(placeholder=placeholder, row=row, options=[discord.SelectOption(
                label=label, value=value, default=str(draft[field]) == value) for value, label in options.items()])
            select.callback = self.selection_callback(field, select)
            self.add_item(select)
        self.button("Условия", self.conditions, row=3, style=discord.ButtonStyle.primary)
        self.button("Фото", self.photo, row=3)
        self.button("Сделать обычным" if draft["hidden"] else "Сделать скрытым", self.visibility, row=3)
        self.button("Предпросмотр", self.preview, row=4, style=discord.ButtonStyle.success)
        self.menu_button(4)

    def selection_callback(self, field: str, select: discord.ui.Select):
        """Создаёт обработчик одного значения списка без доверия к произвольным полям."""
        async def selected(interaction: discord.Interaction) -> None:
            """Сохраняет тип, единицы или срок и обновляет ту же карточку."""
            await interaction.response.defer()
            value = int(select.values[0]) if field == "hours" else select.values[0]
            updated = await self.bot.listings.edit(self.owner, self.draft["id"], self.draft["revision"], {field: value})
            await show_draft(self.bot, interaction, updated)
        return selected

    async def conditions(self, interaction: discord.Interaction) -> None:
        """Открывает форму количества, цены, качества, места и описания."""
        await interaction.response.send_modal(ConditionsModal(self.bot, self.draft))

    async def photo(self, interaction: discord.Interaction) -> None:
        """Открывает штатную загрузку фото в личной форме Discord."""
        await interaction.response.send_modal(PhotoModal(self.bot, self.draft))

    async def visibility(self, interaction: discord.Interaction) -> None:
        """Меняет видимость будущей карточки, не публикуя её."""
        await interaction.response.defer()
        updated = await self.bot.listings.edit(self.owner, self.draft["id"], self.draft["revision"], {"hidden": not self.draft["hidden"]})
        await show_draft(self.bot, interaction, updated)

    async def preview(self, interaction: discord.Interaction) -> None:
        """Показывает актуальный английский текст до подтверждения публикации."""
        await interaction.response.defer()
        current = await self.bot.listings.review(self.owner, self.draft["id"], self.draft["revision"])
        await show_draft(self.bot, interaction, current, preview=True)


class ConditionsModal(PersonalModal):
    """Количество и цена задаются целыми, цена всегда за выбранную единицу."""

    def __init__(self, bot: "TraderBot", draft: dict[str, Any]):
        """Заполняет форму уже введёнными значениями черновика."""
        super().__init__(bot, draft["owner_id"], "Условия объявления")
        self.draft = draft
        specs = [("quantity", f"Количество ({draft['unit']}), целое", str(draft["quantity"]), True, 15),
                 ("price", f"Цена за 1 {draft['unit']}, UEC", str(draft["price"]) if draft["price"] is not None else None, True, 30),
                 ("quality", "Качество 1–1000 (необязательно)", str(draft["quality"]) if draft["quality"] is not None else None, False, 4),
                 ("location", "Место встречи (необязательно)", draft.get("location") or DEFAULT_LOCATION, False, 120),
                 ("description", "Описание по-русски / условия обмена", draft["description_ru"] or None, False, 1000)]
        self.fields = {}
        for key, label, default, required, limit in specs:
            item = discord.ui.TextInput(label=label[:45], default=default, required=required, max_length=limit,
                                        placeholder="Пусто — By arrangement" if key == "location" else None,
                                        style=discord.TextStyle.paragraph if key == "description" else discord.TextStyle.short)
            self.fields[key] = item
            self.add_item(item)

    async def on_submit(self, interaction: discord.Interaction) -> None:
        """Проверяет числа и переводит условия до показа предпросмотра."""
        await interaction.response.defer()
        updated = await self.bot.listings.edit(self.owner, self.draft["id"], self.draft["revision"],
                                               {"conditions": {key: str(item) for key, item in self.fields.items()}})
        await show_draft(self.bot, interaction, updated)


class PhotoModal(PersonalModal):
    """Получает один JPG/PNG через штатный FileUpload discord.py 2.7."""

    def __init__(self, bot: "TraderBot", draft: dict[str, Any]):
        """Отправка без файла удаляет фото из черновика."""
        super().__init__(bot, draft["owner_id"], "Фото товара")
        self.draft = draft
        self.upload = discord.ui.FileUpload(required=False, min_values=0, max_values=1)
        self.add_item(discord.ui.Label(text="Фото товара", description="JPG/PNG до 7 МБ. Без файла — убрать текущее фото.", component=self.upload))

    async def on_submit(self, interaction: discord.Interaction) -> None:
        """Проверяет размер до загрузки файла и сохраняет только фото своего черновика."""
        await interaction.response.defer()
        await self.bot.listings.draft(self.owner, self.draft["id"])
        photo = None
        if self.upload.values:
            attachment = self.upload.values[0]
            if attachment.size > MAX_PHOTO:
                raise ValueError("Фото должно быть не больше 7 МБ.")
            photo = await attachment.read()
        updated = await self.bot.listings.edit(self.owner, self.draft["id"], self.draft["revision"], {"photo": photo})
        await show_draft(self.bot, interaction, updated)


class PreviewView(PersonalView):
    """Явное подтверждение конкретной версии объявления."""

    def __init__(self, bot: "TraderBot", draft: dict[str, Any]):
        """Помечает тестовый режим отдельно от реальной публикации."""
        super().__init__(bot, draft["owner_id"])
        self.draft = draft
        self.button("Опубликовать на UEX" if bot.listings.mode == "production" else "Проверить без публикации",
                    self.publish, row=0, style=discord.ButtonStyle.success)
        self.button("Изменить", self.back, row=0)
        self.menu_button(1)

    async def back(self, interaction: discord.Interaction) -> None:
        """Возвращает настройки того же черновика."""
        await interaction.response.defer()
        current = await self.bot.listings.draft(self.owner, self.draft["id"])
        await show_draft(self.bot, interaction, current)

    async def publish(self, interaction: discord.Interaction) -> None:
        """Создаёт карточку однократно и не обещает завершённую модерацию."""
        await interaction.response.defer()
        result = await self.bot.listings.publish(self.owner, self.draft["id"], self.draft["revision"])
        text = "Проверка UEX пройдена. Это тест: настоящая карточка не создавалась."
        view = ListingsHome(self.bot, self.owner)
        if result["status"] == "created":
            remote = str(result["result"]["id_listing"])
            text = f"Объявление №{remote} создано. Оно может ожидать модерации UEX."
            if self.draft.get("photo") and not result["result"].get("url_image"):
                text += "\nUEX не подтвердил фото — проверь его на сайте."
            view.add_item(discord.ui.Button(label="Открыть на UEX", url=f"https://uexcorp.space/marketplace/item/info?id={remote}", row=2))
            view.add_item(discord.ui.Button(label="Редактировать на UEX", url=f"https://uexcorp.space/marketplace/edit/id/{remote}/", row=2))
        await render(interaction, content=text, view=view)


async def show_own(bot: "TraderBot", interaction: discord.Interaction, owner: str) -> None:
    """Читает свои карточки и объясняет границу полноты списка."""
    if not interaction.response.is_done():
        await interaction.response.defer()
    rows = await bot.listings.own(owner)
    text = ("Твои объявления: активные с UEX и новые карточки, созданные ботом. Скрытые и ожидающие модерации карточки, "
            "созданные на сайте, могут отсутствовать; активных UEX возвращает до 100.")
    if not rows:
        text += "\nВ этом списке пока нет объявлений. Полный список доступен на UEX."
    await render(interaction, content=text, view=OwnView(bot, owner, rows) if rows else ListingsHome(bot, owner))


class OwnView(PersonalView):
    """Личный список объявлений с выбором конкретного объекта управления."""

    def __init__(self, bot: "TraderBot", owner: str, rows: list[dict[str, Any]], page: int = 0):
        """Строит страницу по десять карточек, включая неподтверждённое удаление."""
        super().__init__(bot, owner)
        self.rows, self.page = rows, page
        self.selection = discord.ui.Select(placeholder="Выбери своё объявление", row=0, options=[
            discord.SelectOption(label=row["title"][:100], value=row["id"],
                                 description=f"№{row['external_id']} · {STATUSES.get(row['status'], row['status'])}"[:100])
            for row in rows[page * 10:(page + 1) * 10]])
        self.selection.callback = self.selected
        self.add_item(self.selection)
        self.button("←", self.previous, row=1, disabled=page == 0)
        self.button("→", self.following, row=1, disabled=(page + 1) * 10 >= len(rows))
        self.add_item(discord.ui.Button(label="Все объявления на UEX", url=MANAGE_URL, row=2))
        self.menu_button(2)

    async def selected(self, interaction: discord.Interaction) -> None:
        """Открывает свою карточку с отдельной кнопкой удаления."""
        await interaction.response.defer()
        row = await self.bot.listings.advertisement(self.owner, self.selection.values[0])
        await render(interaction, content=f"**{discord.utils.escape_markdown(row['title'])}**\n№{row['external_id']} · {STATUSES.get(row['status'], row['status'])}",
                     view=ManageView(self.bot, self.owner, row))

    async def previous(self, interaction: discord.Interaction) -> None:
        """Показывает предыдущую страницу своих объявлений."""
        await render(interaction, content="Твои объявления.", view=OwnView(self.bot, self.owner, self.rows, self.page - 1))

    async def following(self, interaction: discord.Interaction) -> None:
        """Показывает следующую страницу своих объявлений."""
        await render(interaction, content="Твои объявления.", view=OwnView(self.bot, self.owner, self.rows, self.page + 1))


class ManageView(PersonalView):
    """Переход на сайт и отдельное подтверждение удаления выбранной карточки."""

    def __init__(self, bot: "TraderBot", owner: str, row: dict[str, Any], *, confirm: bool = False):
        """Подтверждение относится к конкретному локальному id и аккаунту UEX."""
        super().__init__(bot, owner)
        self.record, self.confirm = row, confirm
        self.add_item(discord.ui.Button(label="Открыть на UEX", url=f"https://uexcorp.space/marketplace/item/info?id={row['external_id']}", row=0))
        self.add_item(discord.ui.Button(label="Редактировать на UEX", url=f"https://uexcorp.space/marketplace/edit/id/{row['external_id']}/", row=0))
        label = (f"Да, удалить №{row['external_id']}" if bot.listings.mode == "production" else "Проверить удаление (тест)") if confirm else "Удалить объявление"
        self.button(label, self.remove, row=1, style=discord.ButtonStyle.danger,
                    disabled=row["status"] not in {"active", "created", "unconfirmed"})
        self.button("Мои объявления", self.back, row=2)
        self.menu_button(2)

    async def back(self, interaction: discord.Interaction) -> None:
        """Возвращает обновлённый список только своих объявлений."""
        await show_own(self.bot, interaction, self.owner)

    async def remove(self, interaction: discord.Interaction) -> None:
        """Спрашивает подтверждение, затем удаляет ровно выбранную карточку один раз."""
        await interaction.response.defer()
        row = await self.bot.listings.advertisement(self.owner, self.record["id"])
        if not self.confirm:
            await render(interaction, content=(f"Удалить **{discord.utils.escape_markdown(row['title'])}** (№{row['external_id']}) "
                         f"из аккаунта **{discord.utils.escape_markdown(row['account'])}**?\n"
                         "Объявление будет удалено с UEX. Это не завершает отдельные переговоры. История Discord останется."),
                         view=ManageView(self.bot, self.owner, row, confirm=True))
            return
        result = await self.bot.listings.remove(self.owner, row["id"])
        if result.get("already_missing"):
            text = f"Объявление №{row['external_id']} больше недоступно на UEX и убрано из списка бота."
        elif result["status"] == "deleted":
            text = f"Объявление №{row['external_id']} удалено с UEX."
        else:
            text = "Тест удаления пройден. Объявление на UEX сохранено."
        await render(interaction, content=text, view=ListingsHome(self.bot, self.owner))
