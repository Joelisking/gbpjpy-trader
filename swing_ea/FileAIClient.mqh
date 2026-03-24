//+------------------------------------------------------------------+
//|  FileAIClient.mqh  (Swing EA)                                    |
//|  File-based AI client — fallback when broker disables sockets.  |
//|                                                                  |
//|  Protocol:                                                       |
//|    EA writes  → MQL5/Files/swing_ai_request.json                |
//|    Python reads, deletes request, writes swing_ai_response.json |
//|    EA polls   → MQL5/Files/swing_ai_response.json               |
//|    EA reads + deletes response                                   |
//|                                                                  |
//|  Uses swing_ai_* filenames so scalper and swing EAs can run     |
//|  simultaneously without colliding on the same files.            |
//+------------------------------------------------------------------+
#ifndef SWING_FILEAICLIENT_MQH
#define SWING_FILEAICLIENT_MQH

class CFileAIClient
{
private:
    int    m_timeoutMs;
    string m_requestFile;
    string m_responseFile;

    bool WriteRequest(const string &json)
    {
        int h = FileOpen(m_requestFile, FILE_WRITE|FILE_TXT|FILE_ANSI);
        if(h == INVALID_HANDLE)
        {
            PrintFormat("[SwingFileAI] Cannot write request file (error %d)", GetLastError());
            return false;
        }
        FileWriteString(h, json);
        FileClose(h);
        return true;
    }

    bool ReadResponse(string &json)
    {
        if(!FileIsExist(m_responseFile)) return false;

        int h = FileOpen(m_responseFile, FILE_READ|FILE_TXT|FILE_ANSI);
        if(h == INVALID_HANDLE) return false;

        json = "";
        while(!FileIsEnding(h))
            json += FileReadString(h);
        FileClose(h);
        FileDelete(m_responseFile);
        return StringLen(json) > 0;
    }

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
    CFileAIClient(int timeoutMs = 500)
        : m_timeoutMs(timeoutMs),
          m_requestFile("swing_ai_request.json"),
          m_responseFile("swing_ai_response.json")
    {}

    SAIResponse RequestScoreSafe(const string &featuresJson, const string &direction)
    {
        SAIResponse resp;
        resp.valid      = false;
        resp.entryScore = 0;
        resp.trendScore = 0;
        resp.newsRisk   = 100;
        resp.approve    = false;

        // Remove any stale response from a previous call
        if(FileIsExist(m_responseFile)) FileDelete(m_responseFile);

        string request = StringFormat(
            "{\"type\":\"swing_check\",\"symbol\":\"%s\","
            "\"direction\":\"%s\",\"tf\":\"H1\",\"features\":%s}",
            _Symbol, direction, featuresJson
        );

        if(!WriteRequest(request)) return resp;

        // Poll every 50ms until response appears or timeout
        int polls = MathMax(1, m_timeoutMs / 50);
        string json = "";
        for(int i = 0; i < polls; i++)
        {
            Sleep(50);
            if(ReadResponse(json)) break;
        }

        if(StringLen(json) == 0)
        {
            if(FileIsExist(m_requestFile)) FileDelete(m_requestFile);
            PrintFormat("[SwingFileAI] No response after %dms", m_timeoutMs);
            return resp;
        }

        resp.entryScore = ParseInt(json,  "entry_score");
        resp.trendScore = ParseInt(json,  "trend_score");
        resp.newsRisk   = ParseInt(json,  "news_risk");
        resp.approve    = ParseBool(json, "approve");
        resp.valid      = (resp.entryScore >= 0);

        if(!resp.valid)
            PrintFormat("[SwingFileAI] Parse error. Raw: %s", StringSubstr(json, 0, 100));

        return resp;
    }

    bool IsServerAlive()
    {
        SAIResponse r = RequestScoreSafe("[]", "BUY");
        return r.valid;
    }
};
#endif // SWING_FILEAICLIENT_MQH
