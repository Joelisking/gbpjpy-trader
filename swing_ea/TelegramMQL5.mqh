//+------------------------------------------------------------------+
//|  TelegramMQL5.mqh  (Swing EA)                                    |
//|  Sends Telegram messages from the Swing EA via WebRequest.      |
//|                                                                  |
//|  REQUIRED SETUP IN MT5 (one-time):                              |
//|    Tools > Options > Expert Advisors                            |
//|    Allow WebRequest for listed URLs                             |
//|    Add URL: https://api.telegram.org                            |
//|                                                                  |
//|  If the token input is blank or still says PASTE_TOKEN_HERE,   |
//|  all sends are silently skipped — no errors.                    |
//+------------------------------------------------------------------+
#ifndef SWING_TELEGRAM_MQL5_MQH
#define SWING_TELEGRAM_MQL5_MQH

class CTelegramMQL5
{
private:
    string m_token;
    string m_chatId;
    bool   m_enabled;

    string Escape(const string &s)
    {
        string out = s;
        StringReplace(out, "\\", "\\\\");
        StringReplace(out, "\"", "\\\"");
        StringReplace(out, "\n", "\\n");
        return out;
    }

    bool Send(const string &text)
    {
        if(!m_enabled) return false;

        string url  = "https://api.telegram.org/bot" + m_token + "/sendMessage";
        string body = "{\"chat_id\":\"" + m_chatId + "\","
                       "\"text\":\""    + Escape(text) + "\","
                       "\"parse_mode\":\"HTML\"}";

        uchar  reqData[], respData[];
        string respHeaders;
        StringToCharArray(body, reqData, 0, -1, CP_UTF8);

        int code = WebRequest("POST", url,
                              "Content-Type: application/json\r\n",
                              5000, reqData, respData, respHeaders);
        if(code != 200)
        {
            PrintFormat("[Telegram] Send failed — HTTP %d (check WebRequest whitelist in MT5 options)", code);
            return false;
        }
        return true;
    }

public:
    CTelegramMQL5() : m_enabled(false) {}

    void Init(const string &token, const string &chatId)
    {
        m_token   = token;
        m_chatId  = chatId;
        m_enabled = (StringLen(token) > 20 && StringFind(token, "PASTE") < 0
                                           && StringFind(token, "YOUR_")  < 0);
        if(m_enabled)
            Print("[Telegram] Swing notifications enabled.");
        else
            Print("[Telegram] Token not configured — swing notifications disabled.");
    }

    bool IsEnabled() { return m_enabled; }

    bool SendStartup()
    {
        string msg = "🟢 <b>SWING EA ONLINE</b>\n"
                     "Symbol: GBPJPY H1\n"
                     "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendTradeEntry(string direction, double lots,
                        double entryPrice, double sl, double tp1, double tp2,
                        int trendScore, int newsRisk, double carryDiff)
    {
        string emoji = (direction == "BUY") ? "📈" : "📉";
        string msg = emoji + " <b>SWING ENTRY</b>\n"
            + "Dir: " + direction + " | Lots: " + DoubleToString(lots, 2) + "\n"
            + "Price: " + DoubleToString(entryPrice, 3)
            + " | SL: "  + DoubleToString(sl,  3) + "\n"
            + "TP1: "    + DoubleToString(tp1, 3)
            + " | TP2: " + DoubleToString(tp2, 3) + "\n"
            + "Trend: "  + IntegerToString(trendScore)
            + " | News: " + IntegerToString(newsRisk)
            + " | Carry: " + DoubleToString(carryDiff, 2) + "%\n"
            + "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendTP1Hit(string direction, double partialPips, double partialUsd)
    {
        string pips = "+" + DoubleToString(partialPips, 1);
        string usd  = "+$" + DoubleToString(partialUsd, 2);
        string msg = "✅ <b>SWING TP1 HIT</b>\n"
            + "Dir: " + direction + " | 50% closed\n"
            + "Pips: " + pips + " | P&L: " + usd + "\n"
            + "Remaining 50% trailing to TP2\n"
            + "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendTradeExit(string direction, double profitPips,
                       double profitUsd, string reason)
    {
        string emoji = (profitUsd >= 0) ? "✅" : "❌";
        string pips  = (profitPips >= 0 ? "+" : "") + DoubleToString(profitPips, 1);
        string usd   = (profitUsd  >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(profitUsd), 2);
        string msg = emoji + " <b>SWING EXIT</b>\n"
            + "Dir: " + direction + " | P&L: " + pips + " pips | " + usd + "\n"
            + "Reason: " + reason + "\n"
            + "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendAIServerDown()
    {
        string msg = "⚠️ <b>SWING EA — AI SERVER NOT RESPONDING</b>\n"
                     "Swing EA entering SAFE MODE — no new entries.\n"
                     "Check VPS: uv run python ai_server/server.py\n"
                     "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendHeartbeat(string bias, bool aiUp, double spreadPips,
                       int weeklyTrades, bool haltTriggered, bool positionOpen)
    {
        string biasEmoji = (bias == "BULL") ? "🟢" : (bias == "BEAR") ? "🔴" : "⚪";
        string posStr    = positionOpen ? "📈 OPEN" : "FLAT";
        string msg = "🤖 <b>SWING HEARTBEAT</b>\n"
            + "Bias (4H): " + biasEmoji + " " + bias + "\n"
            + "Position: " + posStr + "\n"
            + "AI Server: " + (aiUp ? "✅ UP" : "❌ DOWN") + "\n"
            + "Spread: " + DoubleToString(spreadPips, 1) + " pips\n"
            + "Weekly Trades: " + IntegerToString(weeklyTrades) + "\n"
            + (haltTriggered ? "🛑 SESSION HALTED\n" : "")
            + "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendBoJAlert()
    {
        string msg = "⚠️ <b>BOJ INTERVENTION DETECTED</b>\n"
                     "Swing position closed — BoJ watchdog triggered.\n"
                     "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }
};
#endif // SWING_TELEGRAM_MQL5_MQH
