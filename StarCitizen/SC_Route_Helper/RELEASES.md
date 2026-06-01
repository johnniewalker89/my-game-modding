# SC Route Helper Releases

## v1.0.0

- Первый стабильный релиз SC Route Helper.
- WinForms launcher на PowerShell.
- Запись фрагмента `Game.log`: `Начать запись` -> `Остановить и разобрать`.
- Поиск `30000` через `CNetChannel::InactivityTimerCallback` и `remoteAddr`.
- Накопление IP-кандидатов.
- Создание отдельного `lists\ipset-starcitizen.txt`.
- Создание нового `_SC_...bat` на основе выбранного zapret bat.
- `ipset-all.txt` не меняется, zapret автоматически не запускается.

### Кратко как пользоваться

1. Установите и настройте [zapret](https://github.com/flowseal/zapret-discord-youtube), чтобы у вас уже был рабочий zapret `.bat`.
2. Скачайте [SC_Route_Helper_v1.0.0.zip](https://github.com/johnniewalker89/my-game-modding/releases/download/sc-route-helper-v1.0.0/SC_Route_Helper_v1.0.0.zip) из этого релиза.
3. Распакуйте архив и запустите `SC_Route_Helper.bat`.
4. Выберите папку игры `StarCitizen\LIVE`.
5. Выберите рабочий zapret `.bat`, на основе которого нужно создать новый.
6. Нажмите `Проверить игру`.
7. Нажмите `Начать запись`, запустите Star Citizen и доведите игру до ошибки `30000`.
8. Вернитесь в helper и нажмите `Остановить и разобрать`.
9. Нажмите `Показать IP`, если хотите посмотреть накопленный список.
10. Нажмите `Создать bat`, затем запускайте созданный `_SC_...bat` вместо старого.
