//+------------------------------------------------------------------+
//|  AIClient.mqh                                                     |
//|  TCP socket client — sends feature vector to Python AI server    |
//|  and returns the three scores.                                    |
//|                                                                   |
//|  Works with both the dummy server (Phase 1) and full AI server   |
//|  (Phase 3) — same JSON protocol.                                  |
//+------------------------------------------------------------------+
#ifndef SWING_AICLIENT_MQH
#define SWING_AICLIENT_MQH

struct SAIResponse
{
    int  entryScore;   // 0-100
    int  trendScore;   // 0-100
    int  newsRisk;     // 0-100
    bool approve;      // entry_score >= 65 AND news_risk < 70
    string msg;
    bool   valid;      // false = server unreachable / parse error
};

class CAIClient
{
private:
    string m_host;
    int    m_port;
    int    m_timeoutMs;

    // Minimal JSON field parser — no external library required
    int ParseInt(const string &json, const string &field)
    {
        string key = "\"" + field + "\":";
        int pos = StringFind(json, key);
        if(pos < 0) return -1;
        pos += StringLen(key);
        while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ') pos++;
        return (int)StringToInteger(StringSubstr(json, pos, 8));
    }

    bool ParseBool(const string &json, const string &field)
    {
        string key = "\"" + field + "\":";
        int pos = StringFind(json, key);
        if(pos < 0) return false;
        pos += StringLen(key);
        while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ') pos++;
        return StringSubstr(json, pos, 4) == "true";
    }

public:
    CAIClient(string host = "127.0.0.1", int port = 5001, int timeoutMs = 500)
        : m_host(host), m_port(port), m_timeoutMs(timeoutMs)
    {}

    // Request entry score from Python AI server.
    // featuresJson: pre-built JSON array of features (from FeatureBuilder)
    // direction:    "BUY" or "SELL"
    SAIResponse RequestScore(const string &featuresJson, const string &direction)
    {
        SAIResponse resp;
        resp.valid      = false;
        resp.entryScore = 0;
        resp.trendScore = 0;
        resp.newsRisk   = 100;
        resp.approve    = false;

        int socket = SocketCreate();
        if(socket == INVALID_HANDLE)
        {
            Print("[AIClient] SocketCreate failed: ", GetLastError());
            return resp;
        }

        if(!SocketConnect(socket, m_host, m_port, m_timeoutMs))
        {
            PrintFormat("[AIClient] Cannot connect to %s:%d — error %d",
                        m_host, m_port, GetLastError());
            SocketClose(socket);
            return resp;
        }

        // Build request JSON
        string request = StringFormat(
            "{\"type\":\"entry_check\","
            "\"symbol\":\"%s\","
            "\"direction\":\"%s\","
            "\"tf\":\"M1\","
            "\"features\":%s}",
            _Symbol, direction, featuresJson
        );

        uchar reqBytes[];
        StringToCharArray(request, reqBytes, 0, StringLen(request));

        uint sent = SocketSend(socket, reqBytes, ArraySize(reqBytes));
        if(sent == 0)
        {
            Print("[AIClient] Send failed: ", GetLastError());
            SocketClose(socket);
            return resp;
        }

        // Read response
        uchar respBytes[];
        ArrayResize(respBytes, 4096);
        uint received = SocketRead(socket, respBytes, ArraySize(respBytes), m_timeoutMs);
        SocketClose(socket);

        if(received == 0)
        {
            Print("[AIClient] No response — server timeout");
            return resp;
        }

        string json = CharArrayToString(respBytes, 0, received);

        resp.entryScore = ParseInt(json,  "entry_score");
        resp.trendScore = ParseInt(json,  "trend_score");
        resp.newsRisk   = ParseInt(json,  "news_risk");
        resp.approve    = ParseBool(json, "approve");
        resp.valid      = (resp.entryScore >= 0);

        if(!resp.valid)
            PrintFormat("[AIClient] Parse error. Raw response: %s", StringSubstr(json, 0, 200));

        return resp;
    }

    // Safe score request — returns safe defaults if server is down
    // Caller should check resp.valid and enter SAFE MODE if false
    SAIResponse RequestScoreSafe(const string &featuresJson, const string &direction)
    {
        SAIResponse resp = RequestScore(featuresJson, direction);
        if(!resp.valid)
        {
            // Safe mode: block all entries when AI is unreachable
            resp.entryScore = 0;
            resp.trendScore = 0;
            resp.newsRisk   = 100;
            resp.approve    = false;
        }
        return resp;
    }

    // Quick health check — returns true if server responds within timeout
    bool IsServerAlive()
    {
        SAIResponse r = RequestScore("[]", "BUY");
        return r.valid;
    }
};
#endif // SWING_AICLIENT_MQH
