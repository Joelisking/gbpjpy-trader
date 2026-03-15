//+------------------------------------------------------------------+
//|  SwingEA.mq5                                                      |
//|  GBP/JPY Swing Rider Bot — 1H/4H timeframes                     |
//|  Attach to GBPJPY H1 chart.                                      |
//|                                                                   |
//|  Phase 2: full rule-based logic, dummy AI scores via server_test  |
//|  Phase 3: replace server_test.py with full AI server             |
//+------------------------------------------------------------------+
#property copyright "GBP/JPY AI Bot"
#property version   "2.0"
#property strict

#include "RiskManager.mqh"
#include "TrendAnalyzer4H.mqh"
#include "CarryTradeFilter.mqh"
#include "SwingEntry1H.mqh"
#include "SwingPositionManager.mqh"
#include "BoJWatchdog.mqh"
#include "AIClient.mqh"

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

//-- Objects -----------------------------------------------------------------
CRiskManager          *RiskMgr;
CTrendAnalyzer4H      *TrendAnalyzer;
CCarryTradeFilter     *CarryFilter;
CSwingEntry1H         *EntryLayer;
CSwingPositionManager *PosMgr;
CBoJWatchdog          *BoJWatch;
CAIClient             *AIClient;

//-- State -------------------------------------------------------------------
int      g_currentBias       = DIR_NONE;
datetime g_lastH4Close       = 0;
datetime g_lastH1Close       = 0;
bool     g_newsShieldActive  = false;
bool     g_aiServerWasDown   = false;
double   g_lastStructuralHL  = 0;  // cached for structural breakdown check
double   g_lastStructuralLH  = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== SwingEA v2.0 starting on ", _Symbol, " H1 ===");

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

    if(!TrendAnalyzer->Init()) return INIT_FAILED;
    if(!EntryLayer->Init())    return INIT_FAILED;

    RiskMgr->InitSession();
    RiskMgr->InitWeek();

    if(!AIClient->IsServerAlive())
        Print("WARNING: AI server not responding on ", AI_Host, ":", AI_Port,
              " — start server_test.py or ai_server/server.py");
    else
        Print("AI server connected on ", AI_Host, ":", AI_Port);

    EventSetTimer(60);

    Print("SwingEA initialised. Waiting for 4H direction...");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();

    if(PosMgr != NULL && PosMgr->IsPositionOpen())
    {
        Print("EA removed — closing swing position");
        PosMgr->CloseAll();
    }

    if(TrendAnalyzer) { TrendAnalyzer->Deinit(); delete TrendAnalyzer; }
    if(EntryLayer)    { EntryLayer->Deinit();     delete EntryLayer; }

    delete RiskMgr;
    delete CarryFilter;
    delete PosMgr;
    delete BoJWatch;
    delete AIClient;
}

