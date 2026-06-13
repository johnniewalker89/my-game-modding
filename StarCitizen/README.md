# Star Citizen

Моды и инструменты для Star Citizen.

## Скачать

### SC Mod Launcher

Основной проект: лаунчер модулей для безопасных правок `global.ini`.

Что умеет:

- `Майнинг и крафт`: подсказки по добыче на планетах и лунах, состав предметов в описаниях и вложенный выбор конкретных семейств рецептов: корабельные компоненты, орудия, добывающие лазеры, броня и FPS-оружие.
- `Квесты и рецепты`: списки чертежей в наградах контрактов, маркеры `[Ч]`, `[А]`, `[С]`, подсказки репутации, вложенные фильтры конкретных семейств рецептов, подсветка выгодных фарм-квестов и Wikelo-подсказки в предметах.
- `Русификатор`: установка, обновление и удаление RuSC прямо из лаунчера. SC Mod Launcher использует перевод ру сообщества [StarCitizenRu](https://github.com/n1ghter/StarCitizenRu) и точечно дополняет его под свои модули.
- `Backup`: восстановление последнего или выбранного `global.ini`, удаление старых backup-файлов из лаунчера.
- `Обновления`: проверка GitHub Releases, скачивание ZIP, SHA-256 проверка, самообновление с сохранением backup/config и обновлением кэша из релиза.

Как поставить:

1. Скачайте `SC_Mod_Launcher_2.0.0.zip` на странице [Releases](https://github.com/johnniewalker89/my-game-modding/releases/tag/sc-mod-launcher-v2.0.0).
2. Откройте архив и извлеките из него папку `SC_Mod_Launcher` в удобное место. Не используйте внешнюю папку `SC_Mod_Launcher_2.0.0` как рабочую.
3. Запустите `SC_Mod_Launcher\SC_Mod_Launcher.exe`.
4. Проверьте путь к `StarCitizen\LIVE`.
5. На вкладке `Русификатор` установите или обновите RuSC, если он ещё не стоит. Если RuSC уже был установлен вручную или старой версией лаунчера, рекомендуем удалить его и поставить заново через лаунчер, чтобы появились metadata версии.
6. Нажмите `Проверить`, при необходимости `Прогреть кэш`, затем `Применить в LIVE`.

SHA-256 релиза `2.0.0`:

```text
BB8B25CEE158AAF85F267FF9EA24664FC4319CC7C9404AB8011B8FEBA7F7A166
```

Подробности: [SC_Mod_Launcher/README.md](SC_Mod_Launcher/README.md).

## Как выглядит SC Mod Launcher в игре

### Квесты и рецепты

Лаунчер добавляет в описания контрактов список чертежей, которые можно получить за миссию, и оставляет только выбранные категории.

Метки в названии контракта:

- `[Ч]` — в награде есть выбранные категории чертежей.
- `[А]` — контракт для асов-пилотов.
- `[С]` — в награде есть скрипты; особенно выгодные контракты дополнительно подсвечиваются синим.

<table>
  <tr>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-contract-recipes.png" alt="Метки контрактов, репутация и список доступных чертежей"></td>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-farm-contract-highlight.png" alt="Подсветка выгодного фарм-квеста"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-wikelo-item-orders.png" alt="Wikelo-заказы в описании предмета"></td>
  </tr>
</table>

### Майнинг и крафт

На планетах и лунах показываются ресурсы по способам добычи и рецепты предметов, которые можно собрать из местных ресурсов.

<table>
  <tr>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-item-craft-composition.png" alt="Состав предмета в инвентаре"></td>
    <td width="50%"><img src="SC_Mod_Launcher/docs/images/sc-mod-launcher-mining-map-hints.png" alt="Подсказки добычи и крафта на карте Mobiglas"></td>
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

