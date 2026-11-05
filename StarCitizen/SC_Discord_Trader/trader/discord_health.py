"""Диагностика Discord и паузы Retry-After без дополнительных запросов и фоновых задач."""

import hashlib
import logging
import math
import re
import time
from collections import Counter, deque
from typing import Any

import aiohttp
import discord

LOGGER = logging.getLogger(__name__)
ERROR_WINDOW_SECONDS = 300
ROUTE_NAMES = frozenset({"guilds", "members", "channels", "messages", "threads", "archived", "public", "private",
                         "users", "@me", "@original", "applications", "commands", "webhooks", "interactions",
                         "callback", "reactions", "pins", "permissions", "recipients", "thread-members"})


def retry_seconds(headers: Any) -> float | None:
    """Читает числовой Retry-After в секундах, исключая отрицательные и бесконечные значения."""
    try:
        value = float(headers.get("Retry-After", ""))
    except (ValueError, TypeError):
        return None
    return value if math.isfinite(value) and value >= 0 else None


class DiscordBackoff(RuntimeError):
    """Сообщает о временной паузе Discord; retry_after задаётся в секундах."""

    def __init__(self, retry_after: float):
        """Даёт игроку срок повторной попытки без деталей запроса или секретов."""
        self.retry_after = retry_after
        delay = f"{math.ceil(retry_after / 60)} мин." if retry_after >= 60 else f"{max(1, math.ceil(retry_after))} с."
        super().__init__(f"Discord временно ограничил запросы. Попробуй через {delay}")


def safe_route(path: str) -> str:
    """Оставляет только названия операций API, заменяя ID, токены и прочие сегменты."""
    parts = re.sub(r"^/api/v\d+", "", path).strip("/").split("/")
    return "/" + "/".join("{token}" if index == 2 and parts[0] in {"webhooks", "interactions"}
                           else part if part in ROUTE_NAMES else "{id}" for index, part in enumerate(parts))


