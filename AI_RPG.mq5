//+------------------------------------------------------------------+
//| AI_RPG.mq5 — AI Trading RPG Expert Advisor v3                   |
//| Fixed WebRequest for MT5 5.x                                     |
//+------------------------------------------------------------------+
#property copyright "AI Trading RPG"
#property version   "3.00"
#include <Trade\Trade.mqh>

input string   LinuxVPS = "http://185.84.160.106";
input string   ApiKey   = "mt5bridge2024";
input double   LotSize  = 0.01;
input int      Magic    = 20240101;
input int      PollSec  = 10;

CTrade trade;
datetime lastCandle = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   Print("AI_RPG v3 started");
   SendCandles("M15",PERIOD_M15,200);
   SendCandles("H1",PERIOD_H1,200);
   SendCandles("H4",PERIOD_H4,200);
   SendCandles("D1",PERIOD_D1,200);
   SendPrice();
   EventSetTimer(PollSec);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r){EventKillTimer();}

void OnTimer()
{
   SendPrice();
   CheckSignal();
   CheckClose();
   if(TimeCurrent()-lastCandle>=900)
   {
      SendCandles("M15",PERIOD_M15,200);
      SendCandles("H1",PERIOD_H1,200);
      SendCandles("H4",PERIOD_H4,200);
      SendCandles("D1",PERIOD_D1,200);
      lastCandle=TimeCurrent();
   }
}

void SendPrice()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return;
   string b=StringFormat(
      "{\"symbol\":\"%s\",\"bid\":%.5f,\"ask\":%.5f,\"time\":%d,"
      "\"account\":{\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,"
      "\"freeMargin\":%.2f,\"profit\":%.2f}}",
      _Symbol,t.bid,t.ask,(int)t.time,
      AccountInfoDouble(ACCOUNT_BALANCE),
      AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_MARGIN),
      AccountInfoDouble(ACCOUNT_MARGIN_FREE),
      AccountInfoDouble(ACCOUNT_PROFIT));
   DoPost("/api/mt5/price",b);
}

void SendCandles(string name,ENUM_TIMEFRAMES tf,int cnt)
{
   MqlRates r[];
   int n=CopyRates(_Symbol,tf,0,cnt,r);
   if(n<=0) return;
   string s="[";
   for(int i=0;i<n;i++)
   {
      if(i>0)s+=",";
      s+=StringFormat("{\"time\":%d,\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f,\"volume\":%d}",
         (int)r[i].time,r[i].open,r[i].high,r[i].low,r[i].close,(int)r[i].tick_volume);
   }
   s+="]";
   DoPost("/api/mt5/candles",StringFormat("{\"symbol\":\"%s\",\"timeframe\":\"%s\",\"candles\":%s}",_Symbol,name,s));
   Print("Candles ",name,": ",n," bars sent");
}

void CheckSignal()
{
   string resp=DoGet("/api/mt5/signal");
   if(StringLen(resp)<5||StringFind(resp,"\"signal\":null")>=0) return;
   string action=JS(resp,"action");
   if(action!="BUY"&&action!="SELL") return;
   double lot=StringToDouble(JS(resp,"lotSize"));
   if(lot<=0)lot=LotSize;
   double sl=StringToDouble(JS(resp,"sl"));
   double tp=StringToDouble(JS(resp,"tp"));
   string ticket=JS(resp,"ticket");
   Print("Signal: ",action," lot=",lot," SL=",sl," TP=",tp);
   bool ok=false;
   if(action=="BUY")  ok=trade.Buy(lot,_Symbol,0,sl,tp,"AI_RPG");
   if(action=="SELL") ok=trade.Sell(lot,_Symbol,0,sl,tp,"AI_RPG");
   if(ok)
   {
      Print("EXECUTED: ",action," @ ",trade.ResultPrice()," #",trade.ResultOrder());
      DoPost("/api/mt5/executed",StringFormat(
         "{\"ticket\":\"%s\",\"mt5Ticket\":%d,\"action\":\"%s\",\"price\":%.5f,\"lot\":%.2f,\"time\":%d}",
         ticket,(int)trade.ResultOrder(),action,trade.ResultPrice(),lot,(int)TimeCurrent()));
   }
   else Print("FAILED retcode=",trade.ResultRetcode());
}

void CheckClose()
{
   string r=DoGet("/api/mt5/close");
   string ts=JS(r,"closeTicket");
   if(StringLen(ts)==0||ts=="null") return;
   ulong t=(ulong)StringToInteger(ts);
   if(PositionSelectByTicket(t)) trade.PositionClose(t);
}

string DoGet(string path)
{
   string url=LinuxVPS+path;
   string headers="X-API-Key: "+ApiKey+"\r\n";
   char   post[],result[];
   string rh;
   ResetLastError();
   int code=WebRequest("GET",url,headers,5000,post,result,rh);
   if(code==200) return CharArrayToString(result);
   Print("GET error ",code," ",GetLastError()," path=",path);
   return "";
}

string DoPost(string path,string body)
{
   string url=LinuxVPS+path;
   string headers="Content-Type: application/json\r\nX-API-Key: "+ApiKey+"\r\n";
   char   post[],result[];
   string rh;
   StringToCharArray(body,post,0,StringLen(body));
   ResetLastError();
   int code=WebRequest("POST",url,headers,5000,post,result,rh);
   if(code==200) return CharArrayToString(result);
   Print("POST error ",code," ",GetLastError()," path=",path);
   return "";
}

string JS(string j,string k)
{
   string s="\""+k+"\":";
   int p=StringFind(j,s); if(p<0)return "";
   p+=StringLen(s);
   while(p<StringLen(j)&&StringGetCharacter(j,p)==' ')p++;
   bool q=StringGetCharacter(j,p)=='"'; if(q)p++;
   int e=p;
   if(q) while(e<StringLen(j)&&StringGetCharacter(j,e)!='"')e++;
   else  while(e<StringLen(j)&&StringGetCharacter(j,e)!=','&&StringGetCharacter(j,e)!='}')e++;
   return StringSubstr(j,p,e-p);
}
