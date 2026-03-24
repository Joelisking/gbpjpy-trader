//+------------------------------------------------------------------+
//|  TrendAnalyzer4H.mqh                                              |
//|  4H direction system — ALL conditions required                   |
//|                                                                   |
//|  Bullish (all required):                                         |
//|    1. 4H market structure: >= 2 consecutive HH and HL            |
//|    2. Price > 200 EMA on 4H                                      |
//|    3. RSI(14) > 50 on 4H                                        |
//|    4. Weekly EMA stack: 21 > 50                                  |
//|    5. AI Trend Strength Score >= 70 (checked by caller)          |
//+------------------------------------------------------------------+
#ifndef SWING_TRENDANALYZER4H_MQH
#define SWING_TRENDANALYZER4H_MQH

#define DIR_NONE    0
#define DIR_BULL    1
#define DIR_BEAR   -1

class CTrendAnalyzer4H
{
private:
    int m_hEMA200_4H;
    int m_hRSI14_4H;
    int m_hEMA21_W1;
    int m_hEMA50_W1;

    int m_structureLookback;  // 4H bars to scan for swing points (default 60)

    bool GetSwingPoints(int direction, double &swings[], int &count)
    {
        int lookback = m_structureLookback;
        double highs[], lows[];
        ArraySetAsSeries(highs, true);
        ArraySetAsSeries(lows,  true);

        if(CopyHigh(_Symbol, PERIOD_H4, 0, lookback, highs) != lookback) return false;
        if(CopyLow (_Symbol, PERIOD_H4, 0, lookback, lows)  != lookback) return false;

        count = 0;
        ArrayResize(swings, 20);

        for(int i = 2; i < lookback - 2 && count < 20; i++)
        {
            if(direction == 1) // collect swing highs
            {
                if(highs[i] > highs[i-1] && highs[i] > highs[i+1])
                    swings[count++] = highs[i];
            }
            else // collect swing lows
            {
                if(lows[i] < lows[i-1] && lows[i] < lows[i+1])
                    swings[count++] = lows[i];
            }
        }
        return (count >= 2);
    }

public:
    CTrendAnalyzer4H(int structureLookback = 60)
        : m_structureLookback(structureLookback)
    {}

