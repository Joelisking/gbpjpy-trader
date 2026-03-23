//+------------------------------------------------------------------+
//|  ScalperEA.mq5                                                    |
//|  GBP/JPY Scalper Bot — 1M/5M timeframes                         |
//|  Attach to GBPJPY M1 chart.                                      |
//|                                                                   |
//|  Phase 2: full rule-based logic, dummy AI scores via server_test  |
//|  Phase 3: replace server_test.py with full AI server             |
//+------------------------------------------------------------------+
#property copyright "GBP/JPY AI Bot"
#property version   "2.0"
#property strict

#include "RiskManager.mqh"
#include "DirectionLayer.mqh"
#include "CorrelationFilter.mqh"
#include "EntryLayer.mqh"
#include "CascadeEntry.mqh"
#include "ExitManager.mqh"
#include "AIClient.mqh"
#include "FileAIClient.mqh"
#include "FeatureBuilder.mqh"
#include "TelegramMQL5.mqh"

//-- Inputs ------------------------------------------------------------------
input double RiskPercent       = 1.5;    // % account risk per trade
input double SessionRiskCap    = 10.0;   // max session loss %
input double SessionHaltPct    = 7.0;    // hard halt trigger %
input int    AIMinScore        = 65;     // minimum AI entry score
input string AI_Host           = "127.0.0.1";
input int    AI_Port           = 5001;
input bool   LondonSpikeBlock  = true;   // block 07:55-08:15 UTC
input double ATRMinPips        = 4.0;    // min ATR to trade
input double MaxSpreadPips     = 30.0;   // max spread to enter
input double SLPipsMin         = 12.0;
input double SLPipsMax         = 18.0;
input double TPPips            = 30.0;
input int    MaxHoldMinutes    = 20;
input bool   NewsShieldEnabled = true;
input string TG_Token          = "PASTE_TOKEN_HERE";  // Telegram bot token
input string TG_ChatId         = "PASTE_CHAT_ID_HERE"; // Telegram chat ID

//-- Objects -----------------------------------------------------------------
CRiskManager       *RiskMgr;
CDirectionLayer    *DirLayer;
CCorrelationFilter *CorrFilter;
CEntryLayer        *EntryLayer;
CCascadeEntry      *Cascade;
CExitManager       *ExitMgr;
CAIClient          *AIClient;     // kept for socket fallback
CFileAIClient      *FileAIClient;
CFeatureBuilder    *FeatureBuilder;
CTelegramMQL5      *Telegram;

//-- State -------------------------------------------------------------------
int      g_currentBias        = DIR_NONE;
datetime g_lastM5Close        = 0;
bool     g_newsShieldActive   = false;
bool     g_aiServerWasDown    = false;
int      g_sessionTradeCount  = 0;
int      g_timerCount         = 0;   // increments every 60s in OnTimer

//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== ScalperEA v2.0 starting on ", _Symbol, " M1 ===");

    if(_Symbol != "GBPJPY")
    {
        Print("ERROR: This EA must run on GBPJPY M1 chart");
        return INIT_FAILED;
    }

    if(Period() != PERIOD_M1)
    {
        Print("ERROR: Attach this EA to M1 chart");
        return INIT_FAILED;
    }

    // Instantiate all components
    RiskMgr        = new CRiskManager(RiskPercent, SessionRiskCap, SessionHaltPct);
    DirLayer       = new CDirectionLayer(ATRMinPips);
    CorrFilter     = new CCorrelationFilter("EURJPY");
    EntryLayer     = new CEntryLayer(MaxSpreadPips);
    Cascade        = new CCascadeEntry(SLPipsMin, SLPipsMax, TPPips);
    ExitMgr        = new CExitManager(12.0, 12.0, 15.0, MaxHoldMinutes);
    AIClient       = new CAIClient(AI_Host, AI_Port, 500);
    FileAIClient   = new CFileAIClient(500);
    FeatureBuilder = new CFeatureBuilder();
    Telegram       = new CTelegramMQL5();
    Telegram.Init(TG_Token, TG_ChatId);

    // Initialise all indicator handles
    if(!DirLayer.Init())       return INIT_FAILED;
    if(!CorrFilter.Init())     return INIT_FAILED;
    if(!EntryLayer.Init())     return INIT_FAILED;
    if(!FeatureBuilder.Init()) return INIT_FAILED;

    RiskMgr.InitSession();
    RiskMgr.InitWeek();

    // Check AI server via file IPC (sockets disabled on Deriv MT5)
    if(!FileAIClient.IsServerAlive())
    {
        Print("WARNING: AI server not responding via file IPC — start: uv run python ai_server/server.py");
        Telegram.SendAIServerDown();
    }
    else
        Print("AI server connected (file IPC)");

    // Warn if EURJPY not in Market Watch (CorrelationFilter will silently block all entries)
    if(SymbolInfoDouble("EURJPY", SYMBOL_BID) == 0)
        Print("WARNING: EURJPY bid = 0 — add EURJPY to Market Watch or CorrelationFilter will block all entries");

    EventSetTimer(60); // 1-minute timer

    Telegram.SendStartup();
    Print("ScalperEA initialised. Waiting for 5M direction...");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();

    // Close all open cascade positions on removal
    if(Cascade != NULL && Cascade.IsSequenceActive())
    {
        Print("EA removed — closing all cascade positions");
        Cascade.CloseAll();
    }

    if(DirLayer)       { DirLayer.Deinit();       delete DirLayer; }
    if(CorrFilter)     { CorrFilter.Deinit();     delete CorrFilter; }
    if(EntryLayer)     { EntryLayer.Deinit();     delete EntryLayer; }
    if(FeatureBuilder) { FeatureBuilder.Deinit(); delete FeatureBuilder; }

    delete RiskMgr;
    delete Cascade;
    delete ExitMgr;
    delete AIClient;
    delete FileAIClient;
    delete Telegram;
}

