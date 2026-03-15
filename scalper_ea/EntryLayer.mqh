//+------------------------------------------------------------------+
//|  EntryLayer.mqh                                                   |
//|  1M entry trigger logic — all 7 conditions required             |
//|                                                                   |
//|  1. 5M EMA stack and EUR/JPY agree (checked by caller)          |
//|  2. 1M price pulled back to 21 EMA                              |
//|  3. Rejection candle on 1M                                       |
//|  4. RSI(7) in zone: 40-55 long, 45-60 short                    |
//|  5. Spread < 30 pips                                            |
//|  6. AI Entry Score >= 65 (checked by caller)                    |
//|  7. Remaining session risk > 2% (checked by caller)             |
//+------------------------------------------------------------------+
#ifndef SCALPER_ENTRYLAYER_MQH
#define SCALPER_ENTRYLAYER_MQH

class CEntryLayer
{
private:
    int    m_hEMA21_1M;
    int    m_hRSI7_1M;

    double m_maxSpreadPips;
    double m_pipSize;
    double m_emaTouchThresholdPips; // how close price must be to EMA (default 3 pips)

    // Candle pattern detection on 1M
    // Returns true if there's a bullish rejection candle on the last closed bar (shift=1)
    bool HasBullishRejectionCandle()
    {
        double o[], h[], l[], c[];
        ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
        ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

        if(CopyOpen (_Symbol, PERIOD_M1, 1, 1, o) != 1) return false;
        if(CopyHigh (_Symbol, PERIOD_M1, 1, 1, h) != 1) return false;
        if(CopyLow  (_Symbol, PERIOD_M1, 1, 1, l) != 1) return false;
        if(CopyClose(_Symbol, PERIOD_M1, 1, 1, c) != 1) return false;

        double body  = MathAbs(c[0] - o[0]);
        double range = h[0] - l[0];
        if(range <= 0) return false;

        bool bullish = c[0] > o[0]; // green candle

        // Bullish engulfing: large green body
        bool engulfing = bullish && (body / range > 0.6);

        // Hammer: small body at top, large lower wick
        double lowerWick = MathMin(o[0], c[0]) - l[0];
        bool hammer = (lowerWick >= 2.0 * body) && (body / range > 0.1);

        // Pin bar (bullish): lower wick >= 2x body, upper wick small
        double upperWick = h[0] - MathMax(o[0], c[0]);
        bool pinBar = (lowerWick >= 2.0 * body) && (upperWick < lowerWick * 0.5);

        return (engulfing || hammer || pinBar);
    }

    bool HasBearishRejectionCandle()
    {
        double o[], h[], l[], c[];
        ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
        ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

        if(CopyOpen (_Symbol, PERIOD_M1, 1, 1, o) != 1) return false;
        if(CopyHigh (_Symbol, PERIOD_M1, 1, 1, h) != 1) return false;
        if(CopyLow  (_Symbol, PERIOD_M1, 1, 1, l) != 1) return false;
        if(CopyClose(_Symbol, PERIOD_M1, 1, 1, c) != 1) return false;

        double body  = MathAbs(c[0] - o[0]);
        double range = h[0] - l[0];
        if(range <= 0) return false;

        bool bearish = c[0] < o[0]; // red candle

        // Bearish engulfing: large red body
        bool engulfing = bearish && (body / range > 0.6);

        // Shooting star: small body at bottom, large upper wick
        double upperWick = h[0] - MathMax(o[0], c[0]);
        bool shootingStar = (upperWick >= 2.0 * body) && (body / range > 0.1);

        // Bearish pin bar
        double lowerWick = MathMin(o[0], c[0]) - l[0];
        bool pinBar = (upperWick >= 2.0 * body) && (lowerWick < upperWick * 0.5);

        return (engulfing || shootingStar || pinBar);
    }

    // Price has pulled back to touch the 1M 21 EMA within threshold
    bool HasPullbackToEMA21(int direction)
    {
        double ema[1];
        if(CopyBuffer(m_hEMA21_1M, 0, 1, 1, ema) != 1) return false;

        double low[1], high[1];
        ArraySetAsSeries(low,  true);
        ArraySetAsSeries(high, true);
        if(CopyLow (_Symbol, PERIOD_M1, 1, 1, low)  != 1) return false;
        if(CopyHigh(_Symbol, PERIOD_M1, 1, 1, high) != 1) return false;

        double threshold = m_emaTouchThresholdPips * m_pipSize;

        if(direction == 1)  // long: price dips to touch EMA from above
            return (low[0] <= ema[0] + threshold && low[0] >= ema[0] - threshold * 2);
        else                // short: price bounces up to touch EMA from below
            return (high[0] >= ema[0] - threshold && high[0] <= ema[0] + threshold * 2);
    }

    bool IsRSI7InZone(int direction)
    {
        double rsi[1];
        if(CopyBuffer(m_hRSI7_1M, 0, 1, 1, rsi) != 1) return false;

        if(direction == 1)  // long: not overbought
            return (rsi[0] >= 40.0 && rsi[0] <= 55.0);
        else                // short: not oversold
            return (rsi[0] >= 45.0 && rsi[0] <= 60.0);
    }

    bool IsSpreadOk()
    {
        long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
        double spreadPips = spreadPoints * _Point / m_pipSize;
        return (spreadPips < m_maxSpreadPips);
    }

public:
    CEntryLayer(double maxSpreadPips = 30.0, double emaTouchThresholdPips = 3.0)
        : m_maxSpreadPips(maxSpreadPips),
          m_emaTouchThresholdPips(emaTouchThresholdPips)
    {
        m_pipSize = 10.0 * _Point;
    }

    bool Init()
    {
        m_hEMA21_1M = iMA(_Symbol, PERIOD_M1, 21, 0, MODE_EMA, PRICE_CLOSE);
        m_hRSI7_1M  = iRSI(_Symbol, PERIOD_M1, 7, PRICE_CLOSE);

        if(m_hEMA21_1M == INVALID_HANDLE || m_hRSI7_1M == INVALID_HANDLE)
        {
            Print("[EntryLayer] ERROR: Failed to create indicator handles");
            return false;
        }
        return true;
    }

    void Deinit()
    {
        IndicatorRelease(m_hEMA21_1M);
        IndicatorRelease(m_hRSI7_1M);
    }

    // Returns true if all entry conditions are met for the given direction
    bool Has1MSignal(int direction)
    {
        if(direction == DIR_NONE) return false;
        if(!IsSpreadOk())              return false;
        if(!HasPullbackToEMA21(direction)) return false;
        if(!IsRSI7InZone(direction))       return false;

        if(direction == 1)
            return HasBullishRejectionCandle();
        else
            return HasBearishRejectionCandle();
    }

    // Expose spread check separately (used in cascade decisions)
    bool IsSpreadAcceptable() { return IsSpreadOk(); }

    // Get current 1M RSI for AI features
    double GetRSI7()
    {
        double rsi[1];
        if(CopyBuffer(m_hRSI7_1M, 0, 0, 1, rsi) != 1) return 50.0;
        return rsi[0];
    }

    // Get current 1M EMA21 value for AI features
    double GetEMA21()
    {
        double ema[1];
        if(CopyBuffer(m_hEMA21_1M, 0, 0, 1, ema) != 1) return 0;
        return ema[0];
    }

    // Get current spread in pips
    double GetSpreadPips()
    {
        long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
        return spreadPoints * _Point / m_pipSize;
    }
};
#endif // SCALPER_ENTRYLAYER_MQH
