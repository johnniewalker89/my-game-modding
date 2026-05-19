# SCMDB Quest Recipe Patcher

Патчер для русской локализации Star Citizen. Он добавляет в контракты информацию о рецептах/чертежах, которые можно получить за выполнение миссий.

## Обязательное требование

Сначала должен быть установлен русский перевод Star Citizen.

Рекомендуемый русификатор: [RuSC](https://www.expanseunion.com/sc/locru).

Обычный порядок:

1. Обновить Star Citizen.
2. Запустить RuSC, чтобы он создал свежий `global.ini`.
3. Запустить этот патчер.

Патчер не заменяет русификатор. Он только дополняет уже готовый файл локализации.

## Что скачать

Для обычной установки скачайте архив `SCMDB_Quest_Recipe_Patcher_v2.0.0.zip` из GitHub Releases, распакуйте его в удобную папку и запустите `SCMDB_Quest_Recipe_Patcher.bat`.

## Как запустить

Самый простой вариант:

1. Запустите `SCMDB_Quest_Recipe_Patcher.bat`.
2. В открывшемся окне выберите папку `StarCitizen\LIVE`.
3. Нажмите `Проверить`.
4. Если проверка выглядит нормально, нажмите `Пропатчить`.

Путь обычно выглядит так:

```text
C:\Games\StarCitizen\LIVE
```

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

## Источники данных

- [SCMDB](https://scmdb.net/) — связь контрактов и рецептов.
- [Star Citizen Wiki API](https://api.star-citizen.wiki/) — типы предметов, размеры, grade, class и производители.
- `data/blueprint-overrides.ru.json` — локальные подтверждённые правки и исключения.

Если внешний источник временно недоступен, патчер использует локальный cache и fallback-распознавание.

## Backup и rollback

Перед реальной записью создаётся backup:

```text
backups\global.ini.YYYYMMDD-HHMMSS.scmdb-recipes.bak
```

В launcher есть кнопка `Откатить backup`, которая восстанавливает последний backup.

## Отчёты

Отчёты пишутся в:

```text
reports\
```

В отчёте есть:

- версия SCMDB;
- сколько строк изменено;
- сколько рецептов найдено через Wiki API;
- сколько найдено через overrides;
- сколько распознано паттернами;
- список `unknownBlueprints`.

## Продвинутый запуск

Проверка без изменения файла:

```powershell
.\SCMDB_Quest_Recipe_Patcher.ps1 "C:\Games\StarCitizen\LIVE" -DryRun
```

Запуск без Wiki API:

```powershell
.\SCMDB_Quest_Recipe_Patcher.ps1 "C:\Games\StarCitizen\LIVE" -NoWikiEnrichment
```

Откат последнего backup:

```powershell
.\SCMDB_Quest_Recipe_Patcher.ps1 "C:\Games\StarCitizen\LIVE" -RestoreLatestBackup
```
