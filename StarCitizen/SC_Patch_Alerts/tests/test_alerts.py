"""Регрессии потребительских сценариев на вымышленных событиях."""

import json
import tempfile
import unittest
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch
from xml.sax.saxutils import escape

from patch_alerts.events import Event, build_payload, demo_payloads, duration_estimate, parse_feed, plain_text
from patch_alerts.scanner import observe, read_json, record_failure, scan_once, write_json

NOW = datetime(2026, 11, 13, 12, 0, tzinfo=timezone.utc)
URL = "https://status.robertsspaceindustries.com/issues/synthetic-fixture/"


def rss(title, body, published="Fri, 13 Nov 2026 10:00:00 +0000", category="Persistent Universe", url=URL):
    """Создаёт вымышленную RSS-запись с заданными title/body и метаданными."""
    return f"<rss><channel><item><title>{escape(title)}</title><link>{escape(url)}</link><pubDate>{published}</pubDate><category>{category}</category><description>{escape(body)}</description></item></channel></rss>".encode()


class FeedTests(unittest.TestCase):
    """Проверяет, какие официальные сигналы допустимо превращать в карточки."""

    def test_captured_rsi_feed_with_date_categories(self):
        """Реальная лента распознаёт выпуск LIVE, исключает Platform и будущую публикацию."""
        raw = (Path(__file__).parent / "fixtures/rsi-status-2026-11-14.xml").read_bytes()
        records = parse_feed(raw, datetime(2026, 11, 14, 0, tzinfo=timezone.utc))
        events = [event for _, event in records if event]
        self.assertEqual(len(events), 1)
        event = events[0]
        self.assertEqual((event.phase, event.version), ("released", "4.10.2"))
        self.assertEqual(event.starts_at, "2026-10-09T10:00:00+00:00")
        self.assertEqual(event.finished_at, "2026-10-09T14:00:00+00:00")

    def test_date_category_requires_explicit_live_scope(self):
        """Дата вместо категории не разрешает общий hotfix или неизвестную систему."""
        for title, category in [("Critical Hotfix", "2026-11-13 10:00:00"),
                                ("Live Service Maintenance", "Platform"),
                                ("Live Service Maintenance", ""),
                                ("Live Service Maintenance", "Unknown")]:
            with self.subTest(title=title, category=category):
                raw = rss(title, "A critical hotfix is being applied to the Live Environment.", category=category)
                self.assertIsNone(parse_feed(raw, NOW)[0][1])

    def test_explicit_schedule_and_moscow_time(self):
        """Полная дата UTC даёт ожидаемое московское время в карточке."""
        event = parse_feed(rss("Live Service Maintenance", "The Live Service will be in a maintenance window starting on 2026-11-14 at 1400 UTC."), NOW)[0][1]
        self.assertEqual(event.phase, "scheduled")
        self.assertIn("14.11 · 17:00 МСК", json.dumps(build_payload(event), ensure_ascii=False))

    def test_future_publication_is_not_an_announcement(self):
        """Будущая дата публикации не считается уже полученным подтверждением."""
        event = parse_feed(rss("[Resolved] Live Deployment", "Alpha 9.9.1-live.777 was deployed without downtime.", "Mon, 16 Nov 2026 17:15:00 +0000"), NOW)[0][1]
        self.assertIsNone(event)

    def test_ptu_and_platform_are_excluded(self):
        """Тестовая ветка и отдельное обслуживание сайта не вызывают LIVE-карточку."""
        for title, category in [("PTU Hotfix", "Persistent Universe"), ("Live Service Maintenance", "Platform")]:
            with self.subTest(title=title):
                self.assertIsNone(parse_feed(rss(title, "A critical hotfix is being applied.", category=category), NOW)[0][1])

    def test_released_version_and_completed_maintenance_differ(self):
        """Завершение инфраструктурных работ не выдаётся за новый патч."""
        release = parse_feed(rss("[Resolved] Live Deployment", "Alpha 9.9.1-live.777 was deployed without downtime."), NOW)[0][1]
        maintenance = parse_feed(rss("[Resolved] Live Service Maintenance", "Expected duration 3.5 hours. Maintenance complete. Servers online."), NOW)[0][1]
        self.assertEqual((release.phase, release.version), ("released", "9.9.1"))
        self.assertEqual((maintenance.phase, maintenance.version), ("completed", ""))
        self.assertNotIn("заметках", build_payload(maintenance)["embeds"][0]["description"])

    def test_deleted_time_and_ambiguous_plan(self):
        """Удалённое время и расплывчатое обещание не становятся расписанием."""
        for body in ["<s>scheduled for 2026-11-14 at 1400 UTC</s> Time to be announced.", "We hope to deploy today.", "scheduled for 2026-11-12 at 1400 UTC"]:
            with self.subTest(body=body):
                self.assertIsNone(parse_feed(rss("Live Service Maintenance", body), NOW)[0][1])

    def test_installing_hotfix_without_invented_time(self):
        """Уже применяемый hotfix не обещает будущий старт или выдуманную версию."""
        event = parse_feed(rss("Live Service Maintenance", "A critical hotfix is being applied to the Live Environment."), NOW)[0][1]
        payload = build_payload(event)
        self.assertEqual(event.phase, "installing")
        self.assertIn("Срок окончания CIG не указал", payload["embeds"][0]["description"])
        self.assertNotIn("МСК", payload["embeds"][0]["description"])

    def test_duration_and_dated_work_timeline(self):
        """Оценка и фактические часы берутся из явно датированных записей CIG."""
        body = "The Live Service is currently in maintenance. Alpha 9.9.1-live.777 was deployed. Not expected to exceed 2 hours. [2026-11-13 Updates] 1000 UTC - Matchmaking disabled. 1135 UTC - Patch deployment complete."
        event = parse_feed(rss("[Resolved] Live Deployment", body), NOW)[0][1]
        self.assertEqual((event.duration_minutes, event.duration_kind), (120, "up_to"))
        self.assertEqual(event.starts_at, "2026-11-13T10:00:00+00:00")
        self.assertEqual(event.finished_at, "2026-11-13T11:35:00+00:00")
        start_text = build_payload(replace(event, phase="installing"))["embeds"][0]["description"]
        end_text = build_payload(event)["embeds"][0]["description"]
        self.assertIn("13.11 · 13:00 МСК", start_text)
        self.assertIn("13.11 · 14:35 МСК", end_text)

    def test_duration_revisions_and_estimate_wording(self):
        """Зачёркнутая оценка не используется, «до» не превращается в точный срок."""
        body = plain_text("Not expected to exceed <s>4</s> 6 hours.")
        self.assertEqual(duration_estimate(body), (360, "up_to"))
        self.assertEqual(duration_estimate("Expected to take 1.5 hours."), (90, "about"))
        self.assertEqual(duration_estimate("Duration will be announced."), (0, ""))

    def test_duration_without_actual_start_does_not_invent_finish(self):
        """Время публикации не подменяет начало работ для расчёта окончания."""
        event = parse_feed(rss("Live Service Maintenance", "The Live Service is currently in maintenance. Not expected to exceed 4 hours."), NOW)[0][1]
        text = build_payload(event)["embeds"][0]["description"]
        self.assertIn("до 4 ч", text)
        self.assertNotIn("МСК", text)
        self.assertNotIn("Ориентир", text)

    def test_invalid_feed_or_external_link(self):
        """Ошибочная страница/посторонняя ссылка не очищают состояние как успешная RSS."""
        for raw in [b"<html>login</html>", b"<!DOCTYPE rss><rss><channel/></rss>", rss("Live Deployment", "Alpha 9.9 was deployed.", url="https://example.invalid/")]:
            with self.subTest(raw=raw):
                self.assertRaises(ValueError, parse_feed, raw, NOW)


