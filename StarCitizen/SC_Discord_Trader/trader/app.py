"""HTTP-стенд, жизненный цикл приложения и локальный запуск."""

import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from trader.config import Settings
from trader.runtime import POLL_SECONDS, configure_logging, open_runtime
from trader.service import TraderService


class DemoDeal(BaseModel):
    """Описывает тестовую карточку и выбранного локального владельца."""

    owner: Literal["demo-1", "demo-2"] = "demo-1"
    direction: Literal["sell", "buy"] = "sell"
    title: str = Field(default="Karna Rifle", min_length=1, max_length=200)
    peer: str = Field(default="SpaceBuyer", min_length=1, max_length=100)


class DemoMessage(BaseModel):
    """Несёт текст сообщения и устойчивый ключ повторного HTTP-запроса."""

    owner: Literal["demo-1", "demo-2"] = "demo-1"
    text: str = Field(min_length=1, max_length=2000)
    request_id: str = Field(default_factory=lambda: uuid.uuid4().hex, min_length=1, max_length=100)


def create_app(settings: Settings | None = None, *, http_transport: httpx.AsyncBaseTransport | None = None) -> FastAPI:
    """Создаёт приложение с изолированными данными demo/live и явными зависимостями."""
    settings = settings or Settings.from_env()
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        """Открывает состояние, запускает обработчики и корректно останавливает их."""
        async with open_runtime(settings, http_transport=http_transport) as runtime:
            app.state.service, app.state.bot = runtime.service, runtime.bot
            app.state.status_provider = runtime.status_provider
            yield

    app = FastAPI(title="SC Discord Trader", lifespan=lifespan)

    def demo_service() -> TraderService:
        """Запрещает все тестовые действия в live, даже при ручном HTTP-запросе."""
        if settings.mode != "demo":
            raise HTTPException(403, "Тестовые действия отключены в live")
        return app.state.service

    @app.exception_handler(PermissionError)
    async def denied(request, exc: PermissionError):
        """Возвращает понятный отказ доступа без traceback и приватных данных."""
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=403, content={"detail": str(exc)})

    @app.exception_handler(ValueError)
    async def invalid_action(request, exc: ValueError):
        """Отклоняет некорректное действие без вывода внутренних значений."""
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=400, content={"detail": "Действие недоступно для текущего состояния сделки"})

    @app.get("/health")
    async def health():
        """Показывает жизнеспособность процесса отдельно от подключения к Discord."""
        accounts = [account for account in app.state.service.store.all("account") if account.get("secret")]
        return {"status": "ok", "mode": settings.mode, "translator": settings.translator,
                "poll_interval_seconds": POLL_SECONDS,
                "uex_personal_accounts": sum(bool(account.get("app_token")) for account in accounts),
                "uex_legacy_accounts": sum(not account.get("app_token") for account in accounts),
                "discord_connected": bool(app.state.bot and app.state.bot.is_ready()),
                "last_error": app.state.service.last_error,
                "runtime": app.state.status_provider()}

    @app.get("/")
    async def index():
        """Открывает локальный стенд без внешних скриптов и CDN."""
        return FileResponse(Path(__file__).parent / "static" / "index.html")

    @app.get("/demo/state")
    async def state(owner: str = "demo-1"):
        """Возвращает только сделки и сообщения текущего тестового владельца."""
        service = demo_service()
        await service.account(owner)
        return {"deals": service.store.all("deal", owner), "messages": service.store.all("message", owner)}

    @app.post("/demo/deals")
    async def new_deal(body: DemoDeal):
        """Создаёт отдельный тестовый диалог продажи или покупки."""
        service = demo_service()
        row = service.market.add_deal(body.owner, body.direction, body.title, body.peer)
        await service.scan(body.owner, force=True)
        return next(deal for deal in service.store.all("deal", body.owner) if deal["external_id"] == row["id"])

    @app.post("/demo/deals/{deal_id}/incoming")
    async def incoming(deal_id: str, body: DemoMessage):
        """Имитирует внешний английский ответ и выполняет настоящий перевод."""
        service = demo_service()
        deal = await service.deal(body.owner, deal_id)
        if deal["own_closed"]:
            raise ValueError("Тестовая сделка завершена")
        service.market.add_message(body.owner, deal["external_id"], deal["peer"], body.text,
                                   request_id=body.request_id)
        await service.scan(body.owner, force=True)
        return {"accepted": True}

    @app.post("/demo/deals/{deal_id}/reply")
    async def reply(deal_id: str, body: DemoMessage):
        """Отправляет русский ответ через общий обработчик и тестовую площадку."""
        return await demo_service().reply(body.owner, deal_id, body.request_id, body.text)

    @app.post("/demo/deals/{deal_id}/close")
    async def close_deal(deal_id: str, owner: str = "demo-1"):
        """Завершает тестовую сделку; не вызывает недокументированные действия UEX."""
        service = demo_service()
        deal = await service.deal(owner, deal_id)
        service.market.close_deal(owner, deal["external_id"])
        await service.scan(owner, force=True)
        return {"closed": True}

    return app


def main() -> None:
    """Настраивает единственный вывод логов и запускает один процесс HTTP/Discord."""
    configure_logging()
    uvicorn.run(create_app(), host="0.0.0.0", port=8765, access_log=False)
