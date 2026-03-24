//+------------------------------------------------------------------+
//| AI_RPG.mq5 — AI Trading RPG Expert Advisor                      |
//| Connects to Linux VPS Oracle Fleet via HTTP API                  |
//+------------------------------------------------------------------+
#property copyright "AI Trading RPG"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Wininet.mqh>

// Input parameters
input string   LinuxVPS   = "http://185.84.160.106";  // Linux VPS URL
input string   ApiKey     = "mt5bridge2024";           // API Key
input double   LotSize    = 0.01;                      // Default lot size
input int      Deviation  = 50;                        // Max price deviation
input int      Magic      = 20240101;                  // Magic number
input int      PollSec    = 10;                        // Poll interval (seconds)

CTrade trade;
datetime lastPoll = 0;
datetime lastCandle = 0;
int      restarts = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Deviation);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   
   Print("AI_RPG EA started | VPS: ", LinuxVPS);
   
   // Send initial candles
   SendCandles("M15", PERIOD_M15, 200);
   SendCandles("H1",  PERIOD_H1,  200);
   SendCandles("H4",  PERIOD_H4,  200);
   SendCandles("D1",  PERIOD_D1,  200);
   
   // Send account info
   SendPrice();
   
   EventSetTimer(PollSec);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Timer — poll every PollSec seconds                                |