//+------------------------------------------------------------------+
void OnTick()
{
    //-- Safety gates: check every tick ---------------------------------
    if(g_newsShieldActive)             return;
    if(RiskMgr.IsHaltTriggered())    return;
    if(RiskMgr.IsWeeklyCapReached()) return;
    if(IsLondonSpikeWindow())         return;

    //-- Manage open cascade positions (exit logic) --------------------
    if(Cascade.IsSequenceActive())
    {
        // Check for direction flip on 5M
        if(HasNewM5Close() && DirLayer.HasDirectionFlipped(Cascade.GetDirection()))
        {
            ExitMgr.OnDirectionFlip(Cascade);
            OnSequenceClosed();
            return;
        }

        bool allClosed = ExitMgr.ManageOpenTrades(Cascade.GetDirection(), Cascade);
        if(allClosed) OnSequenceClosed();

        // Allow cascade to build additional entries
        SAIResponse ai = GetAIScore();
        Cascade.ManageCascade(ai.entryScore, CorrFilter.IsAgreeing(Cascade.GetDirection()));
        return;
    }

    //-- Update 5M direction at each 5M candle close -------------------
    if(HasNewM5Close())
    {
        g_currentBias = DirLayer.Get5MBias();
        PrintFormat("[ScalperEA] 5M bias updated: %s",
                    g_currentBias == DIR_BULL ? "BULL" :
                    g_currentBias == DIR_BEAR ? "BEAR" : "NONE");
        // Log sub-condition breakdown so we can see exactly why bias is NONE
        DirLayer.LogDiagnostics();

        // Log EUR/JPY and spread state alongside the bias
        bool corrOk = CorrFilter.IsAgreeing(g_currentBias);
        PrintFormat("[5M-Diag] EURJPY agrees=%s | Spread=%.1f pips",
            corrOk ? "Y" : "N", EntryLayer.GetSpreadPips());
    }

    if(g_currentBias == DIR_NONE) return;

    //-- EUR/JPY correlation filter ------------------------------------
    if(!CorrFilter.IsAgreeing(g_currentBias)) return;

    //-- 1M entry signal -----------------------------------------------
    if(!EntryLayer.Has1MSignal(g_currentBias)) return;

    //-- Session cap check --------------------------------------------
    if(RiskMgr.IsSessionCapReached()) return;

    //-- AI score gate ------------------------------------------------
    SAIResponse ai = GetAIScore();
    if(!ai.valid)
    {
        if(!g_aiServerWasDown)
        {
            Print("[ScalperEA] AI server down — no new entries (safe mode)");
            Telegram.SendAIServerDown();
            g_aiServerWasDown = true;
        }
        return;
    }
    if(g_aiServerWasDown)
    {
        Print("[ScalperEA] AI server reconnected");
        g_aiServerWasDown = false;
    }

    if(ai.newsRisk >= 70)
    {
        PrintFormat("[ScalperEA] High news risk (%d) — skipping entry", ai.newsRisk);
        return;
    }

    if(ai.entryScore < AIMinScore)
    {
        PrintFormat("[ScalperEA] AI score %d < threshold %d — skipping", ai.entryScore, AIMinScore);
        return;
    }

    //-- Execute pilot entry -------------------------------------------
    if(Cascade.ExecutePilot(g_currentBias))
    {
        g_sessionTradeCount++;
        string dir        = (g_currentBias == 1) ? "BUY" : "SELL";
        double entryPrice = SymbolInfoDouble(_Symbol, g_currentBias == 1 ? SYMBOL_ASK : SYMBOL_BID);
        ExitMgr.OnSequenceOpened(entryPrice);

        PrintFormat("[ScalperEA] ENTRY #%d | Dir=%s | AI=%d | Trend=%d | News=%d",
                    g_sessionTradeCount, dir,
                    ai.entryScore, ai.trendScore, ai.newsRisk);

        double sl  = (g_currentBias == 1)
                     ? entryPrice - SLPipsMin * 10.0 * _Point
                     : entryPrice + SLPipsMin * 10.0 * _Point;
        double tp1 = (g_currentBias == 1)
                     ? entryPrice + TPPips * 10.0 * _Point
                     : entryPrice - TPPips * 10.0 * _Point;
        Telegram.SendTradeEntry(dir, 0.01, entryPrice, sl, tp1,
                                ai.entryScore, ai.trendScore, 1);
    }
}

