# SCMDB Quest Recipe Patcher

Патчер показывает в контрактах Star Citizen, какие чертежи/рецепты можно получить за миссию.

## Установка

1. Установите русский перевод [RuSC](https://www.expanseunion.com/sc/locru).
2. Скачайте `SCMDB_Quest_Recipe_Patcher_v2.0.0.zip` на странице [Releases](https://github.com/johnniewalker89/my-game-modding/releases/tag/v2.0.0).
3. Распакуйте архив в любую удобную папку.
4. Запустите `SCMDB_Quest_Recipe_Patcher.bat`.
5. В открывшемся окне выберите папку `StarCitizen\LIVE`.
6. Нажмите `Пропатчить`.

Путь обычно выглядит так:

```text
C:\Games\StarCitizen\LIVE
```

Патчер не заменяет русификатор. Сначала запускайте RuSC, потом этот патчер.

## Что изменяется

Патчер меняет только один файл:

```text
StarCitizen\LIVE\data\Localization\korean_(south_korea)\global.ini
```

Он не изменяет архивы игры, исполняемые файлы, EasyAntiCheat, сохранения, игровые механики, баланс, награды или аккаунт.

## Что будет в игре

В списке контрактов у заданий с наградами-чертежами появится префикс:

```text
[ЧЕРТЁЖ]
```

Внизу описания контракта появится блок с рецептами:

```text
Доступные чертежи (SCMDB)

Броня/одежда:
- Antium Core Maroon — тяжёлая броня, корпус
- Antium Helmet Jet — тяжёлая броня, шлем

Корабельные компоненты:
- VK-00 — квантовый двигатель, S1, Grade A, Military
- FR-66 — щит, S1, Grade A, Military

Корабельные орудия:
- M3A Cannon — лазерная пушка, S1

Материалы/особое:
- Metamaterial Test #146 — метаматериал Wikelo
```

Если один и тот же текст описания используется несколькими вариантами миссии с разными наградами, патчер пишет:

```text
Возможные чертежи (SCMDB)
```

## После обновления игры или русификатора

1. Обновите Star Citizen.
2. Запустите RuSC.
3. Снова запустите `SCMDB_Quest_Recipe_Patcher.bat`.

## Источники данных

- [SCMDB](https://scmdb.net/) — связь контрактов и рецептов.
- [Star Citizen Wiki API](https://api.star-citizen.wiki/) — типы предметов, размеры, grade, class и производители.
- `data/blueprint-overrides.ru.json` — локальные подтверждённые правки и исключения.

Если внешний источник временно недоступен, патчер использует локальный cache и fallback-распознавание.
