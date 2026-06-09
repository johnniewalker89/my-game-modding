# SC Mod Launcher

Общий лаунчер для безопасных модов Star Citizen в зоне `global.ini`.

## Что уже есть

- выбор папки `StarCitizen\LIVE`;
- список модулей с галками;
- новый WPF launcher shell в космопиратском sci-fi стиле (`SC_Mod_Launcher.exe`);
- модуль `Квесты и рецепты`: награды, чертежи и маркеры контрактов; категории чертежей выбираются отдельно, а метка `[Ч]` зависит от выбранных категорий;
- модуль `Майнинг и крафт`: фильтр методов добычи в SCMDB-подсказках и состав предметов в описаниях;
- dry-run отчёт с краткой сводкой по выбранным модулям и ожидаемым изменениям;
- явное применение в LIVE: preflight SCMDB, backup `global.ini` и JSON-отчёт;
- вкладка `Backup` для восстановления последнего или выбранного backup `global.ini` с предварительным backup текущего LIVE;
- проверка GitHub Releases для `SC_Mod_Launcher_*.zip`, скачивание ZIP, SHA-256 verify и helper самообновления с backup текущей папки лаунчера;
- автотест WPF: лаунчер собирается, запускается, проверяет ключевые русские кнопки/разделы и закрывается без зависшего процесса.

## Важно

Это версия `1.0.0` нового продукта. Игрок запускает один проект: `SC Mod Launcher` с набором модулей.

Лаунчер должен оставаться в безопасной зоне: только `global.ini`, backup/cache/report, UI модулей и документация. Без runtime-хуков, оверлеев, памяти, сети, архивов игры и античита.

Кнопка `Проверить` проверяет источники и cache. Кнопка `Применить в LIVE` пишет настоящий `global.ini` и перед записью создаёт backup.

Вкладка `Backup` показывает найденные backup-файлы из `backups\global.ini.*.sc-mod-launcher.bak`. Можно восстановить последний или выбранный файл, а выбранный backup удалить в корзину Windows. Перед откатом лаунчер сохраняет текущий LIVE в `backups\global.ini.<date>.before-restore.bak`.

Обновление лаунчера идёт через GitHub Releases. Релизный ZIP содержит `update-manifest.json`: updater проверяет SHA-256 пакета и файлов, зеркально обновляет управляемые файлы лаунчера, удаляет устаревшие остатки старых версий и сохраняет пользовательские `backups`, прогретые cache и `updates\backups`.

## Запуск

Основной лаунчер:

```text
SC_Mod_Launcher.exe
```

Для сборки WPF-приложения из исходников:

```powershell
.\tools\Build-WpfLauncher.ps1
```

Для сборки с автозапуском smoke-теста:

```powershell
.\tools\Build-WpfLauncher.ps1 -RunSmokeTest
```

Для полного релизного прогона перед ZIP:

```powershell
.\tools\Build-ReleaseZip.ps1
```

Для консольной проверки:

```powershell
.\SC_Mod_Launcher.ps1 -LivePath "C:\Games\StarCitizen\LIVE" -DryRun
```

Для явного применения в LIVE:

```powershell
.\SC_Mod_Launcher.ps1 -LivePath "C:\Games\StarCitizen\LIVE" -ApplyLive
```
