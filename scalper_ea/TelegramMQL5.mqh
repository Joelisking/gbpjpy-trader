//+------------------------------------------------------------------+
//|  TelegramMQL5.mqh                                                |
//|  Sends Telegram messages from MQL5 via WebRequest.              |
//|                                                                  |
//|  REQUIRED SETUP IN MT5 (one-time):                              |
//|    Tools > Options > Expert Advisors                            |
//|    ✓ Allow WebRequest for listed URLs                           |
//|    Add URL: https://api.telegram.org                            |
//|                                                                  |
//|  If the token input is blank or still says PASTE_TOKEN_HERE,   |
//|  all sends are silently skipped — no errors.                    |
//+------------------------------------------------------------------+
#ifndef TELEGRAM_MQL5_MQH
#define TELEGRAM_MQL5_MQH

class CTelegramMQL5
{
private:
    string m_token;
    string m_chatId;
    bool   m_enabled;

    // Escape quotes and backslashes so the JSON body stays valid
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

        char   reqData[], respData[];
        string respHeaders;
        StringToCharArray(body, reqData, 0, StringLen(body));

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
            Print("[Telegram] Notifications enabled.");
        else
            Print("[Telegram] Token not configured — notifications disabled.");
    }

    bool IsEnabled() { return m_enabled; }

    bool SendStartup()
    {
        string msg = "🟢 <b>SCALPER EA ONLINE</b>\n"
                     "Symbol: GBPJPY M1\n"
                     "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendTradeEntry(string direction, double lots,
                        double entryPrice, double sl, double tp1,
                        int entryScore, int trendScore, int cascadeStep = 0)
    {
        string emoji = (direction == "BUY") ? "📈" : "📉";
        string step  = (cascadeStep > 0)
                       ? " (Cascade #" + IntegerToString(cascadeStep) + ")"
                       : "";
        string msg = emoji + " <b>TRADE ENTRY" + step + "</b>\n"
            + "Dir: " + direction + " | Lots: " + DoubleToString(lots, 2) + "\n"
            + "Price: " + DoubleToString(entryPrice, 3)
            + " | SL: " + DoubleToString(sl, 3)
            + " | TP1: " + DoubleToString(tp1, 3) + "\n"
            + "AI Entry: " + IntegerToString(entryScore)
            + " | Trend: " + IntegerToString(trendScore) + "\n"
            + "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendTradeExit(string direction, double profitPips,
                       double profitUsd, string reason)
    {
        string emoji = (profitUsd >= 0) ? "✅" : "❌";
        string pips  = (profitPips >= 0 ? "+" : "") + DoubleToString(profitPips, 1);
        string usd   = (profitUsd  >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(profitUsd), 2);
        string msg = emoji + " <b>TRADE EXIT</b>\n"
            + "Dir: " + direction + " | P&L: " + pips + " pips | " + usd + "\n"
            + "Reason: " + reason + "\n"
            + "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendAIServerDown()
    {
        string msg = "⚠️ <b>AI SERVER NOT RESPONDING</b>\n"
                     "Scalper entering SAFE MODE — no new entries.\n"
                     "Check VPS: uv run python ai_server/server.py\n"
                     "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendHeartbeat(string bias, bool aiUp, double spreadPips,
                       int sessionTrades, bool haltTriggered)
    {
        string biasEmoji = (bias == "BULL") ? "🟢" : (bias == "BEAR") ? "🔴" : "⚪";
        string msg = "🤖 <b>SCALPER HEARTBEAT</b>\n"
            + "Bias: " + biasEmoji + " " + bias + "\n"
            + "AI Server: " + (aiUp ? "✅ UP" : "❌ DOWN") + "\n"
            + "Spread: " + DoubleToString(spreadPips, 1) + " pips\n"
            + "Session Trades: " + IntegerToString(sessionTrades) + "\n"
            + (haltTriggered ? "🛑 SESSION HALTED\n" : "")
            + "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }

    bool SendRiskAlert(string level, double lossPct)
    {
        string emoji = (level == "RED") ? "🔴" : "🟡";
        string msg = emoji + " <b>RISK ALERT — " + level + "</b>\n"
            + "Session loss: " + DoubleToString(lossPct, 1) + "%\n"
            + (level == "RED" ? "SESSION HALTED — no new entries.\n" : "Approaching halt threshold.\n")
            + "Time: " + TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES) + " UTC";
        return Send(msg);
    }
};
#endif // TELEGRAM_MQL5_MQH
