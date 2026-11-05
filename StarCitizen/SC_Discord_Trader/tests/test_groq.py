"""Проверки Groq без внешних запросов: контракт, секреты и отказ от опасного результата."""

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx

from trader.config import Settings
from trader.app import create_app
from trader.translation import TranslationError, Translator


def completion(text, finish_reason="stop"):
    """Создаёт ответ Groq с переводом text и заданной причиной завершения."""
    return {"choices": [{"finish_reason": finish_reason,
                         "message": {"content": json.dumps({"translation": text})}}]}


class GroqTests(unittest.IsolatedAsyncioTestCase):
    """Проверяет настоящий адаптер и общие проверки защищённых значений."""

    async def test_request_context_and_restored_names_numbers_and_units(self):
        """Контекст передаётся как данные, а ключ только в заголовке запроса."""
        def respond(request):
            self.assertEqual(str(request.url), "https://api.groq.com/openai/v1/chat/completions")
            self.assertEqual(request.headers["Authorization"], "Bearer test-groq-key")
            body = json.loads(request.content)
            self.assertNotIn("test-groq-key", request.content.decode())
            self.assertEqual(body["model"], "openai/gpt-oss-120b")
            self.assertEqual(body["reasoning_effort"], "low")
            self.assertTrue(body["response_format"]["json_schema"]["strict"])
            data = json.loads(body["messages"][1]["content"])
            self.assertEqual(data["context"], {"item": "Janalite", "quality": 964})
            self.assertEqual(data["source_language"], "ru")
            self.assertNotIn("Janalite", data["text"])
            self.assertEqual(data["placeholders"], {"ZXQ0QXZ": "Seller", "ZXQ1QXZ": "Janalite", "ZXQ2QXZ": "aUEC"})
            return httpx.Response(200, json=completion(
                "Hi, ZXQ0QXZ! Is ZXQ1QXZ of quality 964 available for 25000 ZXQ2QXZ?"))

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            result = await Translator(client, "groq", "http://unused", groq_key="test-groq-key").translate(
                "Привет, Seller! Janalite качества 964 доступен за 25000 aUEC?", "ru", "en",
                ("Janalite", "Seller"), context={"item": "Janalite", "quality": 964})
            self.assertEqual(result, "Hi, Seller! Is Janalite of quality 964 available for 25000 aUEC?")

    async def test_abbreviation_context_is_preserved_for_model_instead_of_first_person_rewrite(self):
        """Groq получает исходное WTS в чужой речи, а ник WTBman остаётся защищённым."""
        def respond(request):
            data = json.loads(json.loads(request.content)["messages"][1]["content"])
            self.assertEqual(data["text"], "ZXQ0QXZ, you said WTS, but I want to buy.")
            self.assertEqual(data["placeholders"], {"ZXQ0QXZ": "WTBman"})
            return httpx.Response(200, json=completion("ZXQ0QXZ, ты сказал, что продаёшь, а я хочу купить."))

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            result = await Translator(client, "groq", "", groq_key="test-key").translate(
                "WTBman, you said WTS, but I want to buy.", "en", "ru", ("WTBman",))
        self.assertIn("WTBman", result)
        self.assertIn("ты сказал, что продаёшь", result)

    async def test_provider_failure_has_no_retry_or_local_fallback(self):
        """Отказ ключа, лимит, сбой сервера и таймаут не запускают повтор или другой переводчик."""
        for failure in (401, 429, 503, "timeout"):
            with self.subTest(failure=failure):
                requests = []

                def respond(request):
                    """Фиксирует попытку и возвращает выбранный отказ провайдера."""
                    requests.append(request)
                    if failure == "timeout":
                        raise httpx.ReadTimeout("test", request=request)
                    return httpx.Response(failure, json={"error": {"message": "test"}})

                async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
                    with self.assertRaises(TranslationError):
                        await Translator(client, "groq", "http://unused", groq_key="test-key").translate(
                            "Привет" if failure == "timeout" else "Товар ещё доступен?", "ru", "en")
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0].url.host, "api.groq.com")

    async def test_invalid_truncated_or_damaged_output_is_not_a_translation(self):
        """Обрезанный ответ, испорченные числа и маркеры не попадают в отправку UEX."""
        responses = [completion("Price 25000 ZXQ0QXZ", "length"),
                     completion("Price 25001 ZXQ0QXZ"), completion("Price 25000 UEC"),
                     completion(""), {"choices": []}, {"choices": ["invalid"]},
                     {"choices": [{"finish_reason": "stop", "message": {"content": "not-json"}}]}]
        for response in responses:
            with self.subTest(response=response):
                async with httpx.AsyncClient(transport=httpx.MockTransport(
                    lambda request: httpx.Response(200, json=response)
                )) as client:
                    with self.assertRaises(TranslationError):
                        await Translator(client, "groq", "http://unused", groq_key="test-key").translate(
                            "Цена 25000 aUEC", "ru", "en")

    async def test_provider_log_contains_code_without_response_body_or_message(self):
        """404 различим по коду Groq; ключ и текст отказа с пользовательскими данными не логируются."""
        async with httpx.AsyncClient(transport=httpx.MockTransport(lambda request: httpx.Response(
                404, json={"error": {"code": "model_not_found", "message": "private text test-key"}}))) as client:
            with self.assertLogs("trader.translation", level="WARNING") as captured:
                with self.assertRaises(TranslationError):
                    await Translator(client, "groq", "", groq_key="test-key").translate("Привет", "ru", "en")
        log = " ".join(captured.output)
        self.assertIn("http=404", log)
        self.assertIn("code=model_not_found", log)
        self.assertNotIn("private text", log)
        self.assertNotIn("test-key", log)

    async def test_application_uses_groq_settings_and_passes_deal_context(self):
        """HTTP-приложение передаёт выбранный Groq, ключ и контекст в настоящий адаптер."""
        requests = []

        def respond(request):
            requests.append(request)
            self.assertEqual(request.url.host, "api.groq.com")
            self.assertEqual(request.headers["Authorization"], "Bearer app-groq-key")
            body = json.loads(request.content)
            data = json.loads(body["messages"][1]["content"])
            self.assertEqual(data["context"], {"item": "Janalite", "quality": None, "player_action": "WTB"})
            return httpx.Response(200, json=completion("The price is 25000 ZXQ0QXZ."))

        with tempfile.TemporaryDirectory() as temp:
            app = create_app(Settings(data_dir=Path(temp), translator="groq", groq_key="app-groq-key"),
                             http_transport=httpx.MockTransport(respond))
            async with app.router.lifespan_context(app):
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                    response = await client.post("/demo/deals", json={"direction": "buy", "title": "Janalite", "peer": "TestSeller"})
                    self.assertEqual(response.status_code, 200)
                    reply = await client.post(f"/demo/deals/{response.json()['id']}/reply",
                                              json={"text": "Цена 25000 aUEC.", "request_id": "groq-once"})
                    self.assertEqual(reply.status_code, 200)
                    self.assertEqual(reply.json()["status"], "delivered")
                    self.assertEqual(reply.json()["translated"], "The price is 25000 aUEC.")
        self.assertEqual(len(requests), 1)

    def test_configuration_requires_key_and_hides_it_in_repr(self):
        """Groq включается явно, ключ обязателен и не попадает в представление настроек."""
        with patch.dict(os.environ, {"TRADER_TRANSLATOR": "groq"}, clear=True):
            with self.assertRaises(ValueError):
                Settings.from_env()
            os.environ["TRADER_GROQ_API_KEY"] = "test-private-key"
            settings = Settings.from_env()
            self.assertEqual(settings.groq_model, "openai/gpt-oss-120b")
            self.assertNotIn("test-private-key", repr(settings))
