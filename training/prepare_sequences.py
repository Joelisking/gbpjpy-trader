"""
Shared utility: prepare data for BiLSTM + XGBoost training.

Memory-efficient design:
  - Loads scaled feature array once (~250 MB for full history)
  - BiLSTM training uses tf.data generator — windows produced on the fly, no 10 GB preallocation
  - XGBoost uses flat last-bar array only (~50 MB)

Chronological 70/15/15 split (no shuffle — preserves time order).

Usage:
    from training.prepare_sequences import load_scaled_data, make_tf_dataset, chronological_split_indices
"""
from __future__ import annotations

import pickle
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.preprocessing import RobustScaler

DATA_DIR = Path(__file__).parent.parent / "data"
SEQ_LEN  = 200  # BiLSTM sequence length (per blueprint)

EXCLUDE_COLS = {"gbpjpy_close", "entry_quality", "trend_strength", "news_risk"}


def load_scaled_data(
    target: str = "entry_quality",
    seq_len: int = SEQ_LEN,
    start: str | None = None,
    end:   str | None = None,
) -> tuple[np.ndarray, np.ndarray, list[str], pd.DatetimeIndex]:
    """
    Load + scale features and labels. Returns compact arrays only:
      X_scaled — (N, n_features) float32  [~250 MB for full history]
      y        — (N,) float32
      feature_cols, index

    Windows are NOT pre-built here — use make_tf_dataset() for BiLSTM
    and build X_flat on the fly from X_scaled[i + seq_len - 1].
    """
    feat_path  = DATA_DIR / "features.parquet"
    label_path = DATA_DIR / "labels.parquet"

    if not feat_path.exists():
        raise FileNotFoundError("features.parquet not found — run feature_engineer.py")
    if not label_path.exists():
        raise FileNotFoundError("labels.parquet not found — run label_generator.py")

    features = pd.read_parquet(feat_path)
    labels   = pd.read_parquet(label_path)

    df = features.join(labels, how="inner")

    if start: df = df[df.index >= start]
    if end:   df = df[df.index <= end]

    df = df[df.index.dayofweek < 5]  # drop weekends

    feature_cols = [c for c in features.columns if c not in EXCLUDE_COLS]

    X_raw = df[feature_cols].values.astype(np.float32)
    y_raw = (df[target].values.astype(np.float32)) / 100.0

    scaler   = RobustScaler()
    X_scaled = scaler.fit_transform(X_raw).astype(np.float32)

    scaler_path = DATA_DIR / f"scaler_{target}.pkl"
    with open(scaler_path, "wb") as f:
        pickle.dump(scaler, f)
    print(f"  Scaler saved → {scaler_path.name}")

    index = df.index
    mem_mb = X_scaled.nbytes / 1024**2
    print(f"  Rows: {len(X_scaled):,}  Features: {len(feature_cols)}  RAM: {mem_mb:.0f} MB")
    print(f"  y range: [{y_raw.min():.3f}, {y_raw.max():.3f}]  mean: {y_raw.mean():.3f}")

    return X_scaled, y_raw, feature_cols, index


def chronological_split_indices(
    n: int,
    seq_len: int,
    train_frac: float = 0.70,
    val_frac:   float = 0.15,
) -> tuple[range, range, range]:
    """
    Return (train_range, val_range, test_range) as ranges of valid sequence start indices.
    A sequence starting at index i uses X[i : i+seq_len], label at X[i+seq_len-1].
    """
    # Valid indices: seq_len-1 .. n-1
    valid_n = n - seq_len + 1
    t1 = int(valid_n * train_frac)
    t2 = int(valid_n * (train_frac + val_frac))

    return range(0, t1), range(t1, t2), range(t2, valid_n)


def make_tf_dataset(
    X_scaled: np.ndarray,
    y: np.ndarray,
    indices: range,
    seq_len: int,
    batch_size: int = 512,
    shuffle: bool = False,
    repeat: bool = False,
) -> "tf.data.Dataset":
    """
    Build a tf.data.Dataset that generates (sequence, label) pairs on demand.
    No full window array is ever materialised — each batch reads a contiguous
    slice from X_scaled, keeping peak memory at ~batch_size × seq_len × features.

    repeat=True  → infinite dataset; pass steps_per_epoch to model.fit()
    repeat=False → one pass (use for val/predict)
    Shuffle is done in numpy so the generator closure captures a fixed shuffled order
    (avoids tf.shuffle cardinality issues with from_generator).
    """
    import tensorflow as tf

    idx_array = np.array(indices, dtype=np.int32)
    if shuffle:
        np.random.shuffle(idx_array)

    def _gen():
        for i in idx_array:
            yield X_scaled[i : i + seq_len], y[i + seq_len - 1]

    n_features = X_scaled.shape[1]
    ds = tf.data.Dataset.from_generator(
        _gen,
        output_signature=(
            tf.TensorSpec(shape=(seq_len, n_features), dtype=tf.float32),
            tf.TensorSpec(shape=(),                    dtype=tf.float32),
        ),
    )

    ds = ds.batch(batch_size)
    if repeat:
        ds = ds.repeat()
    ds = ds.prefetch(tf.data.AUTOTUNE)
    return ds


def make_xgb_arrays(
    X_scaled: np.ndarray,
    y: np.ndarray,
    indices: range,
    seq_len: int,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Build flat X_flat (last bar of each window) and y arrays for XGBoost.
    Memory: len(indices) × n_features × 4 bytes — manageable.
    """
    idx = np.array(indices)
    X_flat = X_scaled[idx + seq_len - 1]   # last bar of each window
    y_flat = y[idx + seq_len - 1]
    return X_flat, y_flat


def print_split_info(
    X_scaled: np.ndarray,
    index: pd.DatetimeIndex,
    train_range: range,
    val_range: range,
    test_range: range,
    seq_len: int,
) -> None:
    def _dates(r):
        start_i = r.start + seq_len - 1
        end_i   = r.stop  + seq_len - 2
        return index[start_i].date(), index[min(end_i, len(index)-1)].date()

    for name, r in [("train", train_range), ("val", val_range), ("test", test_range)]:
        s, e = _dates(r)
        print(f"  {name:5s}: {len(r):,} samples  ({s} → {e})")