class StateTests(unittest.TestCase):
    """Проверяет тишину первого запуска, изменения и сохранение после рестарта."""

    def setUp(self):
        """Готовит вымышленное событие, не связанное с реальными объявлениями."""
        self.event = Event(URL, "scheduled", "2026-11-13T10:00:00+00:00", "9.9.1", "2026-11-14T14:00:00+00:00")

    def test_first_read_and_unchanged_restart_are_quiet(self):
        """Начальная история и её повтор после сериализации не дают новых уведомлений."""
        state, notices = observe({}, [(URL, self.event)], NOW)
        self.assertEqual(notices, [])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "state.json"
            write_json(path, state)
            restored = read_json(path, {})
        _, notices = observe(restored, [(URL, self.event)], NOW)
        self.assertEqual(notices, [])

    def test_unrecognized_revision_keeps_last_confirmed_event(self):
        """Временно неразобранная запись не стирает историю и не создаёт повтор при возврате."""
        state, _ = observe({}, [(URL, self.event)], NOW)
        state, notices = observe(state, [(URL, None)], NOW)
        self.assertEqual(notices, [])
        self.assertEqual(state["known"][URL]["phase"], "scheduled")
        _, notices = observe(state, [(URL, self.event)], NOW)
        self.assertEqual(notices, [])

    def test_time_change_and_release_create_new_notices(self):
        """Перенос и выпуск создают новые короткие уведомления, без потери нового времени."""
        state, _ = observe({}, [(URL, self.event)], NOW)
        shifted = replace(self.event, starts_at="2026-11-14T15:00:00+00:00")
        state, notices = observe(state, [(URL, shifted)], NOW)
        self.assertEqual(notices[0]["intended_action"], "new")
        text = notices[0]["payload"]["embeds"][0]["description"]
        self.assertIn("~~17:00~~", text)
        self.assertIn("14.11 · 18:00 МСК", text)
        released = replace(shifted, phase="released", starts_at="")
        _, notices = observe(state, [(URL, released)], NOW)
        self.assertEqual(notices[0]["intended_action"], "new")
        self.assertIn("/patch-notes", notices[0]["payload"]["embeds"][0]["description"])

    def test_old_backfilled_record_and_timestamp_only_change_are_quiet(self):
        """Дополненная старая история и новая дата без изменения карточки не создают спам."""
        state, _ = observe({}, [(URL, self.event)], NOW)
        _, notices = observe(state, [(URL, replace(self.event, published_at=NOW.isoformat())), (URL+"old", replace(self.event, source_url=URL+"old"))], NOW)
        self.assertEqual(notices, [])

    def test_work_start_and_finish_create_separate_notifications(self):
        """Начало и окончание работ отдельно оповещают, как решено после native edit-теста."""
        state, _ = observe({}, [(URL, self.event)], NOW)
        working = replace(self.event, phase="installing", duration_minutes=120, duration_kind="about")
        state, start_notices = observe(state, [(URL, working)], NOW)
        self.assertEqual(start_notices[0]["intended_action"], "new")
        finished = replace(working, phase="released", finished_at="2026-11-14T15:35:00+00:00")
        _, end_notices = observe(state, [(URL, finished)], NOW)
        self.assertEqual(end_notices[0]["intended_action"], "new")
        self.assertIn("начались", start_notices[0]["payload"]["embeds"][0]["title"])
        self.assertIn("завершены", end_notices[0]["payload"]["embeds"][0]["title"])

    def test_corrupt_state_is_not_silently_reset(self):
        """Повреждённый JSON не заменяется пустой базой для повторной рассылки истории."""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "state.json"
            path.write_text("{broken", encoding="utf-8")
            self.assertRaises(ValueError, read_json, path, {})

    def test_source_failure_preserves_history_and_conditional_read(self):
        """Ошибка источника сохраняет историю, а304 не выполняет её повторную обработку."""
        raw = rss("[Resolved] Live Deployment", "Alpha 9.9.1-live.777 was deployed without downtime.")
        with tempfile.TemporaryDirectory() as folder:
            data = Path(folder)
            with patch("patch_alerts.scanner.fetch_feed", return_value=(raw, "fixture-date")):
                scan_once(data, NOW)
            before = (data / "state.json").read_bytes()
            record_failure(data, TimeoutError())
            self.assertEqual(before, (data / "state.json").read_bytes())
            with patch("patch_alerts.scanner.fetch_feed", return_value=(None, "fixture-date")) as fetch:
                status = scan_once(data, NOW)
                fetch.assert_called_once_with("fixture-date")
            self.assertEqual(status["source_response"], 304)
            self.assertEqual(status["state"], "ok")
            self.assertEqual(before, (data / "state.json").read_bytes())


