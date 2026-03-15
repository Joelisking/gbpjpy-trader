# GBP/JPY AI Trading Bot — Project Status
*Last updated: 2026-03-14*

---

## What's Done

### Infrastructure
- [x] Full project scaffold — folder structure, pyproject.toml, `uv` toolchain
- [x] SQLite database (`db/trades.db`) for trade recording
- [x] Config system (`config.json`)
- [x] Git repository with proper `.gitignore` (model files, data, secrets excluded)

### Data Pipeline
- [x] MT5 OHLCV export scripts
- [x] Feature engineering pipeline — 30+ features across M1/M5/H1/H4 timeframes
- [x] Label generation (entry quality and trend strength targets)
- [x] Walk-forward validation framework (12 segments)
- [x] Scalers saved (`scaler_entry_quality.pkl`, `scaler_trend_strength.pkl`)

### AI Models
- [x] **Scalper XGBoost** — trained, 90% test precision, 89.8% accuracy
- [x] **Swing XGBoost** — trained, AUC 0.662, 51.4% precision (vs 36.8% base rate)
- [x] Ensemble weight configs saved (`scalper_ensemble_weights.json`, `swing_ensemble_weights.json`)
- [ ] Scalper BiLSTM — not yet trained
- [ ] Swing BiLSTM — not yet trained (swing XGBoost accuracy may also need improvement first)

### AI Server (`ai_server/`)
- [x] Asyncio TCP socket server on port 5001
- [x] JSON protocol: feature vector in → scores out (`entry_score`, `trend_score`, `news_risk`, `approve`)
- [x] PING/PONG health check
- [x] Graceful fallback mode when models not loaded
- [x] Windows compatibility fix (`add_signal_handler` skipped on win32)
- [x] TensorFlow import deferred until `.keras` files exist (avoids litert DLL error)
- [x] Swing XGBoost loads correctly as `XGBClassifier`

### MQL5 EAs
- [x] **ScalperEA** — compiles clean (0 errors), attached to GBPJPY M1
  - Full rule-based logic: EMA stack, market structure, MACD, ATR, RSI, spread filter
  - Cascade entry system (4 entries: pilot → core → add → max)
  - Exit manager: breakeven, trailing stop, time exit, direction flip close
  - London spike block (07:55–08:15 UTC)
  - AI score gate (entry score ≥ 65, news risk < 70)
  - Session risk cap (10%), hard halt (7%), weekly cap
- [x] **SwingEA** — compiles clean (0 errors), attached to GBPJPY H1
  - 4H trend analysis: EMA200, RSI, market structure, weekly EMA stack
  - 1H entry: 50 EMA pullback, RSI zone, confirmation candle, volume filter
  - TP1/TP2 partial close system (50% at 1:1.5 R:R → breakeven, 50% at 1:3 R:R)
  - BoJ watchdog: rapid JPY move detection, spread spike, Python file-based signal
  - Carry trade filter (BoE-BoJ differential, reads from Python feed)
  - AI trend score gate (≥ 70)
- [x] Both EAs: AI server connection tested, graceful degradation if server down

---

## What's Left

### High Priority

#### 1. Swing Model Accuracy (Before Going Live)
The swing XGBoost AUC of 0.662 and 51.4% precision may not meet the target of 60-68% win rate.
Options (in order of effort):
- **Hyperparameter tuning** — run Optuna on swing XGBoost (`training/train_swing_model.py`)
- **Feature engineering** — add BoE-BoJ rate differential, Nikkei, S&P futures as features
- **BiLSTM for swing** — the 4H model benefits most from sequence data; see section below

#### 2. News Shield Integration
- [ ] ForexFactory XML feed polling (every 60s)
- [ ] News risk score wired into `score_news_risk()` in `ai_server/scorer.py` (currently returns 0)
- [ ] T-60/T-30/T-0/T+15 phases implemented in EAs
- [ ] BoJ keyword scanner writing to `boj_alert.txt` (BoJWatchdog already reads this file)

#### 3. Telegram Monitoring Bot
- [ ] Trade open/close notifications
- [ ] Daily P&L summary
- [ ] Server health alerts (server down, halt triggered)

### Medium Priority

#### 4. BiLSTM Models
Fix TensorFlow on the VPS first:
```cmd
uv add "tensorflow==2.15.1"
```
Then train:
```cmd
uv run python training/train_scalper_model.py   # saves scalper_bilstm.keras
uv run python training/train_swing_model.py     # saves swing_bilstm.keras
```
**Scalper BiLSTM**: lower priority — XGBoost already at 90% precision.
**Swing BiLSTM**: higher priority — sequence patterns matter more at 4H, may close the accuracy gap.

Note: `.keras` files are NOT committed to git. Train directly on the VPS; models live in `models/` locally.

#### 5. Backtesting
- [ ] MT5 Strategy Tester runs for both EAs
- [ ] Walk-forward results reviewed against targets:
  - Scalper: win rate 62-68%, profit factor > 1.4, max DD < 15%
  - Swing: win rate 60-68%, profit factor > 1.6, max DD < 12%
- [ ] Optimise inputs (ATR threshold, TP pips, cascade lot sizes)

#### 6. Carry Trade / Macro Feed
- [ ] Python script to write `config/carry_rates.txt` (BoE-BoJ rate differential)
- [ ] CarryTradeFilter in SwingEA already reads this file — just needs the writer

### Low Priority / Phase 3

#### 7. Full 200-Step Sequence Features
`FeatureBuilder.mqh` currently sends a single-bar feature vector. Phase 3 expands this to a 200-step sequence for the BiLSTM. Requires:
- MT5 EA builds the sequence on each tick
- AI server handles the larger payload
- BiLSTM models trained on sequence input

#### 8. VPS Hardening
- [ ] Windows auto-start: MT5 and AI server on reboot (Task Scheduler)
- [ ] UptimeRobot monitoring for the AI server port
- [ ] Log rotation for `logs/*.log`

#### 9. Live Deployment
- [ ] 4-week demo account run — monitor Journal, verify trade logic matches spec
- [ ] Review actual win rates vs backtest
- [ ] Switch to live account only after demo targets met

---

## Current State Summary

| Component | Status |
|---|---|
| ScalperEA (MQL5) | ✅ Live on M1, awaiting 5M direction signal |
| SwingEA (MQL5) | ✅ Live on H1, awaiting 4H direction signal |
| AI Server | ✅ Running on port 5001 |
| Scalper XGBoost | ✅ Loaded, high accuracy |
| Swing XGBoost | ⚠️ Loaded, accuracy borderline — needs improvement |
| BiLSTM (both) | ❌ Not trained |
| News Shield | ❌ Not implemented (server returns news_risk=0) |
| Telegram Bot | ❌ Not implemented |
| Backtesting | ❌ Not done |
| Demo Run | ❌ Not started |

---

## Known Risks
- **Swing model bias**: BoJ is hiking, BoE is cutting — the rate differential is narrowing. The model was trained partly on historical carry-bull conditions. Monitor swing trade win rate closely in demo.
- **Aug 2024 carry unwind**: Use this period as a stress test benchmark, not just the final 15% test split.
- **AI server as single point of failure**: Both EAs fall back to safe mode (no entries) if server goes down. Ensure Windows auto-restart is configured before going live.
