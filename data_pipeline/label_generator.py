"""
Generate training labels for all three AI outputs:

  1. entry_quality  — scalper entry quality score (0-100)
                      Labels M5 bars as good/neutral/bad entries
                      based on forward return over next 20 minutes

  2. trend_strength — swing trend strength score (0-100)
                      Labels H4 bars by how far price trends over
                      next 48 hours (forward momentum)

  3. news_risk      — news risk score (0-100)
                      Labels M5 bars near ForexFactory high-impact
                      events (GBP/JPY/USD) as high risk

Labels are joined back to the M5 feature index and saved to
data/labels.parquet alongside features.parquet.

Usage:
    uv run python data_pipeline/label_generator.py
    uv run python data_pipeline/label_generator.py --no-news   # skip news labels

Requires:
    data/features.parquet  (from feature_engineer.py)
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).parent.parent / "data"

# ── Entry quality label ────────────────────────────────────────────────────────
# Simulate the scalper's signal: pullback to M5 EMA21 with RSI in zone
# Then check forward return over hold window to score quality

ENTRY_HOLD_BARS  = 4    # 4 × M5 = 20 minutes (max scalper hold)
TP_PIPS          = 0.30  # 30 pips in JPY price units (0.01 per pip)
SL_PIPS          = 0.15  # 15 pips

def make_entry_labels(features: pd.DataFrame) -> pd.Series:
    """
    Score each M5 bar 0-100 based on the realised outcome of a hypothetical trade.

    Score bands:
      80-100 : TP hit before SL (clear winner)
      50-79  : partial gain (price moved > 0 but didn't reach TP)
      20-49  : breakeven or small loss
      0-19   : SL hit before TP (clear loser)

    Direction is inferred from the M5 EMA21 position:
      price > EMA21 → expect bullish scalp (long)
      price < EMA21 → expect bearish scalp (short)
    """
    close = features["gbpjpy_close"]
    ema21_diff = features["m5_ema21"]  # stored as (ema/price - 1)

    scores = pd.Series(50.0, index=features.index, dtype=float)

    closes = close.values
    ema_diff = ema21_diff.values
    n = len(closes)

    for i in range(n - ENTRY_HOLD_BARS):
        entry = closes[i]
        direction = 1 if ema_diff[i] < 0 else -1  # price above EMA21 → short; below → long
        # (we want pullback: if price just pulled back TO ema21 from above → long)
        direction = 1 if ema_diff[i] < 0.001 else -1

        tp_level = entry + direction * TP_PIPS
        sl_level = entry - direction * SL_PIPS

        tp_hit = False
        sl_hit = False
        max_favorable = 0.0

        for j in range(1, ENTRY_HOLD_BARS + 1):
            future_close = closes[i + j]
            favorable = direction * (future_close - entry)
            max_favorable = max(max_favorable, favorable)

            if direction * (future_close - tp_level) >= 0:
                tp_hit = True
                break
            if direction * (sl_level - future_close) >= 0:
                sl_hit = True
                break

        if tp_hit:
            scores.iloc[i] = 85.0
        elif sl_hit:
            scores.iloc[i] = 15.0
        elif max_favorable > TP_PIPS * 0.5:
            scores.iloc[i] = 65.0
        elif max_favorable > 0:
            scores.iloc[i] = 45.0
        else:
            scores.iloc[i] = 30.0

    return scores.rename("entry_quality")


# ── Trend strength label ──────────────────────────────────────────────────────
# Simulates a swing trade (TP/SL outcome) for each M5 bar, same approach as
# entry_quality but with swing parameters. This gives the model a concrete,
# learnable signal tied to actual trade outcomes rather than abstract consistency.
#
# Swing parameters (per blueprint):
#   Direction : sign of h4_structure feature (positive = bullish)
#   SL        : 50 pips  (midpoint of 45-70 pip range)
#   TP1       : 75 pips  (1.5:1 R:R)
#   TP2       : 150 pips (3:1 R:R)
#   Max hold  : 576 M5 bars (48 hours)

SWING_SL_PIPS   = 0.50   # 50 pips in JPY price units (0.01 per pip)
SWING_TP1_PIPS  = 0.75   # 75 pips  (1.5:1)
SWING_TP2_PIPS  = 1.50   # 150 pips (3:1)
SWING_HOLD_BARS = 576    # 48h in M5 bars

def make_trend_labels(features: pd.DataFrame, atr_adaptive: bool = False) -> pd.Series:
    """
    Score swing entry quality 0-100 for each M5 bar using TP/SL simulation.

    Score bands:
      85 : TP2 hit before SL  (full 3:1 winner)
      70 : TP1 hit before SL  (1.5:1 winner, partial close)
      45 : Positive but didn't reach TP1
      25 : Breakeven or small loss
      10 : SL hit before TP1 (loser)

    atr_adaptive=True: SL = 1.0 × H4_ATR, TP1 = 1.5 × H4_ATR, TP2 = 3.0 × H4_ATR
    This normalises labels across different volatility regimes (2010 vs 2024).
    """
    close     = features["gbpjpy_close"]
    h4_struct = features["h4_structure"]

    scores = pd.Series(50.0, index=features.index, dtype=float)
    closes = close.values
    struct = h4_struct.values
    n      = len(closes)

    # ATR-adaptive: h4_atr feature is atr/close, so raw ATR = h4_atr * close
    if atr_adaptive:
        h4_atrs = (features["h4_atr"] * features["gbpjpy_close"]).values
        print(f"  ATR-adaptive labels: H4 ATR range [{h4_atrs.min():.2f}, {h4_atrs.max():.2f}] "
              f"mean={h4_atrs.mean():.2f} price units")

    for i in range(n - SWING_HOLD_BARS):
        if struct[i] == 0:
            continue

        direction = 1 if struct[i] > 0 else -1
        entry     = closes[i]

        if atr_adaptive:
            atr_val = max(h4_atrs[i], 0.30)  # floor at 30 pips to avoid degenerate labels
            sl_dist  = atr_val * 1.0
            tp1_dist = atr_val * 1.5
            tp2_dist = atr_val * 3.0
        else:
            sl_dist  = SWING_SL_PIPS
            tp1_dist = SWING_TP1_PIPS
            tp2_dist = SWING_TP2_PIPS

        tp1 = entry + direction * tp1_dist
        tp2 = entry + direction * tp2_dist
        sl  = entry - direction * sl_dist

        tp1_hit = tp2_hit = sl_hit = False
        max_favorable = 0.0

        for j in range(1, SWING_HOLD_BARS + 1):
            c = closes[i + j]
            favorable = direction * (c - entry)
            max_favorable = max(max_favorable, favorable)

            if direction * (c - tp2) >= 0:
                tp2_hit = True
                break
            if direction * (c - tp1) >= 0:
                tp1_hit = True
                # Don't break — check if TP2 also hit within hold window
                continue
            if direction * (sl - c) >= 0 and not tp1_hit:
                sl_hit = True
                break

        if tp2_hit:
            scores.iloc[i] = 85.0
        elif tp1_hit:
            scores.iloc[i] = 70.0
        elif sl_hit:
            scores.iloc[i] = 10.0
        elif max_favorable > tp1_dist * 0.5:
            scores.iloc[i] = 45.0
        elif max_favorable > 0:
            scores.iloc[i] = 30.0
        else:
            scores.iloc[i] = 20.0

    return scores.rename("trend_strength")


# ── News risk label ──────────────────────────────────────────────────────────
# Mark M5 bars within ±60 minutes of a high-impact news event as high risk

NEWS_WINDOW_MINUTES = 60  # each side of news event

def make_news_labels(features: pd.DataFrame) -> pd.Series:
    """
    Returns news_risk score 0-100 for each M5 bar.
    100 = within ±15min of high-impact news
    70  = within ±60min of high-impact news
    0   = no nearby news

    Uses ForexFactory calendar if available at data/news_calendar.csv,
    otherwise uses a simplified heuristic based on common news times:
      - Fridays 12:30 UTC (US NFP first Friday of month)
      - Thursdays 12:00 UTC (BoE MPC)
      - Wednesdays 18:00 UTC (Fed minutes)
      - Variable BoJ announcements (not predictable — heuristic only)
    """
    scores = pd.Series(0.0, index=features.index, dtype=float)

    news_path = DATA_DIR / "news_calendar.csv"

    if news_path.exists():
        print("  Loading ForexFactory calendar...")
        news = pd.read_csv(news_path)
        news["datetime"] = pd.to_datetime(news["datetime"], utc=False)
        news = news[news["impact"] == "High"]

        for _, row in news.iterrows():
            event_time = row["datetime"]
            window_start = event_time - pd.Timedelta(minutes=NEWS_WINDOW_MINUTES)
            window_end   = event_time + pd.Timedelta(minutes=NEWS_WINDOW_MINUTES)
            close_window = event_time - pd.Timedelta(minutes=15)
            close_end    = event_time + pd.Timedelta(minutes=15)

            in_window = (features.index >= window_start) & (features.index <= window_end)
            in_close  = (features.index >= close_window) & (features.index <= close_end)

            scores[in_window] = scores[in_window].clip(lower=70)
            scores[in_close]  = 100.0

    else:
        print("  news_calendar.csv not found — using heuristic news times")
        idx = features.index

        # US NFP: first Friday of each month at 12:30 UTC
        nfp_mask  = (idx.weekday == 4) & (idx.day <= 7) & \
                    (idx.hour == 12) & (idx.minute.isin([25, 30, 35]))
        # BoE Thursday 12:00 UTC
        boe_mask  = (idx.weekday == 3) & (idx.hour == 12) & (idx.minute <= 15)
        # Fed Wed 18:00 UTC
        fed_mask  = (idx.weekday == 2) & (idx.hour == 18) & (idx.minute <= 15)

        combined  = nfp_mask | boe_mask | fed_mask
        scores[combined] = 85.0

        # Widen ±60 min windows around flagged bars
        flagged_times = idx[combined]
        for t in flagged_times:
            window = (idx >= t - pd.Timedelta(hours=1)) & \
                     (idx <= t + pd.Timedelta(hours=1))
            scores[window] = scores[window].clip(lower=70)

    return scores.rename("news_risk")


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Generate training labels")
    parser.add_argument("--no-news",      action="store_true", help="Skip news risk labelling")
    parser.add_argument("--atr-adaptive", action="store_true", help="Use ATR-scaled SL/TP for swing labels")
    args = parser.parse_args()

    print("GBP/JPY Label Generator")
    print("=" * 50)

    feat_path = DATA_DIR / "features.parquet"
    if not feat_path.exists():
        print("ERROR: features.parquet not found — run feature_engineer.py first")
        return

    print(f"Loading features...")
    features = pd.read_parquet(feat_path)
    print(f"  {len(features):,} rows × {len(features.columns)} columns")

    print("Generating entry quality labels...")
    entry_lbl = make_entry_labels(features)
    print(f"  Distribution: {entry_lbl.value_counts().to_dict()}")

    print("Generating trend strength labels...")
    trend_lbl = make_trend_labels(features, atr_adaptive=args.atr_adaptive)
    mode = "ATR-adaptive" if args.atr_adaptive else "fixed 50-pip"
    print(f"  Mode: {mode}  Mean: {trend_lbl.mean():.1f}  Std: {trend_lbl.std():.1f}")

    if not args.no_news:
        print("Generating news risk labels...")
        news_lbl = make_news_labels(features)
        print(f"  High-risk bars (>70): {(news_lbl > 70).sum():,}")
    else:
        news_lbl = pd.Series(0.0, index=features.index, name="news_risk")
        print("  Skipped (--no-news)")

    labels = pd.concat([entry_lbl, trend_lbl, news_lbl], axis=1)

    out_path = DATA_DIR / "labels.parquet"
    labels.to_parquet(out_path)
    print(f"\nSaved {len(labels):,} rows × {len(labels.columns)} labels → {out_path.name}")

    # Quick sanity check
    print("\nLabel summary:")
    print(labels.describe().round(2))

    print("\nDone. Next: uv run python training/train_scalper_model.py")


if __name__ == "__main__":
    main()
