"""Проверки очереди, HTTP-контракта и восстановления без настоящих Discord-постов."""

import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from patch_alerts.config import NewsSettings
from patch_alerts.delivery import WebhookClient, WebhookError, WebhookTarget
from patch_alerts.events import Event, build_payload
from patch_alerts.locking import state_lock
from patch_alerts.notes import find_notes
from patch_alerts.scanner import observe, read_json, scan_once, write_json
from patch_alerts.worker import NewsWorker, delivery_status, drain_once, reconcile

NOW = datetime(2026, 11, 13, 12, tzinfo=timezone.utc)
URL = "https://status.robertsspaceindustries.com/issues/fixture/"
SCHEDULED = Event(URL, "scheduled", NOW.isoformat(), "9.9.1", "2026-11-14T12:00:00+00:00")


def queued(event=SCHEDULED):
    """Создаёт вымышленное событие после тихого первого чтения, с включённой доставкой."""
    state, _ = observe({}, [(URL, None)], NOW)
    state["delivery_started_at"] = NOW.isoformat()
    return observe(state, [(URL, event)], NOW)[0]


class QueueTests(unittest.TestCase):
    """Проверяет видимые исходы очереди, а не внутреннее оформление кода."""

    def setUp(self):
        """Готовит отдельную папку и клиент, который не умеет обращаться к сети."""
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.data = Path(self.folder.name)
        self.path = self.data / "state.json"
        self.client = Mock(spec=WebhookClient)
        self.client.send.return_value = "123456"

    def test_success_survives_restart_and_does_not_duplicate(self):
        """Сохранённое подтверждение не приводит к повторному POST после нового чтения."""
        write_json(self.path, queued())
        drain_once(self.data, self.client, NOW)
        state = read_json(self.path, {})
        self.assertEqual((state["notices"][0]["delivery"], state["notices"][0]["message_id"]), ("sent", "123456"))
        state, notices = observe(state, [(URL, SCHEDULED)], NOW)
        write_json(self.path, state)
        drain_once(self.data, self.client, NOW)
        self.assertEqual(notices, [])
        self.client.send.assert_called_once()

    def test_shutdown_before_post_keeps_notice_pending(self):
        """SIGTERM во время проверки цели не начинает новую отправку и сохраняет очередь."""
        write_json(self.path, queued())
        stopped = threading.Event()
        self.client.verify.side_effect = stopped.set
        drain_once(self.data, self.client, NOW, stopped=stopped)
        self.client.send.assert_not_called()
        self.assertEqual(read_json(self.path, {})["notices"][0]["delivery"], "pending")

    def test_configured_role_is_above_each_new_card_and_demo_stays_quiet(self):
        """Все этапы сохраняют карточку и получают одну роль; демо и повторы не пингуют."""
        for phase in ("scheduled", "installing", "completed", "released"):
            for demo in (False, True):
                with self.subTest(phase=phase, demo=demo):
                    event = replace(SCHEDULED, phase=phase, demo=demo)
                    state = queued(event)
                    if phase == "scheduled":
                        previous = replace(event, starts_at="2026-11-14T11:00:00+00:00")
                        state["notices"][0]["payload"] = build_payload(event, previous)
                    if phase == "released":
                        state["notices"][0]["notes_lookup_done"] = True
                    expected_embeds = state["notices"][0]["payload"]["embeds"]
                    write_json(self.path, state)
                    self.client.reset_mock()
                    drain_once(self.data, self.client, NOW, mention_role_id="4")
                    payload = self.client.send.call_args.args[0]
                    self.assertEqual(payload["embeds"], expected_embeds)
                    self.assertEqual(payload.get("content", ""), "" if demo else "<@&4>")
                    self.assertEqual(payload["allowed_mentions"], {"parse": []} if demo else {"parse": [], "roles": ["4"]})
                    drain_once(self.data, self.client, NOW, mention_role_id="4")
                    self.client.send.assert_called_once()

    def test_role_payload_is_durable_before_post_and_unknown_does_not_reping(self):
        """Неизвестный ответ сохраняет точный отправленный пинг для сверки, без автоповтора."""
        write_json(self.path, queued())

        def interrupted(payload):
            """Проверяет сохранённый inflight payload до имитации потери ответа Discord."""
            notice = read_json(self.path, {})["notices"][0]
            self.assertEqual(notice["delivery"], "inflight")
            self.assertEqual(notice["payload"], payload)
            self.assertEqual(payload["content"], "<@&4>")
            raise WebhookError("network_or_invalid_response")

        self.client.send.side_effect = interrupted
        drain_once(self.data, self.client, NOW, mention_role_id="4")
        drain_once(self.data, self.client, NOW + timedelta(hours=1), mention_role_id="4")
        self.client.send.assert_called_once()
        self.assertEqual(read_json(self.path, {})["notices"][0]["delivery"], "unknown")

    def test_network_unknown_and_interrupted_inflight_never_retry_automatically(self):
        """Обрыв ответа и падение после записи inflight сохраняют неизвестный исход."""
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                state = queued()
                if interrupted:
                    state["notices"][0]["delivery"] = "inflight"
                write_json(self.path, state)
                client = Mock(spec=WebhookClient)
                client.send.side_effect = WebhookError("network_or_invalid_response")
                drain_once(self.data, client, NOW)
                drain_once(self.data, client, NOW + timedelta(hours=1))
                self.assertEqual(read_json(self.path, {})["notices"][0]["delivery"], "unknown")
                self.assertEqual(client.send.call_count, 0 if interrupted else 1)
                self.assertEqual(delivery_status(self.data)["state"], "attention")

    def test_429_obeys_server_delay_and_401_blocks_without_retry(self):
        """До Retry-After нет POST; неверный ключ не вызывает бесконечных повторов."""
        write_json(self.path, queued())
        self.client.send.side_effect = [WebhookError("http_429", status=429, retry_after=120), "123456"]
        drain_once(self.data, self.client, NOW)
        drain_once(self.data, self.client, NOW + timedelta(seconds=119))
        self.assertEqual(self.client.send.call_count, 1)
        drain_once(self.data, self.client, NOW + timedelta(seconds=120))
        self.assertEqual(self.client.send.call_count, 2)
        self.assertEqual(read_json(self.path, {})["notices"][0]["delivery"], "sent")
        write_json(self.path, queued())
        self.client.verify.side_effect = WebhookError("http_401", status=401)
        self.client.reset_mock()
        drain_once(self.data, self.client, NOW)
        drain_once(self.data, self.client, NOW + timedelta(hours=1))
        self.client.send.assert_not_called()
        self.assertEqual(self.client.verify.call_count, 1)
        self.assertEqual(read_json(self.path, {})["notices"][0]["delivery"], "blocked")

    def test_expired_warning_and_older_phase_are_not_published_late(self):
        """После окончания отправляется окончание, а не накопленные предупреждение/начало."""
        state = queued()
        working = replace(SCHEDULED, phase="installing")
        state, _ = observe(state, [(URL, working)], NOW)
        finished = replace(working, phase="completed", finished_at=NOW.isoformat())
        state, _ = observe(state, [(URL, finished)], NOW)
        write_json(self.path, state)
        drain_once(self.data, self.client, NOW)
        self.assertEqual([n["delivery"] for n in read_json(self.path, {})["notices"]], ["superseded", "superseded", "sent"])
        self.assertIn("завершены", self.client.send.call_args.args[0]["embeds"][0]["title"])
        write_json(self.path, queued())
        self.client.reset_mock()
        drain_once(self.data, self.client, NOW + timedelta(days=2))
        self.client.send.assert_not_called()
        write_json(self.path, queued())
        self.client.send.side_effect = WebhookError("http_429", status=429, retry_after=120)
        drain_once(self.data, self.client, NOW)
        drain_once(self.data, self.client, NOW + timedelta(days=2))
        self.assertEqual(delivery_status(self.data)["state"], "ok")

    def test_cosmetic_duration_and_timestamp_do_not_repeat_start(self):
        """Правка оценки не объявляет начало работ заново; A→B→A даёт два переноса."""
        working = replace(SCHEDULED, phase="installing", duration_minutes=120)
        state = queued(working)
        state, notices = observe(state, [(URL, replace(working, duration_minutes=180, published_at=NOW.isoformat()))], NOW)
        self.assertEqual(notices, [])
        state = queued()
        shifted = replace(SCHEDULED, starts_at="2026-11-14T13:00:00+00:00")
        state, _ = observe(state, [(URL, shifted)], NOW)
        state, notices = observe(state, [(URL, SCHEDULED)], NOW)
        self.assertEqual(len(notices), 1)
        self.assertEqual(len({n["id"] for n in state["notices"]}), 3)

    def test_first_activation_is_quiet_and_pending_is_not_trimmed(self):
        """Включение поверх preview не публикует историю; очередь переживает длинную историю."""
        state = queued()
        state.pop("delivery_started_at")
        state["notices"][0]["delivery"] = "preview"
        write_json(self.path, state)
        raw = b'<rss><channel><item><link>https://status.robertsspaceindustries.com/issues/fixture/</link><title>Unrelated</title><pubDate>Fri, 13 Nov 2026 10:00:00 GMT</pubDate></item></channel></rss>'
        with patch("patch_alerts.scanner.fetch_feed", return_value=(raw, "fixture")) as fetch:
            scan_once(self.data, NOW, activate=True)
            fetch.assert_called_once_with("")
        drain_once(self.data, self.client, NOW)
        self.client.send.assert_not_called()
        state = queued()
        state["notices"] += [{"delivery": "sent", "id": str(i)} for i in range(150)]
        state, _ = observe(state, [(URL, SCHEDULED)], NOW)
        self.assertEqual(state["notices"][0]["delivery"], "pending")

    def test_reconcile_requires_exact_notice_and_explicit_retry(self):
        """Оператор может подтвердить найденный пост; повтор требует явного решения."""
        state = queued()
        state["notices"][0]["delivery"] = "unknown"
        identifier = state["notices"][0]["id"]
        write_json(self.path, state)
        with self.assertRaises(ValueError):
            reconcile(self.data, self.client, identifier, "retry")
        self.client.confirm.return_value = "123456"
        reconcile(self.data, self.client, identifier, "sent", "123456")
        self.assertEqual(read_json(self.path, {})["notices"][0]["delivery"], "sent")
        self.client.send.assert_not_called()

    def test_release_uses_exact_notes_and_failure_has_honest_index_fallback(self):
        """Доставка вызывает настоящий formatter и сохраняет выбранную ссылку перед POST."""
        for url in ("https://robertsspaceindustries.com/comm-link/Patch-Notes/99999-Alpha-991", ""):
            with self.subTest(url=url):
                event = replace(SCHEDULED, phase="released", finished_at=NOW.isoformat())
                write_json(self.path, queued(event))
                with patch("patch_alerts.worker.fetch_notes", return_value=url):
                    drain_once(self.data, self.client, NOW)
                text = self.client.send.call_args.args[0]["embeds"][0]["description"]
                self.assertIn(url if url else "общий список", text)

    def test_corrupt_or_busy_state_does_not_send(self):
        """Повреждённый файл и другой владелец блокировки не вызывают отправки."""
        self.path.write_text('{broken', encoding="utf-8")
        with self.assertRaises(ValueError):
            drain_once(self.data, self.client, NOW)
        write_json(self.path, queued())
        with state_lock(self.data), self.assertRaises(RuntimeError):
            drain_once(self.data, self.client, NOW)
        self.client.send.assert_not_called()
        state = queued()
        state["schema"] = 999
        write_json(self.path, state)
        with patch("patch_alerts.scanner.fetch_feed", return_value=(None, "fixture")), self.assertRaises(ValueError):
            scan_once(self.data, NOW, activate=True)
        self.assertEqual(read_json(self.path, {})["schema"], 999)


