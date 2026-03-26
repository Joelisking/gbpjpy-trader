"""
AIScorer — loads trained models and produces entry/trend/news scores.

Wraps the BiLSTM + XGBoost ensemble for inference.
Called by server.py on each MT5 request.

Thread-safe (models loaded once at startup, read-only during inference).
"""
from __future__ import annotations

import json
import pickle
from pathlib import Path
from typing import Optional

import numpy as np

MODELS_DIR = Path(__file__).parent.parent / "models"
DATA_DIR   = Path(__file__).parent.parent / "data"


class AIScorer:
    def __init__(self) -> None:
        self._scalper_bilstm = None
        self._scalper_xgb    = None
        self._swing_bilstm   = None
        self._swing_xgb      = None
        self._scaler_scalper = None
        self._scaler_swing   = None
        self._scalper_cfg    = {}
        self._swing_cfg      = {}
        self._loaded         = False
        self._news_shield    = None  # set by server.py after NewsShield starts

    def set_news_shield(self, shield) -> None:
        self._news_shield = shield

    def load(self) -> bool:
        """Load all models. Returns True if at least scalper models loaded."""
        import xgboost as xgb

        ok = True

        # ── Scalper models ────────────────────────────────────────────
        scalper_path = MODELS_DIR / "scalper_bilstm.keras"
        if scalper_path.exists():
            try:
                from tensorflow import keras
                self._scalper_bilstm = keras.models.load_model(str(scalper_path))
                print(f"[Scorer] Scalper BiLSTM loaded ({scalper_path.name})")
            except Exception as e:
                print(f"[Scorer] WARNING: Failed to load scalper BiLSTM: {e}")
        else:
            print(f"[Scorer] Scalper BiLSTM not found — using XGBoost only")

        try:
            xgb_path = MODELS_DIR / "scalper_xgb.json"
            if xgb_path.exists():
                self._scalper_xgb = xgb.XGBRegressor()
                self._scalper_xgb.load_model(str(xgb_path))
                print(f"[Scorer] Scalper XGBoost loaded ({xgb_path.name})")
        except Exception as e:
            print(f"[Scorer] WARNING: Failed to load scalper XGBoost: {e}")
            ok = False

        # ── Swing models ──────────────────────────────────────────────
        swing_path = MODELS_DIR / "swing_bilstm.keras"
        if swing_path.exists():
            try:
                from tensorflow import keras
                self._swing_bilstm = keras.models.load_model(str(swing_path))
                print(f"[Scorer] Swing BiLSTM loaded")
            except Exception as e:
                print(f"[Scorer] WARNING: Failed to load swing BiLSTM: {e}")
        else:
            print(f"[Scorer] Swing BiLSTM not found — using XGBoost only")

        try:
            xgb_path = MODELS_DIR / "swing_xgb.json"
            if xgb_path.exists():
                self._swing_xgb = xgb.XGBClassifier()
                self._swing_xgb.load_model(str(xgb_path))
                print(f"[Scorer] Swing XGBoost loaded")
        except Exception as e:
            print(f"[Scorer] WARNING: Failed to load swing XGBoost: {e}")

        # ── Scalers ───────────────────────────────────────────────────
        for name, attr in [("entry_quality", "_scaler_scalper"),
                            ("trend_strength", "_scaler_swing")]:
            path = DATA_DIR / f"scaler_{name}.pkl"
            if path.exists():
                with open(path, "rb") as f:
                    setattr(self, attr, pickle.load(f))
                print(f"[Scorer] Scaler loaded: {path.name}")

        # ── Ensemble configs ──────────────────────────────────────────
        scalper_cfg_path = MODELS_DIR / "scalper_ensemble_weights.json"
        if scalper_cfg_path.exists():
            with open(scalper_cfg_path) as f:
                self._scalper_cfg = json.load(f)

        swing_cfg_path = MODELS_DIR / "swing_ensemble_weights.json"
        if swing_cfg_path.exists():
            with open(swing_cfg_path) as f:
                self._swing_cfg = json.load(f)

        self._loaded = ok
        return ok

    def _predict_ensemble(self, features: np.ndarray,
                          bilstm, xgb_model,
                          seq_len: int,
                          bilstm_weight: float = 0.60,
                          sequence: Optional[np.ndarray] = None) -> float:
        """
        Run ensemble inference.
        features: 1D pre-scaled array for the last bar (used by XGBoost)
        sequence: optional pre-scaled (seq_len, n_features) array for BiLSTM
        Returns score in 0-1 range.
        """
        # XGBoost uses flat features (last bar)
        xgb_score = 0.5
        if xgb_model is not None:
            try:
                # Classifier (swing model) returns probabilities
                xgb_score = float(xgb_model.predict_proba(features.reshape(1, -1))[0][1])
            except AttributeError:
                # Regressor (scalper model) returns raw score
                xgb_score = float(xgb_model.predict(features.reshape(1, -1))[0])
            xgb_score = float(np.clip(xgb_score, 0, 1))

        bl_score = xgb_score  # default to XGBoost if no BiLSTM
        if bilstm is not None:
            if sequence is not None:
                seq = sequence[np.newaxis, :, :]          # (1, seq_len, n_features)
            else:
                seq = np.tile(features, (seq_len, 1))[np.newaxis, :, :]  # fallback
            bl_score = float(bilstm.predict(seq, verbose=0)[0][0])
            bl_score = float(np.clip(bl_score, 0, 1))

        if bilstm is None or bilstm_weight == 0.0:
            return xgb_score
        if xgb_model is None:
            return bl_score

        return bilstm_weight * bl_score + (1 - bilstm_weight) * xgb_score

    def score_entry(self, features_json: str) -> int:
        """
        Score scalper entry quality.
        features_json: JSON array from MQL5 — either n_features floats (single bar,
                       health-check / compat) or seq_len*n_features floats (full
                       200-bar sequence for BiLSTM+XGBoost ensemble).
        Returns entry score 0-100.
        """
        if not self._loaded or (self._scalper_bilstm is None and self._scalper_xgb is None):
            return -1  # signal: models not loaded

        try:
            flist = features_json if isinstance(features_json, list) else json.loads(features_json)
        except (json.JSONDecodeError, ValueError):
            return -1

        seq_len       = self._scalper_cfg.get("seq_len", 200)
        n_features    = self._scalper_cfg.get("n_features", 40)
        bilstm_weight = self._scalper_cfg.get("bilstm_weight", 0.60)

        sequence = None
        if len(flist) == seq_len * n_features:
            # Full sequence from MT5 — scale entire sequence, use last bar for XGBoost
            raw_seq = np.array(flist, dtype=np.float32).reshape(seq_len, n_features)
            if self._scaler_scalper is not None:
                sequence = self._scaler_scalper.transform(raw_seq).astype(np.float32)
            else:
                sequence = raw_seq
            features = sequence[-1]
        elif len(flist) == n_features:
            # Single bar (health check or legacy)
            raw = np.array(flist, dtype=np.float32)
            features = self._scaler_scalper.transform(raw.reshape(1, -1))[0] \
                       if self._scaler_scalper is not None else raw
        else:
            return -1

        raw = self._predict_ensemble(
            features,
            self._scalper_bilstm, self._scalper_xgb,
            seq_len,
            bilstm_weight=bilstm_weight,
            sequence=sequence,
        )
        return int(round(raw * 100))

    def score_trend(self, features_json: str) -> int:
        """
        Score swing trend strength.
        Returns trend score 0-100.
        """
        if self._swing_bilstm is None and self._swing_xgb is None:
            return -1

        try:
            features = np.array(features_json if isinstance(features_json, list) else json.loads(features_json), dtype=np.float32)
        except (json.JSONDecodeError, ValueError):
            return -1

        seq_len       = self._swing_cfg.get("seq_len", 60)
        bilstm_weight = self._swing_cfg.get("bilstm_weight", 0.0)

        if self._scaler_swing is not None:
            features = self._scaler_swing.transform(features.reshape(1, -1))[0]

        raw = self._predict_ensemble(
            features,
            self._swing_bilstm, self._swing_xgb,
            seq_len,
            bilstm_weight=bilstm_weight,
        )
        return int(round(raw * 100))

    def score_news_risk(self) -> int:
        """
        News risk score (0-100) from the live ForexFactory feed.
        Returns 0 if NewsShield is not yet running.
        """
        if self._news_shield is None:
            return 0
        return self._news_shield.news_risk

    @property
    def is_loaded(self) -> bool:
        return self._loaded