class PayloadTests(unittest.TestCase):
    """Проверяет потребительские карточки без настоящей отправки."""

    def test_all_demo_cards_are_marked_and_mentions_are_disabled(self):
        """Все четыре примера явно вымышлены и не пингуют участников сервера."""
        payloads = demo_payloads()
        self.assertEqual(len(payloads), 4)
        for item in payloads:
            payload = item["payload"]
            self.assertTrue(payload["embeds"][0]["title"].startswith("ДЕМО ·"))
            self.assertEqual(payload["allowed_mentions"], {"parse": []})
            self.assertIn("вымышленные", payload["embeds"][0]["footer"]["text"].lower())
            self.assertLess(len(json.dumps(payload, ensure_ascii=False)), 6000)

    def test_compact_production_card_has_one_or_two_lines_and_no_field_rows(self):
        """Новые уведомления сохраняют смысл без прежнего полотна служебных полей."""
        event = Event(URL, "installing", NOW.isoformat(), "9.9.1", "2026-11-13T10:00:00+00:00", duration_minutes=120, duration_kind="up_to")
        payload = build_payload(event)
        embed = payload["embeds"][0]
        self.assertEqual(payload["username"], "SC Patches")
        self.assertIn("9.9.1", embed["title"])
        self.assertNotIn("fields", embed)
        self.assertNotIn("footer", embed)
        self.assertEqual(len(embed["description"].splitlines()), 2)
        self.assertIn("до 2 ч", embed["description"])
        self.assertIn("до **15:00 МСК**", embed["description"])


if __name__ == "__main__":
    unittest.main()
