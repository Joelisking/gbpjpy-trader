"""
Optuna hyperparameter search for the swing XGBoost model.

Searches over XGBoost params to maximise validation AUC.
If the best trial beats the current model (AUC 0.662), saves the new model.

Usage:
    uv run python training/tune_swing_xgb.py                 # 100 trials
    uv run python training/tune_swing_xgb.py --trials 200
    uv run python training/tune_swing_xgb.py --trials 50 --fast   # quick smoke test
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

H1_SUBSAMPLE     = 12      # same as train_swing_model.py
SWING_SEQ        = 120     # same
BASELINE_AUC     = 0.662   # current test AUC to beat
POSITIVE_THRESH  = 0.70    # label binarization threshold (same as training)


def load_data(start: str | None, end: str | None):
    from training.prepare_sequences import (
        load_scaled_data, chronological_split_indices, make_xgb_arrays,
    )

    print("Loading data...")
    X_scaled, y, feature_cols, index = load_scaled_data(
        target="trend_strength",
        seq_len=SWING_SEQ,
        start=start,
        end=end,
    )

    print(f"Subsampling to H1 resolution (every {H1_SUBSAMPLE} bars)...")
    X_sub = X_scaled[::H1_SUBSAMPLE]
    y_sub = y[::H1_SUBSAMPLE]
    print(f"  {len(X_sub):,} rows")

    y_bin = (y_sub >= POSITIVE_THRESH).astype(np.float32)
    pos_rate = y_bin.mean()
    print(f"  Positive rate: {pos_rate:.1%}  (base rate to beat)")

    train_r, val_r, test_r = chronological_split_indices(len(X_sub), SWING_SEQ)

    X_tr, y_tr = make_xgb_arrays(X_sub, y_bin, train_r, SWING_SEQ)
    X_vl, y_vl = make_xgb_arrays(X_sub, y_bin, val_r,   SWING_SEQ)
    X_te, y_te = make_xgb_arrays(X_sub, y_bin, test_r,  SWING_SEQ)

    n_pos = y_tr.sum()
    n_neg = len(y_tr) - n_pos
    scale_pos_weight = float(n_neg / max(n_pos, 1))
    print(f"  Train pos/neg: {int(n_pos):,} / {int(n_neg):,}  "
          f"scale_pos_weight={scale_pos_weight:.2f}")

    return X_tr, y_tr, X_vl, y_vl, X_te, y_te, scale_pos_weight, feature_cols


def objective(trial, X_tr, y_tr, X_vl, y_vl, scale_pos_weight):
    import xgboost as xgb
    from sklearn.metrics import roc_auc_score

    params = {
        "n_estimators":      trial.suggest_int("n_estimators", 200, 1200),
        "max_depth":         trial.suggest_int("max_depth", 3, 8),
        "learning_rate":     trial.suggest_float("learning_rate", 0.005, 0.2, log=True),
        "subsample":         trial.suggest_float("subsample", 0.5, 1.0),
        "colsample_bytree":  trial.suggest_float("colsample_bytree", 0.4, 1.0),
        "colsample_bylevel": trial.suggest_float("colsample_bylevel", 0.4, 1.0),
        "min_child_weight":  trial.suggest_int("min_child_weight", 1, 30),
        "reg_alpha":         trial.suggest_float("reg_alpha", 1e-4, 10.0, log=True),
        "reg_lambda":        trial.suggest_float("reg_lambda", 1e-4, 10.0, log=True),
        "gamma":             trial.suggest_float("gamma", 0.0, 5.0),
        "scale_pos_weight":  scale_pos_weight,
        "objective":         "binary:logistic",
        "eval_metric":       "auc",
        "early_stopping_rounds": 40,
        "n_jobs":            -1,
        "random_state":      42,
        "verbosity":         0,
    }

    model = xgb.XGBClassifier(**params)
    model.fit(
        X_tr, y_tr,
        eval_set=[(X_vl, y_vl)],
        verbose=False,
    )

    prob = model.predict_proba(X_vl)[:, 1]
    return roc_auc_score(y_vl, prob)


def evaluate_model(model, X, y, label: str) -> dict:
    from sklearn.metrics import roc_auc_score, precision_score, recall_score

    prob    = model.predict_proba(X)[:, 1]
    pred    = (prob >= 0.5).astype(int)
    y_int   = y.astype(int)

    auc   = roc_auc_score(y_int, prob)
    prec  = precision_score(y_int, pred, zero_division=0)
    rec   = recall_score(y_int, pred, zero_division=0)
    acc   = (pred == y_int).mean()

    print(f"  {label:5s} | AUC={auc:.4f} | Acc={acc:.3f} | "
          f"Prec={prec:.3f} | Rec={rec:.3f}  "
          f"(predicted pos: {pred.sum():,} / {len(pred):,})")

    return {"auc": round(float(auc), 4), "accuracy": round(float(acc), 4),
            "precision": round(float(prec), 4), "recall": round(float(rec), 4)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trials", type=int, default=100,
                        help="Number of Optuna trials (default 100)")
    parser.add_argument("--start",  type=str, default=None)
    parser.add_argument("--end",    type=str, default=None)
    parser.add_argument("--fast",   action="store_true",
                        help="Quick smoke test: 10 trials")
    args = parser.parse_args()

    if args.fast:
        args.trials = 10

    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    import xgboost as xgb

    print("=" * 60)
    print(f"Swing XGBoost Optuna Tuning  ({args.trials} trials)")
    print(f"Baseline to beat: AUC {BASELINE_AUC}")
    print("=" * 60)

    X_tr, y_tr, X_vl, y_vl, X_te, y_te, scale_pos_weight, feature_cols = \
        load_data(args.start, args.end)

    study = optuna.create_study(
        direction="maximize",
        sampler=optuna.samplers.TPESampler(seed=42),
        pruner=optuna.pruners.MedianPruner(n_startup_trials=10, n_warmup_steps=0),
    )

    print(f"\nRunning {args.trials} trials (optimising val AUC)...")
    study.optimize(
        lambda trial: objective(trial, X_tr, y_tr, X_vl, y_vl, scale_pos_weight),
        n_trials=args.trials,
        show_progress_bar=True,
    )

    best = study.best_trial
    print(f"\nBest trial #{best.number}: val AUC = {best.value:.4f}")
    print("Best params:")
    for k, v in best.params.items():
        print(f"  {k}: {v}")

    # ── Retrain best model on train+val, evaluate on held-out test ────────────
    print("\nRetraining best params on train+val data...")
    X_tv = np.vstack([X_tr, X_vl])
    y_tv = np.concatenate([y_tr, y_vl])

    best_params = {**best.params,
                   "scale_pos_weight": scale_pos_weight,
                   "objective":        "binary:logistic",
                   "eval_metric":      "auc",
                   "n_jobs":           -1,
                   "random_state":     42,
                   "verbosity":        0}
    # No early stopping when training on full train+val (no separate eval set)
    best_params.pop("early_stopping_rounds", None)

    final_model = xgb.XGBClassifier(**best_params)
    final_model.fit(X_tv, y_tv)

    print("\nFinal model evaluation:")
    res_tr = evaluate_model(final_model, X_tr, y_tr, "train")
    res_vl = evaluate_model(final_model, X_vl, y_vl, "val")
    res_te = evaluate_model(final_model, X_te, y_te, "test")

    test_auc = res_te["auc"]
    improved = test_auc > BASELINE_AUC

    print(f"\n{'=' * 60}")
    if improved:
        print(f"✅ Improvement: {BASELINE_AUC:.3f} → {test_auc:.3f} "
              f"(+{test_auc - BASELINE_AUC:.3f})")
        print("Saving new model → models/swing_xgb.json")
        final_model.save_model(str(MODELS_DIR / "swing_xgb.json"))

        # Update ensemble weights config
        cfg_path = MODELS_DIR / "swing_ensemble_weights.json"
        cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
        cfg["optuna_best_val_auc"]  = round(float(best.value), 4)
        cfg["optuna_test_auc"]      = round(float(test_auc), 4)
        cfg["optuna_trials"]        = args.trials
        cfg["optuna_best_params"]   = best.params
        cfg["evaluation"]["train"]  = res_tr
        cfg["evaluation"]["val"]    = res_vl
        cfg["evaluation"]["test"]   = res_te
        cfg_path.write_text(json.dumps(cfg, indent=2))
        print("Updated models/swing_ensemble_weights.json")
    else:
        print(f"⚠️  No improvement: best test AUC {test_auc:.3f} ≤ baseline {BASELINE_AUC:.3f}")
        print("Keeping existing model unchanged.")
        print("\nRecommendation: proceed to BiLSTM training for the swing model.")

    # ── Top feature importances ───────────────────────────────────────────────
    print("\nTop 10 feature importances:")
    imp = final_model.feature_importances_
    idx = np.argsort(imp)[::-1][:10]
    for rank, i in enumerate(idx, 1):
        name = feature_cols[i] if i < len(feature_cols) else f"f{i}"
        print(f"  {rank:2d}. {name:30s} {imp[i]:.4f}")

    # Save study results for reference
    results_path = MODELS_DIR / "swing_optuna_results.json"
    all_trials = [
        {"number": t.number, "value": t.value, "params": t.params}
        for t in study.trials if t.value is not None
    ]
    results_path.write_text(json.dumps({
        "best_val_auc":  round(float(best.value), 4),
        "test_auc":      round(float(test_auc), 4),
        "baseline_auc":  BASELINE_AUC,
        "improved":      improved,
        "n_trials":      args.trials,
        "best_params":   best.params,
        "all_trials":    all_trials,
    }, indent=2))
    print(f"\nFull results saved → {results_path.name}")


if __name__ == "__main__":
    main()
