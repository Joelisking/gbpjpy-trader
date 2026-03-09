//+------------------------------------------------------------------+
//|  SocketTest.mq5                                                  |
//|  Phase 1 — Verify MT5 ↔ Python AI server communication          |
//|                                                                   |
//|  Attach to any chart. On every tick it sends a test JSON to      |
//|  the Python dummy server (server_test.py) on port 5001 and       |
//|  prints the response to the Experts tab.                         |
//|                                                                   |
//|  SUCCESS: You see "AI Response received" in Experts log.         |
//|  FAILURE: "Socket connect failed" — Python server not running.   |
//+------------------------------------------------------------------+
#property copyright "GBP/JPY Bot — Phase 1 Test"
#property version   "1.0"
#property strict

input string AI_Host     = "127.0.0.1";
input int    AI_Port     = 5001;
input int    TestInterval = 10;   // seconds between test requests

datetime g_last_test = 0;
int      g_request_count = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    Print("SocketTest EA loaded. Sending test request every ", TestInterval, " seconds.");
    Print("Python server must be running: python ai_server/server_test.py");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
    if(TimeCurrent() - g_last_test < TestInterval)
        return;

    g_last_test = TimeCurrent();
    g_request_count++;

    SendTestRequest();
}

//+------------------------------------------------------------------+
void SendTestRequest()
{
    // Build a minimal test JSON — matches the format the real EA will send
    string request = StringFormat(
        "{\"type\":\"entry_check\","
        "\"symbol\":\"GBPJPY\","
        "\"direction\":\"BUY\","
        "\"tf\":\"M1\","
        "\"request_id\":%d,"
        "\"features\":[]}",
        g_request_count
    );

    int socket = SocketCreate();
    if(socket == INVALID_HANDLE)
    {
        Print("ERROR: SocketCreate failed — error ", GetLastError());
        return;
    }

    if(!SocketConnect(socket, AI_Host, AI_Port, 3000))
    {
        Print("ERROR: Socket connect failed to ", AI_Host, ":", AI_Port,
              " — error ", GetLastError(),
              " | Is server_test.py running?");
        SocketClose(socket);
        return;
    }

    // Send request
    uchar req_bytes[];
    StringToCharArray(request, req_bytes, 0, StringLen(request));
    uint sent = SocketSend(socket, req_bytes, ArraySize(req_bytes));
    if(sent == 0)
    {
        Print("ERROR: Failed to send data — error ", GetLastError());
        SocketClose(socket);
        return;
    }

    // Read response (with 2 second timeout)
    uchar resp_bytes[];
    ArrayResize(resp_bytes, 4096);
    uint received = SocketRead(socket, resp_bytes, ArraySize(resp_bytes), 2000);
    SocketClose(socket);

    if(received == 0)
    {
        Print("ERROR: No response received — timeout or server closed connection");
        return;
    }

    string response = CharArrayToString(resp_bytes, 0, received);
    Print("=== AI Response received [Request #", g_request_count, "] ===");
    Print("Raw: ", response);

    // Parse key fields
    int entry_score = ParseIntField(response, "entry_score");
    int trend_score = ParseIntField(response, "trend_score");
    int news_risk   = ParseIntField(response, "news_risk");
    bool approve    = ParseBoolField(response, "approve");

    Print("  entry_score: ", entry_score,
          "  trend_score: ", trend_score,
          "  news_risk: ",   news_risk,
          "  approve: ",     approve ? "TRUE" : "FALSE");
    Print("=================================================");
}

//+------------------------------------------------------------------+
//| Minimal JSON field parsers (no external library needed)          |
//+------------------------------------------------------------------+
int ParseIntField(const string json, const string field)
{
    string search = "\"" + field + "\":";
    int pos = StringFind(json, search);
    if(pos < 0) return -1;
    pos += StringLen(search);
    // skip whitespace
    while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ') pos++;
    string rest = StringSubstr(json, pos, 10);
    return (int)StringToInteger(rest);
}

bool ParseBoolField(const string json, const string field)
{
    string search = "\"" + field + "\":";
    int pos = StringFind(json, search);
    if(pos < 0) return false;
    pos += StringLen(search);
    while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ') pos++;
    return StringSubstr(json, pos, 4) == "true";
}
//+------------------------------------------------------------------+
