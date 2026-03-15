"""
NewsShield — ForexFactory calendar poller and news phase manager.

Polls the ForexFactory XML feed every N minutes, tracks high-impact GBP/JPY/USD events,
and exposes a `news_risk` score (0-100) used by the AI server response.

Phase logic:
  CLEAR     — no event within 60 min:      risk = 0
  ALERT     — event in 30-60 min:          risk = 40   (warn, evaluate positions)
  PRE_NEWS  — event in 0-30 min:           risk = 75   (close scalpers, swing → BE)
  BLACKOUT  — event in progress (0–15 min): risk = 100  (no new entries)
  POST_NEWS — T+15 to T+60 after event:    risk = 50   (halved position size)

Also writes boj_alert.txt = "1" when a BoJ event is within 30 minutes,
which is read by the BoJWatchdog MQL5 component.

Usage (started by server.py):
    shield = NewsShield(config, Path("config/boj_alert.txt"))
    await shield.start()
    risk = shield.news_risk
"""
from __future__ import annotations

import asyncio
import logging
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests

log = logging.getLogger("news_shield")

FF_CALENDAR_URL  = "https://nfs.faireconomy.media/ff_calendar_thisweek.xml"
ET_TZ            = ZoneInfo("America/New_York")
UTC              = timezone.utc

HIGH_IMPACT_COUNTRIES = {"GBP", "JPY", "USD"}

# Default BoJ keywords (overridden by config)
DEFAULT_BOJ_KEYWORDS = [
    "intervene", "intervention", "excessive move", "one-sided",
    "smooth", "boj buys", "finance minister", "mof",
    "currency check", "speculative", "bank of japan",
    "boj rate", "monetary policy statement", "interest rate decision",
    "outlook report", "press conference",
]


class _NewsEvent:
    __slots__ = ("title", "country", "time_utc")

    def __init__(self, title: str, country: str, time_utc: datetime):
        self.title    = title
        self.country  = country
        self.time_utc = time_utc

    def minutes_until(self) -> float:
        return (self.time_utc - datetime.now(UTC)).total_seconds() / 60.0


