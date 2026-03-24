//+------------------------------------------------------------------+
//|  DirectionLayer.mqh                                               |
//|  5M direction system — ALL 5 conditions must be true             |
//|                                                                   |
//|  Conditions (bullish, all required):                             |
//|    1. EMA stack: 21 > 50 > 200 on 5M, price above 21 EMA        |
//|    2. Market structure: >= 2 consecutive HH and HL on 5M        |
//|    3. MACD histogram > 0 on 5M                                  |
//|    4. ATR(14) > 4 pips on 5M                                    |
//|    5. EUR/JPY EMA stack agrees (handled by CorrelationFilter)    |
//+------------------------------------------------------------------+
#ifndef SCALPER_DIRECTIONLAYER_MQH
#define SCALPER_DIRECTIONLAYER_MQH

#define DIR_NONE    0
#define DIR_BULL    1
#define DIR_BEAR   -1

class CDirectionLayer
{
private:
    // Indicator handles — created once in Init(), not on every tick
    int m_hEMA21;
    int m_hEMA50;
    int m_hEMA200;
    int m_hMACD;
    int m_hATR;

    ENUM_TIMEFRAMES m_tf;

    double m_atrMinPips;    // minimum ATR in pips (default 4)
    double m_pipSize;       // 1 pip in price (0.01 for JPY pairs)

    // Cached values — updated at each 5M close
    int    m_cachedBias;
    datetime m_lastUpdate;

    // Swing high/low detection lookback
    int m_structureLookback; // bars to look back for structure (default 50)

    bool GetEMAValues(double &e21, double &e50, double &e200)
    {
        double buf21[1], buf50[1], buf200[1];
        if(CopyBuffer(m_hEMA21,  0, 0, 1, buf21)  != 1) return false;
        if(CopyBuffer(m_hEMA50,  0, 0, 1, buf50)  != 1) return false;
        if(CopyBuffer(m_hEMA200, 0, 0, 1, buf200) != 1) return false;
        e21  = buf21[0];
        e50  = buf50[0];
        e200 = buf200[0];
        return true;
    }

    bool IsEMAStackBullish()
    {
        double e21, e50, e200;
        if(!GetEMAValues(e21, e50, e200)) return false;
        double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        return (e21 > e50 && e50 > e200 && price > e21);
    }

    bool IsEMAStackBearish()
    {
        double e21, e50, e200;
        if(!GetEMAValues(e21, e50, e200)) return false;
        double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        return (e21 < e50 && e50 < e200 && price < e21);
    }

    // MT5 iMACD buffers: 0 = MACD line, 1 = Signal line.
    // There is no buffer 2 — histogram must be computed as MACD - Signal.
    bool GetMACDHistogram(double &hist)
    {
        double macd[1], signal[1];
        if(CopyBuffer(m_hMACD, 0, 0, 1, macd)   != 1) return false;
        if(CopyBuffer(m_hMACD, 1, 0, 1, signal) != 1) return false;
        hist = macd[0] - signal[0];
        return true;
    }

    bool IsMACDBullish()
    {
        double hist;
        if(!GetMACDHistogram(hist)) return false;
        return hist > 0;
    }

    bool IsMACDBearish()
    {
        double hist;
        if(!GetMACDHistogram(hist)) return false;
        return hist < 0;
    }

    bool IsATRSufficient()
    {
        double atr[1];
        if(CopyBuffer(m_hATR, 0, 0, 1, atr) != 1) return false;
        return (atr[0] >= m_atrMinPips * m_pipSize);
    }

