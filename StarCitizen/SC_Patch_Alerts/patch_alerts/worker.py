"""Автономная очередь новых постов; торговые данные и Gateway не используются."""

import logging
import threading
import time
from dataclasses import asdict, replace
from datetime import datetime, timezone
from pathlib import Path

from patch_alerts.config import NewsSettings
from patch_alerts.delivery import WebhookClient, WebhookError
from patch_alerts.events import Event, build_payload
from patch_alerts.locking import state_lock
from patch_alerts.notes import fetch_notes
from patch_alerts.scanner import read_json, read_state, record_failure, scan_once, write_json

LOGGER = logging.getLogger(__name__)
PENDING = {"pending", "inflight", "unknown", "blocked"}


def _obsolete(notice: dict, state: dict, now: datetime) -> bool:
    """Отсекает отложенный старый этап notice, когда известен более новый этап."""
    event = notice["event"]
    latest = state.get("known", {}).get(event["source_url"])
    if event["phase"] == "scheduled" and datetime.fromisoformat(event["starts_at"]) <= now:
        return True
    if not latest:
        return False
    rank = {"scheduled": 0, "installing": 1, "completed": 2, "released": 2}
    if rank[latest["phase"]] > rank[event["phase"]]:
        return True
    if latest["phase"] == event["phase"]:
        return (latest.get("version", "") != event.get("version", "")
                or (event["phase"] == "scheduled" and latest["starts_at"] != event["starts_at"]))
    return False


def drain_once(data_dir: Path, client: WebhookClient, now: datetime | None = None,
               *, stopped: threading.Event | None = None, mention_role_id: str = "") -> None:
    """Отправляет пост data_dir; роль закрепляет до первой попытки, stopped отменяет POST."""
    now = now or datetime.now(timezone.utc)
    if stopped is not None and stopped.is_set():
        return
    with state_lock(data_dir):
        path = data_dir / "state.json"
        state = read_state(path)
        if not state.get("delivery_started_at"):
            return
        notices = state.get("notices", [])
        interrupted = [item for item in notices if item.get("delivery") == "inflight"]
        for item in interrupted:
            item.update(delivery="unknown", error="interrupted_send")
        if interrupted:
            write_json(path, state)
            LOGGER.error("Исход отправки неизвестен reason=interrupted_send count=%s auto_retry=no", len(interrupted))
        if any(item.get("delivery") in {"unknown", "blocked"} for item in notices):
            return
        if state.get("delivery_pause_until", 0) > now.timestamp():
            return
        pending = [item for item in notices if item.get("delivery") == "pending"]
        for item in pending:
            if _obsolete(item, state, now):
                item.update(delivery="superseded", error="newer_phase_or_time")
        notice = next((item for item in pending if item["delivery"] == "pending"), None)
        if notice is None:
            if pending or state.get("delivery_error") or state.get("delivery_pause_until"):
                state["delivery_error"] = None
                state["delivery_pause_until"] = 0
                write_json(path, state)
            return
        identifier = notice["id"]
        try:
            client.verify()
        except WebhookError as exc:
            if exc.status == 429 and exc.retry_after is not None:
                state["delivery_pause_until"] = now.timestamp() + max(1, exc.retry_after)
            elif exc.status in {400, 401, 403, 404, 429} or exc.code == "target_mismatch":
                notice.update(delivery="blocked", error=exc.code)
            else:
                state["delivery_pause_until"] = now.timestamp() + 90
            state["delivery_error"] = exc.code
            write_json(path, state)
            LOGGER.warning("Доставка приостановлена notice=%s state=%s reason=%s http=%s retry_after=%s before_post=yes", identifier, notice["delivery"], exc.code, exc.status, max(0, round(state.get("delivery_pause_until", 0) - now.timestamp())))
            return
        event = Event(**notice["event"])
        if event.phase == "released" and not notice.get("notes_lookup_done"):
            try:
                notes_url = fetch_notes(event.version)
            except Exception as exc:
                notes_url = ""
                LOGGER.warning("Прямая ссылка недоступна notice=%s error_type=%s fallback=index", identifier, type(exc).__name__)
            event = replace(event, notes_url=notes_url)
            notice.update(event=asdict(event), payload=build_payload(event), notes_lookup_done=True)
        if stopped is not None and stopped.is_set():
            write_json(path, state)
            return
        if not notice.get("attempts") and mention_role_id and not event.demo:
            notice["payload"] = {**notice["payload"], "content": f"<@&{mention_role_id}>",
                                 "allowed_mentions": {"parse": [], "roles": [mention_role_id]}}
        notice.update(delivery="inflight", attempted_at=now.isoformat(), attempts=notice.get("attempts", 0) + 1)
        state["delivery_error"] = None
        write_json(path, state)
        try:
            message_id = client.send(notice["payload"])
        except WebhookError as exc:
            if exc.status == 429 and exc.retry_after is not None:
                notice.update(delivery="pending", error=exc.code)
                state["delivery_pause_until"] = now.timestamp() + max(1, exc.retry_after)
            elif exc.status in {400, 401, 403, 404, 405, 413, 415, 422, 429}:
                notice.update(delivery="blocked", error=exc.code)
            else:
                notice.update(delivery="unknown", error=exc.code)
            state["delivery_error"] = exc.code
            LOGGER.warning("Отправка не подтверждена notice=%s state=%s reason=%s http=%s retry_after=%s attempts=%s", identifier, notice["delivery"], exc.code, exc.status, max(0, round(state.get("delivery_pause_until", 0) - now.timestamp())), notice["attempts"])
        except ValueError:
            notice.update(delivery="blocked", error="invalid_payload")
            LOGGER.error("Отправка запрещена notice=%s reason=invalid_payload", identifier)
        except Exception as exc:
            notice.update(delivery="unknown", error=type(exc).__name__)
            LOGGER.error("Исход отправки неизвестен notice=%s error_type=%s auto_retry=no", identifier, type(exc).__name__)
        else:
            notice.update(delivery="sent", message_id=message_id, delivered_at=now.isoformat(), error=None)
            LOGGER.info("Уведомление доставлено notice=%s message=%s phase=%s", identifier, message_id, event.phase)
        write_json(path, state)


