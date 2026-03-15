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

scorer = AIScorer()

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

            entry_score = scorer.score_entry(features)
            trend_score = scorer.score_trend(features)
            news_risk   = scorer.score_news_risk()

            # If models not loaded, return safe defaults (same as server_test.py)
            if entry_score < 0:
                entry_score = 55
                trend_score = 55
                log.warning("Models not loaded — returning safe defaults")

            approve = (
                entry_score >= 65
                and trend_score >= 50  # swing doesn't gate scalper; this is informational
                and news_risk < 70
            )

            resp = {
                "entry_score": entry_score,
                "trend_score": trend_score,
                "news_risk":   news_risk,
                "approve":     approve,
            }

            log.info(
                f"[{direction:4s}] entry={entry_score:3d} trend={trend_score:3d} "
                f"news={news_risk:3d} approve={approve}"
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

async def main_async(host: str, port: int) -> None:
    log.info("=" * 50)
    log.info("GBP/JPY AI Server starting")
    log.info(f"Loading models from {ROOT / 'models'}...")

    loaded = scorer.load()
    if loaded:
        log.info("✅ Models loaded — running with real AI scores")
    else:
        log.warning("⚠️  Models not loaded — running in fallback mode (safe defaults)")
        log.warning("    Train models first: uv run python training/train_scalper_model.py")

    server = await asyncio.start_server(handle_client, host, port)
    addr   = server.sockets[0].getsockname()
    log.info(f"Listening on {addr[0]}:{addr[1]}")
    log.info("=" * 50)

    loop = asyncio.get_running_loop()

    def _shutdown():
        log.info("Shutting down...")
        server.close()

    # add_signal_handler is not supported on Windows
    if sys.platform != "win32":
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, _shutdown)

    async with server:
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
