//+------------------------------------------------------------------+
//|  CascadeEntry.mqh                                                 |
//|  Cascade position builder — 4 sequential entries                 |
//|                                                                   |
//|  Entry 1 (Pilot):  0.01 lots — always first, if all 7 conds met |
//|  Entry 2 (Core):   0.02 lots — only if Entry 1 is profitable    |
//|  Entry 3 (Add):    0.02 lots — only if 1+2 profitable + momentum|
//|  Entry 4 (Max):    0.01 lots — only if AI score >= 80 + EURJPY  |
//|                                                                   |
//|  CRITICAL: If Entry 1 hits SL before Entry 2 triggers,          |
//|  the entire sequence is cancelled. Never add to a loser.         |
//+------------------------------------------------------------------+
#pragma once

// Magic numbers to identify cascade entries
#define MAGIC_PILOT  10001
#define MAGIC_CORE   10002
#define MAGIC_ADD    10003
#define MAGIC_MAX    10004

class CCascadeEntry
{
private:
    double m_pipSize;
    double m_slPips_min;   // minimum SL distance in pips
    double m_slPips_max;   // maximum SL distance in pips
    double m_tpPips;       // take profit in pips

    int    m_direction;    // current trade direction (1 long, -1 short)
    double m_entry1Price;  // price of pilot entry (used as reference for SL adjustment)
    bool   m_sequenceActive;
    int    m_entriesOpen;  // count of cascade entries currently open

    // Find the swing low/high for SL placement
    double GetSLPrice(int direction, double entryPrice)
    {
        double lows[], highs[];
        ArraySetAsSeries(lows,  true);
        ArraySetAsSeries(highs, true);

        int lookback = 10;
        if(direction == 1) // long — SL below 1M swing low
        {
            if(CopyLow(_Symbol, PERIOD_M1, 0, lookback, lows) == lookback)
            {
                double swingLow = lows[ArrayMinimum(lows, 0, lookback)];
                double minSL    = entryPrice - m_slPips_min * m_pipSize;
                double maxSL    = entryPrice - m_slPips_max * m_pipSize;
                return MathMax(maxSL, MathMin(minSL, swingLow - m_pipSize));
            }
        }
        else // short — SL above 1M swing high
        {
            if(CopyHigh(_Symbol, PERIOD_M1, 0, lookback, highs) == lookback)
            {
                double swingHigh = highs[ArrayMaximum(highs, 0, lookback)];
                double minSL     = entryPrice + m_slPips_min * m_pipSize;
                double maxSL     = entryPrice + m_slPips_max * m_pipSize;
                return MathMin(maxSL, MathMax(minSL, swingHigh + m_pipSize));
            }
        }

        // Fallback: use minimum SL distance
        return (direction == 1)
            ? entryPrice - m_slPips_min * m_pipSize
            : entryPrice + m_slPips_min * m_pipSize;
    }

    bool PlaceOrder(int direction, double lots, int magic, double sl, double tp)
    {
        MqlTradeRequest req = {};
        MqlTradeResult  res = {};

        req.action   = TRADE_ACTION_DEAL;
        req.symbol   = _Symbol;
        req.volume   = lots;
        req.type     = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
        req.price    = (direction == 1)
                        ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
        req.sl       = NormalizeDouble(sl, _Digits);
        req.tp       = NormalizeDouble(tp, _Digits);
        req.magic    = magic;
        req.comment  = StringFormat("Scalper cascade #%d", magic - 10000);
        req.type_filling = ORDER_FILLING_IOC;
        req.deviation    = 10;

        bool ok = OrderSend(req, res);
        if(!ok || res.retcode != TRADE_RETCODE_DONE)
        {
            PrintFormat("[Cascade] OrderSend failed: retcode=%d magic=%d", res.retcode, magic);
            return false;
        }

        PrintFormat("[Cascade] Entry #%d placed: %s %.2f lots @ %.3f SL=%.3f TP=%.3f",
                    magic - 10000,
                    (direction == 1) ? "BUY" : "SELL",
                    lots, res.price, sl, tp);
        return true;
    }

    // Check if a specific cascade position is profitable
    bool IsMagicProfitable(int magic)
    {
        for(int i = 0; i < PositionsTotal(); i++)
        {
            if(PositionGetSymbol(i) != _Symbol) continue;
            if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
            return PositionGetDouble(POSITION_PROFIT) > 0;
        }
        return false; // not found = treat as not profitable (may have been stopped out)
    }

    bool IsMagicOpen(int magic)
    {
        for(int i = 0; i < PositionsTotal(); i++)
        {
            if(PositionGetSymbol(i) != _Symbol) continue;
            if((int)PositionGetInteger(POSITION_MAGIC) == magic) return true;
        }
        return false;
    }

    bool IsMomentumCandle()
    {
        // Entry 3 trigger: body > 70% of full candle range on last closed 1M bar
        double o[1], h[1], l[1], c[1];
        ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
        ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
        if(CopyOpen (_Symbol, PERIOD_M1, 1, 1, o) != 1) return false;
        if(CopyHigh (_Symbol, PERIOD_M1, 1, 1, h) != 1) return false;
        if(CopyLow  (_Symbol, PERIOD_M1, 1, 1, l) != 1) return false;
        if(CopyClose(_Symbol, PERIOD_M1, 1, 1, c) != 1) return false;

        double range = h[0] - l[0];
        if(range <= 0) return false;
        double body = MathAbs(c[0] - o[0]);
        return (body / range > 0.70);
    }

public:
    CCascadeEntry(double slPipsMin = 12.0, double slPipsMax = 18.0, double tpPips = 30.0)
        : m_slPips_min(slPipsMin),
          m_slPips_max(slPipsMax),
          m_tpPips(tpPips),
          m_direction(0),
          m_entry1Price(0),
          m_sequenceActive(false),
          m_entriesOpen(0)
    {
        m_pipSize = 10.0 * _Point;
    }

