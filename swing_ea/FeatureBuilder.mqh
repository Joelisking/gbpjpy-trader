//+------------------------------------------------------------------+
//|  FeatureBuilder.mqh                                               |
//|  Builds the 40-feature normalised JSON array for the AI server   |
//|                                                                   |
//|  Feature order MUST match data_pipeline/feature_engineer.py:     |
//|  f[0-11]  : M5  — return, ema9/21/50/200, atr, rsi7, macd,     |
//|             bb%b, engulf, pin, vol_ratio                          |
//|  f[12-19] : H1  — return, ema21/50/200, rsi14, macd, atr, vol  |
//|  f[20-25] : H4  — return, ema50/200, rsi14, atr, structure      |
//|  f[26-29] : W1  — return, ema21/50, ema_stack                   |
//|  f[30-32] : EURJPY — return_m5, ema_align, rsi_h1               |
//|  f[33-38] : Time — sin/cos hour, sin/cos dow, london, overlap    |
//|  f[39]    : carry_differential                                    |
//+------------------------------------------------------------------+
#ifndef FEATUREBUILDER_MQH
#define FEATUREBUILDER_MQH

class CFeatureBuilder
{
private:
    // ── M5 handles ─────────────────────────────────────────────────
    int m_hEMA9_M5,  m_hEMA21_M5, m_hEMA50_M5, m_hEMA200_M5;
    int m_hATR14_M5, m_hRSI7_M5,  m_hMACD_M5,  m_hBB_M5;

    // ── H1 handles ─────────────────────────────────────────────────
    int m_hEMA21_H1, m_hEMA50_H1, m_hEMA200_H1;
    int m_hRSI14_H1, m_hMACD_H1,  m_hATR14_H1;

    // ── H4 handles ─────────────────────────────────────────────────
    int m_hEMA50_H4, m_hEMA200_H4, m_hRSI14_H4, m_hATR14_H4;

    // ── W1 handles ─────────────────────────────────────────────────
    int m_hEMA21_W1, m_hEMA50_W1;

    // ── EUR/JPY handles ────────────────────────────────────────────
    int m_hEurEMA21_M5, m_hEurEMA50_M5, m_hEurRSI14_H1;

    // ── Helpers ────────────────────────────────────────────────────

    double Buf(int handle, int bufIdx, int shift)
    {
        double b[];
        ArraySetAsSeries(b, true);
        if(CopyBuffer(handle, bufIdx, shift, 1, b) != 1) return 0.0;
        return b[0];
    }

    double CloseOf(ENUM_TIMEFRAMES tf, int shift)
    {
        double c[];
        ArraySetAsSeries(c, true);
        if(CopyClose(_Symbol, tf, shift, 1, c) != 1) return 0.0;
        return c[0];
    }

    double CloseOf(string symbol, ENUM_TIMEFRAMES tf, int shift)
    {
        double c[];
        ArraySetAsSeries(c, true);
        if(CopyClose(symbol, tf, shift, 1, c) != 1) return 0.0;
        return c[0];
    }

    double Clip(double val, double lo, double hi)
    {
        return MathMax(lo, MathMin(hi, val));
    }

    // pct_change for current vs previous bar, clipped
    double PctChange(ENUM_TIMEFRAMES tf, double clip = 0.05)
    {
        double c[];
        ArraySetAsSeries(c, true);
        if(CopyClose(_Symbol, tf, 0, 2, c) != 2) return 0.0;
        if(c[1] == 0) return 0.0;
        return Clip((c[0] - c[1]) / c[1], -clip, clip);
    }

    double PctChange(string symbol, ENUM_TIMEFRAMES tf, double clip = 0.05)
    {
        double c[];
        ArraySetAsSeries(c, true);
        if(CopyClose(symbol, tf, 0, 2, c) != 2) return 0.0;
        if(c[1] == 0) return 0.0;
        return Clip((c[0] - c[1]) / c[1], -clip, clip);
    }

