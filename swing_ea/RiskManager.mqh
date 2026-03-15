//+------------------------------------------------------------------+
//|  RiskManager.mqh                                                  |
//|  Lot sizing, session risk cap, hard halt, trade recording        |
//+------------------------------------------------------------------+
#ifndef SWING_RISKMANAGER_MQH
#define SWING_RISKMANAGER_MQH

class CRiskManager
{
private:
    double m_riskPct;           // % of balance risked per trade (default 1.5)
    double m_sessionCapPct;     // max session loss % (default 10)
    double m_haltPct;           // hard halt trigger % (default 7)

    double m_sessionStartBalance;
    double m_sessionLoss;       // cumulative loss this session (positive = loss)
    bool   m_haltTriggered;
    bool   m_sessionInitialised;

    double m_weeklyStartBalance;
    double m_weeklyLoss;
    double m_weeklyCapPct;      // default 8%

    // Pip helpers for GBPJPY (3-digit pair, 1 pip = 10 points)
    double PipSize()   { return 10.0 * _Point; }
    double PipValue()  // USD value per pip per 1.0 lot
    {
        double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        return tickVal / tickSize * PipSize();
    }

public:
    CRiskManager(double riskPct = 1.5, double sessionCapPct = 10.0,
                 double haltPct = 7.0, double weeklyCapPct = 8.0)
        : m_riskPct(riskPct),
          m_sessionCapPct(sessionCapPct),
          m_haltPct(haltPct),
          m_weeklyCapPct(weeklyCapPct),
          m_sessionStartBalance(0),
          m_sessionLoss(0),
          m_haltTriggered(false),
          m_sessionInitialised(false),
          m_weeklyStartBalance(0),
          m_weeklyLoss(0)
    {}

    //-- Session management -------------------------------------------------

    void InitSession()
    {
        m_sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        m_sessionLoss         = 0.0;
        m_haltTriggered       = false;
        m_sessionInitialised  = true;
        PrintFormat("[RiskMgr] Session started. Balance: %.2f", m_sessionStartBalance);
    }

    void InitWeek()
    {
        m_weeklyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        m_weeklyLoss         = 0.0;
    }

    bool IsSessionInitialised() { return m_sessionInitialised; }

    //-- Lot sizing ----------------------------------------------------------

    double CalcLotSize(double slPips)
    {
        if(slPips <= 0) return 0.0;

        double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
        double riskUSD  = balance * m_riskPct / 100.0;
        double pipVal   = PipValue();

        if(pipVal <= 0) return 0.0;

        double rawLot   = riskUSD / (slPips * pipVal);

        double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        double stepLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

        // Round to nearest lot step
        rawLot = MathFloor(rawLot / stepLot) * stepLot;
        rawLot = MathMax(minLot, MathMin(maxLot, rawLot));

        return NormalizeDouble(rawLot, 2);
    }

    //-- Session risk checks ------------------------------------------------

    bool IsSessionCapReached()
    {
        if(!m_sessionInitialised) return false;
        double capUSD = m_sessionStartBalance * m_sessionCapPct / 100.0;
        return m_sessionLoss >= capUSD;
    }

    bool IsHaltTriggered()
    {
        if(m_haltTriggered) return true;
        if(!m_sessionInitialised) return false;

        double haltUSD = m_sessionStartBalance * m_haltPct / 100.0;
        if(m_sessionLoss >= haltUSD)
        {
            m_haltTriggered = true;
            PrintFormat("[RiskMgr] HALT TRIGGERED — session loss: %.2f / %.2f",
                        m_sessionLoss, haltUSD);
        }
        return m_haltTriggered;
    }

    bool IsWeeklyCapReached()
    {
        if(m_weeklyStartBalance <= 0) return false;
        double capUSD = m_weeklyStartBalance * m_weeklyCapPct / 100.0;
        return m_weeklyLoss >= capUSD;
    }

    double GetSessionLossPct()
    {
        if(m_sessionStartBalance <= 0) return 0;
        return m_sessionLoss / m_sessionStartBalance * 100.0;
    }

    double GetSessionStartBalance() { return m_sessionStartBalance; }

    //-- Trade recording ----------------------------------------------------

    void RecordTrade(double profitUSD)
    {
        if(profitUSD < 0)
        {
            m_sessionLoss += MathAbs(profitUSD);
            m_weeklyLoss  += MathAbs(profitUSD);
        }
        PrintFormat("[RiskMgr] Trade recorded: %.2f | Session loss: %.2f (%.1f%%)",
                    profitUSD, m_sessionLoss, GetSessionLossPct());
    }

    //-- Risk alerts --------------------------------------------------------

    // Returns 0 = normal, 1 = yellow warning (5%), 2 = red / halted (7%)
    int GetRiskAlertLevel()
    {
        if(IsHaltTriggered()) return 2;
        double pct = GetSessionLossPct();
        if(pct >= 5.0) return 1;
        return 0;
    }

    // Remaining session risk budget in USD (for lot scaling awareness)
    double GetRemainingSessionBudget()
    {
        if(!m_sessionInitialised) return 0;
        double capUSD = m_sessionStartBalance * m_sessionCapPct / 100.0;
        return MathMax(0, capUSD - m_sessionLoss);
    }
};
#endif // SWING_RISKMANAGER_MQH
