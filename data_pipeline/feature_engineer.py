"""
Build the feature matrix for AI training.

Reads GBPJPY M1/M5/H1/H4/W1 + EURJPY M1/H1 parquet files and produces
a single aligned feature DataFrame saved to data/features.parquet.

All features are computed at M5 resolution (the lowest timeframe used
for entry decisions). Higher-timeframe features are forward-filled.

Feature groups:
  1. Price & returns       — M1, M5, H1, H4 OHLC normalised
  2. EMAs                  — EMA9/21/50/200 on M5/H1/H4; EMA21/50 on W1
  3. ATR(14)               — M5, H4
  4. RSI                   — RSI(7) M5, RSI(14) H1/H4
  5. MACD histogram        — M5, H1
  6. Bollinger Bands       — M5 (20, 2σ)
  7. Candle patterns       — engulfing, pin bar, doji (M1, M5)
  8. Market structure      — HH/HL count on H4 (rolling 60 bars)
  9. Volume                — tick volume ratio vs 20-bar avg (M5, H1)
 10. Time encoding         — sin/cos hour-of-day, day-of-week
 11. EUR/JPY               — EMA21 alignment score, return M5
 12. Carry differential    — BoE rate - BoJ rate (static for now)

Usage:
    uv run python data_pipeline/feature_engineer.py
    uv run python data_pipeline/feature_engineer.py --start 2010 --end 2026
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).parent.parent / "data"

# ── Helpers ───────────────────────────────────────────────────────────────────

def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def rsi(series: pd.Series, period: int) -> pd.Series:
    delta = series.diff()
    gain  = delta.clip(lower=0).ewm(alpha=1/period, adjust=False).mean()
    loss  = (-delta.clip(upper=0)).ewm(alpha=1/period, adjust=False).mean()
    rs    = gain / loss.replace(0, np.nan)
    return 100 - (100 / (1 + rs))


def atr(df: pd.DataFrame, period: int) -> pd.Series:
    hi, lo, cl = df["high"], df["low"], df["close"]
    tr = pd.concat([
        hi - lo,
        (hi - cl.shift()).abs(),
        (lo - cl.shift()).abs(),
    ], axis=1).max(axis=1)
    return tr.ewm(span=period, adjust=False).mean()


def macd_histogram(series: pd.Series, fast=12, slow=26, signal=9) -> pd.Series:
    macd_line = ema(series, fast) - ema(series, slow)
    signal_line = ema(macd_line, signal)
    return macd_line - signal_line


def bollinger_pct_b(series: pd.Series, period=20, std_dev=2.0) -> pd.Series:
    mid  = series.rolling(period).mean()
    band = series.rolling(period).std() * std_dev
    return (series - (mid - band)) / (2 * band).replace(0, np.nan)


def engulfing(df: pd.DataFrame) -> pd.Series:
    """Returns +1 (bull engulf), -1 (bear engulf), 0 otherwise."""
    o, c, po, pc = df["open"], df["close"], df["open"].shift(), df["close"].shift()
    bull = (c > o) & (po > pc) & (c > po) & (o < pc)
    bear = (c < o) & (pc > po) & (c < po) & (o > pc)
    return bull.astype(int) - bear.astype(int)


def pin_bar(df: pd.DataFrame) -> pd.Series:
    """Returns +1 (hammer), -1 (shooting star), 0 otherwise."""
    o, h, l, c = df["open"], df["high"], df["low"], df["close"]
    body   = (c - o).abs()
    range_ = (h - l).replace(0, np.nan)
    upper_wick = h - c.clip(lower=o)
    lower_wick = o.clip(upper=c) - l
    hammer       = (lower_wick > 2 * body) & (upper_wick < body) & (range_ > 0)
    shooting_star= (upper_wick > 2 * body) & (lower_wick < body) & (range_ > 0)
    return hammer.astype(int) - shooting_star.astype(int)


def hh_hl_score(close: pd.Series, lookback: int = 60) -> pd.Series:
    """
    Rolling count of higher highs minus lower lows over lookback bars.
    Positive = bullish structure, negative = bearish.
    """
    roll_max = close.rolling(lookback).max()
    roll_min = close.rolling(lookback).min()
    # Fraction of recent bars that are new highs/lows
    is_hh = (close == roll_max).astype(int)
    is_ll = (close == roll_min).astype(int)
    hh_cnt = is_hh.rolling(lookback).sum()
    ll_cnt = is_ll.rolling(lookback).sum()
    return hh_cnt - ll_cnt


def volume_ratio(vol: pd.Series, period: int = 20) -> pd.Series:
    avg = vol.rolling(period).mean()
    return (vol / avg.replace(0, np.nan)).clip(0, 5)


# ── Per-timeframe feature builders ───────────────────────────────────────────

def build_m5_features(df: pd.DataFrame, prefix="m5") -> pd.DataFrame:
    out = pd.DataFrame(index=df.index)
    cl = df["close"]

    out[f"{prefix}_return"]   = cl.pct_change().clip(-0.05, 0.05)
    out[f"{prefix}_ema9"]     = ema(cl, 9)  / cl - 1
    out[f"{prefix}_ema21"]    = ema(cl, 21) / cl - 1
    out[f"{prefix}_ema50"]    = ema(cl, 50) / cl - 1
    out[f"{prefix}_ema200"]   = ema(cl, 200)/ cl - 1
    out[f"{prefix}_atr"]      = atr(df, 14) / cl
    out[f"{prefix}_rsi7"]     = rsi(cl, 7)  / 100
    out[f"{prefix}_macd_hist"]= macd_histogram(cl).clip(-0.01, 0.01) / cl
    out[f"{prefix}_bb_pctb"]  = bollinger_pct_b(cl).clip(0, 1)
    out[f"{prefix}_engulf"]   = engulfing(df)
    out[f"{prefix}_pin"]      = pin_bar(df)

    if "tick_volume" in df.columns:
        out[f"{prefix}_vol_ratio"] = volume_ratio(df["tick_volume"])
    else:
        out[f"{prefix}_vol_ratio"] = 1.0

    return out


def build_h1_features(df: pd.DataFrame, prefix="h1") -> pd.DataFrame:
    out = pd.DataFrame(index=df.index)
    cl = df["close"]

    out[f"{prefix}_return"] = cl.pct_change().clip(-0.05, 0.05)
    out[f"{prefix}_ema21"]  = ema(cl, 21) / cl - 1
    out[f"{prefix}_ema50"]  = ema(cl, 50) / cl - 1
    out[f"{prefix}_ema200"] = ema(cl, 200)/ cl - 1
    out[f"{prefix}_rsi14"]  = rsi(cl, 14) / 100
    out[f"{prefix}_macd_hist"] = macd_histogram(cl).clip(-0.01, 0.01) / cl
    out[f"{prefix}_atr"]    = atr(df, 14) / cl

    if "tick_volume" in df.columns:
        out[f"{prefix}_vol_ratio"] = volume_ratio(df["tick_volume"])
    else:
        out[f"{prefix}_vol_ratio"] = 1.0

    return out


def build_h4_features(df: pd.DataFrame, prefix="h4") -> pd.DataFrame:
    out = pd.DataFrame(index=df.index)
    cl = df["close"]

    out[f"{prefix}_return"]    = cl.pct_change().clip(-0.05, 0.05)
    out[f"{prefix}_ema50"]     = ema(cl, 50)  / cl - 1
    out[f"{prefix}_ema200"]    = ema(cl, 200) / cl - 1
    out[f"{prefix}_rsi14"]     = rsi(cl, 14)  / 100
    out[f"{prefix}_atr"]       = atr(df, 14)  / cl
    out[f"{prefix}_structure"] = hh_hl_score(cl, 60) / 60  # normalised

    return out


def build_w1_features(df: pd.DataFrame, prefix="w1") -> pd.DataFrame:
    out = pd.DataFrame(index=df.index)
    cl = df["close"]

    out[f"{prefix}_return"]  = cl.pct_change().clip(-0.1, 0.1)
    out[f"{prefix}_ema21"]   = ema(cl, 21) / cl - 1
    out[f"{prefix}_ema50"]   = ema(cl, 50) / cl - 1
    # EMA stack direction: +1 if 21>50, -1 if 21<50
    e21 = ema(cl, 21)
    e50 = ema(cl, 50)
    out[f"{prefix}_ema_stack"] = np.sign(e21 - e50)

    return out


def build_eurjpy_features(df_m5: pd.DataFrame, df_h1: pd.DataFrame) -> pd.DataFrame:
    out = pd.DataFrame(index=df_m5.index)
    cl5 = df_m5["close"]

    out["eurjpy_return_m5"] = cl5.pct_change().clip(-0.05, 0.05)

    e21 = ema(cl5, 21)
    e50 = ema(cl5, 50)
    out["eurjpy_ema_align"] = np.sign(e21 - e50)  # +1/-1

    # H1 RSI
    if df_h1 is not None and not df_h1.empty:
        cl1 = df_h1["close"]
        rsi_h1 = rsi(cl1, 14) / 100
        # Resample H1 → M5 by forward fill
        rsi_h1 = rsi_h1.reindex(df_m5.index, method="ffill")
        out["eurjpy_rsi_h1"] = rsi_h1
    else:
        out["eurjpy_rsi_h1"] = 0.5

    return out


def build_time_features(index: pd.DatetimeIndex) -> pd.DataFrame:
    out = pd.DataFrame(index=index)
    hour = index.hour + index.minute / 60
    dow  = index.dayofweek  # 0=Mon, 4=Fri
    out["time_sin_hour"] = np.sin(2 * np.pi * hour / 24)
    out["time_cos_hour"] = np.cos(2 * np.pi * hour / 24)
    out["time_sin_dow"]  = np.sin(2 * np.pi * dow  / 5)
    out["time_cos_dow"]  = np.cos(2 * np.pi * dow  / 5)
    # London session flag (07:00–17:00 UTC)
    out["london_session"] = ((index.hour >= 7) & (index.hour < 17)).astype(int)
    # Overlap (London + NY: 13:00–17:00 UTC)
    out["overlap_session"] = ((index.hour >= 13) & (index.hour < 17)).astype(int)
    return out


# ── Main assembly ─────────────────────────────────────────────────────────────

def load(symbol: str, tf: str) -> pd.DataFrame:
    path = DATA_DIR / f"{symbol}_{tf}.parquet"
    if not path.exists():
        raise FileNotFoundError(f"Missing {path.name} — run resample_timeframes.py first")
    df = pd.read_parquet(path)
    df.index = pd.to_datetime(df.index)
    df = df.sort_index()
    df = df[~df.index.duplicated(keep="last")]
    return df


def build_features(start: str | None = None, end: str | None = None) -> pd.DataFrame:
    print("Loading data files...")
    gbp_m5 = load("GBPJPY", "M5")
    gbp_h1 = load("GBPJPY", "H1")
    gbp_h4 = load("GBPJPY", "H4")
    gbp_w1 = load("GBPJPY", "W1")
    eur_m5 = load("EURJPY", "M5")
    eur_h1 = load("EURJPY", "H1")

    if start:
        gbp_m5 = gbp_m5[gbp_m5.index >= start]
    if end:
        gbp_m5 = gbp_m5[gbp_m5.index <= end]

    print(f"  GBP/JPY M5 rows: {len(gbp_m5):,}  ({gbp_m5.index[0].date()} → {gbp_m5.index[-1].date()})")
    base_index = gbp_m5.index

    print("Computing M5 features...")
    feat_m5 = build_m5_features(gbp_m5)

    print("Computing H1 features (resampled to M5)...")
    feat_h1_raw = build_h1_features(gbp_h1)
    feat_h1 = feat_h1_raw.reindex(base_index, method="ffill")

    print("Computing H4 features (resampled to M5)...")
    feat_h4_raw = build_h4_features(gbp_h4)
    feat_h4 = feat_h4_raw.reindex(base_index, method="ffill")

    print("Computing W1 features (resampled to M5)...")
    feat_w1_raw = build_w1_features(gbp_w1)
    feat_w1 = feat_w1_raw.reindex(base_index, method="ffill")

    print("Computing EUR/JPY features...")
    eur_m5_aligned = eur_m5.reindex(base_index, method="ffill")
    feat_eur = build_eurjpy_features(eur_m5_aligned, eur_h1)
    feat_eur = feat_eur.reindex(base_index, method="ffill")

    print("Computing time features...")
    feat_time = build_time_features(base_index)

    # Carry differential — static placeholder; updated by Python feed
    # BoE 4.75% - BoJ 0.50% = 4.25 as of Phase 2
    carry = pd.Series(4.25, index=base_index, name="carry_differential") / 10.0  # normalise to ~0-1

    print("Merging all feature groups...")
    features = pd.concat([
        feat_m5,
        feat_h1,
        feat_h4,
        feat_w1,
        feat_eur,
        feat_time,
        carry,
    ], axis=1)

    # Add raw close price for label generation
    features["gbpjpy_close"] = gbp_m5["close"].reindex(base_index)

    print(f"  Total features: {len(features.columns) - 1}")  # -1 for close

    # Drop rows with any NaN (warmup period for slow EMAs)
    before = len(features)
    features = features.dropna()
    print(f"  Rows after dropna: {len(features):,} (dropped {before - len(features):,} warmup rows)")

    return features


def main() -> None:
    parser = argparse.ArgumentParser(description="Build feature matrix from parquet data")
    parser.add_argument("--start", type=str, default=None, help="Start date YYYY-MM-DD")
    parser.add_argument("--end",   type=str, default=None, help="End date YYYY-MM-DD")
    args = parser.parse_args()

    print("GBP/JPY Feature Engineering")
    print("=" * 50)

    features = build_features(args.start, args.end)

    out_path = DATA_DIR / "features.parquet"
    features.to_parquet(out_path)
    print(f"\nSaved {len(features):,} rows × {len(features.columns)} columns → {out_path.name}")
    print(f"Date range: {features.index[0]} → {features.index[-1]}")
    print("\nFeature list:")
    for col in features.columns:
        print(f"  {col}")

    print("\nDone. Next: uv run python data_pipeline/label_generator.py")


if __name__ == "__main__":
    main()
