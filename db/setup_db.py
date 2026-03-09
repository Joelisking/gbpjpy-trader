"""
Setup SQLite database with all required tables.
Run once before first use: python db/setup_db.py
"""
import sqlite3
import os
import json

DB_PATH = os.path.join(os.path.dirname(__file__), "trades.db")


def create_tables(conn: sqlite3.Connection) -> None:
    cur = conn.cursor()

    cur.executescript("""
    CREATE TABLE IF NOT EXISTS trades (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        bot             TEXT NOT NULL CHECK(bot IN ('scalper', 'swing')),
        symbol          TEXT NOT NULL DEFAULT 'GBPJPY',
        direction       TEXT NOT NULL CHECK(direction IN ('BUY', 'SELL')),
        lots            REAL NOT NULL,
        entry_price     REAL NOT NULL,
        sl_price        REAL NOT NULL,
        tp1_price       REAL NOT NULL,
        tp2_price       REAL,
        exit_price      REAL,
        exit_reason     TEXT,
        profit_pips     REAL,
        profit_usd      REAL,
        entry_time      TEXT NOT NULL,
        exit_time       TEXT,
        duration_min    REAL,
        entry_score     INTEGER,
        trend_score     INTEGER,
        news_risk       INTEGER,
        session_date    TEXT,
        notes           TEXT
    );

    CREATE TABLE IF NOT EXISTS ai_scores (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp       TEXT NOT NULL,
        symbol          TEXT NOT NULL DEFAULT 'GBPJPY',
        bot             TEXT NOT NULL,
        entry_score     INTEGER,
        trend_score     INTEGER,
        news_risk       INTEGER,
        approved        INTEGER,
        direction       TEXT,
        features_hash   TEXT
    );

    CREATE TABLE IF NOT EXISTS sessions (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        date            TEXT NOT NULL,
        bot             TEXT NOT NULL,
        session_type    TEXT,
        start_balance   REAL,
        end_balance     REAL,
        trades          INTEGER DEFAULT 0,
        wins            INTEGER DEFAULT 0,
        losses          INTEGER DEFAULT 0,
        gross_profit    REAL DEFAULT 0.0,
        gross_loss      REAL DEFAULT 0.0,
        max_drawdown    REAL DEFAULT 0.0,
        news_shields    INTEGER DEFAULT 0,
        halt_triggered  INTEGER DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS news_events (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        event_time      TEXT NOT NULL,
        event_name      TEXT NOT NULL,
        impact          TEXT NOT NULL CHECK(impact IN ('HIGH', 'EXTREME', 'MEDIUM')),
        currency        TEXT,
        actual          TEXT,
        forecast        TEXT,
        previous        TEXT,
        shield_activated INTEGER DEFAULT 0,
        pre_spike_pips  REAL,
        post_spike_pips REAL,
        post_direction  TEXT
    );

    CREATE TABLE IF NOT EXISTS boj_alerts (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp       TEXT NOT NULL,
        keyword_matched TEXT NOT NULL,
        headline        TEXT,
        source          TEXT,
        score           INTEGER,
        positions_reduced INTEGER DEFAULT 0,
        action_taken    TEXT
    );

    CREATE TABLE IF NOT EXISTS model_metadata (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        model_name      TEXT NOT NULL,
        version         INTEGER NOT NULL,
        trained_at      TEXT NOT NULL,
        train_rows      INTEGER,
        val_accuracy    REAL,
        test_accuracy   REAL,
        test_auc        REAL,
        train_period_start TEXT,
        train_period_end   TEXT,
        notes           TEXT,
        is_active       INTEGER DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS carry_trade_rates (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        effective_date  TEXT NOT NULL,
        boe_rate        REAL NOT NULL,
        boj_rate        REAL NOT NULL,
        differential    REAL GENERATED ALWAYS AS (boe_rate - boj_rate) STORED,
        updated_at      TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_trades_entry_time ON trades(entry_time);
    CREATE INDEX IF NOT EXISTS idx_trades_bot ON trades(bot);
    CREATE INDEX IF NOT EXISTS idx_ai_scores_timestamp ON ai_scores(timestamp);
    CREATE INDEX IF NOT EXISTS idx_sessions_date ON sessions(date);
    CREATE INDEX IF NOT EXISTS idx_news_events_time ON news_events(event_time);
    """)

    # Seed current BoE/BoJ rates (update monthly)
    cur.execute("""
        INSERT OR IGNORE INTO carry_trade_rates (effective_date, boe_rate, boj_rate, updated_at)
        SELECT '2026-03-01', 4.75, 0.50, datetime('now')
        WHERE NOT EXISTS (SELECT 1 FROM carry_trade_rates WHERE effective_date = '2026-03-01')
    """)

    conn.commit()
    print(f"Database created: {DB_PATH}")
    print("Tables: trades, ai_scores, sessions, news_events, boj_alerts, model_metadata, carry_trade_rates")


if __name__ == "__main__":
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    create_tables(conn)
    conn.close()
