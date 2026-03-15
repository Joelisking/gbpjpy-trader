//+------------------------------------------------------------------+
//|  FeatureBuilder.mqh                                               |
//|  Builds the 30-feature JSON array sent to the Python AI server   |
//|                                                                   |
//|  Phase 2: sends a simplified single-bar feature set              |
//|  Phase 3: full 200-step sequence will be built here              |
//|                                                                   |
//|  Features match the training data exactly — order matters.       |
//+------------------------------------------------------------------+
#ifndef SCALPER_FEATUREBUILDER_MQH
#define SCALPER_FEATUREBUILDER_MQH

class CFeatureBuilder
{
private:
    // Indicator handles — built on M1 and M5
    int m_hEMA8_M1,  m_hEMA21_M1,  m_hEMA50_M1,  m_hEMA200_M1;
    int m_hEMA8_M5,  m_hEMA21_M5,  m_hEMA50_M5,  m_hEMA200_M5;
    int m_hATR14_M1, m_hATR14_M5;
    int m_hRSI7_M1,  m_hRSI14_M1;
    int m_hRSI14_M5;
    int m_hMACD_M1,  m_hMACD_M5;
    int m_hBB_M1;    // Bollinger Bands
    int m_hEMA21_EURJPY_M5;

    double m_pipSize;

    double SafeBuffer(int handle, int bufIdx, int shift)
    {
        double buf[1];
        if(CopyBuffer(handle, bufIdx, shift, 1, buf) != 1) return 0.0;
        return buf[0];
    }

    double SafeClose(ENUM_TIMEFRAMES tf, int shift)
    {
        double c[1];
        ArraySetAsSeries(c, true);
        if(CopyClose(_Symbol, tf, shift, 1, c) != 1) return 0.0;
        return c[0];
    }

    // Encode candle pattern as numeric value
    // Bullish engulfing=+2, Hammer=+1, Doji=0, Bearish engulfing=-2, Shooting star=-1
    double EncodeCandlePattern(ENUM_TIMEFRAMES tf, int shift)
    {
        double o[], h[], l[], c[];
        ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
        ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
        if(CopyOpen (_Symbol, tf, shift, 1, o) != 1) return 0;
        if(CopyHigh (_Symbol, tf, shift, 1, h) != 1) return 0;
        if(CopyLow  (_Symbol, tf, shift, 1, l) != 1) return 0;
        if(CopyClose(_Symbol, tf, shift, 1, c) != 1) return 0;

        double body  = MathAbs(c[0] - o[0]);
        double range = h[0] - l[0];
        if(range <= 0) return 0;

        bool bull = c[0] > o[0];
        double bodyRatio = body / range;
        double lowerWick = MathMin(o[0], c[0]) - l[0];
        double upperWick = h[0] - MathMax(o[0], c[0]);

        if(bodyRatio < 0.1 && lowerWick < m_pipSize && upperWick < m_pipSize)
            return 0; // Doji

        if(bull && bodyRatio > 0.6) return 2;  // Bullish engulfing
        if(!bull && bodyRatio > 0.6) return -2; // Bearish engulfing

        if(bull && lowerWick >= 2 * body) return 1;   // Hammer
        if(!bull && upperWick >= 2 * body) return -1; // Shooting star

        return 0;
    }

    // Sin/cos encoding for cyclical time features
    void EncodeTime(int hour, int dow, double &sinH, double &cosH, double &sinD, double &cosD)
    {
        double pi2 = 2.0 * M_PI;
        sinH = MathSin(pi2 * hour / 24.0);
        cosH = MathCos(pi2 * hour / 24.0);
        sinD = MathSin(pi2 * dow  / 5.0);
        cosD = MathCos(pi2 * dow  / 5.0);
    }

    double GetVolumeRatio(ENUM_TIMEFRAMES tf, int currentShift = 0, int lookback = 20)
    {
        long vol[];
        ArraySetAsSeries(vol, true);
        if(CopyTickVolume(_Symbol, tf, currentShift, lookback + 1, vol) != lookback + 1) return 1.0;
        double avg = 0;
        for(int i = 1; i <= lookback; i++) avg += (double)vol[i];
        avg /= lookback;
        return (avg > 0) ? (double)vol[0] / avg : 1.0;
    }

public:
    CFeatureBuilder()
    {
        m_pipSize = 10.0 * _Point;
    }

