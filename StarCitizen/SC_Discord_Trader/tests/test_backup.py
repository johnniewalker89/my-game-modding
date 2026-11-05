"""Бэкап работающей WAL-базы, восстановление ключей и дешёвое суточное расписание."""

import asyncio
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

from trader.backup import backup_due, create_snapshot, recovery_path, restore_if_missing
from trader.config import Settings
from trader.runtime import open_runtime
from trader.store import Store, Vault


class BackupTests(unittest.IsolatedAsyncioTestCase):
    """Использует только временные базы; рабочие данные и внешние сервисы не затрагивает."""

    async def test_wal_snapshot_restores_credentials_and_never_replaces_existing_database(self):
        """Снимок видит WAL, не включает незавершённое и восстанавливает доступ с тем же master.key."""
        with tempfile.TemporaryDirectory() as folder:
            database = Path(folder) / "trader-live.sqlite3"
            saved = recovery_path(database)
            vault = Vault(Path(folder) / "master.key")
            store = Store(database)
            record = {"id": "123", "owner_id": "123", "secret": vault.encrypt("fixture-secret"),
                      "app_token": vault.encrypt("fixture-app")}
            store.put("account", record)
            store.db.execute("BEGIN")
            store.db.execute("DELETE FROM documents WHERE kind='account'")
            await asyncio.to_thread(create_snapshot, database, saved)
            store.db.rollback()
            self.assertFalse(restore_if_missing(database))
            self.assertEqual(store.get("account", "123"), record)
            store.close()
            database.unlink()
            self.assertTrue(restore_if_missing(database))
            restored = Store(database)
            try:
                account = restored.get("account", "123")
                self.assertEqual(vault.decrypt(account["secret"]), "fixture-secret")
                self.assertEqual(vault.decrypt(account["app_token"]), "fixture-app")
                self.assertEqual(restored.db.execute("PRAGMA quick_check").fetchone(), ("ok",))
            finally:
                restored.close()
            previous = saved.read_bytes()
            broken = Path(folder) / "broken.sqlite3"
            broken.write_bytes(b"not a database")
            with self.assertRaises(sqlite3.DatabaseError):
                create_snapshot(broken, saved)
            self.assertEqual(saved.read_bytes(), previous)
            self.assertEqual(list(saved.parent.glob("*.tmp")), [])

    async def test_daily_clock_and_runtime_copy_once_without_stopping_worker(self):
        """Проверка раз в минуту не превращается в копирование на каждом опросе или перезапуске."""
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            saved = recovery_path(directory / "trader-demo.sqlite3")
            now = datetime(2026, 11, 5, 3, 54)
            self.assertFalse(backup_due(saved, "", now))
            self.assertTrue(backup_due(saved, "03:55", now))
            saved.parent.mkdir()
            saved.touch()
            yesterday = (now - timedelta(days=1)).timestamp()
            os.utime(saved, (yesterday, yesterday))
            self.assertFalse(backup_due(saved, "03:55", now))
            self.assertTrue(backup_due(saved, "03:55", now.replace(minute=55)))
            saved.unlink()
            original_sleep = asyncio.sleep
            status_checks = asyncio.Event()
            count = 0

            async def quick_sleep(delay):
                nonlocal count
                if delay == 60:
                    count += 1
                    if count >= 3:
                        status_checks.set()
                await original_sleep(0.005)

            with patch("trader.runtime.asyncio.sleep", quick_sleep), patch(
                    "trader.runtime.create_snapshot", wraps=create_snapshot) as export:
                async with open_runtime(Settings(data_dir=directory, translator="groq", backup_time="00:00")) as runtime:
                    await asyncio.wait_for(status_checks.wait(), 3)
                    self.assertEqual(export.call_count, 1)
                    self.assertIsNotNone(runtime.status_provider()["backup_at"])
                    self.assertIsNone(runtime.status_provider()["backup_error"])
                    self.assertFalse(any(task.done() for task in runtime.background_tasks))
            self.assertEqual(list(saved.parent.glob("*.tmp")), [])

    async def test_invalid_clock_is_rejected_before_startup(self):
        """Ошибочное расписание не запускает молчаливо неработающую автоматику."""
        for value in ("25:00", "3:55", "03:55:00", "not-time"):
            with self.subTest(value=value), patch.dict(os.environ, {"TRADER_BACKUP_TIME": value}, clear=True):
                with self.assertRaises(ValueError):
                    Settings.from_env()

    async def test_snapshot_failure_keeps_worker_alive_and_is_not_retried_every_minute(self):
        """Проблема диска видна в диагностике, но не останавливает торговлю и не создаёт цикл повторов."""
        with tempfile.TemporaryDirectory() as folder:
            original_sleep = asyncio.sleep
            checked = asyncio.Event()
            count = 0

            async def quick_sleep(delay):
                nonlocal count
                if delay == 60:
                    count += 1
                    if count >= 3:
                        checked.set()
                await original_sleep(0.005)

            with patch("trader.runtime.asyncio.sleep", quick_sleep), patch(
                    "trader.runtime.create_snapshot", side_effect=OSError("fixture disk full")) as export:
                async with open_runtime(Settings(data_dir=Path(folder), translator="groq", backup_time="00:00")) as runtime:
                    await asyncio.wait_for(checked.wait(), 3)
                    self.assertEqual(export.call_count, 1)
                    self.assertEqual(runtime.status_provider()["backup_error"], "OSError")
                    self.assertEqual(runtime.status_provider()["state"], "degraded")
                    self.assertFalse(any(task.done() for task in runtime.background_tasks))
