"""Локальный предпросмотр настоящих webhook payload без каких-либо отправок."""

import argparse
import json
import logging
import os
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.resources import files
from pathlib import Path

from patch_alerts import __version__
from patch_alerts.events import demo_payloads
from patch_alerts.scanner import read_json, record_failure, scan_once
from patch_alerts.config import NewsSettings
from patch_alerts.delivery import WebhookClient, WebhookError
from patch_alerts.worker import NewsWorker, delivery_status, reconcile

LOGGER = logging.getLogger(__name__)


def serve(data_dir: Path, port: int, poll_seconds: int, offline: bool) -> None:
    """Показывает карточки и состояние data_dir; offline отключает даже чтение RSS."""
    stopped = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        """Обслуживает только фиксированные GET-маршруты локального предпросмотра."""

        def do_GET(self):
            """Возвращает страницу или JSON; запрос не отправляет сообщения и не меняет настройки."""
            route = self.path.split("?", 1)[0]
            content_type = "application/json; charset=utf-8"
            try:
                if route == "/":
                    body = files("patch_alerts").joinpath("preview.html").read_bytes()
                    content_type = "text/html; charset=utf-8"
                elif route == "/api/demos":
                    body = json.dumps(demo_payloads(), ensure_ascii=False).encode()
                elif route == "/api/status":
                    body = json.dumps(read_json(data_dir / "status.json", {"state": "offline" if offline else "starting", "mode": "preview_no_sending"}), ensure_ascii=False).encode()
                elif route == "/api/notices":
                    body = json.dumps(read_json(data_dir / "state.json", {}).get("notices", []), ensure_ascii=False).encode()
                elif route == "/health":
                    body = json.dumps({"service": "sc-patch-alerts", "version": __version__, "mode": "preview_no_sending"}).encode()
                else:
                    self.send_error(404)
                    return
            except (OSError, ValueError):
                self.send_error(503, "Preview state unavailable")
                return
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            """Не пишет каждое обновление страницы в эксплуатационный журнал."""

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)

    def watch():
        """Периодически читает RSS; сетевой сбой не завершает локальный сервис."""
        while not stopped.is_set():
            try:
                scan_once(data_dir)
            except Exception as exc:
                try:
                    record_failure(data_dir, exc)
                except OSError:
                    LOGGER.error("Состояние ошибки не сохранено error_type=%s", type(exc).__name__)
            stopped.wait(poll_seconds)

    def stop(_number, _frame):
        """Передаёт завершение серверу без блокировки его основного потока."""
        stopped.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    previous = {number: signal.signal(number, stop) for number in (signal.SIGINT, signal.SIGTERM)}
    watcher = None
    if not offline:
        watcher = threading.Thread(target=watch, name="rsi-status-reader", daemon=True)
        watcher.start()
    LOGGER.info("Предпросмотр готов port=%s version=%s sending=disabled source_poll=%s", port, __version__, "offline" if offline else poll_seconds)
    try:
        server.serve_forever(poll_interval=0.3)
    finally:
        stopped.set()
        server.server_close()
        if watcher:
            watcher.join(timeout=10)
        for number, handler in previous.items():
            signal.signal(number, handler)
        LOGGER.info("Предпросмотр остановлен штатно")


def main() -> None:
    """Запускает preview либо явно настроенный worker; демо и scan ничего не отправляют."""
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    parser = argparse.ArgumentParser(description="SC Patches · предпросмотр и доставка официальных уведомлений")
    parser.add_argument("command", choices=["serve", "scan", "demo", "worker", "status", "check-target", "reconcile"])
    parser.add_argument("--data-dir", type=Path, help="Каталог только для serve/scan; worker берёт путь из --config")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--poll-seconds", type=int, default=90)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--notice-id")
    parser.add_argument("--decision", choices=["sent", "discard", "retry"])
    parser.add_argument("--message-id", default="")
    parser.add_argument("--confirm-not-sent", action="store_true")
    args = parser.parse_args()
    if args.command in {"worker", "status", "check-target", "reconcile"} and (
            args.offline or args.data_dir is not None or args.port != 8080 or args.poll_seconds != 90):
        parser.error("Настройки preview нельзя применять к доставке; используй отдельный --config")
    if args.poll_seconds < 60:
        parser.error("Минимальный интервал чтения — 60 секунд")
    if args.command == "demo":
        print(json.dumps(demo_payloads(), ensure_ascii=False, indent=2))
    elif args.command == "scan":
        data_dir = args.data_dir or Path("data")
        try:
            print(json.dumps(scan_once(data_dir), ensure_ascii=False))
        except Exception as exc:
            record_failure(data_dir, exc)
            raise SystemExit(1) from None
    elif args.command == "serve":
        serve(args.data_dir or Path("data"), args.port, args.poll_seconds, args.offline)
    else:
        if args.config is None:
            parser.error("Для этой команды нужен --config")
        try:
            settings = NewsSettings.from_file(args.config.resolve())
            if args.command == "status":
                value = delivery_status(settings.data_dir) if settings.enabled else {"state": "disabled"}
                print(json.dumps(value, ensure_ascii=False))
                return
            if not settings.enabled:
                if args.command == "worker":
                    LOGGER.info("Новостной модуль выключен в конфиге")
                    return
                raise ValueError("news_disabled")
            client = WebhookClient(settings.target(), mention_role_id=settings.mention_role_id)
            if args.command == "check-target":
                client.verify()
                print(json.dumps({"state": "verified", "webhook_id": settings.webhook_id,
                                  "channel_id": settings.channel_id, "guild_id": settings.guild_id}))
            elif args.command == "reconcile":
                if not args.notice_id or not args.decision:
                    parser.error("Для сверки нужны --notice-id и --decision")
                reconcile(settings.data_dir, client, args.notice_id, args.decision, args.message_id,
                          confirm_not_sent=args.confirm_not_sent)
            else:
                run_worker(settings, client)
        except (OSError, ValueError, WebhookError) as exc:
            LOGGER.error("Команда новостей не выполнена command=%s reason=%s", args.command, exc.code if isinstance(exc, WebhookError) else type(exc).__name__)
            raise SystemExit(1) from None


def run_worker(settings: NewsSettings, client: WebhookClient) -> None:
    """Держит один явно настроенный worker до SIGINT/SIGTERM без торгового Gateway."""
    stopped = threading.Event()
    previous = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}

    def stop(_number, _frame):
        """Просит остановить foreground worker после текущей операции."""
        stopped.set()

    for number in previous:
        signal.signal(number, stop)
    try:
        with NewsWorker(settings, client) as worker:
            while not stopped.wait(1):
                if not worker.thread.is_alive():
                    raise RuntimeError("news_worker_stopped")
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    main()
