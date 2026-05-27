# SCMDB Quest Recipe Patcher

Лёгкий патчер для русской локализации Star Citizen: добавляет в Mobiglas полезные подсказки по SCMDB-рецептам, пилотам-асам и scrip-наградам.

## Что добавляет

- Метки в списке контрактов: `[Ч]` рецепты, `[А]` пилот-ас, `[С]` scrip-награда.
- Список доступных чертежей в описании контракта.
- Крафт-подсказки на планетах и лунах: какие местные ресурсы нужны для рецептов.
- Backup, rollback и отчёты через простой Windows launcher.

Патчер меняет только файл локализации `global.ini`. Он не трогает архивы игры, исполняемые файлы, EasyAntiCheat, аккаунт, баланс или награды.

## Установка

1. Установите русский перевод [RuSC](https://www.expanseunion.com/sc/locru).
2. Скачайте [SCMDB_Quest_Recipe_Patcher_v2.2.2.zip](https://github.com/johnniewalker89/my-game-modding/releases/download/v2.2.2/SCMDB_Quest_Recipe_Patcher_v2.2.2.zip).
3. Распакуйте архив в любую удобную папку.
4. Запустите `SCMDB_Quest_Recipe_Patcher.bat`.
5. Выберите папку `StarCitizen\LIVE` и нажмите `Пропатчить`.

После обновления игры или RuSC просто запустите патчер ещё раз.

## Как выглядит в игре

![Метки и список рецептов брони/оружия](docs/images/scmdb-recipe-patcher-armor.png)

![Корабельные компоненты и орудия](docs/images/scmdb-recipe-patcher-components.png)

![Крафт-подсказки на карте Mobiglas: Lyria](docs/images/scmdb-recipe-patcher-planet-hints-lyria.png)

## Последний релиз

`v2.2.2` исправляет редкий цветовой баг в одном контракте InterSec, где исходный текст оставлял незакрытый цветовой тег и SCMDB-блок мог стать синим.

История изменений: [RELEASES.md](RELEASES.md)
