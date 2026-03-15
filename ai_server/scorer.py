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
                          bilstm, xgb_model, scaler,
                          seq_len: int,
                          bilstm_weight: float = 0.60) -> float:
        """
        Run ensemble inference on a flat feature vector.
        features: 1D array of raw feature values (unscaled)
        Returns score in 0-1 range.
        """
        if scaler is not None:
            features = scaler.transform(features.reshape(1, -1))[0]

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

        # BiLSTM uses sequence — Phase 3: MT5 will send full 200-bar sequence
        # For now: tile the single bar across seq_len (Phase 2 fallback)
        bl_score = xgb_score  # default to XGBoost if no BiLSTM
        if bilstm is not None:
            seq = np.tile(features, (seq_len, 1))[np.newaxis, :, :]
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
        features_json: JSON array of floats from MQL5 FeatureBuilder
        Returns entry score 0-100.
        """
        if not self._loaded or (self._scalper_bilstm is None and self._scalper_xgb is None):
            return -1  # signal: models not loaded

        try:
            features = np.array(json.loads(features_json), dtype=np.float32)
        except (json.JSONDecodeError, ValueError):
            return -1

        seq_len = self._scalper_cfg.get("seq_len", 200)
        raw = self._predict_ensemble(
            features,
            self._scalper_bilstm, self._scalper_xgb, self._scaler_scalper,
            seq_len,
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
            features = np.array(json.loads(features_json), dtype=np.float32)
        except (json.JSONDecodeError, ValueError):
            return -1

        seq_len = self._swing_cfg.get("seq_len", 60)
        raw = self._predict_ensemble(
            features,
            self._swing_bilstm, self._swing_xgb, self._scaler_swing,
            seq_len,
        )
        return int(round(raw * 100))

    def score_news_risk(self) -> int:
        """
        News risk score based on proximity to next scheduled event.
        In Phase 3 this will query the live ForexFactory feed.
        For now returns 0 (no risk) — news_shield.py will manage this directly.
        """
        return 0

    @property
    def is_loaded(self) -> bool:
        return self._loaded
