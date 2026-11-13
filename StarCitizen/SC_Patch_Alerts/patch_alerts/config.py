"""Явная настройка новостного модуля; секрет остаётся в отдельном файле."""

import json
from dataclasses import dataclass
from pathlib import Path

from patch_alerts.delivery import WebhookTarget


@dataclass(frozen=True)
class NewsSettings:
    """Задаёт включение доставки, собственный data_dir, интервал и фиксированную цель."""

    enabled: bool = False
    data_dir: Path = Path("patches-data")
    poll_seconds: int = 90
    webhook_file: Path | None = None
    webhook_id: str = ""
    channel_id: str = ""
    guild_id: str = ""

    @classmethod
    def from_file(cls, path: Path):
        """Читает только известные ключи path; относительные пути привязывает к конфигу."""
        if path.stat().st_size > 65536:
            raise ValueError("news_config_too_large")
        value = json.loads(path.read_text(encoding="utf-8"))
        allowed = {"enabled", "data_dir", "poll_seconds", "webhook_file", "webhook_id", "channel_id", "guild_id"}
        if not isinstance(value, dict) or set(value) - allowed or type(value.get("enabled", False)) is not bool:
            raise ValueError("invalid_news_config")
        if not value.get("enabled", False):
            return cls()
        if type(value.get("poll_seconds", 90)) is not int or value.get("poll_seconds", 90) < 60:
            raise ValueError("news_poll_must_be_at_least_60_seconds")
        required = ("data_dir", "webhook_file", "webhook_id", "channel_id", "guild_id")
        if any(not isinstance(value.get(key), str) or not value[key].strip() for key in required):
            raise ValueError("missing_news_config")
        data_dir = (path.parent / value["data_dir"]).resolve()
        webhook_file = (path.parent / value["webhook_file"]).resolve()
        return cls(True, data_dir, value.get("poll_seconds", 90), webhook_file,
                   value["webhook_id"], value["channel_id"], value["guild_id"])

    def target(self) -> WebhookTarget:
        """Читает секрет только включённого модуля и проверяет привязку к его IDs."""
        if not self.enabled or self.webhook_file is None:
            raise ValueError("news_disabled")
        return WebhookTarget.from_file(self.webhook_file, self.webhook_id, self.channel_id, self.guild_id)
