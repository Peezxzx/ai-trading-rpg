//+------------------------------------------------------------------+
//| AI_RPG.mq5 — AI Trading RPG Expert Advisor v2                   |
//+------------------------------------------------------------------+
#property copyright "AI Trading RPG"
#property version   "2.00"

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
   Print("AI_RPG v2 started | VPS: ", LinuxVPS);
   SendCandles("M15", PERIOD_M15, 200);
   SendCandles("H1",  PERIOD_H1,  200);
   SendCandles("H4",  PERIOD_H4,  200);
   SendCandles("D1",  PERIOD_D1,  200);
   SendPrice();
   EventSetTimer(PollSec);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); Print("AI_RPG stopped"); }

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
      AccountInfoDouble(ACCOUNT_BALANCE),
      AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_MARGIN),
      AccountInfoDouble(ACCOUNT_FREEMARGIN),
      AccountInfoDouble(ACCOUNT_PROFIT),
      AccountInfoString(ACCOUNT_CURRENCY),
      (int)AccountInfoInteger(ACCOUNT_LEVERAGE));
   HttpPost("/api/mt5/price", body);
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
         (int)rates[i].time,rates[i].open,rates[i].high,
         rates[i].low,rates[i].close,(int)rates[i].tick_volume);
   }
   candles += "]";
   string body = StringFormat(
      "{\"symbol\":\"%s\",\"timeframe\":\"%s\",\"candles\":%s}",
      _Symbol, tfName, candles);
   HttpPost("/api/mt5/candles", body);
   Print("Candles ", tfName, ": ", copied, " bars sent");
}

//+------------------------------------------------------------------+
void CheckSignal()
{
   string resp = HttpGet("/api/mt5/signal");
   if(StringLen(resp) < 5) return;
   if(StringFind(resp,"\"signal\":null") >= 0) return;

   string action = JsonStr(resp, "action");
   if(action != "BUY" && action != "SELL") return;

   double lot = StringToDouble(JsonStr(resp,"lotSize"));
   if(lot <= 0) lot = LotSize;
   double sl = StringToDouble(JsonStr(resp,"sl"));
   double tp = StringToDouble(JsonStr(resp,"tp"));
   string ticket = JsonStr(resp,"ticket");

   Print("Signal: ",action," lot=",lot," SL=",sl," TP=",tp);

   bool ok = false;
   if(action == "BUY")  ok = trade.Buy(lot,_Symbol,0,sl,tp,"AI_RPG");
   if(action == "SELL") ok = trade.Sell(lot,_Symbol,0,sl,tp,"AI_RPG");

   if(ok)
   {
      Print("EXECUTED: ",action," @ ",trade.ResultPrice()," #",trade.ResultOrder());
      string body = StringFormat(
         "{\"ticket\":\"%s\",\"mt5Ticket\":%d,\"action\":\"%s\","
         "\"price\":%.5f,\"lot\":%.2f,\"sl\":%.5f,\"tp\":%.5f,\"time\":%d}",
         ticket,(int)trade.ResultOrder(),action,
         trade.ResultPrice(),lot,sl,tp,(int)TimeCurrent());
      HttpPost("/api/mt5/executed", body);
   }
   else Print("FAILED retcode=",trade.ResultRetcode());
}

//+------------------------------------------------------------------+
void CheckClose()
{
   string resp = HttpGet("/api/mt5/close");
   if(StringFind(resp,"null") >= 0) return;
   string ts = JsonStr(resp,"closeTicket");
   if(StringLen(ts)==0 || ts=="null") return;
   ulong t = (ulong)StringToInteger(ts);
   if(PositionSelectByTicket(t)) trade.PositionClose(t);
}

//+------------------------------------------------------------------+
string HttpGet(string path)
{
   char   data[1], res[];
   string hdrs = "X-API-Key: "+ApiKey+"\r\n";
   string rh;
   int code = WebRequest("GET", LinuxVPS+path, hdrs, "", 5000, data, 0, res, rh);
   if(code == 200) return CharArrayToString(res);
   return "";
}

//+------------------------------------------------------------------+
string HttpPost(string path, string body)
{
   char   data[], res[];
   string hdrs = "Content-Type: application/json\r\nX-API-Key: "+ApiKey+"\r\n";
   string rh;
   StringToCharArray(body, data, 0, StringLen(body));
   int code = WebRequest("POST", LinuxVPS+path, hdrs, "", 5000, data, ArraySize(data)-1, res, rh);
   if(code == 200) return CharArrayToString(res);
   return "";
}

//+------------------------------------------------------------------+
string JsonStr(string json, string key)
{
   string s = "\""+key+"\":";
   int p = StringFind(json,s);
   if(p < 0) return "";
   p += StringLen(s);
   while(p < StringLen(json) && StringGetCharacter(json,p)==' ') p++;
   bool q = (StringGetCharacter(json,p)=='"');
   if(q) p++;
   int e = p;
   if(q) while(e<StringLen(json)&&StringGetCharacter(json,e)!='"') e++;
   else  while(e<StringLen(json)&&StringGetCharacter(json,e)!=','&&StringGetCharacter(json,e)!='}') e++;
   return StringSubstr(json,p,e-p);
}
//+------------------------------------------------------------------+
