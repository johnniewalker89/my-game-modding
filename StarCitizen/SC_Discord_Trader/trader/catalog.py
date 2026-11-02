"""Русские подписи каталога; идентификаторы и названия товаров остаются данными UEX."""

LABELS = {
    "Armor": "Броня", "Arms": "Руки", "Backpacks": "Рюкзаки", "Helmets": "Шлемы",
    "Legs": "Ноги", "Torso": "Корпус", "Full Set": "Полный комплект",
    "Clothing": "Одежда", "Footwear": "Обувь", "Gloves": "Перчатки", "Hats": "Головные уборы",
    "Jackets": "Куртки", "Jumpsuits": "Комбинезоны", "Legwear": "Брюки", "Shirts": "Рубашки",
    "Miscellaneous": "Разное", "Consumables": "Расходники", "Consumable": "Расходные материалы",
    "Personal Weapons": "Личное оружие", "Weapons": "Оружие", "Attachments": "Обвесы",
    "Systems": "Системы", "Coolers": "Охладители", "Liveries": "Окраски",
    "Power Plants": "Энергоустановки", "Quantum Drives": "Квантовые двигатели",
    "Shield Generators": "Генераторы щита", "Undersuits": "Поддоспешники",
    "Utility": "Оборудование", "Docking Collars": "Стыковочные узлы",
    "External Fuel Tanks": "Внешние топливные баки", "Fuel Nozzle": "Заправочные насадки",
    "Gadgets": "Гаджеты", "Mining Laser Heads": "Горные лазеры", "Mining Modules": "Горные модули",
    "Scraper Beams": "Скребковые установки", "Vehicle Weapons": "Корабельное оружие",
    "Guns": "Пушки", "Missile Racks": "Ракетные подвесы", "Missiles": "Ракеты", "Turrets": "Турели",
    "Commodities": "Сырьё", "Data": "Данные", "Points of Interest": "Точки интереса", "Other": "Прочее",
    "Drinks": "Напитки", "Foods": "Еда", "Container": "Контейнеры", "Tractor Beams": "Тяговые лучи",
    "Eyeware": "Очки", "Bombs": "Бомбы", "Dresses": "Платья", "Technology": "Технологии",
    "Mobiglas": "МобиГлас", "Module": "Модули", "Decorations": "Украшения",
    "Point Defense Cannon": "Орудия ближней обороны", "Torpedo Tubes": "Торпедные аппараты",
    "Batteries": "Аккумуляторы", "Avionics": "Авионика", "Flight Blade": "Бортовые вычислители",
    "Radar": "Радары", "Gravity Generator": "Генераторы гравитации", "Propulsion": "Двигатели",
    "Jump Modules": "Прыжковые модули", "Harvestables": "Собираемые ресурсы",
    "Bomb Racks": "Бомбовые подвесы", "Vehicles": "Техника", "Life Support Generator": "Жизнеобеспечение",
    "Flair": "Декор", "Surface": "Поверхности", "Fabricator": "Фабрикаторы",
    "Salvage Beams": "Установки утилизации", "Cards": "Карты доступа", "Storage": "Накопители",
}


def category_label(row: dict) -> str:
    """Переводит известные категории и не повторяет одинаковые раздел/подкатегорию."""
    section = LABELS.get(row.get("section"), row.get("section") or "")
    name = LABELS.get(row["name"], row["name"])
    return f"{section} → {name}" if section and section != name else name
