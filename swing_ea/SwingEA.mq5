//+------------------------------------------------------------------+
//|  SwingEA.mq5                                                      |
//|  GBP/JPY Swing Rider Bot — 1H/4H timeframes                     |
//|  Attach to GBPJPY H1 chart.                                      |
//|                                                                   |
//|  Phase 2: full rule-based logic with file-based AI IPC           |
//+------------------------------------------------------------------+
#property copyright "GBP/JPY AI Bot"
#property version   "2.1"
#property strict

#include "RiskManager.mqh"
#include "TrendAnalyzer4H.mqh"
#include "CarryTradeFilter.mqh"
#include "SwingEntry1H.mqh"
#include "SwingPositionManager.mqh"
#include "BoJWatchdog.mqh"
#include "AIClient.mqh"
#include "FileAIClient.mqh"
#include "FeatureBuilder.mqh"
#include "TelegramMQL5.mqh"

//-- Inputs ------------------------------------------------------------------
input double RiskPercent        = 2.0;    // % account risk per trade
input double SessionRiskCap     = 8.0;    // max weekly loss %
input double SessionHaltPct     = 6.0;    // hard halt trigger %
input int    AIMinTrendScore    = 70;     // minimum AI trend strength score
input int    AICollapseScore    = 40;     // AI score collapse threshold → exit
input string AI_Host            = "127.0.0.1";
input int    AI_Port            = 5001;
input double MaxSpreadPips      = 25.0;
input double EMA50PullbackPips  = 15.0;  // how close to 1H EMA50 for pullback entry
input bool   NewsShieldEnabled  = true;
input bool   BoJWatchdogEnabled = true;
input string TG_Token           = "PASTE_TOKEN_HERE";   // Telegram bot token
input string TG_ChatId          = "PASTE_CHAT_ID_HERE"; // Telegram chat ID

//-- Objects -----------------------------------------------------------------
CRiskManager          *RiskMgr;
CTrendAnalyzer4H      *TrendAnalyzer;
CCarryTradeFilter     *CarryFilter;
CSwingEntry1H         *EntryLayer;
CSwingPositionManager *PosMgr;
CBoJWatchdog          *BoJWatch;
CAIClient             *AIClient;     // kept for socket fallback
CFileAIClient         *FileAIClient;
CFeatureBuilder       *FeatureBldr;
CTelegramMQL5         *Telegram;

//-- State -------------------------------------------------------------------
int      g_currentBias       = DIR_NONE;
datetime g_lastH4Close       = 0;
datetime g_lastH1Close       = 0;
bool     g_newsShieldActive  = false;
bool     g_aiServerWasDown   = false;
bool     g_aiLastKnownUp     = false;  // updated by 5-min AI ping in OnTimer
double   g_lastStructuralHL  = 0;
double   g_lastStructuralLH  = 0;
int      g_sessionTradeCount = 0;
int      g_timerCount        = 0;  // increments every 60s in OnTimer