def delivery_status(data_dir: Path) -> dict:
    """Читает безопасные счётчики доставки data_dir без сетевых запросов."""
    state = read_state(data_dir / "state.json")
    counts = {key: sum(item.get("delivery") == key for item in state.get("notices", [])) for key in PENDING | {"sent"}}
    attention = counts["unknown"] + counts["blocked"] + counts["inflight"]
    delivery_state = "attention" if attention else "degraded" if state.get("delivery_error") else "ok"
    attention_items = [{"id": item.get("id"), "state": item["delivery"], "error": item.get("error")}
                       for item in state.get("notices", []) if item.get("delivery") in {"unknown", "blocked", "inflight"}]
    return {"state": delivery_state, **counts, "attention": attention_items,
            "pause_until": state.get("delivery_pause_until", 0), "error": state.get("delivery_error")}


def reconcile(data_dir: Path, client: WebhookClient, notice_id: str, decision: str,
              message_id: str = "", *, confirm_not_sent: bool = False) -> None:
    """Разбирает ровно notice_id: подтвердить существующий пост, пропустить или явно повторить."""
    with state_lock(data_dir):
        path = data_dir / "state.json"
        state = read_state(path)
        notice = next((item for item in state.get("notices", []) if item.get("id") == notice_id), None)
        if notice is None or notice.get("delivery") not in {"unknown", "blocked", "inflight"}:
            raise ValueError("notice_not_waiting_for_reconciliation")
        if decision == "sent":
            client.verify()
            verified = client.confirm(message_id, notice["payload"])
            notice.update(delivery="sent", message_id=verified, error=None)
        elif decision == "discard":
            notice.update(delivery="discarded", error="operator_discarded")
        elif decision == "retry" and confirm_not_sent:
            notice.update(delivery="pending", error=None)
        else:
            raise ValueError("explicit_reconciliation_required")
        state["delivery_pause_until"] = 0
        state["delivery_error"] = None
        write_json(path, state)
        LOGGER.info("Исход разобран notice=%s decision=%s", notice_id, decision)


class NewsWorker:
    """Ведёт новостной цикл в отдельном потоке того же процесса, без Gateway-клиента."""

    def __init__(self, settings: NewsSettings, client: WebhookClient | None = None):
        """Получает settings и необязательный client для изолированной проверки."""
        self.settings = settings
        self.client = client or WebhookClient(settings.target(), mention_role_id=settings.mention_role_id)
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._watch, name="sc-patches", daemon=True)

    def __enter__(self):
        """Запускает поток после локальной проверки конфига и файла ключа."""
        self.thread.start()
        LOGGER.info("Новостной модуль запущен state=starting poll_seconds=%s mention_role_id=%s", self.settings.poll_seconds, self.settings.mention_role_id or "none")
        return self

    def __exit__(self, *_args):
        """Останавливает цикл и ожидает текущую ограниченную сетевую операцию."""
        self.stopped.set()
        self.thread.join(timeout=30)
        if self.thread.is_alive():
            LOGGER.warning("Новостной поток ещё завершает запрос; inflight при следующем запуске требует сверки")
        else:
            status_path = self.settings.data_dir / "worker-status.json"
            try:
                status = read_json(status_path, {})
                write_json(status_path, {**status, "state": "stopped", "updated_at": time.time()})
            except (OSError, ValueError) as exc:
                LOGGER.warning("Состояние остановки новостей не сохранено error_type=%s", type(exc).__name__)
            LOGGER.info("Новостной модуль остановлен штатно")

    def cycle(self) -> dict:
        """Обновляет источник и доставку независимо, сохраняя отдельный технический статус."""
        error = None
        try:
            scan_once(self.settings.data_dir, activate=True)
        except Exception as exc:
            error = type(exc).__name__
            record_failure(self.settings.data_dir, exc, mode="delivery")
        try:
            drain_once(self.settings.data_dir, self.client, stopped=self.stopped,
                       mention_role_id=self.settings.mention_role_id)
            delivery = delivery_status(self.settings.data_dir)
        except Exception as exc:
            error = type(exc).__name__
            delivery = {"state": "attention", "error": error}
            LOGGER.error("Новостная очередь недоступна error_type=%s", error)
        source = read_json(self.settings.data_dir / "status.json", {})
        status = {"state": "degraded" if error or delivery["state"] != "ok" else "ok",
                  "enabled": True, "updated_at": time.time(), "source": source,
                  "delivery": delivery, "error": error}
        write_json(self.settings.data_dir / "worker-status.json", status)
        return status

    def _watch(self) -> None:
        """Повторяет цикл с безопасной диагностикой; ошибка новостей не завершает торговца."""
        previous = None
        while not self.stopped.is_set():
            try:
                status = self.cycle()
                signature = (status["state"], status["error"], status["delivery"].get("error"))
                if signature != previous:
                    LOGGER.info("Состояние новостей state=%s source=%s delivery=%s error=%s", status["state"], status["source"].get("state"), status["delivery"]["state"], status["error"] or status["delivery"].get("error") or "none")
                    previous = signature
            except Exception as exc:
                LOGGER.error("Новостной цикл не завершён error_type=%s retry_seconds=%s", type(exc).__name__, self.settings.poll_seconds)
            self.stopped.wait(self.settings.poll_seconds)