class DiscordHttpHealth:
    """Хранит число запросов, коды ошибок и один последний отказ с момента запуска."""

    def __init__(self) -> None:
        """Подключает штатный trace aiohttp к существующей HTTP-сессии SDK."""
        self.requests = 0
        self._minutes: deque[list[int]] = deque(maxlen=11)
        self.errors: Counter[str] = Counter()
        self.last_error: dict[str, Any] | None = None
        self._blocked: dict[bytes | str, float] = {}
        self._next_log_at = 0.0
        self.trace = aiohttp.TraceConfig()
        self.trace.on_request_start.append(self._request_start)
        self.trace.on_request_end.append(self._response)
        self.trace.on_request_exception.append(self._connection_error)

    async def _request_start(self, session: Any, context: Any, params: Any) -> None:
        """Не выпускает повтор до Retry-After; отмечает HTTP-время и возраст interaction."""
        key = hashlib.sha256(f"{params.method} {params.url.path}".encode()).digest()
        route = safe_route(params.url.path)
        # Ответы interaction с собственным токеном не входят в глобальный лимит бота.
        interaction = route.startswith(("/interactions/", "/webhooks/")) and "{token}" in route
        global_until = 0 if interaction else self._blocked.get("global", 0)
        remaining = max(self._blocked.get(key, 0), global_until) - time.monotonic()
        if remaining > 0:
            raise DiscordBackoff(remaining)
        context.request_key = key
        context.method = params.method
        context.route = route
        context.started_at = time.monotonic()
        context.interaction_age_ms = None
        parts = params.url.path.rsplit("/", 3)
        if len(parts) == 4 and parts[0].endswith("/interactions") and parts[3] == "callback":
            try:
                created_at = discord.utils.snowflake_time(int(parts[1])).timestamp()
                context.interaction_age_ms = round((time.time() - created_at) * 1000)
            except (ValueError, OverflowError, OSError):
                pass

    async def _response(self, session: Any, context: Any, params: Any) -> None:
        """Считает ответ и читает безопасные поля лимита без тела, полного URL и полного набора заголовков."""
        self._request()
        response = params.response
        if response.status < 400:
            return
        retry_after = retry_seconds(response.headers)
        kind = "html" if "text/html" in response.headers.get("Content-Type", "") else "http"
        scope = response.headers.get("X-RateLimit-Scope")
        scope = scope if scope in {"user", "global", "shared"} else "unknown"
        global_limit = scope == "global" or response.headers.get("X-RateLimit-Global", "").lower() == "true"
        details: dict[str, Any] = {"scope": "global" if global_limit else scope,
                                   "via": bool(response.headers.get("Via")),
                                   "response_type": "html" if kind == "html" else (
                                       "json" if "application/json" in response.headers.get("Content-Type", "") else "other")}
        for header, name in (("X-RateLimit-Limit", "limit"), ("X-RateLimit-Remaining", "remaining"),
                             ("X-RateLimit-Reset-After", "reset_after")):
            try:
                value = float(response.headers.get(header, ""))
            except ValueError:
                continue
            if math.isfinite(value) and value >= 0:
                details[name] = value
        if response.status == 429:
            now = time.monotonic()
            self._blocked = {key: until for key, until in self._blocked.items() if until > now}
            key = "global" if global_limit else context.request_key
            self._blocked[key] = max(self._blocked.get(key, 0), now + (retry_after if retry_after is not None else 1))
        self._error(str(response.status), params.url.path, kind, retry_after, context, details)

    async def _connection_error(self, session: Any, context: Any, params: Any) -> None:
        """Считает сетевой отказ без текста исключения, который может содержать URL."""
        if isinstance(getattr(params, "exception", None), DiscordBackoff):
            return
        self._request()
        self._error("network", params.url.path, "network", None, context)

    def _request(self) -> None:
        """Считает нагрузку по минутам; сохраняет максимум 11 маленьких счётчиков."""
        self.requests += 1
        minute = int(time.monotonic() // 60)
        if not self._minutes or self._minutes[-1][0] != minute:
            self._minutes.append([minute, 0])
        self._minutes[-1][1] += 1

    def _error(self, status: str, path: str, kind: str, retry_after: float | None,
               context: Any = None, details: dict[str, Any] | None = None) -> None:
        """Сохраняет причину и замеры из trace context; пишет не больше одной сводки в минуту."""
        source = "rest"
        if "/webhooks/" in path:
            source = "webhook"
        elif "/interactions/" in path:
            source = "interaction"
        now = time.time()
        self.errors[status] += 1
        self.last_error = {"at": now, "status": status, "source": source,
                           "kind": kind, "retry_after": retry_after, **(details or {})}
        if getattr(context, "method", None):
            self.last_error.update(method=context.method, route=context.route)
        started_at = getattr(context, "started_at", None)
        if started_at is not None:
            self.last_error["request_ms"] = round((time.monotonic() - started_at) * 1000)
        interaction_age = getattr(context, "interaction_age_ms", None)
        if interaction_age is not None:
            self.last_error["interaction_age_ms"] = interaction_age
        if now >= self._next_log_at:
            self._next_log_at = now + 60
            LOGGER.warning("Discord HTTP отказ status=%s source=%s method=%s route=%s kind=%s scope=%s via=%s limit=%s remaining=%s reset_after=%s response_type=%s retry_after=%s request_ms=%s interaction_age_ms=%s requests=%s recent_requests=%s errors=%s",
                           status, source, self.last_error.get("method"), self.last_error.get("route"), kind,
                           self.last_error.get("scope"), self.last_error.get("via"), self.last_error.get("limit"),
                           self.last_error.get("remaining"), self.last_error.get("reset_after"),
                           self.last_error.get("response_type"), retry_after, self.last_error.get("request_ms"),
                           self.last_error.get("interaction_age_ms"), self.requests,
                           self.snapshot()["recent_requests"], dict(self.errors))

    def snapshot(self) -> dict[str, Any]:
        """Возвращает маленький JSON-совместимый снимок без сети и приватных данных."""
        cutoff = int(time.monotonic() // 60) - 10
        # Округление поминутное: окно включает все последние 10 минут и до минуты сверху.
        recent = sum(count for minute, count in self._minutes if minute >= cutoff)
        report = {"requests": self.requests, "recent_requests": recent, "errors": dict(self.errors),
                  "last_error": dict(self.last_error) if self.last_error else None}
        now = time.monotonic()
        self._blocked = {key: until for key, until in self._blocked.items() if until > now}
        remaining = max(self._blocked.values(), default=0) - now
        if remaining > 0:
            report["paused_until"] = time.time() + remaining
        return report


class DiscordHttpErrorFilter(logging.Filter):
    """Заменяет полный HTTP traceback SDK короткой причиной без HTML и URL токенов."""

    def filter(self, record: logging.LogRecord) -> bool:
        """Сохраняет уровень и источник ошибки, сокращая только HTTP-исключения Discord."""
        if record.name.startswith("discord.") and record.exc_info:
            error = record.exc_info[1]
            error = getattr(error, "original", error)
            if isinstance(error, discord.HTTPException):
                record.msg = "Discord HTTP error status=%s code=%s error_type=%s"
                record.args = (error.status, error.code, type(error).__name__)
                record.exc_info = None
                record.exc_text = None
        return True
