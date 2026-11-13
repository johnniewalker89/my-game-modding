"""Совместный launcher, прежний config-контракт и поставка без живых подключений."""

import asyncio
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from companion.status import snapshot
from companion.worker import load_configuration, run_service
from patch_alerts.config import NewsSettings
from patch_alerts.scanner import write_json
from trader.config import Settings
from trader.diagnostics import status_path, write_status

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("hosting_builder", ROOT / "build_hosting.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class CompanionTests(unittest.TestCase):
    """Проверяет общую оркестрацию; торговые функции повторно не тестирует."""

    def test_legacy_operator_config_preserves_paths_and_optional_news(self):
        """Прежний JSON с environment-парами читается без включения новостей."""
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {}, clear=True):
            root = Path(folder)
            config = root / "operator-config.json"
            data = root / "existing-trader-data"
            value = {"TRADER_MODE": "demo", "TRADER_DATA_DIR": str(data), "TRADER_TRANSLATOR": "groq",
                     "TRADER_GROQ_API_KEY": "fixture-no-network", "TZ": "Europe/Moscow"}
            config.write_text(json.dumps(value), encoding="utf-8")
            os.environ["SC_COMPANION_OPERATOR_CONFIG_FILE"] = str(config)
            trader, news = load_configuration()
            self.assertEqual(trader.data_dir, data)
            self.assertEqual(trader.groq_key, "fixture-no-network")
            self.assertFalse(news.enabled)
            self.assertEqual(json.loads(config.read_text()), value)
            self.assertFalse(data.exists())

    def test_explicit_missing_news_config_and_shared_data_directory_are_rejected(self):
        """Опечатка пути и смешивание данных не маскируются выключенным модулем."""
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {}, clear=True):
            root = Path(folder)
            os.environ.update(TRADER_MODE="demo", TRADER_DATA_DIR=str(root / "data"),
                              SC_PATCHES_CONFIG_FILE=str(root / "missing.json"))
            with self.assertRaisesRegex(ValueError, "news_config_missing"):
                load_configuration()
            config = root / "patches.json"
            config.write_text(json.dumps({"enabled": True, "data_dir": "data", "webhook_file": "hook.url",
                                          "webhook_id": "1", "channel_id": "2", "guild_id": "3"}), encoding="utf-8")
            os.environ["SC_PATCHES_CONFIG_FILE"] = str(config)
            with self.assertRaisesRegex(ValueError, "module_data_directories_must_differ"):
                load_configuration()

    def test_news_source_failure_is_visible_while_trader_caller_continues(self):
        """Настоящий news-поток сохраняет отказ, а общий launcher продолжает торговый вызов."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            secret = root / "hook.url"
            secret.write_text("https://discord.com/api/webhooks/1/" + "A" * 60, encoding="utf-8")
            news = NewsSettings(True, root / "news", 90, secret, "1", "2", "3")
            trader = Settings(data_dir=root / "trader")
            called = []

            async def run_fixture(settings):
                """Наблюдает новостной статус во время работы торгового вызывающего."""
                for _ in range(100):
                    path = news.data_dir / "worker-status.json"
                    if path.exists():
                        value = json.loads(path.read_text())
                        self.assertEqual(value["state"], "degraded")
                        self.assertEqual(value["source"]["mode"], "delivery")
                        called.append(settings)
                        return
                    await asyncio.sleep(0.01)
                self.fail("News worker did not publish failure status")

            with patch("patch_alerts.worker.scan_once", side_effect=TimeoutError()), patch("companion.worker.run_trader", run_fixture), self.assertLogs("patch_alerts", level="INFO") as logs:
                run_service(trader, news)
            self.assertEqual(called, [trader])
            self.assertEqual(json.loads((news.data_dir / "worker-status.json").read_text())["state"], "stopped")
            self.assertNotIn("A" * 60, "\n".join(logs.output))

    def test_status_keeps_module_states_separate_and_detects_dead_news(self):
        """Здоровый Trader не скрывает unknown/stale новостей; статус не читает ключ."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            trader = Settings(data_dir=root / "trader")
            trader.data_dir.mkdir()
            news = NewsSettings(True, root / "news", 90, root / "missing-secret.url", "1", "2", "3")
            write_status(status_path(trader.data_dir, "demo"), {"schema_version": 1, "state": "ok", "updated_at": time.time()})
            write_json(news.data_dir / "worker-status.json", {"state": "degraded", "updated_at": time.time(), "delivery": {"unknown": 1}})
            with patch("companion.status.load_configuration", return_value=(trader, news)):
                value = snapshot()
                self.assertEqual(value["trader"]["state"], "ok")
                self.assertEqual(value["patches"]["delivery"]["unknown"], 1)
                write_json(news.data_dir / "worker-status.json", {"state": "ok", "updated_at": 0})
                self.assertEqual(snapshot()["patches"]["state"], "stale")

    def test_zip_is_reproducible_code_only_and_every_payload_hash_matches(self):
        """Настоящий builder выдаёт одинаковый ZIP с импортируемыми модулями и без данных/ключей."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            first, second = root / "a.zip", root / "b.zip"
            a, b = BUILDER.build(first), BUILDER.build(second)
            self.assertEqual(a["sha256"], b["sha256"])
            with zipfile.ZipFile(first) as archive:
                manifest = json.loads(archive.read("release-manifest.json"))
                self.assertIn("trader/worker.py", manifest["files"])
                self.assertIn("patch_alerts/worker.py", manifest["files"])
                self.assertIn("companion/worker.py", manifest["files"])
                self.assertEqual(archive.read("requirements.txt"), (ROOT.parent / "SC_Discord_Trader/requirements.lock").read_bytes())
                self.assertFalse(any(name in archive.namelist() for name in ("operator-config.json", "patches-config.json", "master.key")))
                self.assertFalse(any(name.endswith(".url") or "__pycache__" in name or name.startswith(("private/", "trader-data/", "patches-data/")) for name in archive.namelist()))
                for name, digest in manifest["files"].items():
                    self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest)

    @unittest.skipIf(os.name == "nt", "SIGTERM и network-none проверяются в Linux-контуре")
    def test_delivered_host_entrypoint_starts_and_stops_with_existing_master_key(self):
        """Извлечённый app.py запускает один demo worker и сохраняет исходные данные при SIGTERM."""
        from cryptography.fernet import Fernet
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive = root / "release.zip"
            BUILDER.build(archive)
            with zipfile.ZipFile(archive) as package:
                package.extractall(root / "host")
            host = root / "host"
            data = root / "existing-data"
            data.mkdir()
            key = Fernet.generate_key()
            (data / "master.key").write_bytes(key)
            (data / "sentinel.keep").write_bytes(b"preserve-fixture-data")
            config = {"TRADER_MODE": "demo", "TRADER_DATA_DIR": str(data), "TRADER_TRANSLATOR": "groq", "TRADER_GROQ_API_KEY": "fixture-no-network", "TZ": "Europe/Moscow"}
            (host / "operator-config.json").write_text(json.dumps(config), encoding="utf-8")
            private = host / "private"
            private.mkdir()
            (private / "hook.url").write_text("https://discord.com/api/webhooks/1/" + "A" * 60, encoding="utf-8")
            news_data = root / "news-data"
            (host / "patches-config.json").write_text(json.dumps({"enabled": True, "data_dir": str(news_data),
                "webhook_file": "private/hook.url", "webhook_id": "1", "channel_id": "2", "guild_id": "3"}), encoding="utf-8")
            env = dict(os.environ)
            env.pop("SC_PATCHES_CONFIG_FILE", None)
            env.pop("SC_COMPANION_OPERATOR_CONFIG_FILE", None)
            imports = subprocess.check_output([sys.executable, "-c", "import json,trader,companion,patch_alerts; print(json.dumps([m.__file__ for m in (trader,companion,patch_alerts)]))"], cwd=host, env=env, timeout=10)
            self.assertTrue(all(Path(path).is_relative_to(host) for path in json.loads(imports)))
            process = subprocess.Popen([sys.executable, "-u", "app.py"], cwd=host, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                output = []
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    line = process.stdout.readline()
                    output.append(line)
                    if "Сервис инициализирован".encode() in line:
                        break
                    if process.poll() is not None:
                        self.fail(b"".join(output).decode())
                else:
                    self.fail("Host entrypoint did not start")
                process.terminate()
                tail, _ = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, tail.decode())
                self.assertIn("Сервис остановлен штатно".encode(), tail)
                self.assertEqual((data / "master.key").read_bytes(), key)
                self.assertEqual((data / "sentinel.keep").read_bytes(), b"preserve-fixture-data")
                self.assertEqual(json.loads((host / "operator-config.json").read_text()), config)
                self.assertEqual(json.loads((news_data / "worker-status.json").read_text())["state"], "stopped")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            (host / "app.py").write_bytes((ROOT / "tests/fixtures/legacy_app.py").read_bytes())
            rollback = subprocess.Popen([sys.executable, "-u", "app.py"], cwd=host, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                lines = []
                while line := rollback.stdout.readline():
                    lines.append(line)
                    if "Сервис инициализирован".encode() in line:
                        break
                else:
                    self.fail(b"".join(lines).decode())
                rollback.terminate()
                tail, _ = rollback.communicate(timeout=15)
                self.assertEqual(rollback.returncode, 0, tail.decode())
                self.assertEqual((data / "master.key").read_bytes(), key)
                self.assertEqual((data / "sentinel.keep").read_bytes(), b"preserve-fixture-data")
            finally:
                if rollback.poll() is None:
                    rollback.kill()
                    rollback.wait()


if __name__ == "__main__":
    unittest.main()