//+------------------------------------------------------------------+
void OnTick()
{
    //-- Safety gates ---------------------------------------------------
    if(g_newsShieldActive)            return;
    if(RiskMgr->IsHaltTriggered())   return;
    if(RiskMgr->IsWeeklyCapReached()) return;

    //-- BoJ intervention watchdog -------------------------------------
    if(BoJWatchdogEnabled && BoJWatch->IsInterventionDetected())
    {
        if(PosMgr->IsPositionOpen())
        {
            Print("[SwingEA] BoJ intervention detected — closing position");
            PosMgr->CloseAll();
        }
        return;
    }

    //-- Manage existing position on each new H1 bar close ------------
    if(HasNewH1Close() && PosMgr->IsPositionOpen())
    {
        // Check mandatory exits on 4H candle closes
        bool structBreak = false;
        bool emaBreach   = false;
        if(HasNewH4Close())
        {
            int dir = PosMgr->GetDirection();
            structBreak = (dir == 1)
                ? TrendAnalyzer->IsStructuralBreakdownLong(g_lastStructuralHL)
                : TrendAnalyzer->IsStructuralBreakdownShort(g_lastStructuralLH);
            emaBreach = TrendAnalyzer->Is200EMABreached(dir);
        }

        if(structBreak)
        {
            Print("[SwingEA] 4H structural breakdown — closing position");
            PosMgr->CloseAll();
            return;
        }
        if(emaBreach)
        {
            Print("[SwingEA] 4H 200 EMA breached — closing position");
            PosMgr->CloseAll();
            return;
        }

        // AI score collapse check
        SAIResponse ai = GetAIScore();
        bool aiCollapse = ai.valid && ai.trendScore < AICollapseScore;

        bool closed = PosMgr->ManagePosition(BoJWatch->IsFlagged(), aiCollapse);
        if(!closed)
        {
            // Trail SL to new structural swing low/high
            double pip = 10.0 * _Point;
            if(PosMgr->GetDirection() == 1)
            {
                double newHL = TrendAnalyzer->GetStructuralSwingLow(pip, 40);
                if(newHL > 0) PosMgr->TrailSLToSwingPoint(newHL);
            }
            else
            {
                double newLH = TrendAnalyzer->GetStructuralSwingHigh(pip, 40);
                if(newLH > 0) PosMgr->TrailSLToSwingPoint(newLH);
            }
        }
        return;
    }

    //-- Update 4H direction on each 4H candle close ------------------
    if(HasNewH4Close())
    {
        g_currentBias = TrendAnalyzer->Get4HBias();
        PrintFormat("[SwingEA] 4H bias updated: %s",
                    g_currentBias == DIR_BULL ? "BULL" :
                    g_currentBias == DIR_BEAR ? "BEAR" : "NONE");

        // Cache structural reference levels for breakdown detection
        double pip = 10.0 * _Point;
        g_lastStructuralHL = TrendAnalyzer->GetStructuralSwingLow(pip, 40);
        g_lastStructuralLH = TrendAnalyzer->GetStructuralSwingHigh(pip, 40);
    }

    if(g_currentBias == DIR_NONE) return;
    if(PosMgr->IsPositionOpen())  return;  // one trade at a time

    //-- Entry conditions — checked on new H1 bar close only ----------
    if(!HasNewH1Close()) return;

    //-- Carry trade filter -------------------------------------------
    if(!CarryFilter->IsCarryFavorable(g_currentBias)) return;

    //-- 1H entry signal ----------------------------------------------
    if(!EntryLayer->HasEntrySignal(g_currentBias)) return;

    //-- Session cap ---------------------------------------------------
    if(RiskMgr->IsSessionCapReached()) return;

    //-- AI trend score gate ------------------------------------------
    SAIResponse ai = GetAIScore();
    if(!ai.valid)
    {
        if(!g_aiServerWasDown)
        {
            Print("[SwingEA] AI server down — no new entries (safe mode)");
            g_aiServerWasDown = true;
        }
        return;
    }
    g_aiServerWasDown = false;

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
        ? TrendAnalyzer->GetStructuralSwingLow(pip, 40)
        : TrendAnalyzer->GetStructuralSwingHigh(pip, 40);

    if(slPrc <= 0)
    {
        Print("[SwingEA] Could not determine structural SL level — skipping");
        return;
    }

    if(PosMgr->OpenPosition(g_currentBias, slPrc))
    {
        PrintFormat("[SwingEA] ENTRY | Dir=%s | TrendScore=%d | NewsRisk=%d | Carry=%.2f",
                    g_currentBias == 1 ? "BUY" : "SELL",
                    ai.trendScore, ai.newsRisk,
                    CarryFilter->GetDifferentialForAI());
    }
}

//+------------------------------------------------------------------+
void OnTimer()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Daily session reset
    if(dt.hour == 0 && dt.min < 2)
    {
        Print("[SwingEA] New day — resetting session");
        RiskMgr->InitSession();
    }

    // Weekly reset (Monday 00:00)
    if(dt.day_of_week == 1 && dt.hour == 0 && dt.min < 2)
        RiskMgr->InitWeek();
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+

SAIResponse GetAIScore()
{
    // Build minimal feature string for swing model
    // Phase 3 will expand this to full 200-step sequence
    string direction = (g_currentBias == 1) ? "BUY" : "SELL";
    double ema200    = TrendAnalyzer->GetEMA200();
    double rsi4h     = TrendAnalyzer->GetRSI14();
    double ema50_1h  = EntryLayer->GetEMA50();
    double rsi1h     = EntryLayer->GetRSI14();
    double carry     = CarryFilter->GetDifferentialForAI();

    string features = StringFormat(
        "[%.3f,%.2f,%.3f,%.2f,%.2f]",
        ema200, rsi4h, ema50_1h, rsi1h, carry
    );

    return AIClient->RequestScoreSafe(features, direction);
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
