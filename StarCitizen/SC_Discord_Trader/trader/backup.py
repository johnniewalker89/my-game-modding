"""Согласованная копия SQLite для внешнего бэкапа без остановки worker."""

import os
import sqlite3
import tempfile
from contextlib import closing
from datetime import datetime
from pathlib import Path


def recovery_path(database: Path) -> Path:
    """Возвращает постоянное место последней целостной копии рядом с рабочей базой."""
    return database.parent / "recovery" / database.name


def create_snapshot(source: Path, destination: Path) -> None:
    """Копирует подтверждённые транзакции, включая WAL, и атомарно заменяет прежний снимок."""
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, filename = tempfile.mkstemp(prefix=destination.name + ".", suffix=".tmp", dir=destination.parent)
    os.close(descriptor)
    temporary = Path(filename)
    try:
        with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)) as live:
            with closing(sqlite3.connect(temporary)) as copy:
                live.backup(copy, pages=256, sleep=0.05)
                if copy.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                    raise sqlite3.DatabaseError("Резервная копия не прошла проверку целостности")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def restore_if_missing(database: Path) -> bool:
    """Восстанавливает базу из recovery только при её отсутствии после внешнего восстановления."""
    saved = recovery_path(database)
    if database.exists() or not saved.exists():
        return False
    if any(Path(str(database) + suffix).exists() for suffix in ("-wal", "-shm")):
        raise RuntimeError("Перед восстановлением базы проверь оставшиеся WAL/SHM при остановленном боте")
    create_snapshot(saved, database)
    return True


def backup_due(saved: Path, clock: str, now: datetime) -> bool:
    """Первый снимок создаётся сразу, последующие — раз в сутки после заданного местного времени."""
    if not clock:
        return False
    if not saved.exists():
        return True
    return (now.strftime("%H:%M") >= clock
            and datetime.fromtimestamp(saved.stat().st_mtime).date() < now.date())
