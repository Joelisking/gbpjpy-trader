"""
Resample M1 Parquet files to H1, H4, and W1.

Much faster than re-downloading. Uses the M1 data already on disk.

Usage:
    uv run python data_pipeline/resample_timeframes.py
"""
from pathlib import Path
import pandas as pd

DATA_DIR = Path(__file__).parent.parent / "data"

RULES = {
    "H1": "1h",
    "H4": "4h",
    "W1": "1W",
}

SYMBOLS = ["GBPJPY", "EURJPY"]


def resample_from_m1(symbol: str) -> None:
    m1_path = DATA_DIR / f"{symbol}_M1.parquet"
    if not m1_path.exists():
        print(f"  SKIP {symbol} — M1 file not found")
        return

    print(f"\nLoading {symbol} M1...")
    df = pd.read_parquet(m1_path)
    print(f"  {len(df):,} bars | {df.index[0]} → {df.index[-1]}")

    for tf, rule in RULES.items():
        out_path = DATA_DIR / f"{symbol}_{tf}.parquet"

        resampled = df["close"].resample(rule).agg(["first", "max", "min", "last"])
        resampled.columns = ["open", "high", "low", "close"]

        if "volume" in df.columns:
            resampled["volume"] = df["volume"].resample(rule).sum()
        if "tick_volume" in df.columns:
            resampled["tick_volume"] = df["tick_volume"].resample(rule).sum()

        resampled = resampled.dropna(subset=["open"])
        resampled.index.name = "timestamp"

        resampled.to_parquet(out_path)
        print(f"  Saved {len(resampled):,} {tf} bars → {out_path.name}")


def main() -> None:
    print("Resampling M1 → H1, H4, W1")
    print("=" * 40)
    for symbol in SYMBOLS:
        resample_from_m1(symbol)
    print("\nDone. Run: uv run python data_pipeline/data_validator.py")


if __name__ == "__main__":
    main()