class NewsShield:
    def __init__(self, config: dict, boj_alert_path: Path):
        cfg = config.get("news_shield", {})

        self._poll_interval    = cfg.get("calendar_poll_interval_minutes", 30) * 60
        self._pre_lockdown     = cfg.get("pre_news_lockdown_minutes", 60)      # ALERT window start
        self._prep_window      = cfg.get("preparation_window_minutes", 30)     # PRE_NEWS start
        self._post_start       = cfg.get("post_news_entry_start_minutes", 15)  # BLACKOUT end
        self._post_end         = cfg.get("post_news_entry_end_minutes", 60)    # POST_NEWS end
        self._boj_keywords     = [k.lower() for k in cfg.get("boj_keywords", DEFAULT_BOJ_KEYWORDS)]
        self._boj_alert_path   = boj_alert_path

        self._events: list[_NewsEvent] = []
        self._news_risk: int  = 0
        self._phase: str      = "CLEAR"
        self._running         = False

    # ── Public interface ──────────────────────────────────────────────────────

    @property
    def news_risk(self) -> int:
        return self._news_risk

    @property
    def phase(self) -> str:
        return self._phase

    async def start(self) -> None:
        self._running = True
        # Fetch immediately on startup, then schedule repeating poll
        await self._fetch_calendar()
        asyncio.create_task(self._poll_loop())
        asyncio.create_task(self._check_loop())
        log.info("[NewsShield] Running — phase=%s risk=%d", self._phase, self._news_risk)

    def stop(self) -> None:
        self._running = False

    # ── Background tasks ─────────────────────────────────────────────────────

    async def _poll_loop(self) -> None:
        """Re-fetch the ForexFactory calendar every N minutes."""
        while self._running:
            await asyncio.sleep(self._poll_interval)
            await self._fetch_calendar()

    async def _check_loop(self) -> None:
        """Recompute phase every 60 seconds (catches time-based transitions)."""
        while self._running:
            await asyncio.sleep(60)
            self._update_phase()

    # ── HTTP fetch ────────────────────────────────────────────────────────────

    async def _fetch_calendar(self) -> None:
        loop = asyncio.get_running_loop()
        try:
            xml_text = await loop.run_in_executor(None, self._http_get)
            self._events = self._parse_xml(xml_text)
            log.info("[NewsShield] Fetched %d high-impact events", len(self._events))
            self._update_phase()
        except Exception as exc:
            log.warning("[NewsShield] Calendar fetch failed: %s", exc)

    @staticmethod
    def _http_get() -> str:
        resp = requests.get(FF_CALENDAR_URL, timeout=10)
        resp.raise_for_status()
        return resp.text

    # ── XML parsing ───────────────────────────────────────────────────────────

    def _parse_xml(self, xml_text: str) -> list[_NewsEvent]:
        events = []
        try:
            root = ET.fromstring(xml_text)
        except ET.ParseError as exc:
            log.warning("[NewsShield] XML parse error: %s", exc)
            return events

        for node in root.findall("event"):
            country = (node.findtext("country") or "").strip()
            if country not in HIGH_IMPACT_COUNTRIES:
                continue

            impact = (node.findtext("impact") or "").strip()
            if impact != "High":
                continue

            title    = (node.findtext("title")   or "").strip()
            date_str = (node.findtext("date")    or "").strip()
            time_str = (node.findtext("time")    or "").strip()

            # Skip tentative/all-day events
            if not date_str or time_str.lower() in ("tentative", "all day", ""):
                continue

            event_dt = self._parse_ff_datetime(date_str, time_str)
            if event_dt is None:
                continue

            # Skip events more than 2 h in the past (outside any relevant window)
            if (datetime.now(UTC) - event_dt).total_seconds() > 7200:
                continue

            events.append(_NewsEvent(title, country, event_dt))

        return events

    @staticmethod
    def _parse_ff_datetime(date_str: str, time_str: str) -> datetime | None:
        """Parse ForexFactory date/time (Eastern Time) → UTC datetime.

        FF uses MM-DD-YYYY and 12h time like '8:30am'.
        """
        for fmt in ("%m-%d-%Y %I:%M%p", "%b %d, %Y %I:%M%p"):
            try:
                dt_naive = datetime.strptime(f"{date_str} {time_str}", fmt)
                return dt_naive.replace(tzinfo=ET_TZ).astimezone(UTC)
            except ValueError:
                continue
        return None

    # ── Phase logic ───────────────────────────────────────────────────────────

    def _update_phase(self) -> None:
        nearest, nearest_mins = self._nearest_relevant_event()
        old_phase = self._phase

        if nearest is None:
            phase = "CLEAR"
            risk  = 0
        elif -self._post_start <= nearest_mins <= 0:
            # Event in progress (T-0 to T+post_start)
            phase = "BLACKOUT"
            risk  = 100
        elif 0 < nearest_mins <= self._prep_window:
            # T-prep_window to T-0
            phase = "PRE_NEWS"
            risk  = 75
        elif self._prep_window < nearest_mins <= self._pre_lockdown:
            # T-pre_lockdown to T-prep_window
            phase = "ALERT"
            risk  = 40
        elif -self._post_end <= nearest_mins < -self._post_start:
            # T+post_start to T+post_end
            phase = "POST_NEWS"
            risk  = 50
        else:
            phase = "CLEAR"
            risk  = 0

        self._phase      = phase
        self._news_risk  = risk

        if phase != old_phase:
            detail = (
                f" | {nearest.country} '{nearest.title}' {nearest_mins:+.0f}m"
                if nearest else ""
            )
            log.info("[NewsShield] %s → %s (risk=%d)%s", old_phase, phase, risk, detail)

        self._write_boj_alert()

    def _nearest_relevant_event(self) -> tuple[_NewsEvent | None, float]:
        """Return the event most relevant to the current moment, and its minutes_until."""
        nearest      = None
        nearest_mins = float("inf")

        for event in self._events:
            mins = event.minutes_until()
            # Include events in the window: T-pre_lockdown to T+post_end
            if -self._post_end <= mins <= self._pre_lockdown:
                # Pick the one closest to T-0 (smallest absolute minutes)
                if abs(mins) < abs(nearest_mins):
                    nearest      = event
                    nearest_mins = mins

        if nearest is None:
            return None, 0.0
        return nearest, nearest_mins

    # ── BoJ alert file ────────────────────────────────────────────────────────

    def _write_boj_alert(self) -> None:
        """Write "1" to boj_alert.txt if a BoJ event is within 30 min, else "0"."""
        alert = "0"
        for event in self._events:
            if event.country != "JPY":
                continue
            mins = event.minutes_until()
            if -self._post_start <= mins <= 30:
                title_lower = event.title.lower()
                if any(kw in title_lower for kw in self._boj_keywords):
                    alert = "1"
                    log.warning(
                        "[NewsShield] BoJ alert: '%s' in %+.0f min", event.title, mins
                    )
                    break

        try:
            self._boj_alert_path.parent.mkdir(parents=True, exist_ok=True)
            self._boj_alert_path.write_text(alert)
        except OSError as exc:
            log.warning("[NewsShield] Cannot write boj_alert.txt: %s", exc)