    // MACD histogram = main_line - signal_line, normalised by close and clipped
    double MACDHist(int handle, ENUM_TIMEFRAMES tf, double clip = 0.01)
    {
        double main_v = Buf(handle, 0, 0);
        double sig_v  = Buf(handle, 1, 0);
        double hist   = main_v - sig_v;
        double close  = CloseOf(tf, 0);
        if(close == 0) return 0.0;
        return Clip(hist, -clip, clip) / close;
    }

    // Bollinger %B = (close - lower) / (upper - lower), clipped [0,1]
    double BollingerPctB(int handle, ENUM_TIMEFRAMES tf)
    {
        double upper = Buf(handle, 1, 0);
        double lower = Buf(handle, 2, 0);
        double close = CloseOf(tf, 0);
        double width = upper - lower;
        if(width <= 0) return 0.5;
        return Clip((close - lower) / width, 0.0, 1.0);
    }

    // Volume ratio: current / 20-bar average, clipped [0,5]
    double VolRatio(ENUM_TIMEFRAMES tf)
    {
        long vol[];
        ArraySetAsSeries(vol, true);
        if(CopyTickVolume(_Symbol, tf, 0, 21, vol) != 21) return 1.0;
        double avg = 0;
        for(int i = 1; i <= 20; i++) avg += (double)vol[i];
        avg /= 20.0;
        if(avg <= 0) return 1.0;
        return Clip((double)vol[0] / avg, 0.0, 5.0);
    }

    // Engulfing pattern: +1 bull, -1 bear, 0 none (last CLOSED bar)
    double Engulfing(ENUM_TIMEFRAMES tf)
    {
        double o[], c[], po[], pc[];
        ArraySetAsSeries(o, true); ArraySetAsSeries(c, true);
        ArraySetAsSeries(po, true); ArraySetAsSeries(pc, true);
        if(CopyOpen (_Symbol, tf, 1, 2, o)  != 2) return 0;
        if(CopyClose(_Symbol, tf, 1, 2, c)  != 2) return 0;
        if(CopyOpen (_Symbol, tf, 2, 1, po) != 1) return 0;  // bar before last
        if(CopyClose(_Symbol, tf, 2, 1, pc) != 1) return 0;

        bool bull = c[0] > o[0] && po[0] > pc[0] && c[0] > po[0] && o[0] < pc[0];
        bool bear = c[0] < o[0] && pc[0] > po[0] && c[0] < po[0] && o[0] > pc[0];
        if(bull) return  1.0;
        if(bear) return -1.0;
        return 0.0;
    }

    // Pin bar: +1 hammer, -1 shooting star, 0 none
    double PinBar(ENUM_TIMEFRAMES tf)
    {
        double o[], h[], l[], c[];
        ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
        ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
        if(CopyOpen (_Symbol, tf, 1, 1, o) != 1) return 0;
        if(CopyHigh (_Symbol, tf, 1, 1, h) != 1) return 0;
        if(CopyLow  (_Symbol, tf, 1, 1, l) != 1) return 0;
        if(CopyClose(_Symbol, tf, 1, 1, c) != 1) return 0;

        double body       = MathAbs(c[0] - o[0]);
        double upperWick  = h[0] - MathMax(o[0], c[0]);
        double lowerWick  = MathMin(o[0], c[0]) - l[0];
        double range      = h[0] - l[0];

        if(range <= 0) return 0;
        if(lowerWick > 2 * body && upperWick < body) return  1.0;  // hammer
        if(upperWick > 2 * body && lowerWick < body) return -1.0;  // shooting star
        return 0.0;
    }

    // H4 market structure score: fraction of last 60 H4 bars trending up
    // Approximation of hh_hl_score / 60 from feature_engineer.py
    double H4Structure()
    {
        double c[];
        ArraySetAsSeries(c, true);
        if(CopyClose(_Symbol, PERIOD_H4, 0, 61, c) != 61) return 0.0;

        int up = 0, down = 0;
        for(int i = 0; i < 60; i++)
        {
            if(c[i] > c[i + 1]) up++;
            else if(c[i] < c[i + 1]) down++;
        }
        return (double)(up - down) / 60.0;
    }