    // Detect market structure on 5M.
    // Bullish: most recent swing high > previous swing high (HH)
    //      AND most recent swing low  > previous swing low  (HL).
    // Requires >= 3 swing points of each type to ensure enough price
    // history exists before checking the current pair.
    bool IsStructureBullish()
    {
        int lookback = m_structureLookback;
        double highs[], lows[];
        ArraySetAsSeries(highs, true);
        ArraySetAsSeries(lows,  true);

        if(CopyHigh(_Symbol, m_tf, 0, lookback, highs) != lookback) return false;
        if(CopyLow (_Symbol, m_tf, 0, lookback, lows)  != lookback) return false;

        double swingHighs[10], swingLows[10];
        int nH = 0, nL = 0;
        for(int i = 2; i < lookback - 2 && (nH < 10 || nL < 10); i++)
        {
            if(highs[i] > highs[i-1] && highs[i] > highs[i+1] && nH < 10)
                swingHighs[nH++] = highs[i];
            if(lows[i]  < lows[i-1]  && lows[i]  < lows[i+1]  && nL < 10)
                swingLows[nL++]  = lows[i];
        }

        // Need at least 3 swing points of each type to confirm structure exists
        if(nH < 3 || nL < 3) return false;

        // Most recent HH: swingHighs[0] > swingHighs[1]
        // Most recent HL: swingLows[0]  > swingLows[1]
        return (swingHighs[0] > swingHighs[1] && swingLows[0] > swingLows[1]);
    }

    bool IsStructureBearish()
    {
        int lookback = m_structureLookback;
        double highs[], lows[];
        ArraySetAsSeries(highs, true);
        ArraySetAsSeries(lows,  true);

        if(CopyHigh(_Symbol, m_tf, 0, lookback, highs) != lookback) return false;
        if(CopyLow (_Symbol, m_tf, 0, lookback, lows)  != lookback) return false;

        double swingHighs[10], swingLows[10];
        int nH = 0, nL = 0;
        for(int i = 2; i < lookback - 2 && (nH < 10 || nL < 10); i++)
        {
            if(highs[i] > highs[i-1] && highs[i] > highs[i+1] && nH < 10)
                swingHighs[nH++] = highs[i];
            if(lows[i]  < lows[i-1]  && lows[i]  < lows[i+1]  && nL < 10)
                swingLows[nL++]  = lows[i];
        }

        if(nH < 3 || nL < 3) return false;

        // Most recent LL: swingLows[0]  < swingLows[1]
        // Most recent LH: swingHighs[0] < swingHighs[1]
        return (swingLows[0] < swingLows[1] && swingHighs[0] < swingHighs[1]);
    }

public:
    CDirectionLayer(double atrMinPips = 4.0, int structureLookback = 50)
        : m_atrMinPips(atrMinPips),
          m_structureLookback(structureLookback),
          m_tf(PERIOD_M5),
          m_cachedBias(DIR_NONE),
          m_lastUpdate(0)
    {
        m_pipSize = 10.0 * _Point; // 1 pip for JPY pairs
    }

