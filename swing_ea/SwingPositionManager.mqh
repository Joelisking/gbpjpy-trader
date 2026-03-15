//+------------------------------------------------------------------+
//|  SwingPositionManager.mqh                                         |
//|  Single-entry swing position with TP1/TP2 partial close system  |
//|                                                                   |
//|  Logic:                                                          |
//|    - One position (100% size) opened at entry                   |
//|    - TP1: close 50% at 1:1.5 R:R → move SL to breakeven        |
//|    - TP2: close remaining 50% at 1:3 R:R                        |
//|    - SL: 4H structural swing low/high (45-70 pips)              |
//|    - Max hold: 48h (72h post-BoE meeting)                       |
//+------------------------------------------------------------------+
#ifndef SWING_SWINGPOSITIONMANAGER_MQH
#define SWING_SWINGPOSITIONMANAGER_MQH

#define SWING_MAGIC_FULL  20001
#define SWING_MAGIC_HALF  20002  // after TP1 partial close, half-position gets new ticket

class CSwingPositionManager
{
private:
    double m_riskPercent;        // % of balance to risk
    double m_maxHoldHours;
    double m_postBoeHoldHours;   // extended hold after BoE

    bool   m_tp1Hit;
    bool   m_positionOpen;
    int    m_direction;          // 1=long, -1=short
    double m_entryPrice;
    double m_slPrice;
    double m_tp1Price;
    double m_tp2Price;
    datetime m_entryTime;

    double PipSize() { return 10.0 * _Point; }

    double CalcLotSize(double slPips)
    {
        double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
        double riskAmt  = balance * m_riskPercent / 100.0;
        double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double pipValue = (PipSize() / tickSize) * tickVal;
        if(pipValue <= 0 || slPips <= 0) return 0.01;

        double lot = riskAmt / (slPips * pipValue);
        double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        lot = MathFloor(lot / lotStep) * lotStep;

        double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        return MathMax(minLot, MathMin(lot, maxLot));
    }

    // Close a fraction of all positions with matching magic
    void CloseHalf(int magic)
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
            if(PositionGetInteger(POSITION_MAGIC) != magic)    continue;

            double vol    = PositionGetDouble(POSITION_VOLUME);
            double halfVol = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                                     MathFloor(vol / 2.0 / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP))
                                     * SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));

            MqlTradeRequest req = {};
            MqlTradeResult  res = {};
            req.action    = TRADE_ACTION_DEAL;
            req.symbol    = _Symbol;
            req.volume    = halfVol;
            req.magic     = magic;
            req.type      = (m_direction == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            req.price     = SymbolInfoDouble(_Symbol, m_direction == 1 ? SYMBOL_BID : SYMBOL_ASK);
            req.deviation = 20;
            req.comment   = "SwingEA TP1 partial";
            OrderSend(req, res);
        }
    }

    bool ModifySLToBreakeven(int magic)
    {
        bool ok = true;
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
            if(PositionGetInteger(POSITION_MAGIC) != magic)    continue;

            double currentSL = PositionGetDouble(POSITION_SL);
            double be        = m_entryPrice + (m_direction == 1 ? 2 : -2) * PipSize(); // +2 pip buffer

            // Only move SL if it improves our position
            bool shouldMove = (m_direction == 1 && be > currentSL) ||
                              (m_direction == -1 && be < currentSL);
            if(!shouldMove) continue;

            MqlTradeRequest req = {};
            MqlTradeResult  res = {};
            req.action = TRADE_ACTION_SLTP;
            req.symbol = _Symbol;
            req.sl     = be;
            req.tp     = PositionGetDouble(POSITION_TP);
            if(!OrderSend(req, res)) ok = false;
        }
        return ok;
    }

    bool HasOpenPosition(int magic)
    {
        for(int i = 0; i < PositionsTotal(); i++)
        {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
            if(PositionGetInteger(POSITION_MAGIC) != magic)    continue;
            return true;
        }
        return false;
    }