//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== SwingEA v2.1 starting on ", _Symbol, " H1 ===");

    if(_Symbol != "GBPJPY")
    {
        Print("ERROR: This EA must run on GBPJPY H1 chart");
        return INIT_FAILED;
    }

    if(Period() != PERIOD_H1)
    {
        Print("ERROR: Attach this EA to H1 chart");
        return INIT_FAILED;
    }

    // Instantiate components
    RiskMgr       = new CRiskManager(RiskPercent, SessionRiskCap, SessionHaltPct);
    TrendAnalyzer = new CTrendAnalyzer4H(60);
    CarryFilter   = new CCarryTradeFilter(0.5);
    EntryLayer    = new CSwingEntry1H(MaxSpreadPips, EMA50PullbackPips);
    PosMgr        = new CSwingPositionManager(RiskPercent, 48.0, 72.0);
    BoJWatch      = new CBoJWatchdog(200.0, 3.0);
    AIClient      = new CAIClient(AI_Host, AI_Port, 500);
    FileAIClient  = new CFileAIClient(500);
    FeatureBldr   = new CFeatureBuilder();
    Telegram      = new CTelegramMQL5();
    Telegram.Init(TG_Token, TG_ChatId);

    if(!TrendAnalyzer.Init())  return INIT_FAILED;
    if(!EntryLayer.Init())     return INIT_FAILED;
    if(!FeatureBldr.Init())    return INIT_FAILED;

    RiskMgr.InitSession();
    RiskMgr.InitWeek();

    // Check AI server via file IPC (sockets disabled on Deriv MT5)
    if(!FileAIClient.IsServerAlive())
    {
        Print("WARNING: AI server not responding via file IPC — start: uv run python ai_server/server.py");
        Telegram.SendAIServerDown();
    }
    else
    {
        Print("AI server connected (file IPC)");
        g_aiLastKnownUp = true;
    }

    // Warn if EURJPY not in Market Watch
    if(SymbolInfoDouble("EURJPY", SYMBOL_BID) == 0)
        Print("WARNING: EURJPY bid = 0 — add EURJPY to Market Watch or FeatureBuilder will return empty features");

    EventSetTimer(60);  // 1-minute timer

    Telegram.SendStartup();
    Print("SwingEA initialised. Waiting for 4H direction...");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();

    if(PosMgr != NULL && PosMgr.IsPositionOpen())
    {
        Print("EA removed — closing swing position");
        PosMgr.CloseAll();
    }

    if(TrendAnalyzer) { TrendAnalyzer.Deinit(); delete TrendAnalyzer; }
    if(EntryLayer)    { EntryLayer.Deinit();     delete EntryLayer; }
    if(FeatureBldr)   { FeatureBldr.Deinit();    delete FeatureBldr; }

    delete RiskMgr;
    delete CarryFilter;
    delete PosMgr;
    delete BoJWatch;
    delete AIClient;
    delete FileAIClient;
    delete Telegram;
}