    bool Init()
    {
        m_hEMA200_4H = iMA(_Symbol, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
        m_hRSI14_4H  = iRSI(_Symbol, PERIOD_H4, 14, PRICE_CLOSE);
        m_hEMA21_W1  = iMA(_Symbol, PERIOD_W1, 21,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA50_W1  = iMA(_Symbol, PERIOD_W1, 50,  0, MODE_EMA, PRICE_CLOSE);

        if(m_hEMA200_4H == INVALID_HANDLE || m_hRSI14_4H == INVALID_HANDLE ||
           m_hEMA21_W1  == INVALID_HANDLE || m_hEMA50_W1 == INVALID_HANDLE)
        {
            Print("[TrendAnalyzer4H] ERROR: Failed to create indicator handles");
            return false;
        }
        return true;
    }

    void Deinit()
    {
        IndicatorRelease(m_hEMA200_4H);
        IndicatorRelease(m_hRSI14_4H);
        IndicatorRelease(m_hEMA21_W1);
        IndicatorRelease(m_hEMA50_W1);
    }

    // ── Individual condition checks ──────────────────────────────────

    bool IsHHHL()
    {
        double swingHighs[], swingLows[];
        int nH, nL;

        if(!GetSwingPoints(1, swingHighs, nH)) return false;
        if(!GetSwingPoints(-1, swingLows,  nL)) return false;

        // Need at least 2 consecutive HH and 2 consecutive HL
        int hhCount = 0, hlCount = 0;
        for(int i = 0; i < nH - 1; i++)
            if(swingHighs[i] > swingHighs[i+1]) hhCount++;
        for(int i = 0; i < nL - 1; i++)
            if(swingLows[i] > swingLows[i+1]) hlCount++;

        return (hhCount >= 2 && hlCount >= 2);
    }

    bool IsLLLH()
    {
        double swingHighs[], swingLows[];
        int nH, nL;

        if(!GetSwingPoints(1, swingHighs, nH)) return false;
        if(!GetSwingPoints(-1, swingLows,  nL)) return false;

        int llCount = 0, lhCount = 0;
        for(int i = 0; i < nL - 1; i++)
            if(swingLows[i] < swingLows[i+1]) llCount++;
        for(int i = 0; i < nH - 1; i++)
            if(swingHighs[i] < swingHighs[i+1]) lhCount++;

        return (llCount >= 2 && lhCount >= 2);
    }

    bool IsAbove200EMA()
    {
        double ema[1];
        if(CopyBuffer(m_hEMA200_4H, 0, 0, 1, ema) != 1) return false;
        return SymbolInfoDouble(_Symbol, SYMBOL_BID) > ema[0];
    }

    bool IsBelow200EMA()
    {
        double ema[1];
        if(CopyBuffer(m_hEMA200_4H, 0, 0, 1, ema) != 1) return false;
        return SymbolInfoDouble(_Symbol, SYMBOL_BID) < ema[0];
    }

    bool IsRSI14Above50()
    {
        double rsi[1];
        if(CopyBuffer(m_hRSI14_4H, 0, 0, 1, rsi) != 1) return false;
        return rsi[0] > 50.0;
    }

    bool IsRSI14Below50()
    {
        double rsi[1];
        if(CopyBuffer(m_hRSI14_4H, 0, 0, 1, rsi) != 1) return false;
        return rsi[0] < 50.0;
    }

    bool IsWeeklyBullish()
    {
        double e21[1], e50[1];
        if(CopyBuffer(m_hEMA21_W1, 0, 0, 1, e21) != 1) return false;
        if(CopyBuffer(m_hEMA50_W1, 0, 0, 1, e50) != 1) return false;
        return e21[0] > e50[0];
    }

    bool IsWeeklyBearish()
    {
        double e21[1], e50[1];
        if(CopyBuffer(m_hEMA21_W1, 0, 0, 1, e21) != 1) return false;
        if(CopyBuffer(m_hEMA50_W1, 0, 0, 1, e50) != 1) return false;
        return e21[0] < e50[0];
    }

    // Log the pass/fail state of every 4H sub-condition — call at each 4H close
    void LogDiagnostics()
    {
        bool hhhl    = IsHHHL();
        bool lllh    = IsLLLH();
        bool above   = IsAbove200EMA();
        bool below   = IsBelow200EMA();
        bool rsiBull = IsRSI14Above50();
        bool rsiBear = IsRSI14Below50();
        bool wkBull  = IsWeeklyBullish();
        bool wkBear  = IsWeeklyBearish();

        double ema200 = GetEMA200();
        double rsi    = GetRSI14();
        double price  = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        PrintFormat("[4H-Diag] Structure: HHHL=%s LLLH=%s",
            hhhl ? "Y" : "N", lllh ? "Y" : "N");
        PrintFormat("[4H-Diag] EMA200=%.3f Price=%.3f | Above=%s Below=%s",
            ema200, price, above ? "Y" : "N", below ? "Y" : "N");
        PrintFormat("[4H-Diag] RSI14=%.1f | >50=%s <50=%s",
            rsi, rsiBull ? "Y" : "N", rsiBear ? "Y" : "N");
        PrintFormat("[4H-Diag] Weekly EMA: Bull=%s Bear=%s",
            wkBull ? "Y" : "N", wkBear ? "Y" : "N");

        bool bullAll = hhhl  && above && rsiBull && wkBull;
        bool bearAll = lllh  && below && rsiBear && wkBear;
        PrintFormat("[4H-Diag] => BULL=%s BEAR=%s (all conditions)",
            bullAll ? "YES" : "no", bearAll ? "YES" : "no");
    }

    // ── Main bias — returns DIR_BULL (1), DIR_BEAR (-1), DIR_NONE (0) ──

    int Get4HBias()
    {
        if(IsHHHL() && IsAbove200EMA() && IsRSI14Above50() && IsWeeklyBullish())
            return 1;

        if(IsLLLH() && IsBelow200EMA() && IsRSI14Below50() && IsWeeklyBearish())
            return -1;

        return 0;
    }

    // ── SL placement helpers ─────────────────────────────────────────

    // Returns price just below the last confirmed Higher Low on 4H (long SL)
    double GetStructuralSwingLow(double pipSize, int lookback = 40)
    {
        double lows[];
        ArraySetAsSeries(lows, true);
        if(CopyLow(_Symbol, PERIOD_H4, 0, lookback, lows) != lookback) return 0;

        // Find the most recent swing low (pivot)
        for(int i = 2; i < lookback - 2; i++)
            if(lows[i] < lows[i-1] && lows[i] < lows[i+1])
                return lows[i] - 2 * pipSize;  // 2 pips buffer below

        return lows[ArrayMinimum(lows, 0, lookback)] - 2 * pipSize;
    }

    // Returns price just above the last confirmed Lower High on 4H (short SL)
    double GetStructuralSwingHigh(double pipSize, int lookback = 40)
    {
        double highs[];
        ArraySetAsSeries(highs, true);
        if(CopyHigh(_Symbol, PERIOD_H4, 0, lookback, highs) != lookback) return 0;

        for(int i = 2; i < lookback - 2; i++)
            if(highs[i] > highs[i-1] && highs[i] > highs[i+1])
                return highs[i] + 2 * pipSize;

        return highs[ArrayMaximum(highs, 0, lookback)] + 2 * pipSize;
    }

    // ── Mandatory exit checks (use 4H candle CLOSES only) ────────────

    // 4H candle closed below the last confirmed HL — structural breakdown
    bool IsStructuralBreakdownLong(double lastConfirmedHL)
    {
        double closes[];
        ArraySetAsSeries(closes, true);
        if(CopyClose(_Symbol, PERIOD_H4, 1, 1, closes) != 1) return false; // shift=1 = last CLOSED bar
        return closes[0] < lastConfirmedHL;
    }

    bool IsStructuralBreakdownShort(double lastConfirmedLH)
    {
        double closes[];
        ArraySetAsSeries(closes, true);
        if(CopyClose(_Symbol, PERIOD_H4, 1, 1, closes) != 1) return false;
        return closes[0] > lastConfirmedLH;
    }

    // 4H candle closed below 200 EMA (for longs)
    bool Is200EMABreached(int direction)
    {
        double ema[1], closes[];
        ArraySetAsSeries(closes, true);
        if(CopyBuffer(m_hEMA200_4H, 0, 1, 1, ema)       != 1) return false;
        if(CopyClose(_Symbol, PERIOD_H4, 1, 1, closes)   != 1) return false;

        if(direction == 1)  return closes[0] < ema[0]; // long: close below 200 EMA
        else                return closes[0] > ema[0]; // short: close above 200 EMA
    }

    double GetEMA200()
    {
        double ema[1];
        if(CopyBuffer(m_hEMA200_4H, 0, 0, 1, ema) != 1) return 0;
        return ema[0];
    }

    double GetRSI14()
    {
        double rsi[1];
        if(CopyBuffer(m_hRSI14_4H, 0, 0, 1, rsi) != 1) return 50;
        return rsi[0];
    }
};
#endif // SWING_TRENDANALYZER4H_MQH
