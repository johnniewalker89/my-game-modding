"""Поиск ссылки на нужную версию в публичном официальном индексе CIG."""

import re
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen

from patch_alerts.events import NOTES_URL

MAX_INDEX_BYTES = 1024 * 1024


class NotesLinks(HTMLParser):
    """Собирает видимый текст ссылок, не исполняя HTML или скрипты."""

    def __init__(self):
        """Создаёт пустой список ссылок официального индекса."""
        super().__init__(convert_charrefs=True)
        self.links = []
        self.href = None
        self.text = []

    def handle_starttag(self, tag, attrs):
        """Запоминает href начала ссылки из attrs."""
        if tag == "a":
            self.href = dict(attrs).get("href")
            self.text = []

    def handle_data(self, data):
        """Собирает видимые части data внутри ссылки."""
        if self.href:
            self.text.append(data)

    def handle_endtag(self, tag):
        """Сохраняет закончившуюся ссылку и её текст."""
        if tag == "a" and self.href:
            self.links.append((self.href, " ".join(self.text)))
            self.href = None


def version_tuple(value: str) -> tuple[int, ...]:
    """Сравнивает версии value, считая 4.10 и 4.10.0 одной версией."""
    parts = [int(part) for part in value.split(".")]
    while len(parts) > 2 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def find_notes(html: str, version: str) -> str:
    """Возвращает только официальную ссылку с точной version; пустую при неоднозначности."""
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version):
        return ""
    parser = NotesLinks()
    parser.feed(html)
    matches = set()
    for href, text in parser.links:
        found = re.search(r"Star\s+Citizen\s+Alpha\s+(\d+\.\d+(?:\.\d+)?)(?![\d.])", text, re.I)
        url = urljoin(NOTES_URL, href)
        parsed = urlsplit(url)
        if (not found or re.search(r"\b(?:PTU|EPTU|Evocati)\b", text, re.I)
                or version_tuple(found[1]) != version_tuple(version)):
            continue
        if (parsed.scheme == "https" and parsed.netloc == "robertsspaceindustries.com"
                and re.fullmatch(r"/(?:en/)?comm-link/Patch-Notes/\d+-[A-Za-z0-9-]+", parsed.path)
                and not parsed.query and not parsed.fragment):
            matches.add(url)
    return next(iter(matches)) if len(matches) == 1 else ""


def fetch_notes(version: str) -> str:
    """Ищет version в публичном индексе; сетевой отказ передаёт вызывающему без догадок."""
    request = Request(NOTES_URL, headers={"User-Agent": "SC-Companion/0.1"})
    with urlopen(request, timeout=8) as response:
        raw = response.read(MAX_INDEX_BYTES + 1)
    if len(raw) > MAX_INDEX_BYTES:
        raise ValueError("notes_index_too_large")
    return find_notes(raw.decode("utf-8"), version)
