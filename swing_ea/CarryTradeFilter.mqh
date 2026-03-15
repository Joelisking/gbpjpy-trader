//+------------------------------------------------------------------+
//|  CarryTradeFilter.mqh                                             |
//|  BoE-BoJ carry trade differential filter for swing bias          |
//|                                                                   |
//|  Reads from config/carry_rates.txt (updated by Python feeds)     |
//|  Falls back to last known values if file unavailable             |
//|                                                                   |
//|  NOTE: Do NOT use carry differential as a hard gate.             |
//|  Feed raw values as AI features and let the model learn.         |
//|  This filter only blocks entries when differential is            |
//|  collapsing rapidly (BoJ intervention risk).                     |
//+------------------------------------------------------------------+
#ifndef SWING_CARRYTRADEFILTER_MQH
#define SWING_CARRYTRADEFILTER_MQH

struct SCarryData
{
    double boeRate;       // BoE base rate (%)
    double bojRate;       // BoJ policy rate (%)
    double differential;  // boeRate - bojRate
    bool   valid;
};

class CCarryTradeFilter
{
private:
    double m_lastBoeRate;
    double m_lastBojRate;
    double m_collapseThreshold;  // pips/month collapse rate that triggers caution

    // Read rates from file written by Python carry feed
    // File format: two lines "BOE=4.75\nBOJ=0.50\n"
    bool ReadRatesFromFile(double &boe, double &boj)
    {
        string path = TerminalInfoString(TERMINAL_DATA_PATH) +
                      "\\MQL5\\Files\\carry_rates.txt";
        int handle = FileOpen("carry_rates.txt", FILE_READ | FILE_TXT | FILE_ANSI);
        if(handle == INVALID_HANDLE)
            return false;

        bool gotBoe = false, gotBoj = false;
        while(!FileIsEnding(handle))
        {
            string line = FileReadString(handle);
            if(StringFind(line, "BOE=") == 0)
            {
                boe    = StringToDouble(StringSubstr(line, 4));
                gotBoe = true;
            }
            else if(StringFind(line, "BOJ=") == 0)
            {
                boj    = StringToDouble(StringSubstr(line, 4));
                gotBoj = true;
            }
        }
        FileClose(handle);
        return (gotBoe && gotBoj);
    }

public:
    CCarryTradeFilter(double collapseThreshold = 0.5)
        : m_lastBoeRate(4.75),   // Phase 2 defaults — Python feed overwrites
          m_lastBojRate(0.50),
          m_collapseThreshold(collapseThreshold)
    {}

    SCarryData GetCarryData()
    {
        SCarryData data;
        double boe = m_lastBoeRate;
        double boj = m_lastBojRate;

        if(ReadRatesFromFile(boe, boj))
        {
            m_lastBoeRate = boe;
            m_lastBojRate = boj;
            data.valid    = true;
        }
        else
        {
            // Use cached values — warn on first failure
            data.valid = false;
        }

        data.boeRate      = boe;
        data.bojRate      = boj;
        data.differential = boe - boj;
        return data;
    }

    // Returns raw differential as a feature value for AI (0.0 if unavailable)
    double GetDifferentialForAI()
    {
        SCarryData d = GetCarryData();
        return d.differential;
    }

    // Hard filter: block new LONG entries if differential < 1.0
    // (BoJ hiking aggressively — carry unwind risk)
    bool IsCarryFavorableLong()
    {
        SCarryData d = GetCarryData();
        if(!d.valid) return true;  // neutral if no data
        return d.differential >= 1.0;
    }

    // Carry is always somewhat favorable for SHORT (BoE cutting while BoJ holds)
    // but block if differential > 5.0 (extreme carry = crowded trade risk)
    bool IsCarryFavorableShort()
    {
        SCarryData d = GetCarryData();
        if(!d.valid) return true;
        return (d.differential <= 5.0);
    }

    // Combined check for a given direction (DIR_BULL=1, DIR_BEAR=-1)
    bool IsCarryFavorable(int direction)
    {
        if(direction == 1)  return IsCarryFavorableLong();
        if(direction == -1) return IsCarryFavorableShort();
        return false;
    }
};
#endif // SWING_CARRYTRADEFILTER_MQH