class TransportTests(unittest.TestCase):
    """Проверяет реальные Request и JSON через локальный транспорт без сети."""

    def target(self, folder):
        """Готовит вымышленный закрытый URL для точных ID 1/2/3."""
        path = Path(folder) / "hook.url"
        path.write_text("https://discord.com/api/webhooks/1/" + "A" * 60, encoding="utf-8")
        return WebhookTarget.from_file(path, "1", "2", "3")

    def response(self, value):
        """Упаковывает value в ответ настоящего JSON-протокола."""
        response = io.BytesIO(json.dumps(value).encode())
        response.status = 200
        return response

    def test_verify_send_and_confirm_preserve_target_payload_and_wait(self):
        """GET/POST/GET проверяют канал, payload, wait=true и сообщение без упоминаний."""
        with tempfile.TemporaryDirectory() as folder:
            target = self.target(folder)
            payload = build_payload(SCHEDULED)
            receipt = {"id": "4", "webhook_id": "1", "channel_id": "2", "embeds": payload["embeds"], "mentions": [], "mention_roles": []}
            opener = Mock()
            opener.open.side_effect = [self.response({"id": "1", "channel_id": "2", "guild_id": "3"}), self.response(receipt), self.response(receipt)]
            client = WebhookClient(target, opener)
            client.verify()
            self.assertEqual(client.send(payload), "4")
            self.assertEqual(client.confirm("4", payload), "4")
            post = opener.open.call_args_list[1].args[0]
            self.assertEqual(post.get_method(), "POST")
            self.assertTrue(post.full_url.endswith("?wait=true"))
            self.assertEqual(json.loads(post.data), payload)
            self.assertNotIn("A" * 60, repr(target))

    def test_wrong_target_invalid_receipt_and_429_are_safe_and_not_retried(self):
        """Неверная цель/квитанция и429 дают безопасный отказ после одного запроса."""
        with tempfile.TemporaryDirectory() as folder:
            target = self.target(folder)
            opener = Mock()
            client = WebhookClient(target, opener)
            opener.open.return_value = self.response({"id": "1", "channel_id": "99", "guild_id": "3"})
            with self.assertRaisesRegex(WebhookError, "target_mismatch"):
                client.verify()
            opener.open.side_effect = HTTPError(target.url, 429, "secret-must-not-appear", {}, io.BytesIO(b'{"retry_after":17}'))
            with self.assertRaises(WebhookError) as caught:
                client.send(build_payload(SCHEDULED))
            self.assertEqual(caught.exception.retry_after, 17)
            self.assertNotIn("secret", str(caught.exception))
            self.assertEqual(opener.open.call_count, 2)
            opener.open.side_effect = None
            opener.open.return_value = self.response({"id": "4", "webhook_id": "1", "channel_id": "99", "embeds": []})
            with self.assertRaisesRegex(WebhookError, "message_mismatch"):
                client.send(build_payload(SCHEDULED))
            self.assertEqual(opener.open.call_count, 3)

    def test_role_send_and_confirm_require_exact_content_and_receipt_mentions(self):
        """POST/сверка принимают только настроенную роль и её точное подтверждение Discord."""
        with tempfile.TemporaryDirectory() as folder:
            target = self.target(folder)
            payload = {**build_payload(SCHEDULED), "content": "<@&4>", "allowed_mentions": {"parse": [], "roles": ["4"]}}
            receipt = {"id": "5", "webhook_id": "1", "channel_id": "2", "embeds": payload["embeds"],
                       "content": "<@&4>", "mention_roles": ["4"], "mentions": [], "mention_everyone": False}
            opener = Mock()
            opener.open.side_effect = [self.response(receipt), self.response(receipt)]
            client = WebhookClient(target, opener, mention_role_id="4")
            self.assertEqual(client.send(payload), "5")
            self.assertEqual(client.confirm("5", payload), "5")
            self.assertEqual(json.loads(opener.open.call_args_list[0].args[0].data), payload)
            for changed in ({"mention_roles": []}, {"mention_roles": ["4", "6"]},
                            {"content": ""}, {"mentions": [{"id": "7"}]}, {"mention_everyone": True}):
                with self.subTest(receipt=changed), self.assertRaisesRegex(WebhookError, "message_mismatch"):
                    opener.open.side_effect = None
                    opener.open.return_value = self.response({**receipt, **changed})
                    client.confirm("5", payload)
            for changed in ({"allowed_mentions": {"parse": ["roles"]}}, {"content": "@everyone"},
                            {"content": "<@7>"}, {"content": "<@&6>", "allowed_mentions": {"parse": [], "roles": ["6"]}}):
                opener.reset_mock()
                with self.subTest(payload=changed), self.assertRaisesRegex(ValueError, "unsafe_webhook_payload"):
                    client.send({**payload, **changed})
                opener.open.assert_not_called()
            with self.assertRaisesRegex(ValueError, "unsafe_webhook_payload"):
                WebhookClient(target, opener).send(payload)

    def test_role_config_is_optional_and_rejects_everyone_or_non_role_values(self):
        """Старый конфиг не пингует; новый привязывает worker/client к одной корректной роли."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.target(folder)
            config = root / "config.json"
            value = {"enabled": True, "data_dir": "news", "poll_seconds": 600,
                     "webhook_file": "hook.url", "webhook_id": "1", "channel_id": "2", "guild_id": "3"}
            config.write_text(json.dumps(value), encoding="utf-8")
            self.assertEqual(NewsSettings.from_file(config).mention_role_id, "")
            config.write_text(json.dumps({**value, "mention_role_id": "4"}), encoding="utf-8")
            settings = NewsSettings.from_file(config)
            worker = NewsWorker(settings)
            self.assertEqual(worker.client.mention_role_id, "4")
            with patch("patch_alerts.worker.scan_once"), patch("patch_alerts.worker.drain_once") as drain:
                worker.cycle()
            self.assertEqual(drain.call_args.kwargs["mention_role_id"], "4")
            for role in (None, True, 4, [], "@Космопират", "3", "0", "4 5", "1" * 21):
                config.write_text(json.dumps({**value, "mention_role_id": role}), encoding="utf-8")
                with self.subTest(role=role), self.assertRaisesRegex(ValueError, "invalid_news_mention_role"):
                    NewsSettings.from_file(config)

    def test_config_and_secret_reject_unsafe_targets_without_network(self):
        """Опечатки/redirect-host/замаскированный ключ не превращаются в боевой target."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config = root / "config.json"
            config.write_text('{"enabled":false}', encoding="utf-8")
            self.assertFalse(NewsSettings.from_file(config).enabled)
            for url in ("http://discord.com/api/webhooks/1/" + "A" * 60, "https://example.invalid/api/webhooks/1/" + "A" * 60, "https://discord.com/api/webhooks/1/<redacted>"):
                secret = root / "hook.url"
                secret.write_text(url, encoding="utf-8")
                with self.assertRaises(ValueError):
                    WebhookTarget.from_file(secret, "1", "2", "3")
            config.write_text('{"enabled":true,"poll_seconds":1}', encoding="utf-8")
            with self.assertRaises(ValueError):
                NewsSettings.from_file(config)

    def test_preview_flags_cannot_silently_enable_delivery_or_change_its_destination(self):
        """worker с --offline/--data-dir завершается до чтения конфига и любых запросов."""
        for option in ("--offline", "--data-dir=fixture-only"):
            result = subprocess.run([sys.executable, "-X", "utf8", "-m", "patch_alerts.app", "worker", "--config", "nonexistent.json", option], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertIn("Настройки preview".encode(), result.stderr)

    def test_notes_select_exact_live_version_and_reject_ambiguous_or_external(self):
        """9.9.1 не совпадает с9.9.10/PTU, внешний href и неоднозначный индекс исключаются."""
        html = '<a href="/comm-link/Patch-Notes/900-Alpha">Star Citizen Alpha 9.9.10</a><a href="/comm-link/Patch-Notes/901-Alpha">Star Citizen Alpha 9.9.1</a>'
        self.assertTrue(find_notes(html, "9.9.1").endswith("901-Alpha"))
        self.assertEqual(find_notes(html.replace('href="/comm-link/Patch-Notes/901', 'href="https://example.invalid/comm-link/Patch-Notes/901'), "9.9.1"), "")
        self.assertEqual(find_notes(html + '<a href="/comm-link/Patch-Notes/902-Alpha">Star Citizen Alpha 9.9.1</a>', "9.9.1"), "")


if __name__ == "__main__":
    unittest.main()
