"""Счётчики реальных запросов Discord без дополнительных запросов и истории."""

import logging
import math
import time
from collections import Counter, deque
from typing import Any

import aiohttp
import discord

LOGGER = logging.getLogger(__name__)
ERROR_WINDOW_SECONDS = 300


class DiscordHttpHealth:
    """Хранит число запросов, коды ошибок и один последний отказ с момента запуска."""

    def __init__(self) -> None:
        """Подключает штатный trace aiohttp к существующей HTTP-сессии SDK."""
        self.requests = 0
        self._minutes: deque[list[int]] = deque(maxlen=11)
        self.errors: Counter[str] = Counter()
        self.last_error: dict[str, Any] | None = None
        self._next_log_at = 0.0
        self.trace = aiohttp.TraceConfig()
        self.trace.on_request_start.append(self._request_start)
        self.trace.on_request_end.append(self._response)
        self.trace.on_request_exception.append(self._connection_error)

    async def _request_start(self, session: Any, context: Any, params: Any) -> None:
        """Отмечает начало HTTP-запроса и возраст interaction по его публичному snowflake ID."""
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
        """Считает полученный ответ; тело, полный URL и заголовки не сохраняет."""
        self._request()
        response = params.response
        if response.status < 400:
            return
        try:
            retry_after = float(response.headers.get("Retry-After", ""))
            if not math.isfinite(retry_after) or retry_after < 0:
                retry_after = None
        except ValueError:
            retry_after = None
        kind = "html" if "text/html" in response.headers.get("Content-Type", "") else "http"
        self._error(str(response.status), params.url.path, kind, retry_after, context)

    async def _connection_error(self, session: Any, context: Any, params: Any) -> None:
        """Считает сетевой отказ без текста исключения, который может содержать URL."""
        self._request()
        self._error("network", params.url.path, "network", None, context)

    def _request(self) -> None:
        """Считает нагрузку по минутам; сохраняет максимум 11 маленьких счётчиков."""
        self.requests += 1
        minute = int(time.monotonic() // 60)
        if not self._minutes or self._minutes[-1][0] != minute:
            self._minutes.append([minute, 0])
        self._minutes[-1][1] += 1

    def _error(self, status: str, path: str, kind: str, retry_after: float | None, context: Any = None) -> None:
        """Сохраняет причину и замеры из trace context; пишет не больше одной сводки в минуту."""
        source = "rest"
        if "/webhooks/" in path:
            source = "webhook"
        elif "/interactions/" in path:
            source = "interaction"
        now = time.time()
        self.errors[status] += 1
        self.last_error = {"at": now, "status": status, "source": source,
                           "kind": kind, "retry_after": retry_after}
        started_at = getattr(context, "started_at", None)
        if started_at is not None:
            self.last_error["request_ms"] = round((time.monotonic() - started_at) * 1000)
        interaction_age = getattr(context, "interaction_age_ms", None)
        if interaction_age is not None:
            self.last_error["interaction_age_ms"] = interaction_age
        if now >= self._next_log_at:
            self._next_log_at = now + 60
            LOGGER.warning("Discord HTTP отказ status=%s source=%s kind=%s retry_after=%s request_ms=%s interaction_age_ms=%s requests=%s recent_requests=%s errors=%s",
                           status, source, kind, retry_after, self.last_error.get("request_ms"),
                           self.last_error.get("interaction_age_ms"), self.requests,
                           self.snapshot()["recent_requests"], dict(self.errors))

    def snapshot(self) -> dict[str, Any]:
        """Возвращает маленький JSON-совместимый снимок без сети и приватных данных."""
        cutoff = int(time.monotonic() // 60) - 10
        # Округление поминутное: окно включает все последние 10 минут и до минуты сверху.
        recent = sum(count for minute, count in self._minutes if minute >= cutoff)
        return {"requests": self.requests, "recent_requests": recent, "errors": dict(self.errors),
                "last_error": dict(self.last_error) if self.last_error else None}


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