//+------------------------------------------------------------------+
void OnTick()
{
    //-- Safety gates ---------------------------------------------------
    if(g_newsShieldActive)            return;
    if(RiskMgr.IsHaltTriggered())   return;
    if(RiskMgr.IsWeeklyCapReached()) return;

    //-- BoJ intervention watchdog -------------------------------------
    if(BoJWatchdogEnabled && BoJWatch.IsInterventionDetected())
    {
        if(PosMgr.IsPositionOpen())
        {
            Print("[SwingEA] BoJ intervention detected — closing position");
            PosMgr.CloseAll();
            Telegram.SendBoJAlert();
        }
        return;
    }

    //-- Manage existing position on each new H1 bar close ------------
    if(HasNewH1Close() && PosMgr.IsPositionOpen())
    {
        // Check mandatory exits on 4H candle closes
        bool structBreak = false;
        bool emaBreach   = false;
        if(HasNewH4Close())
        {
            int dir = PosMgr.GetDirection();
            structBreak = (dir == 1)
                ? TrendAnalyzer.IsStructuralBreakdownLong(g_lastStructuralHL)
                : TrendAnalyzer.IsStructuralBreakdownShort(g_lastStructuralLH);
            emaBreach = TrendAnalyzer.Is200EMABreached(dir);
        }

        if(structBreak)
        {
            Print("[SwingEA] 4H structural breakdown — closing position");
            PosMgr.CloseAll();
            return;
        }
        if(emaBreach)
        {
            Print("[SwingEA] 4H 200 EMA breached — closing position");
            PosMgr.CloseAll();
            return;
        }

        // AI score collapse check
        SAIResponse ai = GetAIScore();
        if(ai.valid)
        {
            g_aiLastKnownUp = true;
            g_aiServerWasDown = false;
        }
        bool aiCollapse = ai.valid && ai.trendScore < AICollapseScore;

        bool closed = PosMgr.ManagePosition(BoJWatch.IsFlagged(), aiCollapse);
        if(!closed)
        {
            // Trail SL to new structural swing low/high
            double pip = 10.0 * _Point;
            if(PosMgr.GetDirection() == 1)
            {
                double newHL = TrendAnalyzer.GetStructuralSwingLow(pip, 40);
                if(newHL > 0) PosMgr.TrailSLToSwingPoint(newHL);
            }
            else
            {
                double newLH = TrendAnalyzer.GetStructuralSwingHigh(pip, 40);
                if(newLH > 0) PosMgr.TrailSLToSwingPoint(newLH);
            }
        }
        return;
    }

    //-- Update 4H direction on each 4H candle close ------------------
    if(HasNewH4Close())
    {
        g_currentBias = TrendAnalyzer.Get4HBias();
        PrintFormat("[SwingEA] 4H bias updated: %s",
                    g_currentBias == DIR_BULL ? "BULL" :
                    g_currentBias == DIR_BEAR ? "BEAR" : "NONE");

        // Log sub-condition breakdown so we can see exactly why bias is NONE
        TrendAnalyzer.LogDiagnostics();

        // Cache structural reference levels for breakdown detection
        double pip = 10.0 * _Point;
        g_lastStructuralHL = TrendAnalyzer.GetStructuralSwingLow(pip, 40);
        g_lastStructuralLH = TrendAnalyzer.GetStructuralSwingHigh(pip, 40);
    }

    if(g_currentBias == DIR_NONE) return;
    if(PosMgr.IsPositionOpen())  return;  // one trade at a time

    //-- Entry conditions — checked on new H1 bar close only ----------
    if(!HasNewH1Close()) return;

    //-- Carry trade filter -------------------------------------------
    if(!CarryFilter.IsCarryFavorable(g_currentBias)) return;

    //-- 1H entry signal ----------------------------------------------
    if(!EntryLayer.HasEntrySignal(g_currentBias)) return;

    //-- Session cap ---------------------------------------------------
    if(RiskMgr.IsSessionCapReached()) return;

    //-- AI trend score gate ------------------------------------------
    SAIResponse ai = GetAIScore();
    if(!ai.valid)
    {
        g_aiLastKnownUp = false;
        if(!g_aiServerWasDown)
        {
            Print("[SwingEA] AI server down — no new entries (safe mode)");
            Telegram.SendAIServerDown();
            g_aiServerWasDown = true;
        }
        return;
    }
    g_aiLastKnownUp = true;
    if(g_aiServerWasDown)
    {
        Print("[SwingEA] AI server reconnected");
        g_aiServerWasDown = false;
    }

    if(ai.newsRisk >= 70)
    {
        PrintFormat("[SwingEA] High news risk (%d) — skipping entry", ai.newsRisk);
        return;
    }

    if(ai.trendScore < AIMinTrendScore)
    {
        PrintFormat("[SwingEA] Trend score %d < threshold %d — skipping", ai.trendScore, AIMinTrendScore);
        return;
    }

    //-- Compute SL price and open position ---------------------------
    double pip   = 10.0 * _Point;
    double slPrc = (g_currentBias == 1)
        ? TrendAnalyzer.GetStructuralSwingLow(pip, 40)
        : TrendAnalyzer.GetStructuralSwingHigh(pip, 40);

    if(slPrc <= 0)
    {
        Print("[SwingEA] Could not determine structural SL level — skipping");
        return;
    }

    if(PosMgr.OpenPosition(g_currentBias, slPrc))
    {
        g_sessionTradeCount++;
        string dir        = (g_currentBias == 1) ? "BUY" : "SELL";
        double entryPrice = SymbolInfoDouble(_Symbol, g_currentBias == 1 ? SYMBOL_ASK : SYMBOL_BID);
        double carry      = CarryFilter.GetDifferentialForAI();

        // Approximate TP1 (1:1.5 R:R) and TP2 (1:3 R:R) for Telegram
        double slDist = MathAbs(entryPrice - slPrc);
        double tp1    = (g_currentBias == 1)
                        ? entryPrice + slDist * 1.5
                        : entryPrice - slDist * 1.5;
        double tp2    = (g_currentBias == 1)
                        ? entryPrice + slDist * 3.0
                        : entryPrice - slDist * 3.0;

        PrintFormat("[SwingEA] ENTRY #%d | Dir=%s | TrendScore=%d | NewsRisk=%d | Carry=%.2f",
                    g_sessionTradeCount, dir,
                    ai.trendScore, ai.newsRisk, carry);

        Telegram.SendTradeEntry(dir, 0.01, entryPrice, slPrc, tp1, tp2,
                                ai.trendScore, ai.newsRisk, carry);
    }
}

