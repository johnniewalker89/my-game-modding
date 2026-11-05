"""Лёгкое состояние worker: локальная проверка и вывод без веб-сервера или сети."""

import json
import os
import time
from pathlib import Path
from typing import Any

STATUS_STALE_SECONDS = 180


def status_path(data_dir: Path, mode: str) -> Path:
    """Возвращает отдельный файл состояния для demo/live в постоянном каталоге."""
    if mode not in {"demo", "live"}:
        raise ValueError("Неизвестный режим")
    return data_dir / f"runtime-status-{mode}.json"


def write_status(path: Path, snapshot: dict[str, Any]) -> None:
    """Атомарно заменяет небольшой технический snapshot; вызывающий исключает секреты и переписки."""
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        temporary.chmod(0o600)
        json.dump(snapshot, handle, ensure_ascii=False)
    temporary.replace(path)


def read_status(path: Path, *, now: float | None = None) -> dict[str, Any]:
    """Читает snapshot и помечает устаревшим, если heartbeat старше трёх минут."""
    snapshot = json.loads(path.read_text(encoding="utf-8"))
    if (not isinstance(snapshot, dict) or snapshot.get("schema_version") != 1
            or not isinstance(snapshot.get("updated_at"), (int, float))
            or snapshot.get("state") not in {"starting", "ok", "degraded", "failed", "stopped"}):
        raise ValueError("Неизвестный формат состояния")
    age = max(0, (time.time() if now is None else now) - snapshot["updated_at"])
    return {**snapshot, "state": "stale" if age > STATUS_STALE_SECONDS else snapshot["state"],
            "heartbeat_age_seconds": round(age, 1)}


def status_text(snapshot: dict[str, Any]) -> str:
    """Формирует короткое личное сообщение администратора только из технических полей."""
    labels = {"starting": "запускается", "ok": "работает", "degraded": "требует внимания",
              "failed": "ошибка процесса", "stopped": "остановлен", "stale": "нет свежего состояния"}
    connected = snapshot.get("discord_connected")
    discord_state = "подключён" if connected else "нет подключения"
    if snapshot.get("mode") == "demo":
        discord_state = "деморежим"
    checked, accounts = snapshot.get("uex_checked", 0), snapshot.get("uex_accounts", 0)
    last = snapshot.get("uex_oldest_success_at")
    last_text = f"<t:{int(last)}:R>" if last else "ещё не было"
    errors = ", ".join(snapshot.get("uex_errors", [])) or "нет"
    http = snapshot.get("discord_http")
    http_text = ""
    if http:
        counts = ", ".join(f"{code}: {count}" for code, count in sorted(http["errors"].items())) or "нет"
        http_text = f"Discord HTTP с запуска: запросов {http['requests']}, ошибки — {counts}.\n"
        http_text += f"Запросов за ≈10 минут: {http['recent_requests']}.\n"
        if http.get("paused_until"):
            http_text += f"Некоторые запросы Discord на паузе до <t:{int(http['paused_until'])}:t>.\n"
        last_error = http.get("last_error")
        if last_error:
            http_text += f"Последний отказ: {last_error['status']} · {last_error['source']} · <t:{int(last_error['at'])}:R>.\n"
            if last_error.get("method") and last_error.get("route"):
                http_text += f"Операция: {last_error['method']} {last_error['route']}.\n"
            if last_error["status"] == "429" and last_error.get("scope"):
                http_text += f"Область ограничения: {last_error['scope']}.\n"
            if last_error.get("request_ms") is not None:
                http_text += f"Запрос к Discord: {last_error['request_ms']} мс.\n"
            if last_error.get("interaction_age_ms") is not None:
                http_text += f"Возраст действия перед HTTP-запросом: {last_error['interaction_age_ms']} мс.\n"
    return (f"**Состояние бота: {labels.get(snapshot['state'], 'неизвестно')}**\n"
            f"Discord: {discord_state}.\n{http_text}UEX: проверено после запуска {checked}/{accounts} подключений.\n"
            f"Самая давняя успешная сверка: {last_text}.\nОшибки UEX: {errors}.\n"
            f"Переводчик: {snapshot.get('translator', 'неизвестно')} — ошибки перевода смотри в логах.")


def main() -> None:
    """Проверяет heartbeat из TRADER_DATA_DIR без токенов, HTTP, Discord и запросов UEX."""
    import argparse

    parser = argparse.ArgumentParser(description="Состояние SC Discord Trader без сетевых запросов")
    parser.add_argument("--check", action="store_true", help="Только код выхода: 0 — процесс жив, 1 — запуск/остановка/устаревшее состояние")
    args = parser.parse_args()
    try:
        path = status_path(Path(os.getenv("TRADER_DATA_DIR", "data")), os.getenv("TRADER_MODE", "demo"))
        snapshot = read_status(path)
    except (OSError, ValueError, TypeError) as exc:
        snapshot = {"state": "unavailable", "error_type": type(exc).__name__}
    if not args.check:
        print(json.dumps(snapshot, ensure_ascii=False, indent=2))
    # Отказ внешней площадки требует диагностики, а не бесконечного рестарта процесса.
    raise SystemExit(0 if snapshot["state"] in {"ok", "degraded"} else 1)


if __name__ == "__main__":
    main()