    bool Init()
    {
        m_hEMA8_M1   = iMA(_Symbol, PERIOD_M1, 8,   0, MODE_EMA, PRICE_CLOSE);
        m_hEMA21_M1  = iMA(_Symbol, PERIOD_M1, 21,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA50_M1  = iMA(_Symbol, PERIOD_M1, 50,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA200_M1 = iMA(_Symbol, PERIOD_M1, 200, 0, MODE_EMA, PRICE_CLOSE);
        m_hEMA8_M5   = iMA(_Symbol, PERIOD_M5, 8,   0, MODE_EMA, PRICE_CLOSE);
        m_hEMA21_M5  = iMA(_Symbol, PERIOD_M5, 21,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA50_M5  = iMA(_Symbol, PERIOD_M5, 50,  0, MODE_EMA, PRICE_CLOSE);
        m_hEMA200_M5 = iMA(_Symbol, PERIOD_M5, 200, 0, MODE_EMA, PRICE_CLOSE);
        m_hATR14_M1  = iATR(_Symbol, PERIOD_M1, 14);
        m_hATR14_M5  = iATR(_Symbol, PERIOD_M5, 14);
        m_hRSI7_M1   = iRSI(_Symbol, PERIOD_M1, 7,  PRICE_CLOSE);
        m_hRSI14_M1  = iRSI(_Symbol, PERIOD_M1, 14, PRICE_CLOSE);
        m_hRSI14_M5  = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
        m_hMACD_M1   = iMACD(_Symbol, PERIOD_M1, 12, 26, 9, PRICE_CLOSE);
        m_hMACD_M5   = iMACD(_Symbol, PERIOD_M5, 12, 26, 9, PRICE_CLOSE);
        m_hBB_M1     = iBands(_Symbol, PERIOD_M1, 20, 0, 2.0, PRICE_CLOSE);
        m_hEMA21_EURJPY_M5 = iMA("EURJPY", PERIOD_M5, 21, 0, MODE_EMA, PRICE_CLOSE);

        bool ok = (m_hEMA8_M1 != INVALID_HANDLE && m_hEMA21_M1 != INVALID_HANDLE
                && m_hEMA50_M1 != INVALID_HANDLE && m_hEMA200_M1 != INVALID_HANDLE
                && m_hATR14_M1 != INVALID_HANDLE && m_hRSI7_M1   != INVALID_HANDLE
                && m_hMACD_M1  != INVALID_HANDLE && m_hBB_M1     != INVALID_HANDLE);

        if(!ok) Print("[FeatureBuilder] ERROR: Failed to create one or more indicator handles");
        return ok;
    }

    void Deinit()
    {
        int handles[] = {
            m_hEMA8_M1, m_hEMA21_M1, m_hEMA50_M1, m_hEMA200_M1,
            m_hEMA8_M5, m_hEMA21_M5, m_hEMA50_M5, m_hEMA200_M5,
            m_hATR14_M1, m_hATR14_M5, m_hRSI7_M1, m_hRSI14_M1,
            m_hRSI14_M5, m_hMACD_M1, m_hMACD_M5, m_hBB_M1,
            m_hEMA21_EURJPY_M5
        };
        for(int i = 0; i < ArraySize(handles); i++)
            if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
    }

    // Build the feature JSON array for the AI server.
    // Phase 2: returns a flat array of current-bar features.
    // Phase 3: will expand to 200-step sequence.
    string Build()
    {
        double close1M = SafeClose(PERIOD_M1, 0);
        double close5M = SafeClose(PERIOD_M5, 0);

        double ema21_1M  = SafeBuffer(m_hEMA21_M1,  0, 0);
        double ema50_1M  = SafeBuffer(m_hEMA50_M1,  0, 0);
        double ema200_1M = SafeBuffer(m_hEMA200_M1, 0, 0);
        double ema21_5M  = SafeBuffer(m_hEMA21_M5,  0, 0);
        double ema50_5M  = SafeBuffer(m_hEMA50_M5,  0, 0);
        double ema200_5M = SafeBuffer(m_hEMA200_M5, 0, 0);
        double atr_1M    = SafeBuffer(m_hATR14_M1,  0, 0);
        double atr_5M    = SafeBuffer(m_hATR14_M5,  0, 0);
        double rsi7_1M   = SafeBuffer(m_hRSI7_M1,   0, 0);
        double rsi14_1M  = SafeBuffer(m_hRSI14_M1,  0, 0);
        double rsi14_5M  = SafeBuffer(m_hRSI14_M5,  0, 0);
        double macd_1M   = SafeBuffer(m_hMACD_M1,   2, 0); // histogram
        double macd_5M   = SafeBuffer(m_hMACD_M5,   2, 0);
        double bb_upper  = SafeBuffer(m_hBB_M1,     1, 0);
        double bb_lower  = SafeBuffer(m_hBB_M1,     2, 0);
        double bb_mid    = SafeBuffer(m_hBB_M1,     0, 0);

        // Derived
        double ema21_dist_pct = ema21_1M > 0 ? (close1M - ema21_1M) / ema21_1M * 100 : 0;
        double bb_width       = bb_upper - bb_lower;
        double bb_pos         = (bb_width > 0) ? (close1M - bb_lower) / bb_width : 0.5;

        double candlePattern = EncodeCandlePattern(PERIOD_M1, 1);

        // Time encoding
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);
        double sinH, cosH, sinD, cosD;
        EncodeTime(dt.hour, dt.day_of_week, sinH, cosH, sinD, cosD);

        // Volume ratio
        double volRatio1M = GetVolumeRatio(PERIOD_M1);

        // Spread as ratio to 20-bar average (proxy)
        long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
        double spread  = spreadPts * _Point;

        // EUR/JPY EMA21 direction on 5M (+1, -1, 0)
        double eurjpy_price = SymbolInfoDouble("EURJPY", SYMBOL_BID);
        double eurjpy_ema21 = SafeBuffer(m_hEMA21_EURJPY_M5, 0, 0);
        double eurjpy_dir   = (eurjpy_price > eurjpy_ema21) ? 1.0 :
                              (eurjpy_price < eurjpy_ema21) ? -1.0 : 0.0;

        // London open spike flag (07:55-08:15 UTC)
        bool londonSpike = (dt.hour == 7 && dt.min >= 55) || (dt.hour == 8 && dt.min <= 15);

        // Assemble 30-feature array (order must match Python training pipeline)
        double f[30];
        f[0]  = close1M;
        f[1]  = ema21_1M;
        f[2]  = ema50_1M;
        f[3]  = ema200_1M;
        f[4]  = ema21_5M;
        f[5]  = ema50_5M;
        f[6]  = ema200_5M;
        f[7]  = atr_1M / m_pipSize;        // in pips
        f[8]  = atr_5M / m_pipSize;
        f[9]  = rsi7_1M;
        f[10] = rsi14_1M;
        f[11] = rsi14_5M;
        f[12] = macd_1M;
        f[13] = macd_5M;
        f[14] = bb_width / m_pipSize;      // Bollinger bandwidth in pips
        f[15] = bb_pos;                    // 0=at lower, 1=at upper band
        f[16] = candlePattern;
        f[17] = ema21_dist_pct;            // % distance price to EMA21
        f[18] = sinH;
        f[19] = cosH;
        f[20] = sinD;
        f[21] = cosD;
        f[22] = spread / m_pipSize;        // spread in pips
        f[23] = volRatio1M;
        f[24] = eurjpy_dir;
        f[25] = (double)(close1M > ema21_1M ? 1 : 0);  // price above EMA21 flag
        f[26] = (double)(close5M > ema200_5M ? 1 : 0); // price above 5M 200 EMA
        f[27] = (double)londonSpike;
        f[28] = (double)dt.hour;
        f[29] = (double)dt.day_of_week;

        // Serialise to JSON array
        string json = "[";
        for(int i = 0; i < 30; i++)
        {
            json += StringFormat("%.6f", f[i]);
            if(i < 29) json += ",";
        }
        json += "]";
        return json;
    }
};
#endif // SCALPER_FEATUREBUILDER_MQH
