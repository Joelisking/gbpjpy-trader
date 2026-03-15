"""
Walk-forward validation for scalper and swing models.

Splits the full date range into 12 chronological segments.
Each segment: train on all prior data, evaluate on current segment.
Mimics live trading — no future data leakage.

Scalper: BiLSTM (60%) + XGBoost regressor (40%), threshold 0.65
Swing:   XGBoost classifier only, threshold 0.55

Usage:
    uv run python training/walk_forward.py --model scalper
    uv run python training/walk_forward.py --model swing
    uv run python training/walk_forward.py --model scalper --fast
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))

DATA_DIR   = ROOT / "data"
MODELS_DIR = ROOT / "models"

N_SEGMENTS = 12


def walk_forward_segments(index: pd.DatetimeIndex, n: int = 12) -> list[tuple]:
    total    = len(index)
    seg_size = total // n
    segments = []
    for i in range(3, n):  # minimum 3 segments of training data
        train_end = index[seg_size * i - 1]
        seg_start = index[seg_size * i]
        seg_end   = index[min(seg_size * (i + 1) - 1, total - 1)]
        segments.append((train_end, seg_start, seg_end))
    return segments


def run_scalper_segment(X_scaled, y, index, train_end, seg_start, seg_end,
                        fast: bool) -> dict:
    import xgboost as xgb
    from sklearn.metrics import mean_absolute_error, roc_auc_score
    from tensorflow import keras
    from training.prepare_sequences import make_tf_dataset, make_xgb_arrays

    seq_len = 200
    train_mask = index <= train_end
    test_mask  = (index >= seg_start) & (index <= seg_end)

    # Build index ranges for generator
    train_idx = np.where(train_mask)[0]
    test_idx   = np.where(test_mask)[0]

    # Valid sequence start indices (need seq_len look-back)
    valid_train = train_idx[train_idx >= seq_len]
    valid_test  = test_idx[test_idx >= seq_len]

    if len(valid_train) < 500 or len(valid_test) < 50:
        return {"skip": True, "reason": "insufficient data"}

    train_range = range(valid_train[0] - seq_len, valid_train[-1] - seq_len + 1)
    test_range  = range(valid_test[0]  - seq_len, valid_test[-1]  - seq_len + 1)

    n_features = X_scaled.shape[1]

    # ── BiLSTM ───────────────────────────────────────────────────────
    from training.train_scalper_model import build_bilstm
    bilstm = build_bilstm(seq_len, n_features)

    epochs     = 3 if fast else 10
    batch_size = 1024 if fast else 512
    steps    = len(train_range) // batch_size
    train_ds = make_tf_dataset(X_scaled, y, train_range, seq_len, batch_size, shuffle=True, repeat=True)
    val_ds   = make_tf_dataset(X_scaled, y, test_range,  seq_len, batch_size)

    bilstm.fit(train_ds, epochs=epochs, steps_per_epoch=steps, verbose=0)

    # ── XGBoost regressor ─────────────────────────────────────────────
    n_trees = 100 if fast else 300
    X_tr, y_tr = make_xgb_arrays(X_scaled, y, train_range, seq_len)
    X_te, y_te = make_xgb_arrays(X_scaled, y, test_range,  seq_len)

    xgb_model = xgb.XGBRegressor(
        n_estimators=n_trees, max_depth=5, learning_rate=0.1,
        n_jobs=-1, random_state=42, verbosity=0,
    )
    xgb_model.fit(X_tr, y_tr)

    # ── Ensemble ──────────────────────────────────────────────────────
    bl_pred  = bilstm.predict(val_ds, verbose=0).flatten()
    xgb_pred = xgb_model.predict(X_te)
    ensemble = 0.60 * bl_pred + 0.40 * xgb_pred

    threshold = 0.65
    pred_bin  = (ensemble >= threshold).astype(int)
    true_bin  = (y_te     >= threshold).astype(int)
    acc  = (pred_bin == true_bin).mean()
    prec = (pred_bin & true_bin).sum() / max(pred_bin.sum(), 1)
    rec  = (pred_bin & true_bin).sum() / max(true_bin.sum(), 1)
    mae  = float(np.mean(np.abs(ensemble - y_te)))
    try:
        auc = float(roc_auc_score(true_bin, ensemble))
    except Exception:
        auc = 0.5

    keras.backend.clear_session()

    return {
        "skip": False,
        "train_end": str(train_end.date()),
        "seg_start": str(seg_start.date()),
        "seg_end":   str(seg_end.date()),
        "n_train":   len(valid_train),
        "n_test":    len(valid_test),
        "mae":       round(mae, 4),
        "auc":       round(auc, 4),
        "accuracy":  round(float(acc), 4),
        "precision": round(float(prec), 4),
        "recall":    round(float(rec), 4),
    }


def run_swing_segment(X_scaled, y_raw, index, train_end, seg_start, seg_end,
                      fast: bool) -> dict:
    import xgboost as xgb
    from sklearn.metrics import roc_auc_score
    from training.prepare_sequences import make_xgb_arrays

    seq_len     = 120
    subsample   = 12  # H1 resolution
    threshold   = 0.55

    # Subsample first
    sub_idx   = np.arange(0, len(index), subsample)
    X_sub     = X_scaled[sub_idx]
    y_sub_raw = y_raw[sub_idx]
    idx_sub   = index[sub_idx]

    # Binarize
    y_bin = (y_sub_raw >= 0.70).astype(np.float32)

    train_mask = idx_sub <= train_end
    test_mask  = (idx_sub >= seg_start) & (idx_sub <= seg_end)

    valid_train = np.where(train_mask)[0]
    valid_test  = np.where(test_mask)[0]
    valid_train = valid_train[valid_train >= seq_len]
    valid_test  = valid_test[valid_test  >= seq_len]

    if len(valid_train) < 200 or len(valid_test) < 30:
        return {"skip": True, "reason": "insufficient data"}

    train_range = range(valid_train[0] - seq_len, valid_train[-1] - seq_len + 1)
    test_range  = range(valid_test[0]  - seq_len, valid_test[-1]  - seq_len + 1)

    X_tr, y_tr = make_xgb_arrays(X_sub, y_bin, train_range, seq_len)
    X_te, y_te = make_xgb_arrays(X_sub, y_bin, test_range,  seq_len)

    n_pos = y_tr.sum()
    n_neg = len(y_tr) - n_pos
    spw   = float(n_neg / max(n_pos, 1))

    n_trees = 50 if fast else 200
    xgb_model = xgb.XGBClassifier(
        n_estimators=n_trees, max_depth=5, learning_rate=0.1,
        scale_pos_weight=spw, objective="binary:logistic",
        n_jobs=-1, random_state=42, verbosity=0,
    )
    xgb_model.fit(X_tr, y_tr)

    probs    = xgb_model.predict_proba(X_te)[:, 1]
    pred_bin = (probs >= threshold).astype(int)
    true_bin = y_te.astype(int)

    acc  = (pred_bin == true_bin).mean()
    prec = (pred_bin & true_bin).sum() / max(pred_bin.sum(), 1)
    rec  = (pred_bin & true_bin).sum() / max(true_bin.sum(), 1)
    try:
        auc = float(roc_auc_score(true_bin, probs))
    except Exception:
        auc = 0.5

    return {
        "skip": False,
        "train_end": str(train_end.date()),
        "seg_start": str(seg_start.date()),
        "seg_end":   str(seg_end.date()),
        "n_train":   len(valid_train),
        "n_test":    len(valid_test),
        "auc":       round(auc, 4),
        "accuracy":  round(float(acc), 4),
        "precision": round(float(prec), 4),
        "recall":    round(float(rec), 4),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model",    choices=["scalper", "swing"], default="scalper")
    parser.add_argument("--segments", type=int, default=N_SEGMENTS)
    parser.add_argument("--start",    type=str, default=None)
    parser.add_argument("--end",      type=str, default=None)
    parser.add_argument("--fast",     action="store_true")
    args = parser.parse_args()

    print("=" * 60)
    print(f"Walk-Forward Validation: {args.model.upper()} model")
    print(f"Segments: {args.segments}")
    print("=" * 60)

    from training.prepare_sequences import load_scaled_data

    target = "entry_quality" if args.model == "scalper" else "trend_strength"
    seq_len = 200 if args.model == "scalper" else 120

    print("\nLoading data...")
    X_scaled, y, feature_cols, index = load_scaled_data(
        target=target,
        seq_len=seq_len,
        start=args.start,
        end=args.end,
    )

    segments = walk_forward_segments(index, args.segments)
    print(f"\nRunning {len(segments)} segments...\n")

    all_results = []

    for i, (train_end, seg_start, seg_end) in enumerate(segments, 1):
        print(f"Segment {i}/{len(segments)}: "
              f"train→{train_end.date()} | test {seg_start.date()}→{seg_end.date()}")

        if args.model == "scalper":
            result = run_scalper_segment(X_scaled, y, index,
                                         train_end, seg_start, seg_end, args.fast)
        else:
            result = run_swing_segment(X_scaled, y, index,
                                       train_end, seg_start, seg_end, args.fast)

        if result.get("skip"):
            print(f"  SKIPPED: {result['reason']}\n")
            continue

        all_results.append(result)

        flag = ""
        if result.get("auc", 1) < 0.55:
            flag = "  ⚠️  AUC <0.55 (regime change)"
        elif result.get("precision", 1) < 0.40:
            flag = "  ⚠️  Low precision"

        auc_str  = f"AUC={result['auc']:.3f} | " if "auc" in result else ""
        mae_str  = f"MAE={result['mae']:.4f} | " if "mae" in result else ""
        print(f"  {mae_str}{auc_str}Acc={result['accuracy']:.3f} | "
              f"Prec={result['precision']:.3f} | Rec={result['recall']:.3f}{flag}\n")

    if not all_results:
        print("No valid segments completed.")
        return

    # ── Summary ──────────────────────────────────────────────────────
    aucs  = [r["auc"]       for r in all_results if "auc"  in r]
    precs = [r["precision"] for r in all_results]
    accs  = [r["accuracy"]  for r in all_results]

    print("=" * 60)
    print("Walk-Forward Summary:")
    print(f"  Segments completed : {len(all_results)}/{len(segments)}")
    if aucs:
        print(f"  AUC       — mean: {np.mean(aucs):.3f}  "
              f"std: {np.std(aucs):.3f}  "
              f"min: {np.min(aucs):.3f}  max: {np.max(aucs):.3f}")
    print(f"  Precision — mean: {np.mean(precs):.3f}  "
          f"std: {np.std(precs):.3f}  "
          f"min: {np.min(precs):.3f}  max: {np.max(precs):.3f}")
    print(f"  Accuracy  — mean: {np.mean(accs):.3f}")

    below = sum(a < 0.55 for a in aucs) if aucs else sum(a < 0.55 for a in accs)
    print(f"\n  Segments flagged   : {below}/{len(all_results)}")
    if below > len(all_results) * 0.4:
        print("  ⚠️  >40% segments flagged — regime instability detected")
    else:
        print("  ✅ Model stable enough across regimes to proceed")

    out = {
        "model":    args.model,
        "segments": all_results,
        "summary": {
            "mean_auc":       round(float(np.mean(aucs)), 4) if aucs else None,
            "std_auc":        round(float(np.std(aucs)), 4)  if aucs else None,
            "mean_precision": round(float(np.mean(precs)), 4),
            "std_precision":  round(float(np.std(precs)), 4),
            "mean_accuracy":  round(float(np.mean(accs)), 4),
            "segments_flagged": below,
        },
    }
    result_path = ROOT / "backtest_results" / f"walk_forward_{args.model}.json"
    result_path.parent.mkdir(exist_ok=True)
    with open(result_path, "w") as f:
        json.dump(out, f, indent=2)
    print(f"\nResults saved → {result_path.name}")
    print("\nNext: deploy to VPS")


if __name__ == "__main__":
    main()
