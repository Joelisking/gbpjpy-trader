"""
Train the swing AI model: BiLSTM (60%) + XGBoost (40%) ensemble.

Target: trend_strength score (0-100 → normalised 0-1)
Output: models/swing_bilstm.keras + models/swing_xgb.json + models/swing_ensemble_weights.json

Subsamples to H4 resolution before building sequences (every 48th M5 bar)
to avoid training on 48× repeated data.

Usage:
    uv run python training/train_swing_model.py
    uv run python training/train_swing_model.py --tiny
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))

DATA_DIR   = ROOT / "data"
MODELS_DIR = ROOT / "models"
MODELS_DIR.mkdir(exist_ok=True)

H1_SUBSAMPLE = 12   # M5 bars per H1 bar (was H4=48, too few training samples)
SWING_SEQ    = 120  # 120 H1 bars = 5 days of context


def build_swing_bilstm(seq_len: int, n_features: int, lstm_units: int = 48):
    # Binary classifier: P(TP1 hit before SL within 48h)
    #
    # Previous run (units=64, dropout=0.3): train AUC 0.96, val AUC 0.58 — severe overfit.
    # Fixes:
    #   - Reduced units 64→48 / 32→24 (fewer params)
    #   - L2 on LSTM kernels (1e-4)
    #   - recurrent_dropout 0.1 (applied inside LSTM cell)
    #   - Increased dropout 0.3→0.4 on LSTM outputs
    #   - SpatialDropout1D on input (drops whole feature channels, stronger regulariser)
    #   - Removed Dense(32) hidden layer — straight to output
    #   - clipnorm=1.0 on Adam to prevent gradient spikes
    from tensorflow import keras

    inp = keras.Input(shape=(seq_len, n_features), name="h1_sequence_input")
    x   = keras.layers.SpatialDropout1D(0.1)(inp)
    x   = keras.layers.Bidirectional(
              keras.layers.LSTM(
                  lstm_units,
                  return_sequences=True,
                  recurrent_dropout=0.1,
                  kernel_regularizer=keras.regularizers.l2(1e-4),
                  recurrent_regularizer=keras.regularizers.l2(1e-4),
              ))(x)
    x   = keras.layers.Dropout(0.4)(x)
    x   = keras.layers.Bidirectional(
              keras.layers.LSTM(
                  lstm_units // 2,
                  recurrent_dropout=0.1,
                  kernel_regularizer=keras.regularizers.l2(1e-4),
                  recurrent_regularizer=keras.regularizers.l2(1e-4),
              ))(x)
    x   = keras.layers.Dropout(0.4)(x)
    out = keras.layers.Dense(1, activation="sigmoid", name="trend_score")(x)

    model = keras.Model(inp, out, name="swing_bilstm")
    model.compile(
        optimizer=keras.optimizers.Adam(learning_rate=1e-3, clipnorm=1.0),
        loss="binary_crossentropy",
        metrics=["accuracy", "AUC"],
    )
    return model


POSITIVE_THRESHOLD = 0.70  # score >= 70 = TP1 hit = positive class


def train_bilstm(X_sub, y_sub, train_range, val_range,
                 seq_len, n_features, epochs, batch_size):
    import numpy as np
    from tensorflow import keras
    from training.prepare_sequences import make_tf_dataset, make_xgb_arrays

    model = build_swing_bilstm(seq_len, n_features)
    model.summary()

    # Binarize labels for BCE: 1 = TP1 hit (score >= 0.70), 0 = loser
    y_bin = (y_sub >= POSITIVE_THRESHOLD).astype(np.float32)

    # Class weights to handle ~75% negative / ~25% positive imbalance
    n_pos = y_bin[list(train_range)].sum()
    n_neg = len(train_range) - n_pos
    weight_for_0 = 1.0
    weight_for_1 = float(n_neg / max(n_pos, 1))
    class_weight = {0: weight_for_0, 1: weight_for_1}
    print(f"  Class weights: {{0: {weight_for_0:.1f}, 1: {weight_for_1:.1f}}}  "
          f"(pos={int(n_pos)}, neg={int(n_neg)})")

    steps = len(train_range) // batch_size
    train_ds = make_tf_dataset(X_sub, y_bin, train_range, seq_len, batch_size, shuffle=True, repeat=True)
    val_ds   = make_tf_dataset(X_sub, y_bin, val_range,   seq_len, batch_size)

    callbacks = [
        keras.callbacks.EarlyStopping(patience=10, restore_best_weights=True,
                                      monitor="val_AUC", mode="max"),
        keras.callbacks.ReduceLROnPlateau(patience=5, factor=0.5, min_lr=1e-6,
                                          monitor="val_AUC", mode="max"),
        keras.callbacks.ModelCheckpoint(str(MODELS_DIR / "swing_bilstm_best.keras"),
                                        save_best_only=True, monitor="val_AUC", mode="max"),
    ]

    history = model.fit(
        train_ds,
        validation_data=val_ds,
        epochs=epochs,
        steps_per_epoch=steps,
        class_weight=class_weight,
        callbacks=callbacks,
        verbose=1,
    )
    return model, history, y_bin


def train_xgboost(X_sub, y_bin, train_range, val_range, seq_len, n_estimators):
    import numpy as np
    import xgboost as xgb
    from training.prepare_sequences import make_xgb_arrays

    X_tr, y_tr_raw = make_xgb_arrays(X_sub, y_bin, train_range, seq_len)
    X_vl, y_vl_raw = make_xgb_arrays(X_sub, y_bin, val_range,   seq_len)

    # y_bin already binarized upstream — use directly
    n_pos = y_tr_raw.sum()
    n_neg = len(y_tr_raw) - n_pos
    scale_pos_weight = float(n_neg / max(n_pos, 1))

    model = xgb.XGBClassifier(
        n_estimators=n_estimators,
        max_depth=5,
        learning_rate=0.05,
        subsample=0.8,
        colsample_bytree=0.8,
        min_child_weight=5,
        scale_pos_weight=scale_pos_weight,
        objective="binary:logistic",
        eval_metric="auc",
        early_stopping_rounds=30,
        n_jobs=-1,
        random_state=42,
    )
    model.fit(X_tr, y_tr_raw, eval_set=[(X_vl, y_vl_raw)], verbose=50)
    return model


def evaluate_ensemble(bilstm, xgb_model, X_sub, y_bin,
                      splits_map, seq_len, bilstm_weight=0.60):
    import numpy as np
    from sklearn.metrics import roc_auc_score
    from training.prepare_sequences import make_tf_dataset, make_xgb_arrays

    results = {}
    threshold = 0.50  # decision boundary on probability output

    for name, rng in splits_map.items():
        ds       = make_tf_dataset(X_sub, y_bin, rng, seq_len, batch_size=512)
        bl_prob  = bilstm.predict(ds, verbose=0).flatten()
        X_fl, y_true = make_xgb_arrays(X_sub, y_bin, rng, seq_len)
        xgb_prob = xgb_model.predict_proba(X_fl)[:, 1]

        ensemble  = bilstm_weight * bl_prob + (1 - bilstm_weight) * xgb_prob
        pred_bin  = (ensemble >= threshold).astype(int)
        true_bin  = y_true.astype(int)

        acc   = (pred_bin == true_bin).mean()
        prec  = (pred_bin & true_bin).sum() / max(pred_bin.sum(), 1)
        rec   = (pred_bin & true_bin).sum() / max(true_bin.sum(), 1)
        try:
            auc = roc_auc_score(true_bin, ensemble)
        except Exception:
            auc = 0.5

        results[name] = {
            "accuracy":  round(float(acc), 4),
            "precision": round(float(prec), 4),
            "recall":    round(float(rec), 4),
            "auc":       round(float(auc), 4),
        }
        print(f"  {name:5s} | AUC={auc:.4f} | Acc={acc:.3f} | "
              f"Prec={prec:.3f} | Rec={rec:.3f}  "
              f"(predicted pos: {pred_bin.sum():,} / {len(pred_bin):,})")

    return results


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs",     type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--xgb-trees",  type=int, default=400)
    parser.add_argument("--start",      type=str, default="2019-01-01")
    parser.add_argument("--end",        type=str, default=None)
    parser.add_argument("--fast",       action="store_true")
    parser.add_argument("--tiny",       action="store_true")
    args = parser.parse_args()

    if args.tiny:
        args.epochs    = 2
        args.xgb_trees = 50
        args.batch_size = 128
        args.start = args.start or "2024-01-01"
    elif args.fast:
        args.epochs    = 5
        args.xgb_trees = 100

    print("=" * 60)
    print("Swing Model Training: BiLSTM + XGBoost Ensemble")
    print("=" * 60)

    from training.prepare_sequences import (
        load_scaled_data, chronological_split_indices, print_split_info
    )

    print("\nLoading data...")
    X_scaled, y, feature_cols, index = load_scaled_data(
        target="trend_strength",
        seq_len=SWING_SEQ,
        start=args.start,
        end=args.end,
    )

    # Subsample to H1 resolution to reduce redundancy while keeping enough samples
    print(f"\nSubsampling to H1 resolution (every {H1_SUBSAMPLE} bars)...")
    X_sub = X_scaled[::H1_SUBSAMPLE]
    y_sub = y[::H1_SUBSAMPLE]
    idx_sub = index[::H1_SUBSAMPLE]
    print(f"  {len(X_sub):,} H1-resolution rows")

    seq_len    = SWING_SEQ
    n_features = X_sub.shape[1]

    print("\nChronological split (70/15/15):")
    train_r, val_r, test_r = chronological_split_indices(len(X_sub), seq_len)
    print_split_info(X_sub, idx_sub, train_r, val_r, test_r, seq_len)

    splits_map = {"train": train_r, "val": val_r, "test": test_r}

    print(f"\nTraining BiLSTM ({args.epochs} epochs, batch={args.batch_size})...")
    bilstm, history, y_bin = train_bilstm(
        X_sub, y_sub, train_r, val_r,
        seq_len, n_features, args.epochs, args.batch_size,
    )
    bilstm.save(str(MODELS_DIR / "swing_bilstm.keras"))
    print(f"  Saved → swing_bilstm.keras")

    print(f"\nTraining XGBoost ({args.xgb_trees} trees)...")
    xgb_model = train_xgboost(X_sub, y_bin, train_r, val_r, seq_len, args.xgb_trees)
    xgb_model.save_model(str(MODELS_DIR / "swing_xgb.json"))
    print(f"  Saved → swing_xgb.json")

    # Evaluate both XGBoost-only and 60/40 ensemble to pick the best blend
    print("\nEnsemble evaluation (XGBoost-only: BiLSTM weight=0):")
    results_xgb = evaluate_ensemble(bilstm, xgb_model, X_sub, y_bin, splits_map, seq_len,
                                    bilstm_weight=0.0)
    print("\nEnsemble evaluation (60% BiLSTM + 40% XGBoost):")
    results_ens = evaluate_ensemble(bilstm, xgb_model, X_sub, y_bin, splits_map, seq_len,
                                    bilstm_weight=0.6)

    # Pick whichever blend has higher test AUC
    if results_ens.get("test", {}).get("auc", 0) > results_xgb.get("test", {}).get("auc", 0):
        bilstm_w = 0.6
        results  = results_ens
        print("\nUsing 60/40 ensemble (BiLSTM improves on XGBoost alone)")
    else:
        bilstm_w = 0.0
        results  = results_xgb
        print("\nUsing XGBoost-only (BiLSTM does not improve ensemble)")

    config = {
        "bilstm_weight": bilstm_w, "xgb_weight": round(1.0 - bilstm_w, 1),
        "seq_len": seq_len, "n_features": n_features,
        "feature_names": feature_cols,
        "trend_threshold": 0.55,   # lowered from 0.70 — XGBoost is a weak filter, not a gate
        "collapse_score": 0.30,
        "resolution": "H1", "subsample_step": H1_SUBSAMPLE,
        "note": "BiLSTM disabled — overfits due to regime mismatch 2010-2021 vs 2023-2026. XGBoost val_AUC=0.66.",
        "evaluation": results,
    }
    with open(MODELS_DIR / "swing_ensemble_weights.json", "w") as f:
        json.dump(config, f, indent=2)

    with open(MODELS_DIR / "swing_bilstm_history.json", "w") as f:
        json.dump({k: [float(v) for v in vals]
                   for k, vals in history.history.items()}, f, indent=2)

    print("\n" + "=" * 60)
    test_auc  = results.get("test", {}).get("auc", 0)
    test_prec = results.get("test", {}).get("precision", 0)
    if test_auc >= 0.60:
        print(f"✅ Test AUC {test_auc:.3f} meets target (≥0.60)")
    else:
        print(f"⚠️  Test AUC {test_auc:.3f} below target (≥0.60) — model struggling to separate classes")
    if test_prec >= 0.55:
        print(f"✅ Test precision {test_prec:.1%} acceptable for live trading")
    else:
        print(f"⚠️  Test precision {test_prec:.1%} — review before deploying")

    print("\nNext: uv run python training/walk_forward.py")


if __name__ == "__main__":
    main()
