//+------------------------------------------------------------------+
//|  SwingEntry1H.mqh                                                 |
//|  1H entry conditions for the Swing Rider EA                      |
//|                                                                   |
//|  Entry requires ALL of:                                          |
//|    1. Price has pulled back to 1H 50 EMA                        |
//|    2. RSI(14) in 40-55 zone (bull) or 45-60 zone (bear)        |
//|    3. Confirmation candle closes in trend direction              |
//|    4. Volume > 20-bar average                                    |
//|    5. Spread within limit                                        |
//+------------------------------------------------------------------+
#ifndef SWING_SWINGENTRY1H_MQH
#define SWING_SWINGENTRY1H_MQH

class CSwingEntry1H
{
private:
    int    m_hEMA50_1H;
    int    m_hRSI14_1H;
    double m_maxSpreadPips;
    double m_ema50PullbackPips;  // how close price must be to EMA50 (default 15 pips)

    double PipSize() { return 10.0 * _Point; }  // JPY pair: 1 pip = 0.01

    // Returns true if the last CLOSED 1H candle body closes in direction
    bool IsConfirmationCandle(int direction)
    {
        double opens[], closes[];
        ArraySetAsSeries(opens,  true);
        ArraySetAsSeries(closes, true);

        if(CopyOpen (_Symbol, PERIOD_H1, 1, 1, opens)  != 1) return false;
        if(CopyClose(_Symbol, PERIOD_H1, 1, 1, closes) != 1) return false;

        double body = closes[0] - opens[0];

        if(direction == 1)  return body > 0;   // bull: close > open
        if(direction == -1) return body < 0;   // bear: close < open
        return false;
    }

    bool IsVolumeAboveAverage()
    {
        long volumes[];
        ArraySetAsSeries(volumes, true);
        if(CopyTickVolume(_Symbol, PERIOD_H1, 0, 21, volumes) != 21) return true; // skip if unavailable

        long currentVol = volumes[0];
        long sum = 0;
        for(int i = 1; i <= 20; i++) sum += volumes[i];
        double avg = (double)sum / 20.0;

        return (double)currentVol > avg;
    }

public:
    CSwingEntry1H(double maxSpreadPips = 25.0, double ema50PullbackPips = 15.0)
        : m_maxSpreadPips(maxSpreadPips),
          m_ema50PullbackPips(ema50PullbackPips)
    {}

    bool Init()
    {
        m_hEMA50_1H = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
        m_hRSI14_1H = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);

        if(m_hEMA50_1H == INVALID_HANDLE || m_hRSI14_1H == INVALID_HANDLE)
        {
            Print("[SwingEntry1H] ERROR: Failed to create indicator handles");
            return false;
        }
        return true;
    }

    void Deinit()
    {
        IndicatorRelease(m_hEMA50_1H);
        IndicatorRelease(m_hRSI14_1H);
    }

    // ── Individual condition checks ──────────────────────────────────

    bool IsNearEMA50(int direction)
    {
        double ema[1];
        if(CopyBuffer(m_hEMA50_1H, 0, 0, 1, ema) != 1) return false;

        double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double dist    = MathAbs(bid - ema[0]);
        double distPips = dist / PipSize();

        // Price should be near (within pullbackPips) OR slightly beyond EMA
        // For bull: price above EMA but within pullback zone
        // For bear: price below EMA but within pullback zone
        if(direction == 1)
            return (bid >= ema[0] * 0.9995) && (distPips <= m_ema50PullbackPips);
        if(direction == -1)
            return (bid <= ema[0] * 1.0005) && (distPips <= m_ema50PullbackPips);
        return false;
    }

    bool IsRSIInZone(int direction)
    {
        double rsi[1];
        if(CopyBuffer(m_hRSI14_1H, 0, 0, 1, rsi) != 1) return false;

        if(direction == 1)  return rsi[0] >= 40.0 && rsi[0] <= 55.0;
        if(direction == -1) return rsi[0] >= 45.0 && rsi[0] <= 60.0;
        return false;
    }

    bool IsSpreadOk()
    {
        double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
        double spreadPips = spread / PipSize();
        return spreadPips <= m_maxSpreadPips;
    }

    double GetSpreadPips()
    {
        return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point / PipSize();
    }

    // ── Main entry check ─────────────────────────────────────────────
    // Call on new 1H candle open (after previous bar confirmed)

    bool HasEntrySignal(int direction)
    {
        if(direction == 0) return false;

        return IsNearEMA50(direction)
            && IsRSIInZone(direction)
            && IsConfirmationCandle(direction)
            && IsVolumeAboveAverage()
            && IsSpreadOk();
    }

    // ── Feature values for AI ────────────────────────────────────────

    double GetEMA50()
    {
        double ema[1];
        if(CopyBuffer(m_hEMA50_1H, 0, 0, 1, ema) != 1) return 0;
        return ema[0];
    }

    double GetRSI14()
    {
        double rsi[1];
        if(CopyBuffer(m_hRSI14_1H, 0, 0, 1, rsi) != 1) return 50;
        return rsi[0];
    }

    // Distance from price to EMA50 in pips (signed: + above, - below)
    double GetEMA50DistancePips()
    {
        double ema[1];
        if(CopyBuffer(m_hEMA50_1H, 0, 0, 1, ema) != 1) return 0;
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        return (bid - ema[0]) / PipSize();
    }
};
#endif // SWING_SWINGENTRY1H_MQH