    bool Init()
    {
        m_hEMA21  = iMA(_Symbol, m_tf, 21,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA50  = iMA(_Symbol, m_tf, 50,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA200 = iMA(_Symbol, m_tf, 200, 0, MODE_EMA, PRICE_CLOSE);
        m_hMACD   = iMACD(_Symbol, m_tf, 12, 26, 9, PRICE_CLOSE);
        m_hATR    = iATR(_Symbol, m_tf, 14);

        if(m_hEMA21 == INVALID_HANDLE || m_hEMA50 == INVALID_HANDLE ||
           m_hEMA200 == INVALID_HANDLE || m_hMACD == INVALID_HANDLE ||
           m_hATR == INVALID_HANDLE)
        {
            Print("[DirectionLayer] ERROR: Failed to create indicator handles");
            return false;
        }
        return true;
    }

    void Deinit()
    {
        IndicatorRelease(m_hEMA21);
        IndicatorRelease(m_hEMA50);
        IndicatorRelease(m_hEMA200);
        IndicatorRelease(m_hMACD);
        IndicatorRelease(m_hATR);
    }

    // Call on every 5M candle close — returns DIR_BULL, DIR_BEAR, or DIR_NONE
    int Get5MBias()
    {
        // ATR check first — if market is dead, skip session entirely
        if(!IsATRSufficient())
        {
            m_cachedBias = DIR_NONE;
            return DIR_NONE;
        }

        if(IsEMAStackBullish() && IsStructureBullish() && IsMACDBullish())
        {
            m_cachedBias = DIR_BULL;
            return DIR_BULL;
        }

        if(IsEMAStackBearish() && IsStructureBearish() && IsMACDBearish())
        {
            m_cachedBias = DIR_BEAR;
            return DIR_BEAR;
        }

        m_cachedBias = DIR_NONE;
        return DIR_NONE;
    }

    int GetCachedBias() { return m_cachedBias; }

    // Log the pass/fail state of every sub-condition — call at each 5M close
    void LogDiagnostics()
    {
        double e21, e50, e200;
        bool emaDataOk = GetEMAValues(e21, e50, e200);
        double price   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        double atr[1];
        bool atrDataOk  = (CopyBuffer(m_hATR,  0, 0, 1, atr)  == 1);
        double atrPips  = atrDataOk ? atr[0] / m_pipSize : 0;

        double histVal    = 0;
        bool macdDataOk   = GetMACDHistogram(histVal);

        bool atrPass      = atrDataOk  && (atrPips >= m_atrMinPips);
        bool emaStackBull = emaDataOk  && (e21 > e50 && e50 > e200 && price > e21);
        bool emaStackBear = emaDataOk  && (e21 < e50 && e50 < e200 && price < e21);
        bool macdBull     = macdDataOk && histVal > 0;
        bool macdBear     = macdDataOk && histVal < 0;
        bool structBull   = IsStructureBullish();
        bool structBear   = IsStructureBearish();

        PrintFormat("[5M-Diag] ATR=%.1f pips (min %.1f) [%s]",
            atrPips, m_atrMinPips, atrPass ? "OK" : "FAIL");
        PrintFormat("[5M-Diag] EMA stack: BULL=%s BEAR=%s | Price=%.3f EMA21=%.3f EMA50=%.3f EMA200=%.3f",
            emaStackBull ? "Y" : "N", emaStackBear ? "Y" : "N",
            price,
            emaDataOk ? e21  : 0,
            emaDataOk ? e50  : 0,
            emaDataOk ? e200 : 0);
        PrintFormat("[5M-Diag] MACD hist=%.5f [BULL=%s BEAR=%s]",
            macdDataOk ? histVal : 0,
            macdBull ? "Y" : "N", macdBear ? "Y" : "N");
        PrintFormat("[5M-Diag] Structure: BULL=%s BEAR=%s",
            structBull ? "Y" : "N", structBear ? "Y" : "N");
    }

    // Used by ExitManager to detect direction flip while trade is open
    bool HasDirectionFlipped(int entryDirection)
    {
        int current = Get5MBias();
        if(current == DIR_NONE) return false;
        return (current != entryDirection);
    }

    // Get current ATR in pips (for SL calculation)
    double GetATRPips()
    {
        double atr[1];
        if(CopyBuffer(m_hATR, 0, 0, 1, atr) != 1) return 0;
        return atr[0] / m_pipSize;
    }

    // Get the last confirmed swing low/high on 5M (for SL placement)
    double GetSwingLow(int lookback = 20)
    {
        double lows[];
        ArraySetAsSeries(lows, true);
        if(CopyLow(_Symbol, m_tf, 0, lookback, lows) != lookback) return 0;
        return lows[ArrayMinimum(lows, 0, lookback)];
    }

    double GetSwingHigh(int lookback = 20)
    {
        double highs[];
        ArraySetAsSeries(highs, true);
        if(CopyHigh(_Symbol, m_tf, 0, lookback, highs) != lookback) return 0;
        return highs[ArrayMaximum(highs, 0, lookback)];
    }
};
#endif // SCALPER_DIRECTIONLAYER_MQH
