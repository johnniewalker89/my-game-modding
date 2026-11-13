"""Публичное чтение RSI Status и сохранение новых уведомлений перед доставкой."""

import json
import hashlib
import logging
import os
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from patch_alerts.events import FEED_URL, MAX_FEED_BYTES, Event, build_payload, parse_feed
from patch_alerts.locking import state_lock

LOGGER = logging.getLogger(__name__)


def read_json(path: Path, default: dict) -> dict:
    """Читает объект из path; отсутствие файла отличается от повреждённого состояния."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    if not isinstance(value, dict):
        raise ValueError("Ожидался JSON-объект")
    return value


def write_json(path: Path, value: dict) -> None:
    """Атомарно записывает value в собственный файл path."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def read_state(path: Path) -> dict:
    """Проверяет структуру очереди path даже при ответе304; повреждение не сбрасывает историю."""
    state = read_json(path, {})
    if (type(state.get("schema", 1)) is not int or state.get("schema", 1) not in {1, 2}
            or not isinstance(state.get("known", {}), dict) or not isinstance(state.get("notices", []), list)
            or type(state.get("notice_sequence", 0)) is not int or state.get("notice_sequence", 0) < 0):
        raise ValueError("invalid_news_state")
    for item in state.get("notices", []):
        if not isinstance(item, dict):
            raise ValueError("invalid_news_notice")
        if item.get("delivery") in {"pending", "inflight", "unknown", "blocked"}:
            if not isinstance(item.get("id"), str) or not isinstance(item.get("event"), dict) or not isinstance(item.get("payload"), dict):
                raise ValueError("invalid_pending_notice")
            Event(**item["event"])
    return state


def observe(state: dict, records: list[tuple[str, Event | None]], now: datetime) -> tuple[dict, list[dict]]:
    """Сравнивает records со state, сохраняя последний понятный этап; первое чтение молчит."""
    primed_at = state.get("primed_at")
    known = state.get("known", {})
    if not isinstance(known, dict) or not isinstance(state.get("notices", []), list):
        raise ValueError("Некорректный формат состояния")
    if state.get("schema", 1) not in {1, 2}:
        raise ValueError("Неизвестная версия состояния")
    new_known = dict(known)
    sequence = state.get("notice_sequence", 0)
    if not isinstance(sequence, int) or sequence < 0:
        raise ValueError("Некорректный счётчик уведомлений")
    notices = []
    for key, event in records:
        before = known.get(key)
        if event:
            new_known[key] = asdict(event)
        elif key not in new_known:
            new_known[key] = None
        if not event or not primed_at:
            continue
        if before:
            previous = Event(**before)
            if previous.fingerprint == event.fingerprint:
                continue
            if previous.phase == event.phase and previous.version == event.version:
                if event.phase != "scheduled" or previous.starts_at == event.starts_at:
                    continue
        else:
            previous = None
            if key not in known and datetime.fromisoformat(event.published_at) < datetime.fromisoformat(primed_at):
                continue
        sequence += 1
        notice_id = hashlib.sha256(f"{key}\0{sequence}".encode()).hexdigest()[:24]
        notices.append({"id": notice_id, "delivery": "pending" if state.get("delivery_started_at") else "preview",
                        "observed_at": now.isoformat(), "event": asdict(event),
                        "intended_action": "new",
                        "payload": build_payload(event, previous)})
    history = state.get("notices", []) + notices
    pending = {"pending", "inflight", "unknown", "blocked"}
    completed = [item for item in history if item.get("delivery") not in pending][-100:]
    retained = [item for item in history if item.get("delivery") in pending or item in completed]
    return {**state, "schema": 2, "primed_at": primed_at or now.isoformat(),
            "notice_sequence": sequence, "known": new_known, "notices": retained}, notices


def fetch_feed(last_modified: str = "") -> tuple[bytes | None, str]:
    """Читает только публичную RSS; last_modified позволяет получить ответ304 без тела."""
    headers = {"User-Agent": "SC-Companion/0.1"}
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    try:
        with urlopen(Request(FEED_URL, headers=headers), timeout=8) as response:
            raw = response.read(MAX_FEED_BYTES + 1)
            if len(raw) > MAX_FEED_BYTES:
                raise ValueError("RSS превысила разрешённый размер")
            return raw, response.headers.get("Last-Modified", "")
    except HTTPError as exc:
        if exc.code == 304:
            return None, last_modified
        raise


def scan_once(data_dir: Path, now: datetime | None = None, *, activate: bool = False) -> dict:
    """Обновляет data_dir без отправок; activate включает очередь с тихим первым чтением."""
    with state_lock(data_dir):
        return _scan_locked(data_dir, now or datetime.now(timezone.utc), activate)


def _scan_locked(data_dir: Path, now: datetime, activate: bool) -> dict:
    """Читает источник под уже взятой блокировкой; activate задаёт рабочую очередь."""
    path = data_dir / "state.json"
    state = read_state(path)
    first_activation = activate and not state.get("delivery_started_at")
    raw, last_modified = fetch_feed("" if first_activation else state.get("last_modified", ""))
    notices = []
    records = None
    if raw is not None:
        records = parse_feed(raw, now)
        if first_activation:
            state = {**state, "primed_at": None, "known": {}, "delivery_started_at": now.isoformat()}
        state, notices = observe(state, records, now)
        state["last_modified"] = last_modified
        write_json(path, state)
    elif first_activation or not state.get("primed_at"):
        raise ValueError("Ответ304 до начального чтения источника")
    status = {"state": "ok", "mode": "delivery" if activate else "preview_no_sending", "checked_at": now.isoformat(),
              "last_success_at": now.isoformat(), "source": FEED_URL,
              "source_response": 304 if raw is None else 200,
              "known_items": len(state.get("known", {})), "new_notices": len(notices),
              "recorded_notices": len(state.get("notices", [])), "error": None}
    write_json(data_dir / "status.json", status)
    LOGGER.info("Источник проверен http=%s items=%s new=%s mode=%s", status["source_response"], status["known_items"], len(notices), status["mode"])
    return status


def record_failure(data_dir: Path, exc: Exception, *, mode: str = "preview_no_sending") -> None:
    """Сохраняет безопасную причину отказа exc, не сбрасывая уже просмотренную историю."""
    try:
        status = read_json(data_dir / "status.json", {})
    except (OSError, ValueError):
        status = {}
    status.update(state="degraded", mode=mode, checked_at=datetime.now(timezone.utc).isoformat(),
                  error=type(exc).__name__)
    write_json(data_dir / "status.json", status)
    LOGGER.warning("Источник не проверен error_type=%s mode=%s", type(exc).__name__, mode)
