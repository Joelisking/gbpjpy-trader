//+------------------------------------------------------------------+
//|  CorrelationFilter.mqh                                            |
//|  EUR/JPY 5M EMA stack confirmation filter                        |
//|  GBP/JPY and EUR/JPY share 97.8% directional correlation.       |
//|  If EUR/JPY disagrees, the signal is rejected (~25% of setups). |
//+------------------------------------------------------------------+
#ifndef SCALPER_CORRELATIONFILTER_MQH
#define SCALPER_CORRELATIONFILTER_MQH

class CCorrelationFilter
{
private:
    int    m_hEMA21;
    int    m_hEMA50;

    string m_corrSymbol;
    ENUM_TIMEFRAMES m_tf;

    bool GetEMAValues(double &e21, double &e50, double &e200)
    {
        double buf21[1], buf50[1];
        if(CopyBuffer(m_hEMA21, 0, 0, 1, buf21) != 1) return false;
        if(CopyBuffer(m_hEMA50, 0, 0, 1, buf50) != 1) return false;
        e21  = buf21[0];
        e50  = buf50[0];
        e200 = 0; // unused — kept for signature compatibility
        return true;
    }

public:
    CCorrelationFilter(string corrSymbol = "EURJPY")
        : m_corrSymbol(corrSymbol),
          m_tf(PERIOD_M5)
    {}

    bool Init()
    {
        m_hEMA21 = iMA(m_corrSymbol, m_tf, 21, 0, MODE_EMA, PRICE_CLOSE);
        m_hEMA50 = iMA(m_corrSymbol, m_tf, 50, 0, MODE_EMA, PRICE_CLOSE);

        if(m_hEMA21 == INVALID_HANDLE || m_hEMA50 == INVALID_HANDLE)
        {
            PrintFormat("[CorrelationFilter] ERROR: Failed to create handles for %s", m_corrSymbol);
            return false;
        }
        return true;
    }

    void Deinit()
    {
        IndicatorRelease(m_hEMA21);
        IndicatorRelease(m_hEMA50);
    }

    // Returns DIR_BULL (1), DIR_BEAR (-1), or DIR_NONE (0)
    // Condition: EMA21 > EMA50 (bull) or EMA21 < EMA50 (bear).
    // Matches the EurJpyEmaAlign feature (f[31]) used during model training.
    int GetBias()
    {
        double e21, e50, e200;
        if(!GetEMAValues(e21, e50, e200)) return 0;

        if(e21 > e50) return  1;
        if(e21 < e50) return -1;
        return 0;
    }

    // Main gate — does EUR/JPY agree with the GBP/JPY direction?
    bool IsAgreeing(int gbpjpyDirection)
    {
        int eurjpyDir = GetBias();
        if(eurjpyDir == 0) return false;
        return (eurjpyDir == gbpjpyDirection);
    }
};
#endif // SCALPER_CORRELATIONFILTER_MQH