//+------------------------------------------------------------------+
void OnTimer()
{
    g_timerCount++;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Session reset (new day at 00:00 UTC)
    if(dt.hour == 0 && dt.min < 2)
    {
        Print("[ScalperEA] New day — resetting session");
        RiskMgr.InitSession();
        g_sessionTradeCount = 0;
    }

    // Weekly reset (Monday 00:00)
    if(dt.day_of_week == 1 && dt.hour == 0 && dt.min < 2)
        RiskMgr.InitWeek();

    // Every 5 minutes: log heartbeat to Experts tab
    if(g_timerCount % 5 == 0)
    {
        string biasStr = (g_currentBias == DIR_BULL) ? "BULL"
                       : (g_currentBias == DIR_BEAR) ? "BEAR" : "NONE";
        bool   aiUp    = FileAIClient.IsServerAlive();
        double spread  = EntryLayer.GetSpreadPips();
        bool   corrOk  = CorrFilter.IsAgreeing(g_currentBias);

        PrintFormat("[Heartbeat] %02d:%02d UTC | Bias=%s | EURJPY=%s | AI=%s | Spread=%.1f pips | SessionTrades=%d | Halt=%s",
            dt.hour, dt.min, biasStr,
            corrOk  ? "agree" : "NO",
            aiUp    ? "UP"    : "DOWN",
            spread,
            g_sessionTradeCount,
            RiskMgr.IsHaltTriggered() ? "YES" : "no");
    }

    // Every 60 minutes: send Telegram heartbeat
    if(g_timerCount % 60 == 0)
    {
        string biasStr = (g_currentBias == DIR_BULL) ? "BULL"
                       : (g_currentBias == DIR_BEAR) ? "BEAR" : "NONE";
        Telegram.SendHeartbeat(biasStr, FileAIClient.IsServerAlive(),
                               EntryLayer.GetSpreadPips(),
                               g_sessionTradeCount,
                               RiskMgr.IsHaltTriggered());
    }
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+

SAIResponse GetAIScore()
{
    string features  = FeatureBuilder.Build();
    string direction = (g_currentBias == 1) ? "BUY" : "SELL";
    return FileAIClient.RequestScoreSafe(features, direction);
}

bool HasNewM5Close()
{
    datetime m5time[];
    ArraySetAsSeries(m5time, true);
    if(CopyTime(_Symbol, PERIOD_M5, 0, 2, m5time) != 2) return false;

    if(m5time[1] != g_lastM5Close)
    {
        g_lastM5Close = m5time[1];
        return true;
    }
    return false;
}

bool IsLondonSpikeWindow()
{
    if(!LondonSpikeBlock) return false;
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    // 07:55-08:15 UTC
    return (dt.hour == 7 && dt.min >= 55) || (dt.hour == 8 && dt.min <= 15);
}

void OnSequenceClosed()
{
    // Record P&L for session tracking
    // In a production system, query last closed position profit here
    // For now, just log the closure
    Print("[ScalperEA] Sequence closed. Session trades: ", g_sessionTradeCount);
}

// Called from external news system (NewsShield integration — Phase 3)
void SetNewsShield(bool active)
{
    g_newsShieldActive = active;
    if(active)
    {
        Print("[ScalperEA] NEWS SHIELD ACTIVE — all new entries blocked");
        // Close profitable scalper positions if near TP
        // Full implementation in Phase 3 news integration
    }
}
//+------------------------------------------------------------------+
