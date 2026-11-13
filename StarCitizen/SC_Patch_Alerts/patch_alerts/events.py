"""Чтение публичной RSS и подготовка русских карточек без модели."""

import hashlib
import json
import re
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from datetime import datetime, timezone, timedelta
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from urllib.parse import urlparse

FEED_URL = "https://status.robertsspaceindustries.com/index.xml"
NOTES_URL = "https://robertsspaceindustries.com/en/patch-notes"
MSK = timezone(timedelta(hours=3))
MAX_FEED_BYTES = 1024 * 1024


class PlainText(HTMLParser):
    """Извлекает текст HTML, пропуская удалённые условия и служебные блоки."""

    def __init__(self):
        """Создаёт пустой сборщик текстовых фрагментов."""
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.ignored = 0

    def handle_starttag(self, tag, attrs):
        """Учитывает начало удалённого блока и разделители текста."""
        if tag in {"s", "del", "script", "style"}:
            self.ignored += 1
        if tag in {"p", "br", "li", "div"}:
            self.parts.append(" ")

    def handle_endtag(self, tag):
        """Завершает удалённый блок или абзац."""
        if tag in {"s", "del", "script", "style"} and self.ignored:
            self.ignored -= 1
        if tag in {"p", "li", "div"}:
            self.parts.append(" ")

    def handle_data(self, data):
        """Сохраняет видимый фрагмент data."""
        if not self.ignored:
            self.parts.append(data)


def plain_text(value: str) -> str:
    """Возвращает видимый текст HTML value с обычными пробелами."""
    parser = PlainText()
    parser.feed(value)
    return re.sub(r"\s+", " ", "".join(parser.parts)).strip()


@dataclass(frozen=True)
class Event:
    """Содержит только подтверждённые поля одного официального события."""

    source_url: str
    phase: str
    published_at: str
    version: str = ""
    starts_at: str = ""
    demo: bool = False
    duration_minutes: int = 0
    duration_kind: str = ""
    finished_at: str = ""
    notes_url: str = ""

    @property
    def fingerprint(self) -> str:
        """Идентифицирует существенное содержание карточки, без истории правок источника."""
        material = {key: value for key, value in asdict(self).items() if key not in {"published_at", "notes_url"}}
        return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()


def parse_feed(raw: bytes, now: datetime) -> list[tuple[str, Event | None]]:
    """Разбирает RSS raw; now нужен для отсечения будущих публикаций и устаревших планов."""
    if len(raw) > MAX_FEED_BYTES or b"<!DOCTYPE" in raw.upper():
        raise ValueError("Недопустимый размер или формат RSS")
    root = ET.fromstring(raw)
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Источник не вернул RSS")
    result = []
    for item in root.findall("channel/item"):
        url = item.findtext("link", "").strip()
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.netloc != "status.robertsspaceindustries.com":
            continue
        result.append((url, _event(item, url, now)))
    if not result:
        raise ValueError("RSS не содержит корректных записей")
    return result


def timeline_time(body: str, phrase: str, *, latest: bool = False) -> str:
    """Находит время phrase только под явной датой Updates в body; latest выбирает последнее."""
    markers = list(re.finditer(r"\[(\d{4}-\d{2}-\d{2})\s+Updates\]|\b(\d{2}):?(\d{2})\s*UTC\s*-\s*", body, re.I))
    date = None
    found = []
    for index, marker in enumerate(markers):
        if marker[1]:
            date = marker[1]
            continue
        if not date:
            continue
        end = markers[index + 1].start() if index + 1 < len(markers) else len(body)
        if not re.search(phrase, body[marker.end():end], re.I):
            continue
        try:
            found.append(datetime.fromisoformat(f"{date}T{marker[2]}:{marker[3]}:00+00:00"))
        except ValueError:
            continue
    return (max(found) if latest else min(found)).isoformat() if found else ""


def duration_estimate(body: str) -> tuple[int, str]:
    """Читает явную оценку длительности body, сохраняя различие «до» и «около»."""
    match = re.search(r"(not expected to exceed|expected to (?:take|last)|approximately|around|about)\s*~?\s*(\d+(?:\.\d+)?)\s*(hours?|minutes?)\b", body, re.I)
    if not match:
        return 0, ""
    minutes = float(match[2]) * (60 if match[3].lower().startswith("hour") else 1)
    if minutes <= 0 or not minutes.is_integer():
        return 0, ""
    return int(minutes), "up_to" if match[1].lower() == "not expected to exceed" else "about"