//+------------------------------------------------------------------+
void OnTimer()
{
    g_timerCount++;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Daily session reset
    if(dt.hour == 0 && dt.min < 2)
    {
        Print("[SwingEA] New day — resetting session");
        RiskMgr.InitSession();
        g_sessionTradeCount = 0;
    }

    // Weekly reset (Monday 00:00)
    if(dt.day_of_week == 1 && dt.hour == 0 && dt.min < 2)
        RiskMgr.InitWeek();

    // Every 5 minutes: ping AI server + log heartbeat to Experts tab
    if(g_timerCount % 5 == 0)
    {
        g_aiLastKnownUp = FileAIClient.IsServerAlive();

        string biasStr = (g_currentBias == DIR_BULL) ? "BULL"
                       : (g_currentBias == DIR_BEAR) ? "BEAR" : "NONE";
        double spread  = EntryLayer.GetSpreadPips();

        PrintFormat("[Heartbeat] %02d:%02d UTC | Bias=%s | AI=%s | Spread=%.1f pips | Trades=%d | Position=%s | Halt=%s",
            dt.hour, dt.min, biasStr,
            g_aiLastKnownUp          ? "UP"   : "DOWN",
            spread,
            g_sessionTradeCount,
            PosMgr.IsPositionOpen()  ? "OPEN" : "flat",
            RiskMgr.IsHaltTriggered() ? "YES" : "no");
    }

    // Every 60 minutes: send Telegram heartbeat
    if(g_timerCount % 60 == 0)
    {
        string biasStr = (g_currentBias == DIR_BULL) ? "BULL"
                       : (g_currentBias == DIR_BEAR) ? "BEAR" : "NONE";
        Telegram.SendHeartbeat(biasStr, g_aiLastKnownUp,
                               EntryLayer.GetSpreadPips(),
                               g_sessionTradeCount,
                               RiskMgr.IsHaltTriggered(),
                               PosMgr.IsPositionOpen());
    }
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+

SAIResponse GetAIScore()
{
    string direction = (g_currentBias == 1) ? "BUY" : "SELL";
    string features  = FeatureBldr.Build();

    if(features == "")
    {
        SAIResponse empty;
        empty.valid      = false;
        empty.entryScore = 0;
        empty.trendScore = 0;
        empty.newsRisk   = 100;
        empty.approve    = false;
        return empty;
    }

    return FileAIClient.RequestScoreSafe(features, direction);
}

bool HasNewH1Close()
{
    datetime h1time[];
    ArraySetAsSeries(h1time, true);
    if(CopyTime(_Symbol, PERIOD_H1, 0, 2, h1time) != 2) return false;

    static datetime s_lastH1 = 0;
    if(h1time[1] != s_lastH1)
    {
        s_lastH1 = h1time[1];
        return true;
    }
    return false;
}

bool HasNewH4Close()
{
    datetime h4time[];
    ArraySetAsSeries(h4time, true);
    if(CopyTime(_Symbol, PERIOD_H4, 0, 2, h4time) != 2) return false;

    static datetime s_lastH4 = 0;
    if(h4time[1] != s_lastH4)
    {
        s_lastH4 = h4time[1];
        return true;
    }
    return false;
}

// Called from external news system (NewsShield integration — Phase 3)
void SetNewsShield(bool active)
{
    g_newsShieldActive = active;
    if(active)
    {
        Print("[SwingEA] NEWS SHIELD ACTIVE — all new entries blocked");
        // Move swing SL to breakeven on news, don't close outright
        // Full implementation in Phase 3 news integration
    }
}
//+------------------------------------------------------------------+