public:
    CSwingPositionManager(double riskPercent = 2.0,
                          double maxHoldHours = 48.0,
                          double postBoeHoldHours = 72.0)
        : m_riskPercent(riskPercent),
          m_maxHoldHours(maxHoldHours),
          m_postBoeHoldHours(postBoeHoldHours),
          m_tp1Hit(false),
          m_positionOpen(false),
          m_direction(0),
          m_entryPrice(0),
          m_slPrice(0),
          m_tp1Price(0),
          m_tp2Price(0),
          m_entryTime(0)
    {}

    bool IsPositionOpen() { return m_positionOpen && HasOpenPosition(SWING_MAGIC_FULL); }
    int  GetDirection()   { return m_direction; }
    double GetEntryPrice(){ return m_entryPrice; }
    double GetSLPrice()   { return m_slPrice; }

    // ── Open new swing position ───────────────────────────────────────

    bool OpenPosition(int direction, double slPrice)
    {
        if(m_positionOpen) return false;

        double price  = SymbolInfoDouble(_Symbol, direction == 1 ? SYMBOL_ASK : SYMBOL_BID);
        double slPips = MathAbs(price - slPrice) / PipSize();

        if(slPips < 45.0 || slPips > 70.0)
        {
            PrintFormat("[SwingPositionManager] SL %.1f pips outside 45-70 range — skipping", slPips);
            return false;
        }

        double rrRatio1 = 1.5;
        double rrRatio2 = 3.0;
        double tp1 = price + direction * slPips * rrRatio1 * PipSize();
        double tp2 = price + direction * slPips * rrRatio2 * PipSize();
        double lot = CalcLotSize(slPips);

        MqlTradeRequest req = {};
        MqlTradeResult  res = {};
        req.action    = TRADE_ACTION_DEAL;
        req.symbol    = _Symbol;
        req.volume    = lot;
        req.type      = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
        req.price     = price;
        req.sl        = slPrice;
        req.tp        = tp2;   // Full TP2 initially; TP1 handled manually
        req.magic     = SWING_MAGIC_FULL;
        req.deviation = 20;
        req.comment   = "SwingEA entry";

        if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE)
        {
            PrintFormat("[SwingPositionManager] OrderSend failed: %d", res.retcode);
            return false;
        }

        m_positionOpen = true;
        m_direction    = direction;
        m_entryPrice   = price;
        m_slPrice      = slPrice;
        m_tp1Price     = tp1;
        m_tp2Price     = tp2;
        m_tp1Hit       = false;
        m_entryTime    = TimeCurrent();

        PrintFormat("[SwingPositionManager] OPEN %s | Lot=%.2f | SL=%.3f (%.1fpips) | TP1=%.3f | TP2=%.3f",
                    direction == 1 ? "BUY" : "SELL",
                    lot, slPrice, slPips, tp1, tp2);
        return true;
    }

    // ── Manage existing position — call on every new 1H bar close ────
    // Returns true if position is now fully closed

    bool ManagePosition(bool bojInterventionRisk = false, bool aiScoreCollapse = false)
    {
        if(!m_positionOpen) return false;

        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double currentPrice = (m_direction == 1) ? bid : ask;

        // ── TP1 check (50% close + move to breakeven) ────────────────
        if(!m_tp1Hit)
        {
            bool tp1Reached = (m_direction == 1) ? (bid >= m_tp1Price)
                                                 : (ask <= m_tp1Price);
            if(tp1Reached)
            {
                PrintFormat("[SwingPositionManager] TP1 hit at %.3f — closing 50%%", currentPrice);
                CloseHalf(SWING_MAGIC_FULL);
                ModifySLToBreakeven(SWING_MAGIC_FULL);
                m_tp1Hit = true;
            }
        }

        // ── Time exit ────────────────────────────────────────────────
        double maxHold = bojInterventionRisk ? m_maxHoldHours / 2.0 : m_maxHoldHours;
        double hoursHeld = (double)(TimeCurrent() - m_entryTime) / 3600.0;
        if(hoursHeld >= maxHold)
        {
            Print("[SwingPositionManager] Time exit — closing all");
            CloseAll();
            return true;
        }

        // ── AI score collapse exit ────────────────────────────────────
        if(aiScoreCollapse)
        {
            Print("[SwingPositionManager] AI score collapsed < 40 — closing all");
            CloseAll();
            return true;
        }

        // ── Check if all positions closed naturally ──────────────────
        if(!HasOpenPosition(SWING_MAGIC_FULL))
        {
            PrintFormat("[SwingPositionManager] Position closed (TP2 or SL). Held %.1fh", hoursHeld);
            m_positionOpen = false;
            m_tp1Hit       = false;
            return true;
        }

        return false;
    }

    // ── Forced close (structural breakdown, 200 EMA breach) ──────────

    void CloseAll()
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
            if(PositionGetInteger(POSITION_MAGIC) != SWING_MAGIC_FULL) continue;

            MqlTradeRequest req = {};
            MqlTradeResult  res = {};
            req.action    = TRADE_ACTION_DEAL;
            req.symbol    = _Symbol;
            req.volume    = PositionGetDouble(POSITION_VOLUME);
            req.type      = (m_direction == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            req.price     = SymbolInfoDouble(_Symbol, m_direction == 1 ? SYMBOL_BID : SYMBOL_ASK);
            req.magic     = SWING_MAGIC_FULL;
            req.deviation = 20;
            req.comment   = "SwingEA force close";
            OrderSend(req, res);
        }
        m_positionOpen = false;
        m_tp1Hit       = false;
    }

    // Move SL to structural level (called when 4H structure confirms)
    bool TrailSLToSwingPoint(double newSL)
    {
        bool improved = (m_direction == 1 && newSL > m_slPrice) ||
                        (m_direction == -1 && newSL < m_slPrice);
        if(!improved) return false;

        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
            if(PositionGetInteger(POSITION_MAGIC) != SWING_MAGIC_FULL) continue;

            MqlTradeRequest req = {};
            MqlTradeResult  res = {};
            req.action = TRADE_ACTION_SLTP;
            req.symbol = _Symbol;
            req.sl     = newSL;
            req.tp     = PositionGetDouble(POSITION_TP);
            OrderSend(req, res);
        }
        m_slPrice = newSL;
        return true;
    }
};
#endif // SWING_SWINGPOSITIONMANAGER_MQH
