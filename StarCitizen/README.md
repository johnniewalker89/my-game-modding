# Star Citizen

Моды и патчеры для Star Citizen.

## Скачать

### SC Route Helper

Помогает игроку поймать сетевую ошибку `30000` в `Game.log`, накопить IP-кандидаты Star Citizen и создать новый zapret bat на основе уже рабочего bat-файла.

1. Установите и настройте [zapret](https://github.com/flowseal/zapret-discord-youtube), чтобы у вас уже был рабочий zapret `.bat`.
2. Скачайте [SC_Route_Helper_v1.0.0.zip](https://github.com/johnniewalker89/my-game-modding/releases/download/sc-route-helper-v1.0.0/SC_Route_Helper_v1.0.0.zip).
3. Распакуйте архив.
4. Запустите `SC_Route_Helper.bat`.
5. Выберите папку `StarCitizen\LIVE`.
6. Выберите рабочий zapret `.bat`, на основе которого нужно создать новый.
7. Нажмите `Проверить игру`.
8. Нажмите `Начать запись`, запустите Star Citizen и доведите игру до ошибки `30000`.
9. Вернитесь в helper и нажмите `Остановить и разобрать`.
10. Нажмите `Создать bat` и запускайте созданный `_SC_...bat` вместо старого.

Подробная инструкция: [SC_Route_Helper/README.md](SC_Route_Helper/README.md).

### SCMDB Quest Recipe Patcher

Показывает в контрактах, какие чертежи/рецепты можно получить за миссию, где встречаются пилоты-асы и где дают обменные scrip/coin-награды.

1. Установите русский перевод [RuSC](https://www.expanseunion.com/sc/locru).
2. Скачайте `SCMDB_Quest_Recipe_Patcher_v2.2.2.zip` на странице [Releases](https://github.com/johnniewalker89/my-game-modding/releases/tag/v2.2.2).
3. Распакуйте архив.
4. Запустите `SCMDB_Quest_Recipe_Patcher.bat`.
5. Выберите папку `StarCitizen\LIVE` и нажмите `Пропатчить`.

Подробная инструкция: [SCMDB_Quest_Recipe_Patcher/README.md](SCMDB_Quest_Recipe_Patcher/README.md).

## Как выглядит в игре

![Список рецептов брони и оружия](SCMDB_Quest_Recipe_Patcher/docs/images/scmdb-recipe-patcher-armor.png)

![Список корабельных компонентов и орудий](SCMDB_Quest_Recipe_Patcher/docs/images/scmdb-recipe-patcher-components.png)

![Подсказки крафта на карте Mobiglas: Lyria](SCMDB_Quest_Recipe_Patcher/docs/images/scmdb-recipe-patcher-planet-hints-lyria.png)
