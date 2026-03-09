"""
Phase 1 dummy AI server — returns fixed scores to verify MT5 ↔ Python socket
communication works end-to-end before real models are built.

Run: python ai_server/server_test.py

The server listens on 127.0.0.1:5001 (same port the production server will use).
MT5 EA sends a JSON request; this server returns a valid dummy response.

Expected request format:
{
  "type": "entry_check",
  "symbol": "GBPJPY",
  "direction": "BUY",
  "tf": "M1",
  "features": []
}

Response format:
{
  "entry_score": 75,
  "trend_score": 68,
  "news_risk": 20,
  "approve": true,
  "msg": "DUMMY SERVER — Phase 1 test"
}
"""
import asyncio
import json
import logging
import time
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("logs/ai_server_test.log", mode="a"),
    ],
)
log = logging.getLogger(__name__)

HOST = "127.0.0.1"
PORT = 5001

# Fixed dummy scores — always approve so you can verify EA logic fires correctly
DUMMY_RESPONSE = {
    "entry_score": 75,
    "trend_score": 68,
    "news_risk": 20,
    "approve": True,
    "msg": "DUMMY SERVER — Phase 1 test",
}

request_count = 0
start_time = time.time()


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    global request_count
    peer = writer.get_extra_info("peername")
    t0 = time.perf_counter()

    try:
        raw = await asyncio.wait_for(reader.read(65536), timeout=5.0)
        if not raw:
            return

        data = json.loads(raw.decode())
        request_count += 1

        log.info(
            f"[#{request_count}] {peer} → type={data.get('type')} "
            f"symbol={data.get('symbol')} dir={data.get('direction')}"
        )

        response = {**DUMMY_RESPONSE, "request_id": request_count, "server_time": datetime.utcnow().isoformat()}
        encoded = json.dumps(response).encode()
        writer.write(encoded)
        await writer.drain()

        elapsed_ms = (time.perf_counter() - t0) * 1000
        log.info(f"[#{request_count}] Response sent in {elapsed_ms:.1f}ms")

    except asyncio.TimeoutError:
        log.warning(f"Timeout reading from {peer}")
    except json.JSONDecodeError as e:
        log.error(f"Invalid JSON from {peer}: {e}")
    except Exception as e:
        log.error(f"Error handling client {peer}: {e}")
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def stats_reporter() -> None:
    """Log request stats every 60 seconds."""
    while True:
        await asyncio.sleep(60)
        uptime = (time.time() - start_time) / 60
        log.info(f"STATS — uptime: {uptime:.1f}min | total requests: {request_count}")


async def main() -> None:
    import os
    os.makedirs("logs", exist_ok=True)

    server = await asyncio.start_server(handle_client, HOST, PORT)
    log.info(f"DUMMY AI Server listening on {HOST}:{PORT}")
    log.info("Waiting for MT5 EA connections...")

    async with server:
        await asyncio.gather(
            server.serve_forever(),
            stats_reporter(),
        )


if __name__ == "__main__":
    asyncio.run(main())
