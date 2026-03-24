//+------------------------------------------------------------------+
//| AI_RPG.mq5 — AI Trading RPG Expert Advisor                      |
//| Connects to Linux VPS Oracle Fleet via HTTP API                  |
//+------------------------------------------------------------------+
#property copyright "AI Trading RPG"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input string   LinuxVPS   = "http://185.84.160.106";
input string   ApiKey     = "mt5bridge2024";
input double   LotSize    = 0.01;
input int      Deviation  = 50;
input int      Magic      = 20240101;
input int      PollSec    = 10;

CTrade trade;
datetime lastCandle = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Deviation);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   Print("AI_RPG EA started | VPS: ", LinuxVPS);
   SendCandles("M15", PERIOD_M15, 200);
   SendCandles("H1",  PERIOD_H1,  200);
   SendCandles("H4",  PERIOD_H4,  200);
   SendCandles("D1",  PERIOD_D1,  200);
   SendPrice();
   EventSetTimer(PollSec);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   SendPrice();
   CheckSignal();
   CheckClose();
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
void SendPrice()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   string body = StringFormat(
      "{\"symbol\":\"%s\",\"bid\":%.5f,\"ask\":%.5f,\"time\":%d,"
      "\"account\":{\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,"
      "\"freeMargin\":%.2f,\"profit\":%.2f,\"currency\":\"%s\",\"leverage\":%d}}",
      _Symbol, tick.bid, tick.ask, (int)tick.time,
      AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_MARGIN), AccountInfoDouble(ACCOUNT_FREEMARGIN),
      AccountInfoDouble(ACCOUNT_PROFIT), AccountInfoString(ACCOUNT_CURRENCY),
      (int)AccountInfoInteger(ACCOUNT_LEVERAGE));
   PostRequest("/api/mt5/price", body);
}

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
         rates[i].low, rates[i].close, (int)rates[i].tick_volume);
   }
   candles += "]";
   string body = StringFormat(
      "{\"symbol\":\"%s\",\"timeframe\":\"%s\",\"candles\":%s}",
      _Symbol, tfName, candles);
   string result = PostRequest("/api/mt5/candles", body);
   Print("Candles ", tfName, ": ", copied, " bars sent");
}

//+------------------------------------------------------------------+
void CheckSignal()
{
   string result = GetRequest("/api/mt5/signal");
   if(StringLen(result) < 5) return;
   if(StringFind(result, "\"signal\":null") >= 0) return;
   if(StringFind(result, "\"signal\":{}") >= 0) return;

   string action = ExtractStr(result, "action");
   if(action != "BUY" && action != "SELL") return;

   double lot = StringToDouble(ExtractStr(result, "lotSize"));
   if(lot <= 0) lot = LotSize;
   double sl = StringToDouble(ExtractStr(result, "sl"));
   double tp = StringToDouble(ExtractStr(result, "tp"));
   string ticket = ExtractStr(result, "ticket");

   Print("Signal: ", action, " lot=", lot, " SL=", sl, " TP=", tp);

   bool ok = false;
   if(action == "BUY")
      ok = trade.Buy(lot, _Symbol, 0, sl, tp, "AI_RPG");
   else
      ok = trade.Sell(lot, _Symbol, 0, sl, tp, "AI_RPG");

   if(ok)
   {
      Print("Trade EXECUTED: ", action, " @ ", trade.ResultPrice(), " #", trade.ResultOrder());
      string body = StringFormat(
         "{\"ticket\":\"%s\",\"mt5Ticket\":%d,\"action\":\"%s\","
         "\"price\":%.5f,\"lot\":%.2f,\"sl\":%.5f,\"tp\":%.5f,\"time\":%d}",
         ticket, (int)trade.ResultOrder(), action,
         trade.ResultPrice(), lot, sl, tp, (int)TimeCurrent());
      PostRequest("/api/mt5/executed", body);
   }
   else
      Print("Trade FAILED retcode=", trade.ResultRetcode());
}

//+------------------------------------------------------------------+
void CheckClose()
{
   string result = GetRequest("/api/mt5/close");
   if(StringFind(result, "null") >= 0) return;
   string ticketStr = ExtractStr(result, "closeTicket");
   if(StringLen(ticketStr) == 0 || ticketStr == "null") return;
   ulong mt5Ticket = (ulong)StringToInteger(ticketStr);
   if(PositionSelectByTicket(mt5Ticket))
      trade.PositionClose(mt5Ticket);
}

//+------------------------------------------------------------------+
string GetRequest(string endpoint)
{
   string headers = "X-API-Key: " + ApiKey + "\r\n";
   char result[]; string rh;
   int res = WebRequest("GET", LinuxVPS + endpoint, headers, 5000, NULL, result, rh);
   if(res == 200) return CharArrayToString(result);
   return "";
}

//+------------------------------------------------------------------+
string PostRequest(string endpoint, string body)
{
   string headers = "Content-Type: application/json\r\nX-API-Key: " + ApiKey + "\r\n";
   char data[], result[]; string rh;
   StringToCharArray(body, data, 0, StringLen(body));
   int res = WebRequest("POST", LinuxVPS + endpoint, headers, 5000, data, result, rh);
   if(res == 200) return CharArrayToString(result);
   return "";
}

//+------------------------------------------------------------------+
string ExtractStr(string json, string key)
{
   string search = "\"" + key + "\":";
   int start = StringFind(json, search);
   if(start < 0) return "";
   start += StringLen(search);
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ') start++;
   bool isStr = (StringGetCharacter(json, start) == '"');
   if(isStr) start++;
   int end = start;
   if(isStr)
      while(end < StringLen(json) && StringGetCharacter(json, end) != '"') end++;
   else
      while(end < StringLen(json) && StringGetCharacter(json, end) != ',' && StringGetCharacter(json, end) != '}') end++;
   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { EventKillTimer(); Print("AI_RPG EA stopped"); }
//+------------------------------------------------------------------+
