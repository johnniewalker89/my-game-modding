# Star Citizen Releases

## SCMDB Quest Recipe Patcher v2.0.0

- папка мода перенесена в `StarCitizen/SCMDB_Quest_Recipe_Patcher`;
- добавлен Windows launcher с выбором папки `StarCitizen\LIVE`;
- добавлены кнопки `Проверить`, `Пропатчить`, `Откатить backup`, `Открыть отчёты`;
- добавлено обогащение рецептов через Star Citizen Wiki API;
- добавлены группы рецептов: броня/одежда, оружие, корабельные компоненты, корабельные орудия, снаряжение/расходники, не распознано;
- добавлен cache Wiki API;
- добавлен `data/blueprint-overrides.ru.json`;
- отчёт теперь содержит `wikiMatched`, `overrideMatched`, `patternMatched`, `unknownBlueprints`;
- добавлен скрипт сборки ZIP-архива для GitHub Releases.
- проверено в игре пользователем.

## SCMDB Quest Recipe Patcher v1.0.0

- первый рабочий публичный патчер;
- источник контрактов и рецептов: SCMDB;
- патчит `StarCitizen\LIVE\data\Localization\korean_(south_korea)\global.ini`;
- создаёт backup перед записью;
- повторный запуск идемпотентен;
- подтверждён успешный тест у 3 игроков.
