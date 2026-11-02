"""Постоянные документы состояния; один процесс и один SQLite-файл."""

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any

from cryptography.fernet import Fernet


class Store:
    """Хранит документы по уникальному ключу и владельцу в локальной SQLite."""

    def __init__(self, path: Path):
        """Открывает path, включает WAL и создаёт собственную схему при первом запуске."""
        path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False, timeout=10)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA busy_timeout=10000")
        version = self.db.execute("PRAGMA user_version").fetchone()[0]
        if version not in {0, 1}:
            raise ValueError("Неизвестная версия базы; автоматический downgrade запрещён")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS documents (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                owner_id TEXT NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY (kind, id)
            );
            CREATE INDEX IF NOT EXISTS documents_owner
                ON documents (kind, owner_id);
            PRAGMA user_version=1;
        """)

    def put(self, kind: str, record: dict[str, Any], *, new_only: bool = False) -> bool:
        """Сохраняет документ; new_only атомарно отклоняет повтор того же kind/id."""
        conflict = ("DO NOTHING" if new_only else
                    "DO UPDATE SET payload=excluded.payload WHERE documents.owner_id=excluded.owner_id")
        with self._lock, self.db:
            cursor = self.db.execute(
                "INSERT INTO documents (kind, id, owner_id, payload) VALUES (?, ?, ?, ?) "
                f"ON CONFLICT (kind, id) {conflict}",
                (kind, record["id"], record["owner_id"], json.dumps(record, ensure_ascii=False)),
            )
            if cursor.rowcount == 0:
                owner = self.db.execute(
                    "SELECT owner_id FROM documents WHERE kind = ? AND id = ?",
                    (kind, record["id"]),
                ).fetchone()
                if owner and owner[0] != record["owner_id"]:
                    raise PermissionError("Нельзя сменить владельца существующей записи")
            return cursor.rowcount == 1

    def get(self, kind: str, record_id: str) -> dict[str, Any] | None:
        """Возвращает документ kind/id или None без изменения состояния."""
        with self._lock:
            row = self.db.execute("""
                SELECT
                      payload
                FROM documents
                WHERE kind = ? AND id = ?
            """, (kind, record_id)).fetchone()
        return json.loads(row[0]) if row else None

    def all(self, kind: str, owner_id: str | None = None) -> list[dict[str, Any]]:
        """Возвращает документы вида kind, при необходимости только одного владельца."""
        query = """
            SELECT
                  payload
            FROM documents
            WHERE kind = ?
        """
        params: tuple[str, ...] = (kind,)
        if owner_id is not None:
            query += " AND owner_id = ?"
            params += (owner_id,)
        with self._lock:
            rows = self.db.execute(query, params).fetchall()
        return [json.loads(row[0]) for row in rows]

    def close(self) -> None:
        """Закрывает SQLite после остановки обработчиков."""
        self.db.close()

    def prune_expired(self, now: float) -> tuple[int, int]:
        """По Unix-времени now очищает тексты закрытых сделок через 14 дней, черновики через 3 дня."""
        with self._lock, self.db:
            # Старым закрытым сделкам даём полный срок с первого прохода новой версии.
            self.db.execute("""
                UPDATE documents
                SET payload = json_set(payload, '$.closed_at', ?)
                WHERE kind = 'deal'
                    AND (json_extract(payload, '$.own_closed') = 1
                         OR json_extract(payload, '$.peer_closed') = 1)
                    AND json_extract(payload, '$.closed_at') IS NULL
            """, (now,))
            messages = self.db.execute("""
                UPDATE documents AS message
                SET payload = json_set(json_remove(payload, '$.original', '$.translated'),
                                       '$.text_purged_at', ?)
                WHERE kind = 'message'
                    AND json_extract(payload, '$.status') IN ('delivered', 'baseline', 'failed')
                    AND json_type(payload, '$.original') IS NOT NULL
                    AND EXISTS (
                        SELECT
                              1
                        FROM documents deal
                        WHERE deal.kind = 'deal'
                            AND deal.id = json_extract(message.payload, '$.deal_id')
                            AND deal.owner_id = message.owner_id
                            AND (json_extract(deal.payload, '$.own_closed') = 1
                                 OR json_extract(deal.payload, '$.peer_closed') = 1)
                            AND json_extract(deal.payload, '$.closed_at') <= ?
                    )
            """, (now, now - 14 * 86400)).rowcount
            drafts = self.db.execute("""
                DELETE FROM documents
                WHERE kind = 'listing_draft'
                    AND json_extract(payload, '$.status') IN ('draft', 'cancelled', 'created', 'tested', 'failed')
                    AND json_extract(payload, '$.created_at') <= ?
            """, (now - 3 * 86400,)).rowcount
        # Освободившиеся страницы используются повторно; тяжёлый VACUUM не нужен.
        if messages or drafts:
            with self._lock:
                self.db.execute("PRAGMA wal_checkpoint(PASSIVE)")
        return messages, drafts


class Vault:
    """Шифрует личные ключи UEX ключом из постоянного локального тома."""

    def __init__(self, path: Path):
        """Создаёт секретный файл path только при его отсутствии, затем открывает Fernet."""
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with path.open("xb") as handle:
                path.chmod(0o600)
                handle.write(Fernet.generate_key())
        except FileExistsError:
            pass
        self._cipher = Fernet(path.read_bytes())

    def encrypt(self, secret: str) -> str:
        """Шифрует переданный личный ключ; открытый текст не сохраняется."""
        return self._cipher.encrypt(secret.encode()).decode()

    def decrypt(self, ciphertext: str) -> str:
        """Открывает ciphertext только для выполнения запроса площадки."""
        return self._cipher.decrypt(ciphertext.encode()).decode()