//+------------------------------------------------------------------+
void OnTimer()
{
   SendPrice();
   CheckSignal();
   CheckClose();
   
   // Refresh candles every 15 min
   if(TimeCurrent() - lastCandle >= 900)
   {
      SendCandles("M15", PERIOD_M15, 200);
      SendCandles("H1",  PERIOD_H1,  200);
      SendCandles("H4",  PERIOD_H4,  200);
      SendCandles("D1",  PERIOD_D1,  200);
      lastCandle = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Send real-time price + account to Linux VPS                      |
//+------------------------------------------------------------------+
void SendPrice()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin   = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMgn  = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   double profit   = AccountInfoDouble(ACCOUNT_PROFIT);
   
   string body = StringFormat(
      "{\"symbol\":\"%s\",\"bid\":%.5f,\"ask\":%.5f,\"time\":%d,"
      "\"account\":{\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,"
      "\"freeMargin\":%.2f,\"profit\":%.2f,\"currency\":\"%s\",\"leverage\":%d}}",
      _Symbol, tick.bid, tick.ask, (int)tick.time,
      balance, equity, margin, freeMgn, profit,
      AccountInfoString(ACCOUNT_CURRENCY),
      (int)AccountInfoInteger(ACCOUNT_LEVERAGE)
   );
   
   PostRequest("/api/mt5/price", body);
}

//+------------------------------------------------------------------+
//| Send candle data to Linux VPS                                     |
//+------------------------------------------------------------------+
void SendCandles(string tfName, ENUM_TIMEFRAMES tf, int count)
{
   MqlRates rates[];
   int copied = CopyRates(_Symbol, tf, 0, count, rates);
   if(copied <= 0) return;
   
   string candles = "[";
   for(int i = 0; i < copied; i++)
   {
      if(i > 0) candles += ",";
      candles += StringFormat(
         "{\"time\":%d,\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f,\"volume\":%d}",
         (int)rates[i].time, rates[i].open, rates[i].high,
         rates[i].low, rates[i].close, (int)rates[i].tick_volume
      );
   }
   candles += "]";
   
   string body = StringFormat(
      "{\"symbol\":\"%s\",\"timeframe\":\"%s\",\"candles\":%s}",
      _Symbol, tfName, candles
   );
   
   string result = PostRequest("/api/mt5/candles", body);
   Print("Candles ", tfName, ": sent ", copied, " bars → ", result);
}

//+------------------------------------------------------------------+
//| Check and execute trade signal                                    |
//+------------------------------------------------------------------+
void CheckSignal()
{
   string result = GetRequest("/api/mt5/signal");
   if(result == "" || StringFind(result, "null") >= 0) return;
   
   // Parse signal
   string action  = ExtractValue(result, "action");
   string lotStr  = ExtractValue(result, "lotSize");
   string slStr   = ExtractValue(result, "sl");
   string tpStr   = ExtractValue(result, "tp");
   string ticket  = ExtractValue(result, "ticket");
   
   if(action == "") return;
   
   double lot = (lotStr != "") ? StringToDouble(lotStr) : LotSize;
   double sl  = StringToDouble(slStr);
   double tp  = StringToDouble(tpStr);
   
   Print("Signal: ", action, " lot=", lot, " SL=", sl, " TP=", tp);
   
   bool ok = false;
   if(action == "BUY")
      ok = trade.Buy(lot, _Symbol, 0, sl, tp, "AI_RPG_" + StringSubstr(ticket,0,8));
   else if(action == "SELL")
      ok = trade.Sell(lot, _Symbol, 0, sl, tp, "AI_RPG_" + StringSubstr(ticket,0,8));
   
   if(ok)
   {
      Print("✅ Trade EXECUTED: ", action, " @ ", trade.ResultPrice(), " ticket=", trade.ResultOrder());
      string body = StringFormat(
         "{\"ticket\":\"%s\",\"mt5Ticket\":%d,\"action\":\"%s\","
         "\"price\":%.5f,\"lot\":%.2f,\"sl\":%.5f,\"tp\":%.5f,\"time\":%d}",
         ticket, (int)trade.ResultOrder(), action,
         trade.ResultPrice(), lot, sl, tp, (int)TimeCurrent()
      );
      PostRequest("/api/mt5/executed", body);
   }
   else
   {
      Print("❌ Trade FAILED: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Check close signal                                                |
//+------------------------------------------------------------------+
void CheckClose()
{
   string result = GetRequest("/api/mt5/close");
   if(result == "" || StringFind(result, "null") >= 0) return;
   
   string ticketStr = ExtractValue(result, "closeTicket");
   if(ticketStr == "" || ticketStr == "null") return;
   
   ulong mt5Ticket = (ulong)StringToInteger(ticketStr);
   if(PositionSelectByTicket(mt5Ticket))
   {
      trade.PositionClose(mt5Ticket);
      Print("✅ Position closed: ticket=", mt5Ticket);
   }
}

//+------------------------------------------------------------------+
//| HTTP GET request                                                  |
//+------------------------------------------------------------------+
string GetRequest(string endpoint)
{
   string headers = "X-API-Key: " + ApiKey + "\r\n";
   char   result[];
   string resultHeaders;
   int    timeout = 5000;
   
   int res = WebRequest("GET", LinuxVPS + endpoint, headers, timeout, NULL, result, resultHeaders);
   if(res == 200) return CharArrayToString(result);
   return "";
}

//+------------------------------------------------------------------+
//| HTTP POST request                                                 |
//+------------------------------------------------------------------+
string PostRequest(string endpoint, string body)
{
   string headers = "Content-Type: application/json\r\nX-API-Key: " + ApiKey + "\r\n";
   char   data[], result[];
   string resultHeaders;
   
   StringToCharArray(body, data, 0, StringLen(body));
   ArrayResize(data, ArraySize(data)-1);
   
   int res = WebRequest("POST", LinuxVPS + endpoint, headers, 5000, data, result, resultHeaders);
   if(res == 200) return CharArrayToString(result);
   return "";
}

//+------------------------------------------------------------------+
//| Extract JSON value by key                                         |
//+------------------------------------------------------------------+
string ExtractValue(string json, string key)
{
   string search = "\"" + key + "\":";
   int start = StringFind(json, search);
   if(start < 0) return "";
   
   start += StringLen(search);
   // Skip whitespace
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ') start++;
   
   bool isString = (StringGetCharacter(json, start) == '"');
   if(isString) start++;
   
   int end = start;
   if(isString)
      while(end < StringLen(json) && StringGetCharacter(json, end) != '"') end++;
   else
      while(end < StringLen(json) && StringGetCharacter(json, end) != ',' && StringGetCharacter(json, end) != '}') end++;
   
   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("AI_RPG EA stopped");
}
//+------------------------------------------------------------------+
