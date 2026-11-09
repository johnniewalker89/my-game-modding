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

    async def test_alphanumeric_locations_and_model_names_are_protected_whole(self):
        """Буквы, дефисы и цифры обозначения защищаются одним маркером, а не раздельно."""
        def respond(request):
            """Возвращает искусственные обозначения только через полученные маркеры."""
            data = json.loads(json.loads(request.content)["messages"][1]["content"])
            self.assertEqual(data["placeholders"], {"ZXQ0QXZ": "TEST-K8", "ZXQ1QXZ": "TestDrill-7",
                "ZXQ2QXZ": "TestDrill-8", "ZXQ3QXZ": "C2"})
            return httpx.Response(200, json=completion("Storage at ZXQ0QXZ: ZXQ1QXZ, ZXQ2QXZ and ZXQ3QXZ."))

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            translated = await Translator(client, "groq", "", groq_key="fixture").translate(
                "Склад на TEST-K8: TestDrill-7, TestDrill-8 и C2.", "ru", "en")
        self.assertEqual(translated, "Storage at TEST-K8: TestDrill-7, TestDrill-8 and C2.")

    async def test_numeric_quantity_stays_exact_when_russian_would_use_a_word(self):
        """Groq получает значение количества для смысла и возвращает маркер вместо склонённого числительного."""
        def respond(request):
            data = json.loads(json.loads(request.content)["messages"][1]["content"])
            self.assertEqual(data["placeholders"], {"ZXQ0QXZ": "6"})
            self.assertNotIn("6", data["text"])
            return httpx.Response(200, json=completion("Отложите по ZXQ0QXZ образцов каждого вида, пожалуйста."))

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            translated = await Translator(client, "groq", "", groq_key="fixture").translate(
                "Reserve 6 samples of every variant, please.", "en", "ru")
        self.assertEqual(translated, "Отложите по 6 образцов каждого вида, пожалуйста.")

    async def test_amount_quantity_units_and_time_keep_original_digits_and_format(self):
        """Числа не меняются местами и восстанавливаются вместе с исходными разделителями."""
        def respond(request):
            data = json.loads(json.loads(request.content)["messages"][1]["content"])
            self.assertEqual(list(data["placeholders"].values()), ["25,000", "aUEC", "2", "SCU", "19:30"])
            return httpx.Response(200, json=completion(
                "Цена ZXQ0QXZ ZXQ1QXZ за ZXQ2QXZ ZXQ3QXZ. Встреча в ZXQ4QXZ."))

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            translated = await Translator(client, "groq", "", groq_key="fixture").translate(
                "Price 25,000 aUEC for 2 SCU. Meet at 19:30.", "en", "ru")
        self.assertEqual(translated, "Цена 25,000 aUEC за 2 SCU. Встреча в 19:30.")

    async def test_numeric_markers_cannot_be_lost_duplicated_reordered_or_augmented(self):
        """Защита суммы/количества сохраняется; модель не может добавить ещё одно число."""
        for output, code in (("ZXQ0QXZ", "protected_values_changed"),
                             ("ZXQ0QXZ ZXQ0QXZ ZXQ1QXZ", "protected_values_changed"),
                             ("ZXQ1QXZ ZXQ0QXZ", "protected_values_changed"),
                             ("ZXQ0QXZ ZXQ1QXZ extra 999", "numeric_values_changed")):
            with self.subTest(output=output):
                async with httpx.AsyncClient(transport=httpx.MockTransport(
                    lambda request: httpx.Response(200, json=completion(output)))) as client:
                    with self.assertRaises(TranslationError) as raised:
                        await Translator(client, "groq", "", groq_key="fixture").translate(
                            "Reserve 8 samples for 46000.", "en", "ru")
                self.assertEqual(raised.exception.code, code)

    async def test_rejection_reasons_are_bounded_and_truncation_is_distinguishable(self):
        """Диагностический код не содержит текст провайдера или сообщения участника."""
        self.assertEqual(TranslationError("private fixture", code="private-fixture-code").code, "translation_failed")
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, json=completion("private fixture", "length")))) as client:
            with self.assertRaises(TranslationError) as raised:
                await Translator(client, "groq", "", groq_key="fixture").translate("Fixture text", "en", "ru")
        self.assertEqual(raised.exception.code, "output_truncated")
        self.assertNotIn("private fixture", str(raised.exception))

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
            self.assertEqual(data["placeholders"], {"ZXQ0QXZ": "Seller", "ZXQ1QXZ": "Janalite", "ZXQ2QXZ": "964",
                                                  "ZXQ3QXZ": "25000", "ZXQ4QXZ": "aUEC"})
            return httpx.Response(200, json=completion(
                "Hi, ZXQ0QXZ! Is ZXQ1QXZ of quality ZXQ2QXZ available for ZXQ3QXZ ZXQ4QXZ?"))

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
            return httpx.Response(200, json=completion("The price is ZXQ0QXZ ZXQ1QXZ."))

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
