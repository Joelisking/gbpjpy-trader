"""
AI Server — asyncio TCP socket server on port 5001.

Protocol (same as server_test.py, now backed by real models):

  MT5 → Python  (newline-terminated JSON):
    {"features": "[f1,f2,...,fn]", "direction": "BUY"}

  Python → MT5  (newline-terminated JSON):
    {"entry_score": 72, "trend_score": 68, "news_risk": 20, "approve": true}

  Health check:
    MT5 → "PING\n"
    Python → "PONG\n"

Graceful fallback:
  If models are not yet trained, falls back to server_test.py dummy scores.
  Bots check `approve` field; if server restarts they enter safe mode.

Usage:
    uv run python ai_server/server.py
    uv run python ai_server/server.py --port 5001 --host 127.0.0.1
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import signal
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("ai_server")

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))

from ai_server.scorer import AIScorer
from ai_server.news_shield import NewsShield
from ai_server.telegram_alerts import TelegramAlerter

scorer = AIScorer()

# Telegram alerter — initialised in main_async after config is loaded
_tg: TelegramAlerter | None = None

def _tg_send(text: str) -> None:
    """Fire-and-forget Telegram send. Swallows all errors so server never crashes."""
    if _tg is None:
        return
    try:
        _tg._send(text)
    except Exception as e:
        log.warning(f"Telegram send failed: {e}")

# ── Shared scoring helper ─────────────────────────────────────────────────────

def _build_response(features: str, direction: str) -> dict:
    """
    Score a request and return the response dict.
    Empty features array ("[]") = health-check ping — returns alive signal
    without running models (avoids crashing on zero-length feature vector).
    """
    news_risk = scorer.score_news_risk()

    try:
        flist = json.loads(features)
    except (json.JSONDecodeError, ValueError):
        flist = []

    # Health-check ping from EA's IsServerAlive() — reply without scoring
    if len(flist) == 0:
        return {"entry_score": 55, "trend_score": 55,
                "news_risk": news_risk, "approve": True}

    entry_score = scorer.score_entry(features)
    trend_score = scorer.score_trend(features)

    if entry_score < 0:
        entry_score = 55
        trend_score = 55
        log.warning("Models not loaded — returning safe defaults")

    approve = entry_score >= 65 and news_risk < 70
    return {
        "entry_score": entry_score,
        "trend_score": trend_score,
        "news_risk":   news_risk,
        "approve":     approve,
    }


# ── Request handler ──────────────────────────────────────────────────────────

async def handle_client(reader: asyncio.StreamReader,
                        writer: asyncio.StreamWriter) -> None:
    addr = writer.get_extra_info("peername")
    log.debug(f"Connection from {addr}")

    try:
        while True:
            data = await asyncio.wait_for(reader.readline(), timeout=10.0)
            if not data:
                break

            raw = data.decode("utf-8").strip()

            # ── Health check ──────────────────────────────────────────
            if raw == "PING":
                writer.write(b"PONG\n")
                await writer.drain()
                continue

            # ── Score request ─────────────────────────────────────────
            try:
                req = json.loads(raw)
            except json.JSONDecodeError:
                log.warning(f"Bad JSON from {addr}: {raw[:80]}")
                writer.write(b'{"error":"bad_json"}\n')
                await writer.drain()
                continue

            features  = req.get("features",  "[]")
            direction = req.get("direction", "BUY")

            resp = _build_response(features, direction)

            log.info(
                f"[{direction:4s}] entry={resp['entry_score']:3d} trend={resp['trend_score']:3d} "
                f"news={resp['news_risk']:3d} approve={resp['approve']} "
                f"phase={scorer._news_shield.phase if scorer._news_shield else 'N/A'}"
            )

            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()

    except asyncio.TimeoutError:
        log.debug(f"Client {addr} timed out")
    except ConnectionResetError:
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


# ── Server lifecycle ─────────────────────────────────────────────────────────

async def _file_ipc_loop(files_dir: Path,
                         req_name: str = "ai_request.json",
                         resp_name: str = "ai_response.json",
                         label: str = "Scalper") -> None:
    """
    Poll for a request file written by the MQL5 EA, score it, write response back.
    Call once per EA (scalper + swing) with different file names to avoid conflicts.
    """
    request_file  = files_dir / req_name
    response_file = files_dir / resp_name
    log.info(f"File IPC [{label}] watching: {files_dir / req_name}")

    while True:
        try:
            if request_file.exists():
                raw = request_file.read_text(encoding="utf-8").strip()
                request_file.unlink(missing_ok=True)

                req       = json.loads(raw)
                features  = req.get("features",  "[]")
                direction = req.get("direction", "BUY")

                resp = _build_response(features, direction)
                response_file.write_text(json.dumps(resp), encoding="utf-8")
                log.info(
                    f"[File/{label}/{direction}] entry={resp['entry_score']} "
                    f"trend={resp['trend_score']} news={resp['news_risk']} approve={resp['approve']}"
                )
        except Exception as e:
            log.error(f"File IPC [{label}] error: {e}")

        await asyncio.sleep(0.05)   # poll every 50 ms


async def _hourly_heartbeat() -> None:
    """Send a Telegram heartbeat every hour so we know the server is alive."""
    while True:
        await asyncio.sleep(3600)
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        loaded = "✅ loaded" if scorer.is_loaded else "⚠️ fallback"
        phase  = scorer._news_shield.phase if scorer._news_shield else "N/A"
        _tg_send(
            f"🖥 <b>AI SERVER HEARTBEAT</b>\n"
            f"Models: {loaded}\n"
            f"News Shield phase: {phase}\n"
            f"Time: {now}"
        )
        log.info("Hourly Telegram heartbeat sent.")


async def main_async(host: str, port: int) -> None:
    global _tg
    log.info("=" * 50)
    log.info("GBP/JPY AI Server starting")
    log.info(f"Loading models from {ROOT / 'models'}...")

    loaded = scorer.load()
    if loaded:
        log.info("✅ Models loaded — running with real AI scores")
    else:
        log.warning("⚠️  Models not loaded — running in fallback mode (safe defaults)")
        log.warning("    Train models first: uv run python training/train_scalper_model.py")

    # ── News Shield ───────────────────────────────────────────────────────────
    config_path = ROOT / "config.json"
    config = {}
    if config_path.exists():
        with open(config_path) as f:
            config = json.load(f)

    # ── Telegram ──────────────────────────────────────────────────────────────
    tg_cfg  = config.get("telegram", {})
    tg_token = tg_cfg.get("bot_token", "")
    tg_chat  = tg_cfg.get("chat_id", "")
    if tg_token and "PASTE" not in tg_token and "YOUR_" not in tg_token:
        _tg = TelegramAlerter(token=tg_token, chat_id=tg_chat)
        log.info("Telegram alerter configured (chat_id=%s)", tg_chat)
    else:
        log.warning("Telegram not configured — set bot_token and chat_id in config.json")

    # boj_alert_file: path the MQL5 BoJWatchdog reads from.
    boj_alert_file = config.get("news_shield", {}).get("boj_alert_file", "config/boj_alert.txt")
    boj_alert_path = Path(boj_alert_file) if Path(boj_alert_file).is_absolute() else ROOT / boj_alert_file

    shield = NewsShield(config, boj_alert_path)
    scorer.set_news_shield(shield)
    await shield.start()
    log.info("✅ News Shield running — phase=%s", shield.phase)

    server = await asyncio.start_server(handle_client, host, port)
    addr   = server.sockets[0].getsockname()
    log.info(f"Listening on {addr[0]}:{addr[1]}")
    log.info("=" * 50)

    # ── Startup Telegram ping ─────────────────────────────────────────────────
    model_status = "✅ Models loaded" if scorer.is_loaded else "⚠️ Fallback mode (no models)"
    _tg_send(
        f"🖥 <b>AI SERVER ONLINE</b>\n"
        f"{model_status}\n"
        f"Listening on {addr[0]}:{addr[1]}\n"
        f"News Shield: phase={shield.phase}"
    )
    if _tg:
        log.info("Telegram startup message sent.")

    loop = asyncio.get_running_loop()

    def _shutdown():
        log.info("Shutting down...")
        server.close()

    # add_signal_handler is not supported on Windows
    if sys.platform != "win32":
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, _shutdown)

    # ── File IPC (for brokers that disable socket API, e.g. Deriv MT5) ──────────
    boj_path   = config.get("news_shield", {}).get("boj_alert_file", "")
    files_dir  = Path(boj_path).parent if boj_path else None
    if files_dir and files_dir.exists():
        log.info(f"File IPC enabled — watching {files_dir}")
    else:
        log.warning(
            "File IPC: MT5 Files directory not found. "
            "Set news_shield.boj_alert_file in config.json to the full path of boj_alert.txt."
        )
        files_dir = None

    async with server:
        asyncio.ensure_future(_hourly_heartbeat())
        if files_dir:
            asyncio.ensure_future(_file_ipc_loop(
                files_dir, "ai_request.json", "ai_response.json", "Scalper"))
            asyncio.ensure_future(_file_ipc_loop(
                files_dir, "swing_ai_request.json", "swing_ai_response.json", "Swing"))
        await server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser(description="GBP/JPY AI Server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5001)
    args = parser.parse_args()

    try:
        asyncio.run(main_async(args.host, args.port))
    except KeyboardInterrupt:
        log.info("Server stopped.")


if __name__ == "__main__":
    main()
