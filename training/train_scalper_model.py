"""
Train the scalper AI model: BiLSTM (60%) + XGBoost (40%) ensemble.

Target: entry_quality score (0-100 → normalised 0-1)
Output: models/scalper_bilstm.keras + models/scalper_xgb.json + models/scalper_ensemble_weights.json

Memory-efficient: uses tf.data generator — only ~250 MB base array in RAM,
no 10 GB pre-allocated window tensor.

Architecture (per blueprint):
    BiLSTM: 200 time steps × 40 features → Bidirectional(LSTM(128)) → Dense(64) → Dense(1)
    XGBoost: last-bar flat features → gradient boosted regressor
    Ensemble: 0.60 × BiLSTM + 0.40 × XGBoost

Usage:
    uv run python training/train_scalper_model.py
    uv run python training/train_scalper_model.py --epochs 50 --start 2015
    uv run python training/train_scalper_model.py --tiny   # pipeline smoke test
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


# ── BiLSTM ────────────────────────────────────────────────────────────────────

def build_bilstm(seq_len: int, n_features: int, lstm_units: int = 128):
    from tensorflow import keras

    inp  = keras.Input(shape=(seq_len, n_features), name="sequence_input")
    x    = keras.layers.Bidirectional(
               keras.layers.LSTM(lstm_units, return_sequences=True))(inp)
    x    = keras.layers.Dropout(0.3)(x)
    x    = keras.layers.Bidirectional(
               keras.layers.LSTM(lstm_units // 2))(x)
    x    = keras.layers.Dropout(0.3)(x)
    x    = keras.layers.Dense(64, activation="relu")(x)
    x    = keras.layers.BatchNormalization()(x)
    x    = keras.layers.Dense(32, activation="relu")(x)
    out  = keras.layers.Dense(1, activation="sigmoid", name="score")(x)

    model = keras.Model(inp, out, name="scalper_bilstm")
    model.compile(
        optimizer="adam",
        loss="huber",
        metrics=["mae"],
    )
    return model


def train_bilstm(X_scaled, y, train_range, val_range,
                 seq_len, n_features, epochs, batch_size):
    from tensorflow import keras
    from training.prepare_sequences import make_tf_dataset

    model = build_bilstm(seq_len, n_features)
    model.summary()

    steps = len(train_range) // batch_size
    train_ds = make_tf_dataset(X_scaled, y, train_range, seq_len, batch_size, shuffle=True, repeat=True)
    val_ds   = make_tf_dataset(X_scaled, y, val_range,   seq_len, batch_size)

    callbacks = [
        keras.callbacks.EarlyStopping(patience=8, restore_best_weights=True,
                                      monitor="val_mae"),
        keras.callbacks.ReduceLROnPlateau(patience=4, factor=0.5, min_lr=1e-6,
                                          monitor="val_mae"),
        keras.callbacks.ModelCheckpoint(str(MODELS_DIR / "scalper_bilstm_best.keras"),
                                        save_best_only=True, monitor="val_mae"),
    ]

    history = model.fit(
        train_ds,
        validation_data=val_ds,
        epochs=epochs,
        steps_per_epoch=steps,
        callbacks=callbacks,
        verbose=1,
    )
    return model, history


# ── XGBoost ──────────────────────────────────────────────────────────────────

def train_xgboost(X_scaled, y, train_range, val_range, seq_len, n_estimators):
    import xgboost as xgb
    from training.prepare_sequences import make_xgb_arrays

    X_tr, y_tr = make_xgb_arrays(X_scaled, y, train_range, seq_len)
    X_vl, y_vl = make_xgb_arrays(X_scaled, y, val_range,   seq_len)

    model = xgb.XGBRegressor(
        n_estimators=n_estimators,
        max_depth=6,
        learning_rate=0.05,
        subsample=0.8,
        colsample_bytree=0.8,
        min_child_weight=10,
        reg_alpha=0.1,
        reg_lambda=1.0,
        objective="reg:squarederror",
        eval_metric="mae",
        early_stopping_rounds=30,
        n_jobs=-1,
        random_state=42,
        verbosity=1,
    )
    model.fit(X_tr, y_tr, eval_set=[(X_vl, y_vl)], verbose=50)
    return model


# ── Ensemble evaluation ──────────────────────────────────────────────────────

def evaluate_ensemble(bilstm, xgb_model, X_scaled, y,
                      splits_map, seq_len, bilstm_weight=0.60):
    from sklearn.metrics import mean_absolute_error, r2_score
    from training.prepare_sequences import make_tf_dataset, make_xgb_arrays

    results = {}
    xgb_weight = 1.0 - bilstm_weight

    for name, rng in splits_map.items():
        ds       = make_tf_dataset(X_scaled, y, rng, seq_len, batch_size=1024)
        bl_pred  = bilstm.predict(ds, verbose=0).flatten()

        X_fl, y_true = make_xgb_arrays(X_scaled, y, rng, seq_len)
        xgb_pred = xgb_model.predict(X_fl)

        ensemble  = bilstm_weight * bl_pred + xgb_weight * xgb_pred
        threshold = 0.65

        mae      = mean_absolute_error(y_true, ensemble)
        r2       = r2_score(y_true, ensemble)
        pred_bin = (ensemble  >= threshold).astype(int)
        true_bin = (y_true    >= threshold).astype(int)
        acc      = (pred_bin == true_bin).mean()
        prec     = (pred_bin & true_bin).sum() / max(pred_bin.sum(), 1)
        rec      = (pred_bin & true_bin).sum() / max(true_bin.sum(), 1)

        results[name] = {
            "mae": round(float(mae), 4), "r2": round(float(r2), 4),
            "accuracy": round(float(acc), 4),
            "precision": round(float(prec), 4), "recall": round(float(rec), 4),
        }
        print(f"  {name:5s} | MAE={mae:.4f} | R²={r2:.4f} | "
              f"Acc={acc:.3f} | Prec={prec:.3f} | Rec={rec:.3f}")

    return results


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs",     type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--xgb-trees",  type=int, default=500)
    parser.add_argument("--start",      type=str, default=None)
    parser.add_argument("--end",        type=str, default=None)
    parser.add_argument("--fast",       action="store_true", help="5 epochs, 200 trees")
    parser.add_argument("--tiny",       action="store_true", help="2 epochs, 50 trees, 2024 data only")
    args = parser.parse_args()

    if args.tiny:
        args.epochs    = 2
        args.xgb_trees = 50
        args.batch_size = 256
        args.start = args.start or "2024-01-01"
    elif args.fast:
        args.epochs    = 5
        args.xgb_trees = 200

    print("=" * 60)
    print("Scalper Model Training: BiLSTM + XGBoost Ensemble")
    print("=" * 60)

    from training.prepare_sequences import (
        load_scaled_data, chronological_split_indices, print_split_info
    )

    print("\nLoading data...")
    X_scaled, y, feature_cols, index = load_scaled_data(
        target="entry_quality",
        seq_len=200,
        start=args.start,
        end=args.end,
    )

    seq_len    = 200
    n_features = X_scaled.shape[1]

    print("\nChronological split (70/15/15):")
    train_r, val_r, test_r = chronological_split_indices(len(X_scaled), seq_len)
    print_split_info(X_scaled, index, train_r, val_r, test_r, seq_len)

    splits_map = {"train": train_r, "val": val_r, "test": test_r}

    # ── BiLSTM ───────────────────────────────────────────────────────
    print(f"\nTraining BiLSTM ({args.epochs} epochs, batch={args.batch_size})...")
    bilstm, history = train_bilstm(
        X_scaled, y, train_r, val_r,
        seq_len, n_features, args.epochs, args.batch_size,
    )
    bilstm_path = MODELS_DIR / "scalper_bilstm.keras"
    bilstm.save(str(bilstm_path))
    print(f"  BiLSTM saved → {bilstm_path.name}")

    # ── XGBoost ──────────────────────────────────────────────────────
    print(f"\nTraining XGBoost ({args.xgb_trees} trees)...")
    xgb_model = train_xgboost(X_scaled, y, train_r, val_r, seq_len, args.xgb_trees)
    xgb_path  = MODELS_DIR / "scalper_xgb.json"
    xgb_model.save_model(str(xgb_path))
    print(f"  XGBoost saved → {xgb_path.name}")

    # ── Ensemble evaluation ──────────────────────────────────────────
    print("\nEnsemble evaluation (60% BiLSTM + 40% XGBoost):")
    results = evaluate_ensemble(bilstm, xgb_model, X_scaled, y, splits_map, seq_len)

    ensemble_config = {
        "bilstm_weight":  0.60,
        "xgb_weight":     0.40,
        "seq_len":        seq_len,
        "n_features":     n_features,
        "feature_names":  feature_cols,
        "entry_threshold": 0.65,
        "evaluation":     results,
    }
    config_path = MODELS_DIR / "scalper_ensemble_weights.json"
    with open(config_path, "w") as f:
        json.dump(ensemble_config, f, indent=2)
    print(f"\nEnsemble config saved → {config_path.name}")

    hist_path = MODELS_DIR / "scalper_bilstm_history.json"
    with open(hist_path, "w") as f:
        json.dump({k: [float(v) for v in vals]
                   for k, vals in history.history.items()}, f, indent=2)

    print("\n" + "=" * 60)
    test_acc = results.get("test", {}).get("accuracy", 0)
    if test_acc >= 0.62:
        print(f"✅ Test accuracy {test_acc:.1%} meets target (≥62%)")
    else:
        print(f"⚠️  Test accuracy {test_acc:.1%} below target (≥62%)")

    print("\nNext: uv run python training/train_swing_model.py")


if __name__ == "__main__":
    main()
