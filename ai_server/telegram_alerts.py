"""
Telegram alert system — all significant bot events sent to your phone.

Usage:
    from ai_server.telegram_alerts import TelegramAlerter
    tg = TelegramAlerter(token="...", chat_id="...")
    tg.send_trade_entry(...)

Test from command line:
    python ai_server/telegram_alerts.py
"""
import json
import logging
import os
import sys
import time
from datetime import datetime
from typing import Optional

import requests

log = logging.getLogger(__name__)

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "..", "config.json")


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return json.load(f)


class TelegramAlerter:
    def __init__(self, token: str, chat_id: str):
        self.token = token
        self.chat_id = str(chat_id)
        self.base_url = f"https://api.telegram.org/bot{token}"
        self._last_send = 0.0
        self._min_interval = 0.5  # avoid Telegram rate limits

    def _send(self, text: str, parse_mode: str = "HTML") -> bool:
        now = time.time()
        wait = self._min_interval - (now - self._last_send)
        if wait > 0:
            time.sleep(wait)

        try:
            resp = requests.post(
                f"{self.base_url}/sendMessage",
                json={"chat_id": self.chat_id, "text": text, "parse_mode": parse_mode},
                timeout=10,
            )
            resp.raise_for_status()
            self._last_send = time.time()
            log.debug(f"Telegram sent: {text[:60]}...")
            return True
        except requests.RequestException as e:
            log.error(f"Telegram send failed: {e}")
            return False

    # ── Trade Notifications ──────────────────────────────────────────────

    def send_trade_entry(
        self,
        bot: str,
        direction: str,
        lots: float,
        entry_price: float,
        sl_price: float,
        tp1_price: float,
        entry_score: int,
        trend_score: int,
        cascade_step: Optional[int] = None,
    ) -> bool:
        step = f" (Cascade #{cascade_step})" if cascade_step else ""
        emoji = "📈" if direction == "BUY" else "📉"
        msg = (
            f"{emoji} <b>TRADE ENTRY{step}</b>\n"
            f"Bot: {bot.upper()} | {direction}\n"
            f"Lots: {lots:.2f} | Price: {entry_price:.3f}\n"
            f"SL: {sl_price:.3f} | TP1: {tp1_price:.3f}\n"
            f"AI Entry: {entry_score} | Trend: {trend_score}\n"
            f"Time: {datetime.utcnow().strftime('%H:%M:%S UTC')}"
        )
        return self._send(msg)

    def send_trade_exit(
        self,
        bot: str,
        direction: str,
        profit_pips: float,
        profit_usd: float,
        exit_reason: str,
        session_pnl_usd: float,
    ) -> bool:
        emoji = "✅" if profit_usd >= 0 else "❌"
        pips_str = f"+{profit_pips:.1f}" if profit_pips >= 0 else f"{profit_pips:.1f}"
        usd_str = f"+${profit_usd:.2f}" if profit_usd >= 0 else f"-${abs(profit_usd):.2f}"
        msg = (
            f"{emoji} <b>TRADE EXIT</b>\n"
            f"Bot: {bot.upper()} | {direction}\n"
            f"P&L: {pips_str} pips | {usd_str}\n"
            f"Reason: {exit_reason}\n"
            f"Session P&L: ${session_pnl_usd:+.2f}\n"
            f"Time: {datetime.utcnow().strftime('%H:%M:%S UTC')}"
        )
        return self._send(msg)

    # ── Risk Notifications ───────────────────────────────────────────────

    def send_risk_alert(self, loss_pct: float, account_balance: float, level: str = "YELLOW") -> bool:
        emoji = "🟡" if level == "YELLOW" else "🔴"
        msg = (
            f"{emoji} <b>RISK ALERT — {level}</b>\n"
            f"Session loss: {loss_pct:.1f}% of account\n"
            f"Balance: ${account_balance:.2f}\n"
            f"{'SESSION HALTED — no new entries' if level == 'RED' else 'Warning — approaching halt'}\n"
            f"Time: {datetime.utcnow().strftime('%H:%M:%S UTC')}"
        )
        return self._send(msg)

    # ── News Shield Notifications ────────────────────────────────────────

    def send_news_shield_active(self, event_name: str, event_time: str, impact: str) -> bool:
        msg = (
            f"🛡 <b>NEWS SHIELD ACTIVE</b>\n"
            f"Event: {event_name}\n"
            f"Impact: {impact}\n"
            f"Event Time: {event_time} UTC\n"
            f"All new entries blocked."
        )
        return self._send(msg)

    def send_news_shield_cleared(self, event_name: str) -> bool:
        msg = (
            f"✅ <b>NEWS SHIELD CLEARED</b>\n"
            f"Event: {event_name}\n"
            f"Post-news reduced-size window now active.\n"
            f"Normal entries resume in 60 minutes."
        )
        return self._send(msg)

    # ── BoJ Intervention ─────────────────────────────────────────────────

    def send_boj_intervention(self, keyword: str, headline: str, score: int) -> bool:
        msg = (
            f"🚨 <b>BOJ INTERVENTION SIGNAL DETECTED</b>\n"
            f"Keyword: '{keyword}'\n"
            f"Headline: {headline[:200]}\n"
            f"Risk Score: {score}/3\n"
            f"ACTION: Positions reduced 50% — SL → breakeven\n"
            f"New entries blocked 90 minutes.\n"
            f"Time: {datetime.utcnow().strftime('%H:%M:%S UTC')}"
        )
        return self._send(msg)

    # ── System Status ────────────────────────────────────────────────────

    def send_ai_server_down(self, last_response_ms: float) -> bool:
        msg = (
            f"⚠️ <b>AI SERVER NOT RESPONDING</b>\n"
            f"Last response: {last_response_ms:.0f}ms ago\n"
            f"Bots entering SAFE MODE — no new entries.\n"
            f"Check VPS immediately."
        )
        return self._send(msg)

    def send_daily_summary(
        self,
        date: str,
        total_trades: int,
        wins: int,
        gross_pnl: float,
        max_dd: float,
        news_shields: int,
        ai_uptime_pct: float,
    ) -> bool:
        win_rate = (wins / total_trades * 100) if total_trades > 0 else 0
        emoji = "🟢" if gross_pnl >= 0 else "🔴"
        msg = (
            f"{emoji} <b>DAILY SUMMARY — {date}</b>\n"
            f"Trades: {total_trades} | Wins: {wins} ({win_rate:.1f}%)\n"
            f"Gross P&L: ${gross_pnl:+.2f}\n"
            f"Max Drawdown: {max_dd:.1f}%\n"
            f"News Shields: {news_shields}\n"
            f"AI Server Uptime: {ai_uptime_pct:.1f}%"
        )
        return self._send(msg)

    def send_weekly_summary(
        self,
        week: str,
        total_pnl: float,
        scalper_win_rate: float,
        swing_win_rate: float,
        max_drawdown: float,
    ) -> bool:
        emoji = "📊"
        msg = (
            f"{emoji} <b>WEEKLY SUMMARY — {week}</b>\n"
            f"Total P&L: ${total_pnl:+.2f}\n"
            f"Scalper Win Rate: {scalper_win_rate:.1f}%\n"
            f"Swing Win Rate: {swing_win_rate:.1f}%\n"
            f"Max Drawdown: {max_drawdown:.1f}%"
        )
        return self._send(msg)

    def send_retraining_reminder(
        self, month: str, live_accuracy: float, val_accuracy: float, needs_retrain: bool
    ) -> bool:
        action = "⚠️ RETRAIN NOW" if needs_retrain else "✅ No retrain needed yet"
        msg = (
            f"🔄 <b>MONTHLY RETRAINING CHECK — {month}</b>\n"
            f"Live accuracy: {live_accuracy:.1f}%\n"
            f"Validation accuracy: {val_accuracy:.1f}%\n"
            f"Drop: {val_accuracy - live_accuracy:.1f}pp\n"
            f"Status: {action}"
        )
        return self._send(msg)

    def send_test(self) -> bool:
        msg = (
            f"🤖 <b>BOT SYSTEM TEST</b>\n"
            f"GBP/JPY AI Trading Bot is online.\n"
            f"All alert types are functional.\n"
            f"Time: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}"
        )
        return self._send(msg)


def test_telegram():
    """Quick test — sends a test message to verify token/chat_id work."""
    config = load_config()
    tg_cfg = config.get("telegram", {})
    token = tg_cfg.get("bot_token", "")
    chat_id = tg_cfg.get("chat_id", "")

    if "YOUR_BOT_TOKEN" in token or not token:
        print("ERROR: Set your Telegram bot_token and chat_id in config.json first.")
        print("Steps:")
        print("  1. Message @BotFather on Telegram → /newbot → save the API token")
        print("  2. Message @userinfobot on Telegram → save your chat ID")
        print("  3. Update config.json: telegram.bot_token and telegram.chat_id")
        sys.exit(1)

    alerter = TelegramAlerter(token=token, chat_id=chat_id)
    print("Sending test message...")
    success = alerter.send_test()
    if success:
        print("✅ Test message sent successfully. Check your Telegram.")
    else:
        print("❌ Failed to send. Check your bot token and chat ID.")


if __name__ == "__main__":
    test_telegram()
