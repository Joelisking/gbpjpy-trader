//+------------------------------------------------------------------+
//|  ExitManager.mqh                                                  |
//|  Manages all exits for open cascade positions                    |
//|                                                                   |
//|  Logic (in priority order):                                      |
//|  1. Direction flip on 5M close → close ALL immediately           |
//|  2. Time exit: 20 minutes max hold                               |
//|  3. Breakeven: at +12 pips, move all SLs to Entry 1 price       |
//|  4. Trailing: after breakeven, trail all SLs 12 pips behind      |
//|  5. TP extension: if +15 pips in 5 min, extend TP to 45 pips    |
//+------------------------------------------------------------------+
#pragma once

class CExitManager
{
private:
    double m_pipSize;
    double m_breakevenTriggerPips;  // default 12
    double m_trailingPips;          // default 12
    double m_tpExtendPips;          // extend to 45 pips if 15 pip run in 5 min
    double m_tpExtendTriggerPips;   // default 15
    int    m_maxHoldMinutes;        // default 20

    // Per-sequence state
    bool   m_atBreakeven;
    double m_entry1Price;
    datetime m_sequenceOpenTime;
    bool   m_tpExtended;

    int m_magics[4];

    void ModifyAllSLs(double newSL)
    {
        for(int m = 0; m < 4; m++)
        {
            for(int i = 0; i < PositionsTotal(); i++)
            {
                if(PositionGetSymbol(i) != _Symbol) continue;
                if((int)PositionGetInteger(POSITION_MAGIC) != m_magics[m]) continue;

                double currentSL = PositionGetDouble(POSITION_SL);
                double currentTP = PositionGetDouble(POSITION_TP);
                int    posType   = (int)PositionGetInteger(POSITION_TYPE);

                // Only move SL in profit direction
                bool improved = (posType == POSITION_TYPE_BUY && newSL > currentSL)
                             || (posType == POSITION_TYPE_SELL && newSL < currentSL);
                if(!improved) continue;

                MqlTradeRequest req = {};
                MqlTradeResult  res = {};
                req.action   = TRADE_ACTION_SLTP;
                req.symbol   = _Symbol;
                req.position = PositionGetInteger(POSITION_TICKET);
                req.sl       = NormalizeDouble(newSL, _Digits);
                req.tp       = currentTP;
                OrderSend(req, res);
            }
        }
    }

    void ExtendAllTPs(double newTP)
    {
        for(int m = 0; m < 4; m++)
        {
            for(int i = 0; i < PositionsTotal(); i++)
            {
                if(PositionGetSymbol(i) != _Symbol) continue;
                if((int)PositionGetInteger(POSITION_MAGIC) != m_magics[m]) continue;

                MqlTradeRequest req = {};
                MqlTradeResult  res = {};
                req.action   = TRADE_ACTION_SLTP;
                req.symbol   = _Symbol;
                req.position = PositionGetInteger(POSITION_TICKET);
                req.sl       = PositionGetDouble(POSITION_SL);
                req.tp       = NormalizeDouble(newTP, _Digits);
                OrderSend(req, res);
            }
        }
        m_tpExtended = true;
        PrintFormat("[ExitMgr] TP extended to 45 pips");
    }

    // Best floating profit in pips across all open positions
    double GetBestProfitPips(int direction)
    {
        double price = (direction == 1)
            ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        double bestPips = 0;
        for(int m = 0; m < 4; m++)
        {
            for(int i = 0; i < PositionsTotal(); i++)
            {
                if(PositionGetSymbol(i) != _Symbol) continue;
                if((int)PositionGetInteger(POSITION_MAGIC) != m_magics[m]) continue;

                double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                double profit    = (direction == 1)
                    ? (price - openPrice) / m_pipSize
                    : (openPrice - price) / m_pipSize;
                bestPips = MathMax(bestPips, profit);
            }
        }
        return bestPips;
    }

public:
    CExitManager(double breakevenTriggerPips = 12.0, double trailingPips = 12.0,
                 double tpExtendTriggerPips = 15.0, int maxHoldMinutes = 20)
        : m_breakevenTriggerPips(breakevenTriggerPips),
          m_trailingPips(trailingPips),
          m_tpExtendTriggerPips(tpExtendTriggerPips),
          m_maxHoldMinutes(maxHoldMinutes),
          m_atBreakeven(false),
          m_entry1Price(0),
          m_sequenceOpenTime(0),
          m_tpExtended(false)
    {
        m_pipSize = 10.0 * _Point;
        m_tpExtendPips = 45.0;
        int tmp[4] = {MAGIC_PILOT, MAGIC_CORE, MAGIC_ADD, MAGIC_MAX};
        ArrayCopy(m_magics, tmp);
    }

    void OnSequenceOpened(double entry1Price)
    {
        m_entry1Price       = entry1Price;
        m_sequenceOpenTime  = TimeCurrent();
        m_atBreakeven       = false;
        m_tpExtended        = false;
    }

    // Call on every tick while positions are open
    // Returns true if all positions were closed (caller should reset state)
    bool ManageOpenTrades(int direction, CCascadeEntry &cascade)
    {
        if(cascade.CountOpenPositions() == 0) return false;

        double profitPips = GetBestProfitPips(direction);
        double price      = (direction == 1)
            ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        //-- Time exit: 20 minutes
        int elapsedMin = (int)((TimeCurrent() - m_sequenceOpenTime) / 60);
        if(elapsedMin >= m_maxHoldMinutes)
        {
            Print("[ExitMgr] TIME EXIT — 20 minutes elapsed. Closing all.");
            cascade.CloseAll();
            return true;
        }

        //-- TP extension: +15 pips within 5 minutes → extend to 45 pips
        if(!m_tpExtended && profitPips >= m_tpExtendTriggerPips && elapsedMin <= 5)
        {
            double newTP = (direction == 1)
                ? m_entry1Price + m_tpExtendPips * m_pipSize
                : m_entry1Price - m_tpExtendPips * m_pipSize;
            ExtendAllTPs(newTP);
        }

        //-- Breakeven: move all SLs to Entry 1 open price at +12 pips
        if(!m_atBreakeven && profitPips >= m_breakevenTriggerPips)
        {
            PrintFormat("[ExitMgr] BREAKEVEN triggered at +%.1f pips. Moving SLs to %.3f",
                        profitPips, m_entry1Price);
            ModifyAllSLs(m_entry1Price);
            m_atBreakeven = true;
        }

        //-- Trailing stop: 12 pips behind current price (only after breakeven)
        if(m_atBreakeven)
        {
            double trailSL = (direction == 1)
                ? price - m_trailingPips * m_pipSize
                : price + m_trailingPips * m_pipSize;

            // Only trail if it improves the SL
            ModifyAllSLs(trailSL);
        }

        return false;
    }

    // Called by main EA when 5M direction flips
    void OnDirectionFlip(CCascadeEntry &cascade)
    {
        Print("[ExitMgr] DIRECTION FLIP — closing all positions immediately");
        cascade.CloseAll();
    }

    bool IsAtBreakeven() { return m_atBreakeven; }

    int GetElapsedMinutes()
    {
        if(m_sequenceOpenTime == 0) return 0;
        return (int)((TimeCurrent() - m_sequenceOpenTime) / 60);
    }
};
