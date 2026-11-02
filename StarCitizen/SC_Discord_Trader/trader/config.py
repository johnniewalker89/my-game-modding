"""Настройки одного локального экземпляра сервиса."""

import os
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    """Хранит режим, пути и подключения; секреты исключены из repr."""

    mode: str = "demo"
    data_dir: Path = Path("data")
    translator: str = "libretranslate"
    translate_url: str = "http://translator:5000"
    discord_token: str = field(default="", repr=False)
    uex_app_token: str = field(default="", repr=False)
    guild_id: int = 0
    channel_id: int = 0
    role_id: int = 0
    send_mode: str = "test"
    listing_mode: str = "test"
    azure_key: str = field(default="", repr=False)
    azure_region: str = ""
    groq_key: str = field(default="", repr=False)
    groq_model: str = "openai/gpt-oss-120b"

    @classmethod
    def from_env(cls) -> "Settings":
        """Читает только собственные TRADER_* переменные и проверяет режим."""
        settings = cls(
            mode=os.getenv("TRADER_MODE", "demo"),
            data_dir=Path(os.getenv("TRADER_DATA_DIR", "data")),
            translator=os.getenv("TRADER_TRANSLATOR", "libretranslate"),
            translate_url=os.getenv("TRADER_TRANSLATE_URL", "http://translator:5000"),
            discord_token=os.getenv("TRADER_DISCORD_TOKEN", ""),
            uex_app_token=os.getenv("TRADER_UEX_APP_TOKEN", ""),
            guild_id=int(os.getenv("TRADER_GUILD_ID") or 0),
            channel_id=int(os.getenv("TRADER_CHANNEL_ID") or 0),
            role_id=int(os.getenv("TRADER_ROLE_ID") or 0),
            send_mode=os.getenv("TRADER_UEX_SEND_MODE", "test"),
            listing_mode=os.getenv("TRADER_UEX_LISTING_MODE", "test"),
            azure_key=os.getenv("TRADER_AZURE_KEY", ""),
            azure_region=os.getenv("TRADER_AZURE_REGION", ""),
            groq_key=os.getenv("TRADER_GROQ_API_KEY", ""),
            groq_model=os.getenv("TRADER_GROQ_MODEL", "openai/gpt-oss-120b"),
        )
        if settings.mode not in {"demo", "live"}:
            raise ValueError("TRADER_MODE должен быть demo или live")
        if settings.translator not in {"libretranslate", "azure", "groq"}:
            raise ValueError("Неизвестный переводчик")
        if settings.send_mode not in {"test", "production"}:
            raise ValueError("TRADER_UEX_SEND_MODE должен быть test или production")
        if settings.listing_mode not in {"test", "production"}:
            raise ValueError("TRADER_UEX_LISTING_MODE должен быть test или production")
        if settings.mode == "live" and not all(
            [settings.discord_token, settings.uex_app_token, settings.guild_id,
             settings.channel_id, settings.role_id]
        ):
            raise ValueError("Для live нужны токены Discord/UEX и ID сервера, канала, роли")
        if settings.translator == "azure" and not settings.azure_key:
            raise ValueError("Для Azure нужен TRADER_AZURE_KEY")
        if settings.translator == "groq" and not (settings.groq_key and settings.groq_model):
            raise ValueError("Для Groq нужны TRADER_GROQ_API_KEY и TRADER_GROQ_MODEL")
        return settings
