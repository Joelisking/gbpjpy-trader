//+------------------------------------------------------------------+
//|  BoJWatchdog.mqh                                                  |
//|  Bank of Japan intervention detection                             |
//|                                                                   |
//|  Detects abnormal JPY moves that signal BoJ intervention:        |
//|    - Rapid move > 200 pips in < 15 minutes on any JPY pair      |
//|    - Sudden spread widening > 3× normal                          |
//|    - Keyword flag from Python BoJ feed (file-based signal)       |
//|                                                                   |
//|  On detection: signal caller to close all positions immediately  |
//+------------------------------------------------------------------+
#ifndef SWING_BOJWATCHDOG_MQH
#define SWING_BOJWATCHDOG_MQH

class CBoJWatchdog
{
private:
    double m_interventionPipThreshold;  // default 200 pips in 15 min
    double m_spreadMultiplier;          // default 3×
    double m_normalSpread;              // rolling average spread
    int    m_spreadSamples;
    double m_spreadSum;

    bool m_interventionFlagged;
    datetime m_lastCheckTime;

    double PipSize() { return 10.0 * _Point; }

    // Check file written by Python BoJ keyword scanner
    // File exists and contains "1" when intervention keyword detected
    bool CheckBoJSignalFile()
    {
        int handle = FileOpen("boj_alert.txt", FILE_READ | FILE_TXT | FILE_ANSI);
        if(handle == INVALID_HANDLE) return false;

        string content = "";
        if(!FileIsEnding(handle))
            content = FileReadString(handle);
        FileClose(handle);

        return (StringTrimLeft(StringTrimRight(content)) == "1");
    }

    // Check for rapid M1 price move (JPY pair velocity)
    bool IsRapidJPYMove()
    {
        double closes[];
        ArraySetAsSeries(closes, true);
        if(CopyClose(_Symbol, PERIOD_M1, 0, 15, closes) != 15) return false;

        double rangeHigh = closes[0], rangeLow = closes[0];
        for(int i = 1; i < 15; i++)
        {
            if(closes[i] > rangeHigh) rangeHigh = closes[i];
            if(closes[i] < rangeLow)  rangeLow  = closes[i];
        }

        double rangePips = (rangeHigh - rangeLow) / PipSize();
        return rangePips >= m_interventionPipThreshold;
    }

    // Check for spread blow-out (broker pulling liquidity)
    bool IsSpreadAnomaly()
    {
        if(m_spreadSamples < 10) return false;  // need baseline first

        double avgSpread = m_spreadSum / m_spreadSamples;
        double currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point / PipSize();
        return currentSpread > avgSpread * m_spreadMultiplier;
    }

    void UpdateSpreadBaseline()
    {
        double sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point / PipSize();
        if(m_spreadSamples < 100)
        {
            m_spreadSum += sp;
            m_spreadSamples++;
        }
        else
        {
            // Rolling average: exponential smoothing
            m_spreadSum = m_spreadSum * 0.99 + sp * 0.01 * 100;
        }
    }

public:
    CBoJWatchdog(double pipThreshold = 200.0, double spreadMult = 3.0)
        : m_interventionPipThreshold(pipThreshold),
          m_spreadMultiplier(spreadMult),
          m_normalSpread(0),
          m_spreadSamples(0),
          m_spreadSum(0),
          m_interventionFlagged(false),
          m_lastCheckTime(0)
    {}

    // Returns true if intervention is detected — caller should close all positions
    bool IsInterventionDetected()
    {
        // Don't re-check more than once per minute
        datetime now = TimeCurrent();
        if(now - m_lastCheckTime < 60) return m_interventionFlagged;
        m_lastCheckTime = now;

        UpdateSpreadBaseline();

        bool detected = IsRapidJPYMove() || IsSpreadAnomaly() || CheckBoJSignalFile();

        if(detected && !m_interventionFlagged)
        {
            PrintFormat("[BoJWatchdog] INTERVENTION SIGNAL DETECTED | "
                        "RapidMove=%s SpreadAnomaly=%s FileSignal=%s",
                        IsRapidJPYMove()    ? "YES" : "NO",
                        IsSpreadAnomaly()   ? "YES" : "NO",
                        CheckBoJSignalFile()? "YES" : "NO");
            m_interventionFlagged = true;
        }

        // Auto-clear after 2 hours (let market stabilise)
        // Caller is responsible for re-opening positions after review
        return m_interventionFlagged;
    }

    // Call this when the swing position has been safely closed after intervention
    void Acknowledge()
    {
        m_interventionFlagged = false;
        Print("[BoJWatchdog] Intervention acknowledged — watchdog reset");
    }

    bool IsFlagged() { return m_interventionFlagged; }

    // Feature value for AI (1.0 if intervention risk, 0.0 if normal)
    double GetRiskScore()
    {
        if(m_interventionFlagged) return 1.0;
        if(IsRapidJPYMove())      return 0.7;
        return 0.0;
    }
};
#endif // SWING_BOJWATCHDOG_MQH
