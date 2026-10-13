# Star Citizen

Моды и инструменты для Star Citizen.

## Скачать

### SC Mod Launcher

Основной проект: лаунчер для установки RuSC и безопасных модульных правок `global.ini`.

Что умеет:

- `Русификатор`: установка, обновление, удаление RuSC и fallback через локальный ZIP; используется перевод [StarCitizenRu](https://github.com/n1ghter/StarCitizenRu), лаунчер только дополняет его под свои модули.
- `Майнинг и крафт`: ресурсы по способам добычи для планет, лун, кластеров, mining-баз и станций, состав предметов, ТТХ оружия/компонентов по данным Star Citizen Wiki, фильтры семейств рецептов, бонусы переработки и скупка сырой руды на refinery-станциях.
- `Квесты и рецепты`: чертежи в наградах, метки `[Ч]`, `[Ч?]`, `[А]`, `[С]`, репутация при наличии данных источника, farm-подсветка и Wikelo-подсказки в предметах.
- `Проверка и cache`: диагностика источников, прогрев свежего cache и применение в LIVE без лишних realtime-запросов.
- `Backup и обновления`: восстановление `global.ini`, GitHub Releases, SHA-256 проверка и самообновление с сохранением backup/config.

Версия `2.1.9` поддерживает Star Citizen `4.10.2` и RuSC `4.10.2-v128`. Рецепты и классификация чертежей используют SCMDB, бонусы переработки и цены руды — UEX, ТТХ — Star Citizen Wiki. Все релизные кэши заново прогреты; Wiki соответствует точному build `4.10.2-LIVE.12881860`.

Фарм-подсветка включает сценарии #5–7 и засады с ожиданием корабля в облаке за8 скриптов и выше у Headhunters, Eckhart Security и Foxwell Enforcement. Номер лаунчера в игровом меню актуализируется при применении модулей.

Варианты одной модели с одинаковыми ресурсами объединены, сохранённый выбор переносится. Для F55 Shadowflux и Monolith Shadowflux доступны полные рецепты; оборудование Рекко Баттальи выбирается в фильтрах квестов, куда можно перенести выбор из майнинга.

Очки RSI Discovery Month автоматически добавляются в начало описаний контрактов: количество и категория события, без отдельной галки, порогов и сведений о группе. Одинаковые очки общего зачёта не дублируются. После исчезновения данных события подписи удаляются при повторном применении, отсутствующие задания пропускаются.

Как поставить:

1. Скачайте `SC_Mod_Launcher_2.1.9.zip` на странице [Releases](https://github.com/johnniewalker89/my-game-modding/releases/tag/sc-mod-launcher-v2.1.9).
2. Откройте архив и извлеките из него папку `SC_Mod_Launcher` в удобное место. Не используйте внешнюю папку `SC_Mod_Launcher_2.1.9` как рабочую.
3. Запустите `SC_Mod_Launcher\SC_Mod_Launcher.exe`.
4. Проверьте путь к `StarCitizen\LIVE`.
5. На вкладке `Русификатор` установите или обновите RuSC, если он ещё не стоит. Если GitHub API не открывается, скачайте ZIP [StarCitizenRu](https://github.com/n1ghter/StarCitizenRu) вручную и нажмите `Из ZIP`. Если RuSC уже был установлен вручную или старой версией лаунчера, рекомендуем удалить его и поставить заново через лаунчер, чтобы появились metadata версии.
6. Нажмите `Проверить`, при необходимости `Прогреть кэш`, затем `Применить в LIVE`.

SHA-256 релиза `2.1.9`:

```text
14ED894A2AFD05871CF7323E7C2FE88F7D5FDC89849E57F0A902AD58F5A13F50
```

Подробности: [SC_Mod_Launcher/README.md](SC_Mod_Launcher/README.md).

Лицензия исходного кода лаунчера: [GNU GPL v3 only](SC_Mod_Launcher/LICENSE-SCOPE.md). Брендинг SCM и сторонние материалы имеют отдельные условия.

This is an unofficial Star Citizen fan project, not affiliated with the Cloud Imperium group of companies. All content not authored by the project is property of its respective owners. [Official Star Citizen website](https://robertsspaceindustries.com/).

## Как выглядит SC Mod Launcher в игре

### Квесты и рецепты

Лаунчер добавляет в описания контрактов список чертежей, которые можно получить за миссию, и оставляет только выбранные категории.

Метки в названии контракта:

- `[Ч]` — в награде есть выбранные категории чертежей.
- `[Ч?]` — общий заголовок у смешанных вариантов, где не каждый вариант содержит выбранный чертёж.
- `[А]` — контракт для асов-пилотов.
- `[С]` — в награде есть скрипты; особенно выгодные контракты дополнительно подсвечиваются синим.

<table>
  <tr>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-contract-recipes.png" alt="Метки контрактов, репутация и список доступных чертежей"></td>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-wikelo-item-orders.png" alt="Wikelo-заказы в описании предмета"></td>
  </tr>
</table>

### Репутация

Лаунчер показывает награду репутации в контрактах и точные пороги рангов в карьере. Особенно выгодные контракты со скриптами можно дополнительно подсветить.

<table>
  <tr>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-farm-contract-highlight.png" alt="Репутация и скрипты в списке контрактов"></td>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-reputation-ranks.png" alt="Пороги рангов в разделе репутации"></td>
  </tr>
</table>

### Майнинг и крафт

На планетах, лунах, астероидных кластерах, mining-базах и станциях показываются ресурсы по способам добычи и рецепты предметов, которые можно собрать из местных ресурсов. На refinery-станциях можно включить подсказки по бонусам и штрафам переработки.

<table>
  <tr>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-item-craft-composition.png" alt="Состав предмета в инвентаре"></td>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-mining-map-hints.png" alt="Подсказки добычи и крафта на карте Mobiglas"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-mining-refinery-ruin.png" alt="Бонусы переработки на станции Ruin"></td>
  </tr>
</table>

### Общие подсказки предметов

ТТХ оружия и корабельных компонентов добавляются прямо в описание предметов. Исторические скриншоты ниже показывают оформление; текущий источник — Star Citizen Wiki, фактическая версия и резервный кэш указаны в журнале.

<table>
  <tr>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-erkul-weapon-passport.png" alt="ТТХ оружия в инвентаре"></td>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-erkul-component-passport.png" alt="ТТХ компонентов на корабле"></td>
  </tr>
</table>

## SC Route Helper

Вспомогательный инструмент для диагностики сетевой ошибки `30000` и подготовки zapret bat на основе уже рабочего bat-файла.

1. Установите и настройте [zapret](https://github.com/flowseal/zapret-discord-youtube), чтобы у вас уже был рабочий zapret `.bat`.
2. Скачайте `SC_Route_Helper_v1.0.0.zip` на странице [Releases](https://github.com/johnniewalker89/my-game-modding/releases/tag/sc-route-helper-v1.0.0).
3. Распакуйте архив.
4. Запустите `SC_Route_Helper.bat`.
5. Выберите папку `StarCitizen\LIVE`.
6. Выберите рабочий zapret `.bat`, на основе которого нужно создать новый.
7. Нажмите `Проверить игру`.
8. Нажмите `Начать запись`, запустите Star Citizen и доведите игру до ошибки `30000`.
9. Вернитесь в helper и нажмите `Остановить и разобрать`.
10. Нажмите `Создать bat` и запускайте созданный `_SC_...bat` вместо старого.

Подробности: [SC_Route_Helper/README.md](SC_Route_Helper/README.md).