    // EUR/JPY EMA alignment: sign(ema21 - ema50), +1/-1/0
    double EurJpyEmaAlign()
    {
        double e21 = Buf(m_hEurEMA21_M5, 0, 0);
        double e50 = Buf(m_hEurEMA50_M5, 0, 0);
        if(e21 > e50) return  1.0;
        if(e21 < e50) return -1.0;
        return 0.0;
    }

public:
    bool Init()
    {
        // M5 indicators
        m_hEMA9_M5   = iMA(_Symbol, PERIOD_M5, 9,   0, MODE_EMA, PRICE_CLOSE);
        m_hEMA21_M5  = iMA(_Symbol, PERIOD_M5, 21,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA50_M5  = iMA(_Symbol, PERIOD_M5, 50,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA200_M5 = iMA(_Symbol, PERIOD_M5, 200, 0, MODE_EMA, PRICE_CLOSE);
        m_hATR14_M5  = iATR(_Symbol, PERIOD_M5, 14);
        m_hRSI7_M5   = iRSI(_Symbol, PERIOD_M5, 7,  PRICE_CLOSE);
        m_hMACD_M5   = iMACD(_Symbol, PERIOD_M5, 12, 26, 9, PRICE_CLOSE);
        m_hBB_M5     = iBands(_Symbol, PERIOD_M5, 20, 0, 2.0, PRICE_CLOSE);

        // H1 indicators
        m_hEMA21_H1  = iMA(_Symbol, PERIOD_H1, 21,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA50_H1  = iMA(_Symbol, PERIOD_H1, 50,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA200_H1 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
        m_hRSI14_H1  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
        m_hMACD_H1   = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);
        m_hATR14_H1  = iATR(_Symbol, PERIOD_H1, 14);

        // H4 indicators
        m_hEMA50_H4  = iMA(_Symbol, PERIOD_H4, 50,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA200_H4 = iMA(_Symbol, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
        m_hRSI14_H4  = iRSI(_Symbol, PERIOD_H4, 14, PRICE_CLOSE);
        m_hATR14_H4  = iATR(_Symbol, PERIOD_H4, 14);

        // W1 indicators
        m_hEMA21_W1  = iMA(_Symbol, PERIOD_W1, 21, 0, MODE_EMA, PRICE_CLOSE);
        m_hEMA50_W1  = iMA(_Symbol, PERIOD_W1, 50, 0, MODE_EMA, PRICE_CLOSE);

        // EUR/JPY indicators
        m_hEurEMA21_M5  = iMA("EURJPY", PERIOD_M5, 21, 0, MODE_EMA, PRICE_CLOSE);
        m_hEurEMA50_M5  = iMA("EURJPY", PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
        m_hEurRSI14_H1  = iRSI("EURJPY", PERIOD_H1, 14, PRICE_CLOSE);

        bool ok =
            m_hEMA9_M5   != INVALID_HANDLE && m_hEMA21_M5  != INVALID_HANDLE &&
            m_hEMA50_M5  != INVALID_HANDLE && m_hEMA200_M5 != INVALID_HANDLE &&
            m_hATR14_M5  != INVALID_HANDLE && m_hRSI7_M5   != INVALID_HANDLE &&
            m_hMACD_M5   != INVALID_HANDLE && m_hBB_M5     != INVALID_HANDLE &&
            m_hEMA21_H1  != INVALID_HANDLE && m_hEMA50_H1  != INVALID_HANDLE &&
            m_hEMA200_H1 != INVALID_HANDLE && m_hRSI14_H1  != INVALID_HANDLE &&
            m_hMACD_H1   != INVALID_HANDLE && m_hATR14_H1  != INVALID_HANDLE &&
            m_hEMA50_H4  != INVALID_HANDLE && m_hEMA200_H4 != INVALID_HANDLE &&
            m_hRSI14_H4  != INVALID_HANDLE && m_hATR14_H4  != INVALID_HANDLE &&
            m_hEMA21_W1  != INVALID_HANDLE && m_hEMA50_W1  != INVALID_HANDLE &&
            m_hEurEMA21_M5 != INVALID_HANDLE && m_hEurEMA50_M5 != INVALID_HANDLE &&
            m_hEurRSI14_H1 != INVALID_HANDLE;

        if(!ok) Print("[FeatureBuilder] ERROR: One or more indicator handles failed");
        return ok;
    }

    void Deinit()
    {
        int handles[] = {
            m_hEMA9_M5, m_hEMA21_M5, m_hEMA50_M5, m_hEMA200_M5,
            m_hATR14_M5, m_hRSI7_M5, m_hMACD_M5, m_hBB_M5,
            m_hEMA21_H1, m_hEMA50_H1, m_hEMA200_H1,
            m_hRSI14_H1, m_hMACD_H1, m_hATR14_H1,
            m_hEMA50_H4, m_hEMA200_H4, m_hRSI14_H4, m_hATR14_H4,
            m_hEMA21_W1, m_hEMA50_W1,
            m_hEurEMA21_M5, m_hEurEMA50_M5, m_hEurRSI14_H1
        };
        for(int i = 0; i < ArraySize(handles); i++)
            if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
    }

    // Build and return the JSON feature array.
    // Returns "" on critical data failure.
    string Build()
    {
        // ── Current closes (for normalisation) ─────────────────────
        double cl_m5 = CloseOf(PERIOD_M5, 0);
        double cl_h1 = CloseOf(PERIOD_H1, 0);
        double cl_h4 = CloseOf(PERIOD_H4, 0);
        double cl_w1 = CloseOf(PERIOD_W1, 0);
        if(cl_m5 == 0 || cl_h1 == 0 || cl_h4 == 0) return "";

        // ── Time encoding ───────────────────────────────────────────
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);
        double hour    = dt.hour + dt.min / 60.0;
        double pi2     = 2.0 * M_PI;
        double sinH    = MathSin(pi2 * hour / 24.0);
        double cosH    = MathCos(pi2 * hour / 24.0);
        double sinD    = MathSin(pi2 * dt.day_of_week / 5.0);
        double cosD    = MathCos(pi2 * dt.day_of_week / 5.0);
        double london  = (dt.hour >= 7 && dt.hour < 17)  ? 1.0 : 0.0;
        double overlap = (dt.hour >= 13 && dt.hour < 17) ? 1.0 : 0.0;

        // ── Carry differential (BoE rate - BoJ rate, normalised /10) ─
        // Static value: 4.75% - 0.50% = 4.25 → 0.425
        // Update this when BoE/BoJ rates change, or wire to carry_rates.txt
        double carry = 0.425;

        // ── Assemble 40 features ────────────────────────────────────
        double f[40];

        // -- M5 (f[0-11]) -------------------------------------------
        f[0]  = PctChange(PERIOD_M5);                              // m5_return
        f[1]  = (cl_m5 > 0) ? Buf(m_hEMA9_M5,   0, 0) / cl_m5 - 1 : 0;  // m5_ema9
        f[2]  = (cl_m5 > 0) ? Buf(m_hEMA21_M5,  0, 0) / cl_m5 - 1 : 0;  // m5_ema21
        f[3]  = (cl_m5 > 0) ? Buf(m_hEMA50_M5,  0, 0) / cl_m5 - 1 : 0;  // m5_ema50
        f[4]  = (cl_m5 > 0) ? Buf(m_hEMA200_M5, 0, 0) / cl_m5 - 1 : 0;  // m5_ema200
        f[5]  = (cl_m5 > 0) ? Buf(m_hATR14_M5,  0, 0) / cl_m5     : 0;  // m5_atr
        f[6]  = Buf(m_hRSI7_M5, 0, 0) / 100.0;                           // m5_rsi7
        f[7]  = MACDHist(m_hMACD_M5, PERIOD_M5);                          // m5_macd_hist
        f[8]  = BollingerPctB(m_hBB_M5, PERIOD_M5);                       // m5_bb_pctb
        f[9]  = Engulfing(PERIOD_M5);                                      // m5_engulf
        f[10] = PinBar(PERIOD_M5);                                         // m5_pin
        f[11] = VolRatio(PERIOD_M5);                                       // m5_vol_ratio

        // -- H1 (f[12-19]) ------------------------------------------
        f[12] = PctChange(PERIOD_H1);                              // h1_return
        f[13] = (cl_h1 > 0) ? Buf(m_hEMA21_H1,  0, 0) / cl_h1 - 1 : 0;  // h1_ema21
        f[14] = (cl_h1 > 0) ? Buf(m_hEMA50_H1,  0, 0) / cl_h1 - 1 : 0;  // h1_ema50
        f[15] = (cl_h1 > 0) ? Buf(m_hEMA200_H1, 0, 0) / cl_h1 - 1 : 0;  // h1_ema200
        f[16] = Buf(m_hRSI14_H1, 0, 0) / 100.0;                          // h1_rsi14
        f[17] = MACDHist(m_hMACD_H1, PERIOD_H1);                          // h1_macd_hist
        f[18] = (cl_h1 > 0) ? Buf(m_hATR14_H1, 0, 0) / cl_h1 : 0;       // h1_atr
        f[19] = VolRatio(PERIOD_H1);                                       // h1_vol_ratio

        // -- H4 (f[20-25]) ------------------------------------------
        f[20] = PctChange(PERIOD_H4);                              // h4_return
        f[21] = (cl_h4 > 0) ? Buf(m_hEMA50_H4,  0, 0) / cl_h4 - 1 : 0;  // h4_ema50
        f[22] = (cl_h4 > 0) ? Buf(m_hEMA200_H4, 0, 0) / cl_h4 - 1 : 0;  // h4_ema200
        f[23] = Buf(m_hRSI14_H4, 0, 0) / 100.0;                          // h4_rsi14
        f[24] = (cl_h4 > 0) ? Buf(m_hATR14_H4, 0, 0) / cl_h4 : 0;       // h4_atr
        f[25] = H4Structure();                                             // h4_structure

        // -- W1 (f[26-29]) ------------------------------------------
        f[26] = PctChange(PERIOD_W1, 0.10);                        // w1_return (±10%)
        f[27] = (cl_w1 > 0) ? Buf(m_hEMA21_W1, 0, 0) / cl_w1 - 1 : 0;   // w1_ema21
        f[28] = (cl_w1 > 0) ? Buf(m_hEMA50_W1, 0, 0) / cl_w1 - 1 : 0;   // w1_ema50
        {
            double e21 = Buf(m_hEMA21_W1, 0, 0);
            double e50 = Buf(m_hEMA50_W1, 0, 0);
            f[29] = (e21 > e50) ? 1.0 : (e21 < e50) ? -1.0 : 0.0;        // w1_ema_stack
        }

        // -- EUR/JPY (f[30-32]) -------------------------------------
        f[30] = PctChange("EURJPY", PERIOD_M5);                    // eurjpy_return_m5
        f[31] = EurJpyEmaAlign();                                  // eurjpy_ema_align
        f[32] = Buf(m_hEurRSI14_H1, 0, 0) / 100.0;               // eurjpy_rsi_h1

        // -- Time (f[33-38]) ----------------------------------------
        f[33] = sinH;      // time_sin_hour
        f[34] = cosH;      // time_cos_hour
        f[35] = sinD;      // time_sin_dow
        f[36] = cosD;      // time_cos_dow
        f[37] = london;    // london_session
        f[38] = overlap;   // overlap_session

        // -- Carry (f[39]) ------------------------------------------
        f[39] = carry;

        // ── Serialise to JSON array ─────────────────────────────────
        string json = "[";
        for(int i = 0; i < 40; i++)
        {
            json += StringFormat("%.8f", f[i]);
            if(i < 39) json += ",";
        }
        return json + "]";
    }
};
#endif // FEATUREBUILDER_MQH
