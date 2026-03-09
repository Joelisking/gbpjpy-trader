"""
One-time Phase 1 setup script.
Run from the project root: python setup.py

Does:
  1. Creates all required directories
  2. Initialises the SQLite database
  3. Verifies Python package imports
  4. Prints next steps
"""
import importlib
import os
import subprocess
import sys

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
DIRS = [
    "scalper_ea", "swing_ea", "ai_server", "data_pipeline",
    "models", "training", "db", "logs", "backtest_results",
    "data", "config",
]
REQUIRED_PACKAGES = [
    ("pandas", "pandas"),
    ("numpy", "numpy"),
    ("sklearn", "scikit-learn"),
    ("xgboost", "xgboost"),
    ("requests", "requests"),
    ("feedparser", "feedparser"),
    ("yfinance", "yfinance"),
    ("telegram", "python-telegram-bot"),
    ("optuna", "optuna"),
    ("pyarrow", "pyarrow"),
]
OPTIONAL_PACKAGES = [
    ("talib", "TA-Lib (brew install ta-lib && uv add TA-Lib)"),
    ("tensorflow", "TensorFlow — uv sync --extra ai"),
    ("MetaTrader5", "MetaTrader5 (Windows VPS only — uv sync --extra mt5)"),
]


def create_dirs():
    print("\n[1/3] Creating directories...")
    for d in DIRS:
        path = os.path.join(PROJECT_ROOT, d)
        os.makedirs(path, exist_ok=True)
        print(f"  ✅ {d}/")


def setup_database():
    print("\n[2/3] Initialising database...")
    db_setup = os.path.join(PROJECT_ROOT, "db", "setup_db.py")
    result = subprocess.run([sys.executable, db_setup], capture_output=True, text=True)
    if result.returncode == 0:
        print(f"  ✅ {result.stdout.strip()}")
    else:
        print(f"  ❌ DB setup failed: {result.stderr}")


def check_packages():
    print("\n[3/3] Checking Python packages...")
    all_ok = True
    for import_name, pip_name in REQUIRED_PACKAGES:
        try:
            importlib.import_module(import_name)
            print(f"  ✅ {pip_name}")
        except ImportError:
            print(f"  ❌ {pip_name} — run: pip install {pip_name}")
            all_ok = False

    print("\n  Optional packages:")
    for import_name, display_name in OPTIONAL_PACKAGES:
        try:
            importlib.import_module(import_name)
            print(f"  ✅ {display_name}")
        except ImportError:
            print(f"  ⚠️  {display_name} — not installed (needed for later phases)")

    return all_ok


def print_next_steps():
    print("\n" + "=" * 55)
    print("Phase 1 Setup Complete. Next steps:")
    print("=" * 55)
    print("""
  WEEK 1 — Data & Communication
  ─────────────────────────────
  1. On Windows VPS with MT5 installed:
     uv run python data_pipeline/export_mt5_data.py
     → Downloads GBPJPY + EURJPY history to data/

  2. Validate the exported data:
     uv run python data_pipeline/data_validator.py

  3. Start the dummy AI server:
     uv run python ai_server/server_test.py

  4. In MT5: compile and attach SocketTest.mq5 to any chart.
     Check Experts tab for "AI Response received" messages.
     → Confirms MT5 ↔ Python socket communication works.

  5. Set up Telegram bot:
     - Message @BotFather → /newbot → save token
     - Message @userinfobot → save chat_id
     - Update config.json: telegram.bot_token + chat_id
     - Test: uv run python ai_server/telegram_alerts.py

  6. Create SQLite DB (already done by this script):
     uv run python db/setup_db.py

  WEEK 2 is Phase 2 — Bot logic in MQL5.
""")


if __name__ == "__main__":
    print("GBP/JPY AI Bot — Phase 1 Setup")
    print(f"Project root: {PROJECT_ROOT}")

    create_dirs()
    setup_database()
    packages_ok = check_packages()

    print_next_steps()

    if not packages_ok:
        print("⚠️  Some required packages missing — install them before continuing.")
        sys.exit(1)
    else:
        print("✅ All required packages installed.")
