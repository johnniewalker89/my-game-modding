"""Проверки экономичного запуска, завершения процесса и доставки без кэша SDK."""

import asyncio
import os
import signal
import sys
import tempfile
import unittest
from contextlib import asynccontextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from trader.config import Settings
from trader.discord_bot import TraderBot
from trader.runtime import TraderRuntime
from trader.store import Store
from trader.worker import run


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет процесс без рабочих ключей, сети и данных пользователя."""

    async def test_worker_import_does_not_load_http_frameworks(self):
        """Новый процесс импортирует бота без FastAPI и Uvicorn, экономя их память."""
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-c", "import sys; import trader.worker; assert 'fastapi' not in sys.modules; assert 'uvicorn' not in sys.modules",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await asyncio.wait_for(process.communicate(), 10)
        self.assertEqual(process.returncode, 0, (stdout + stderr).decode())

    @unittest.skipIf(os.name == "nt", "Завершение SIGTERM проверяется в Linux Docker")
    async def test_worker_sigterm_closes_runtime_and_exits_cleanly(self):
        """Реальная CLI-команда штатно завершает изолированный demo-процесс по SIGTERM."""
        with tempfile.TemporaryDirectory() as temp:
            environment = dict(os.environ, TRADER_MODE="demo", TRADER_DATA_DIR=temp,
                               TRADER_TRANSLATOR="groq", TRADER_GROQ_API_KEY="fixture-no-network")
            process = await asyncio.create_subprocess_exec(
                sys.executable, "-u", "-m", "trader.worker", env=environment,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)

            async def wait_started():
                """Дожидается инициализации после обычных стартовых сообщений сервиса."""
                lines = []
                while line := await process.stdout.readline():
                    lines.append(line)
                    if "Сервис инициализирован".encode() in line:
                        return
                self.fail(b"".join(lines).decode())

            try:
                await asyncio.wait_for(wait_started(), 10)
                process.send_signal(signal.SIGTERM)
                output, _ = await asyncio.wait_for(process.communicate(), 10)
                self.assertEqual(process.returncode, 0, output.decode())
                self.assertIn("Сервис остановлен штатно".encode(), output)
                self.assertTrue((Path(temp) / "trader-demo.sqlite3").exists())
            finally:
                if process.returncode is None:
                    process.kill()
                    await process.wait()

    async def test_worker_closes_runtime_after_discord_stops_or_background_task_fails(self):
        """Оба вида остановки завершают worker, закрывают ресурсы и не раскрывают текст ошибки."""
        for discord_task in (True, False):
            with self.subTest(discord_task=discord_task):
                closed = []

                async def finish_task():
                    """Завершает Discord штатно либо имитирует программный сбой poll."""
                    if not discord_task:
                        raise ValueError("private-fixture-must-not-be-logged")

                @asynccontextmanager
                async def runtime(settings):
                    """Передаёт критическую задачу через соответствующее поле runtime."""
                    task = asyncio.create_task(finish_task(), name="discord" if discord_task else "uex-poll")
                    try:
                        yield TraderRuntime(SimpleNamespace(last_error=None), None,
                            discord_task=task if discord_task else None,
                            background_tasks=() if discord_task else (task,))
                    finally:
                        await asyncio.gather(task, return_exceptions=True)
                        closed.append(True)

                before = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
                with patch("trader.worker.open_runtime", runtime), self.assertLogs("trader.worker", level="ERROR") as logs:
                    with self.assertRaisesRegex(RuntimeError, "Discord worker" if discord_task else "Фоновый worker"):
                        await run(Settings())
                self.assertEqual(closed, [True])
                self.assertIn("task_closed" if discord_task else "ValueError", logs.output[0])
                self.assertNotIn("private-fixture", logs.output[0])
                self.assertEqual(before, {number: signal.getsignal(number) for number in before})

    async def test_messages_are_dispatched_when_sdk_cache_is_disabled(self):
        """Отключённый кэш не мешает передавать входящие сообщения обработчику бота."""
        with tempfile.TemporaryDirectory() as temp:
            store = Store(Path(temp) / "state.sqlite3")
            bot = TraderBot(Settings(), store)
            dispatched = Mock()
            bot._connection.dispatch = dispatched
            try:
                for number in range(3):
                    bot._connection.parse_message_create({
                        "id": str(number + 100), "channel_id": "200", "type": 0,
                        "author": {"id": "300", "username": "fixture", "discriminator": "0", "avatar": None},
                        "content": "Сообщение", "timestamp": "2026-11-02T00:00:00+00:00",
                        "edited_timestamp": None, "tts": False, "mention_everyone": False,
                        "mentions": [], "mention_roles": [], "attachments": [], "embeds": [], "pinned": False,
                    })
                self.assertEqual(len(bot.cached_messages), 0)
                self.assertEqual(dispatched.call_count, 3)
                self.assertTrue(all(call.args[0] == "message" for call in dispatched.call_args_list))
                self.assertEqual([call.args[1].content for call in dispatched.call_args_list], ["Сообщение"] * 3)
            finally:
                await bot.close()
                store.close()
