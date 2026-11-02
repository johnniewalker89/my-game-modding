"""Запуск того же Discord-бота без загрузки HTTP-стенда и его библиотек."""

import asyncio
import contextlib
import logging
import signal

from trader.config import Settings
from trader.runtime import configure_logging, open_runtime

LOGGER = logging.getLogger(__name__)


async def run(settings: Settings) -> None:
    """Работает с настройками settings до SIGINT/SIGTERM, затем штатно закрывает ресурсы."""
    loop = asyncio.get_running_loop()
    stopped = asyncio.Event()
    signals = (signal.SIGINT, signal.SIGTERM)
    previous = {number: signal.getsignal(number) for number in signals}

    def stop_received(_number, _frame) -> None:
        """Передаёт сигнал завершения в основной цикл без прерывания текущих записей."""
        loop.call_soon_threadsafe(stopped.set)

    for number in signals:
        signal.signal(number, stop_received)
    try:
        async with open_runtime(settings) as runtime:
            stop_task = asyncio.create_task(stopped.wait())
            try:
                watched = {stop_task, *runtime.background_tasks}
                if runtime.discord_task is not None:
                    watched.add(runtime.discord_task)
                done, _ = await asyncio.wait(watched, return_when=asyncio.FIRST_COMPLETED)
                if not stopped.is_set():
                    completed = next(iter(done))
                    error = None if completed.cancelled() else completed.exception()
                    LOGGER.error("Фоновая задача завершилась task=%s error_type=%s", completed.get_name(), type(error).__name__ if error else "task_closed")
                    name = "Discord" if completed is runtime.discord_task else "Фоновый"
                    raise RuntimeError(f"{name} worker завершился")
            finally:
                stop_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await stop_task
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    LOGGER.info("Сервис остановлен штатно")


def main() -> None:
    """Читает обычные TRADER_* настройки и запускает один процесс без HTTP-порта."""
    configure_logging()
    try:
        asyncio.run(run(Settings.from_env()))
    except RuntimeError:
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
