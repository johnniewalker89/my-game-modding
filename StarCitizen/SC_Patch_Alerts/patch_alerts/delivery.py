"""Один подтверждённый webhook-запрос без скрытых повторов и утечки URL."""

import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class WebhookError(Exception):
    """Хранит безопасный code и необязательные HTTP status/retry_after в секундах."""

    def __init__(self, code: str, *, status: int = 0, retry_after: float | None = None):
        """Создаёт отказ без тела ответа, URL и секрета."""
        super().__init__(code)
        self.code = code
        self.status = status
        self.retry_after = retry_after


class NoRedirect(HTTPRedirectHandler):
    """Запрещает пересылать секрет webhook на адрес перенаправления."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        """Отклоняет любой redirect исходного req без второго запроса."""
        return None


@dataclass(frozen=True)
class WebhookTarget:
    """Связывает закрытый URL с ожидаемыми ID webhook, канала и сервера."""

    url: str = field(repr=False)
    webhook_id: str
    channel_id: str
    guild_id: str

    @classmethod
    def from_file(cls, path: Path, webhook_id: str, channel_id: str, guild_id: str):
        """Читает ключ из path и проверяет точные IDs, не выполняя сетевые запросы."""
        if path.stat().st_size > 2048:
            raise ValueError("webhook_secret_too_large")
        url = path.read_text(encoding="utf-8").strip()
        parsed = urlsplit(url)
        pattern = rf"/api(?:/v10)?/webhooks/{re.escape(webhook_id)}/[A-Za-z0-9_.-]{{40,}}"
        if (parsed.scheme != "https" or parsed.netloc != "discord.com"
                or not re.fullmatch(pattern, parsed.path) or parsed.query or parsed.fragment
                or "redacted" in url.lower()
                or not all(re.fullmatch(r"[0-9]{1,20}", item) for item in (webhook_id, channel_id, guild_id))):
            raise ValueError("invalid_webhook_target")
        return cls(url, webhook_id, channel_id, guild_id)


class WebhookClient:
    """Читает/публикует только в одном WebhookTarget, с явным подтверждением сообщения."""

    def __init__(self, target: WebhookTarget, opener=None, *, mention_role_id: str = ""):
        """Привязывает target, разрешённую роль и тестовый opener без скрытой отправки."""
        if not isinstance(mention_role_id, str) or (mention_role_id and (
                not re.fullmatch(r"[1-9][0-9]{0,19}", mention_role_id) or mention_role_id == target.guild_id)):
            raise ValueError("invalid_news_mention_role")
        self.target = target
        self.mention_role_id = mention_role_id
        self.opener = opener or build_opener(NoRedirect())

    def _request(self, method: str, suffix: str = "", payload: dict | None = None) -> dict:
        """Выполняет ровно один method; ошибки возвращает безопасным WebhookError."""
        body = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
        request = Request(self.target.url + suffix, data=body, method=method,
                          headers={"Content-Type": "application/json", "User-Agent": "SC-Companion/0.1"})
        try:
            with self.opener.open(request, timeout=8) as response:
                raw = response.read(1024 * 1024 + 1)
                if response.status != 200 or len(raw) > 1024 * 1024:
                    raise WebhookError("unexpected_response")
                value = json.loads(raw)
                if not isinstance(value, dict):
                    raise WebhookError("invalid_response")
                return value
        except HTTPError as exc:
            retry_after = None
            if exc.code == 429:
                try:
                    value = json.loads(exc.read(65537))
                    retry_after = float(value.get("retry_after", exc.headers.get("Retry-After")))
                except (OSError, ValueError, TypeError, AttributeError):
                    try:
                        retry_after = float(exc.headers.get("Retry-After"))
                    except (ValueError, TypeError, AttributeError):
                        retry_after = None
                if retry_after is not None and (not math.isfinite(retry_after) or retry_after < 0):
                    retry_after = None
            raise WebhookError(f"http_{exc.code}", status=exc.code, retry_after=retry_after) from None
        except WebhookError:
            raise
        except Exception:
            raise WebhookError("network_or_invalid_response") from None

    def verify(self) -> None:
        """Проверяет текущие webhook/channel/guild до возможной публикации."""
        value = self._request("GET")
        if any(str(value.get(key)) != expected for key, expected in (
                ("id", self.target.webhook_id), ("channel_id", self.target.channel_id),
                ("guild_id", self.target.guild_id))):
            raise WebhookError("target_mismatch")

    def send(self, payload: dict) -> str:
        """Публикует payload без пинга либо с одной настроенной ролью, проверяет message ID."""
        no_ping = payload.get("allowed_mentions") == {"parse": []} and not payload.get("content")
        role_ping = (bool(self.mention_role_id)
                     and payload.get("allowed_mentions") == {"parse": [], "roles": [self.mention_role_id]}
                     and payload.get("content") == f"<@&{self.mention_role_id}>")
        if not (no_ping or role_ping) or len(payload.get("embeds", [])) != 1:
            raise ValueError("unsafe_webhook_payload")
        embed = payload["embeds"][0]
        if len(embed.get("title", "")) > 256 or len(embed.get("description", "")) > 4096:
            raise ValueError("oversized_webhook_payload")
        value = self._request("POST", "?wait=true", payload)
        return self._message_id(value, payload)

    def confirm(self, message_id: str, payload: dict) -> str:
        """Проверяет существующий message_id при ручном разборе неизвестного исхода."""
        if not re.fullmatch(r"[0-9]{1,20}", message_id):
            raise ValueError("invalid_message_id")
        value = self._request("GET", "/messages/" + message_id)
        confirmed = self._message_id(value, payload)
        if confirmed != message_id:
            raise WebhookError("message_mismatch")
        return confirmed

    def _message_id(self, value: dict, payload: dict) -> str:
        """Сверяет value с target, текстом, карточкой и точными упоминаниями payload."""
        identifier = str(value.get("id", ""))
        if (not re.fullmatch(r"[0-9]{1,20}", identifier)
                or str(value.get("channel_id")) != self.target.channel_id
                or str(value.get("webhook_id")) != self.target.webhook_id
                or value.get("content", "") != payload.get("content", "")
                or value.get("mention_roles", []) != payload.get("allowed_mentions", {}).get("roles", [])
                or value.get("mentions") or value.get("mention_everyone")):
            raise WebhookError("message_mismatch")
        actual = value.get("embeds", [])
        expected = payload["embeds"]
        if len(actual) != 1 or any(actual[0].get(key) != item for key, item in expected[0].items()):
            raise WebhookError("message_mismatch")
        return identifier