def _event(item: ET.Element, url: str, now: datetime) -> Event | None:
    """Распознаёт ограниченные явные формулировки CIG; неоднозначный текст пропускает."""
    try:
        published = parsedate_to_datetime(item.findtext("pubDate", ""))
    except (ValueError, TypeError):
        return None
    if published.tzinfo is None or published > now:
        return None
    categories = [(category.text or "").strip() for category in item.findall("category")]
    title = item.findtext("title", "")
    body = plain_text(item.findtext("description", ""))
    if re.search(r"\b(?:PTU|EPTU|Evocati)\b", title, re.I):
        return None
    # В RSS RSI category содержит дату обновления; явный LIVE-заголовок сохраняет область.
    dated_categories = bool(categories) and all(re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", value) for value in categories)
    if "persistent universe" not in " ".join(categories).lower() and not (
            dated_categories and re.search(r"\blive (?:deployment|service maintenance)\b", title, re.I)):
        return None
    if not re.search(r"live (?:deployment|service maintenance)|hotfix", title, re.I):
        return None
    version_match = re.search(r"\b(?:alpha|patch|version)\s+(?:sc-alpha-)?(\d+\.\d+(?:\.\d+)?)\b", body, re.I)
    if not version_match:
        version_match = re.search(r"\b(\d+\.\d+(?:\.\d+)?)-live\.\d+\b", body, re.I)
    version = version_match.group(1) if version_match else ""
    minutes, kind = duration_estimate(body)
    started = timeline_time(body, r"matchmaking disabled|maintenance(?: window)? begins|servers offline")
    finished = timeline_time(body, r"maintenance complete|rollout complete|patch deployment complete|servers (?:online|open)|(?:was|has been) deployed", latest=True)
    resolved = bool(re.search(r"\[resolved\]", title, re.I))
    if resolved:
        if version and re.search(r"(?:was|has been) deployed|patch deployment complete|patch download.*available|available for download", body, re.I):
            return Event(url, "released", published.isoformat(), version, started,
                         duration_minutes=minutes, duration_kind=kind, finished_at=finished)
        if re.search(r"maintenance complete|servers (?:online|open)|rollout complete", body, re.I):
            return Event(url, "completed", published.isoformat(), starts_at=started,
                         duration_minutes=minutes, duration_kind=kind, finished_at=finished)
        return None
    if re.search(r"currently.*maintenance|is being applied|deployment (?:has begun|in.progress)|rollout (?:has begun|in.progress)", body, re.I):
        return Event(url, "installing", published.isoformat(), version, started,
                     duration_minutes=minutes, duration_kind=kind)
    schedule = re.search(r"(?:starting|scheduled)\s+(?:on\s+|for\s+)?(\d{4}-\d{2}-\d{2})\s*(?:at|@)\s*(\d{2}):?(\d{2})\s*UTC", body, re.I)
    if schedule:
        try:
            start = datetime.fromisoformat(f"{schedule[1]}T{schedule[2]}:{schedule[3]}:00+00:00")
        except ValueError:
            return None
        if start > now:
            return Event(url, "scheduled", published.isoformat(), version, start.isoformat())
    return None


def msk_time(value: str) -> str:
    """Показывает компактную дату и ISO-время value по Москве без зависимости от TZ процесса."""
    moment = datetime.fromisoformat(value).astimezone(MSK)
    return moment.strftime("%d.%m · %H:%M МСК")


def build_payload(event: Event, previous: Event | None = None) -> dict:
    """Создаёт компактный новый пост; previous нужен только для старого времени при переносе."""
    url = event.source_url
    if event.phase == "scheduled":
        changed = previous is not None and previous.starts_at != event.starts_at
        title = "⏱ Перенос обновления" if changed else "⚠️ Скоро обновление LIVE"
        when = msk_time(event.starts_at)
        if changed and previous.starts_at:
            before = datetime.fromisoformat(previous.starts_at).astimezone(MSK)
            after = datetime.fromisoformat(event.starts_at).astimezone(MSK)
            old = before.strftime("%H:%M") if before.date() == after.date() else msk_time(previous.starts_at)
            description = f"~~{old}~~ → **{when}**"
        else:
            description = f"**{when}**\nУбери экипировку и сохрани корабль."
        color = 0xD2A64A
    elif event.phase == "installing":
        title = "🛠 Работы начались"
        started = datetime.fromisoformat(event.starts_at).astimezone(MSK) if event.starts_at else None
        minutes = event.duration_minutes
        pieces = [f"**{msk_time(event.starts_at)}**"] if started else []
        if minutes:
            amount = f"{minutes // 60} ч" if minutes % 60 == 0 else f"{minutes} мин"
            pieces.append(("до " if event.duration_kind == "up_to" else "≈ ") + amount)
        description = " · ".join(pieces) or "Срок окончания CIG не указал."
        if started and minutes:
            expected = started + timedelta(minutes=minutes)
            clock = expected.strftime("%H:%M МСК") if expected.date() == started.date() else msk_time(expected.isoformat())
            description += "\nОриентир: " + ("до " if event.duration_kind == "up_to" else "≈ ") + f"**{clock}**"
        color = 0x5C8DB8
    elif event.phase in {"released", "completed"}:
        title = "✅ Работы завершены"
        pieces = [f"**{msk_time(event.finished_at)}**"] if event.finished_at else []
        if event.phase == "released":
            if event.notes_url:
                pieces.append(f"[Изменения патча]({event.notes_url})")
            else:
                pieces.append(f"[Изменения: общий список]({NOTES_URL})")
        description = " · ".join(pieces) or "Подробности — в сообщении CIG."
        color = 0x56A585
    else:
        raise ValueError("Неизвестный этап события")
    if event.version:
        title += " · " + event.version
    if event.demo:
        title = "ДЕМО · " + title
    embed = {"title": title, "description": description, "color": color, "url": url}
    if event.demo:
        embed["footer"] = {"text": "Вымышленные данные"}
    return {"username": "SC Patches", "allowed_mentions": {"parse": []}, "embeds": [embed]}


def demo_payloads() -> list[dict]:
    """Готовит четыре вымышленных примера тем же formatter, что использует сканер."""
    url = "https://status.robertsspaceindustries.com/"
    first = Event(url, "scheduled", "2026-11-20T10:00:00+00:00", "DEMO.0", "2026-11-20T15:00:00+00:00", True)
    shifted = Event(url, "scheduled", first.published_at, "DEMO.0", "2026-11-20T16:00:00+00:00", True)
    installing = Event(url, "installing", first.published_at, "DEMO.0", first.starts_at, True, 120, "about")
    released = Event(url, "released", first.published_at, "DEMO.0", first.starts_at, True, 120, "about", "2026-11-20T16:35:00+00:00")
    return [{"label": label, "payload": build_payload(event, previous)} for label, event, previous in
            [("Скоро патч", first, None), ("Перенос", shifted, first), ("Начало работ", installing, None), ("Окончание работ", released, installing)]]