    // Execute Entry 1 (Pilot) — always the starting point
    bool ExecutePilot(int direction)
    {
        if(IsMagicOpen(MAGIC_PILOT))
        {
            Print("[Cascade] Pilot already open — skipping");
            return false;
        }

        double price = (direction == 1)
            ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
            : SymbolInfoDouble(_Symbol, SYMBOL_BID);

        double sl = GetSLPrice(direction, price);
        double tp = (direction == 1)
            ? price + m_tpPips * m_pipSize
            : price - m_tpPips * m_pipSize;

        if(PlaceOrder(direction, 0.01, MAGIC_PILOT, sl, tp))
        {
            m_direction     = direction;
            m_entry1Price   = price;
            m_sequenceActive = true;
            m_entriesOpen   = 1;
            return true;
        }
        return false;
    }

    // Manage the cascade — call on every tick while sequence is active
    void ManageCascade(int aiScore, bool eurjpyAccelerating)
    {
        if(!m_sequenceActive) return;

        // CRITICAL RULE: if pilot is closed/stopped, cancel entire sequence
        if(!IsMagicOpen(MAGIC_PILOT))
        {
            Print("[Cascade] Pilot stopped out — sequence CANCELLED");
            CloseAll();
            m_sequenceActive = false;
            return;
        }

        // Entry 2 (Core): pilot must be profitable
        if(!IsMagicOpen(MAGIC_CORE) && IsMagicProfitable(MAGIC_PILOT))
        {
            double price = (m_direction == 1)
                ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                : SymbolInfoDouble(_Symbol, SYMBOL_BID);

            double sl = GetSLPrice(m_direction, m_entry1Price); // same SL as pilot
            double tp = (m_direction == 1)
                ? price + m_tpPips * m_pipSize
                : price - m_tpPips * m_pipSize;

            if(PlaceOrder(m_direction, 0.02, MAGIC_CORE, sl, tp))
                m_entriesOpen++;
        }

        // Entry 3 (Add): pilot+core both profitable + momentum candle
        if(!IsMagicOpen(MAGIC_ADD)
           && IsMagicOpen(MAGIC_CORE)
           && IsMagicProfitable(MAGIC_PILOT)
           && IsMagicProfitable(MAGIC_CORE)
           && IsMomentumCandle())
        {
            // SL moves to Entry 2 open price (breakeven for core)
            double corePriceApprox = m_entry1Price; // conservative — use pilot reference
            double sl = (m_direction == 1)
                ? corePriceApprox - 2 * m_pipSize
                : corePriceApprox + 2 * m_pipSize;

            double price = (m_direction == 1)
                ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double tp = (m_direction == 1)
                ? price + m_tpPips * m_pipSize
                : price - m_tpPips * m_pipSize;

            if(PlaceOrder(m_direction, 0.02, MAGIC_ADD, sl, tp))
                m_entriesOpen++;
        }

        // Entry 4 (Max): high-confidence only
        if(!IsMagicOpen(MAGIC_MAX)
           && IsMagicOpen(MAGIC_ADD)
           && aiScore >= 80
           && eurjpyAccelerating)
        {
            double price = (m_direction == 1)
                ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            // Trailing 10 pip stop from current price
            double sl = (m_direction == 1)
                ? price - 10 * m_pipSize
                : price + 10 * m_pipSize;
            double tp = (m_direction == 1)
                ? price + m_tpPips * m_pipSize
                : price - m_tpPips * m_pipSize;

            if(PlaceOrder(m_direction, 0.01, MAGIC_MAX, sl, tp))
                m_entriesOpen++;
        }
    }

    void CloseAll()
    {
        int magics[4] = {MAGIC_PILOT, MAGIC_CORE, MAGIC_ADD, MAGIC_MAX};
        for(int m = 0; m < 4; m++)
        {
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                if(PositionGetSymbol(i) != _Symbol) continue;
                if((int)PositionGetInteger(POSITION_MAGIC) != magics[m]) continue;

                MqlTradeRequest req = {};
                MqlTradeResult  res = {};
                req.action   = TRADE_ACTION_DEAL;
                req.symbol   = _Symbol;
                req.position = PositionGetInteger(POSITION_TICKET);
                req.volume   = PositionGetDouble(POSITION_VOLUME);
                req.type     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                                ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
                req.price    = (req.type == ORDER_TYPE_SELL)
                                ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                req.type_filling = ORDER_FILLING_IOC;
                req.deviation    = 20;
                OrderSend(req, res);
            }
        }

        m_sequenceActive = false;
        m_entriesOpen    = 0;
        m_direction      = 0;
    }

    bool IsSequenceActive()     { return m_sequenceActive; }
    int  GetDirection()         { return m_direction; }
    int  GetEntriesOpen()       { return m_entriesOpen; }
    bool IsPilotOpen()          { return IsMagicOpen(MAGIC_PILOT); }

    // Count all open cascade positions (used by ExitManager)
    int  CountOpenPositions()
    {
        int count = 0;
        int magics[4] = {MAGIC_PILOT, MAGIC_CORE, MAGIC_ADD, MAGIC_MAX};
        for(int m = 0; m < 4; m++)
            if(IsMagicOpen(magics[m])) count++;
        return count;
    }
};
