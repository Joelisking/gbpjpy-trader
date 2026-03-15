# GBP/JPY AI Trading Bot — Project Report
*March 2026*

---

## What We've Built

Two automated trading bots for GBP/JPY, running inside MetaTrader 5. Both are live on the charts and waiting for the right conditions before taking any trades.

**Bot 1 — The Scalper** runs on the 1-minute chart. It looks for short, sharp moves during the London session, enters in up to 4 layers as momentum builds, and aims to be in and out within 20 minutes. Target: 25–35 pips per trade.

**Bot 2 — The Swing Trader** runs on the 1-hour chart, using the 4-hour chart for direction. It's designed for multi-day trades that ride a broader trend, entering on pullbacks to a key moving average. Target: 45–100+ pips per trade.

Both bots are connected to an AI server running in the background. Before opening a trade, each bot asks the AI: *"How confident are you in this setup?"* If the AI score is too low, the trade is skipped — regardless of what the technical indicators say.

---

## AI Model Results

### Scalper Model

The scalper's AI was trained to answer one question: *"Is this a high-quality entry setup?"*

| Metric | Value | What it means |
|---|---|---|
| Accuracy | 89.8% | Out of every 100 labelled bars, the model correctly identified 90 as good or bad setups |
| Precision | 90% | When the model says "this is a good entry", it's right 90% of the time |
| Recall | 4.3% | The model only flags roughly 1 in 23 setups as high-quality — it's very selective |
| AUC | 0.97 | Near-perfect ability to distinguish good setups from bad ones (1.0 would be perfect) |

**What the low recall means:** The scalper AI is a strict gatekeeper. It passes very few trades. In practice, the bot will sit idle most of the day and only enter when multiple technical conditions *and* a high AI confidence score line up. This is by design — precision over frequency.

**What this means for live trading:** On a typical London session, the bot might get 0–2 AI-approved entry signals. When it does fire, the historical precision suggests roughly 9 out of 10 of those signals were genuinely good setups in the training data.

**Honest caveat:** High precision on test data doesn't guarantee live profits — slippage, spread, and live market conditions can erode an edge. The 20-minute time exit and cascade entry rules provide a second layer of protection if the AI misjudges.

---

### Swing Model

The swing model was trained to answer: *"Is the 4-hour trend strong enough to hold a multi-day position?"*

| Metric | Value | What it means |
|---|---|---|
| AUC | 0.662 | Moderate ability to separate trending from non-trending conditions (0.5 = random, 1.0 = perfect) |
| Precision | 51.4% | When the model calls a trend "strong", it's right about half the time |
| Base rate | 36.8% | Without the model, randomly entering would be right ~37% of the time |
| Improvement | +14.6pp | The model adds 14.6 percentage points over random guessing |

**What the numbers say plainly:** The swing model is better than guessing, but not dramatically so. It correctly filters out some bad setups — particularly those that look like trends on the chart but are actually noise or counter-trend retracements. It is *not* yet good enough to use as the primary entry signal; it works as a supporting filter.

**What this means for live trading:** The AI trend score gate (≥70 required to enter) will block some trades that the 4H technical analysis says are valid. In backtesting, this filter should improve the quality of the swing entries that do get through, but the model needs further improvement before it's carrying significant weight in the decision.

**Why the swing model is harder:** The scalper operates on 1-minute patterns that are relatively regime-stable. The swing model is trying to detect 4-hour trends on a pair (GBP/JPY) whose behaviour has shifted significantly since 2023 as the Bank of Japan began hiking rates for the first time in decades. A model trained on historical carry-bull conditions will struggle on data where that dynamic has reversed.

---

## What's Working Right Now

| System | Status | Notes |
|---|---|---|
| Scalper Bot | Live on 1M chart | Waiting for direction signal; connected to AI |
| Swing Bot | Live on H1 chart | Waiting for direction signal; connected to AI |
| AI Server | Running on port 5001 | Serving both bots; scalper XGBoost loaded |
| Scalper AI | Active | 90% precision model loaded and scoring entries |
| Swing AI | Active (with caveat) | XGBoost model loaded; acceptable but not yet optimal |
| BoJ Watchdog | Active | Will close swing positions on any rapid JPY move |
| Spread filters | Active | Both bots skip entries when spread is excessive |
| Session risk caps | Active | Scalper halts after 7% drawdown or 10% session loss |

---

## What's Not Done Yet

### 1. Swing Model Accuracy (Most Important Gap)

The swing model's 51.4% precision is workable, but the target is 60–68% win rate in live trading. Closing this gap is the biggest priority before running the swing bot with real money.

Three options, in order of difficulty:

- **Tune the existing model** — Run an automated search (Optuna) over hundreds of parameter combinations to find a configuration that scores higher. Estimated effort: half a day of compute, an hour of setup.
- **Add macro features** — Feed the model the actual BoE–BoJ interest rate differential, Nikkei 225 futures, and S&P 500 futures. These directly affect GBP/JPY carry flows but aren't currently in the training data. Estimated effort: 1–2 days.
- **Train the deep learning model (BiLSTM)** — The current model looks at each bar independently. The BiLSTM version would look at sequences of 200 bars, which is better suited to detecting trend momentum on the 4-hour chart. This is the highest-effort option but also the most likely to close the accuracy gap meaningfully.

### 2. News Protection (Not Yet Built)

Neither bot currently knows when major economic news is about to be released. The plan is to pull data from ForexFactory every 60 seconds and automatically:
- Warn and tighten stops 60 minutes before a high-impact event
- Close all scalper positions 30 minutes before
- Block new entries during the event
- Resume with reduced size in the 15–60 minutes after

Until this is built, the bots need to be manually monitored around events like BoE rate decisions, UK CPI, and BoJ meetings.

### 3. Telegram Alerts (Not Yet Built)

There's no notification system yet. When a trade opens, closes, or the system hits a risk halt, you currently have to check the MetaTrader Journal manually. Building the Telegram bot would send instant messages for:
- Trade open/close with entry price and P&L
- Daily P&L summary each evening
- Alert if the AI server goes offline

### 4. Backtesting

Neither bot has been formally backtested in MetaTrader's Strategy Tester yet. The AI models have been validated on held-out historical data, but that's not the same as a full end-to-end simulation with realistic spread, slippage, and commission. Backtesting is needed before committing to a live account.

### 5. Demo Run

The plan is a 4-week demo account run before going live. This will reveal whether the live win rates match the backtested targets, and whether any edge cases exist that weren't caught in development.

---

## Key Risks to Be Aware Of

**Swing model trained on the wrong regime.** GBP/JPY was in a prolonged carry-bull trend for much of the training window. That environment is changing as the BoJ normalises rates. The swing model's performance in live trading may be lower than training data suggests. This is the most important risk to monitor.

**AI server is a single point of failure.** If the Python server crashes, both bots automatically stop entering new trades (they fail safe). But they won't restart themselves. Automated restart on Windows (via Task Scheduler) is on the to-do list.

**August 2024 stress test.** During the August 2024 carry unwind, GBP/JPY dropped ~2000 pips in a matter of days. The BoJ Watchdog is designed to detect and close positions in events like this, but it has never been tested under live conditions.

---

## What Comes Next

The recommended sequence before going live:

1. Train the BiLSTM swing model (or tune the existing one) to close the accuracy gap
2. Build the news shield (ForexFactory feed)
3. Run the Strategy Tester backtest on both bots
4. Start 4-week demo account run
5. Review live win rates vs targets — only switch to real money after targets are met
