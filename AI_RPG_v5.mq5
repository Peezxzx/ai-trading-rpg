//+------------------------------------------------------------------+
//| AI_RPG_v5.mq5 — AI Trading RPG EA                               |
//+------------------------------------------------------------------+
#property copyright "AI Trading RPG"
#property version   "5.00"
#include <Trade\Trade.mqh>
#include <Files\FileTxt.mqh>

input double LotSize = 0.01;
input int    Magic   = 20240101;
input int    PollSec = 5;

CTrade trade;
string SigFile  = "C:\\AI\\signal.txt";
string DoneFile = "C:\\AI\\signal_done.txt";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   EventSetTimer(PollSec);
   Print("AI_RPG v5 ready");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r) { EventKillTimer(); }

//+------------------------------------------------------------------+
void OnTimer() { CheckFile(); }

//+------------------------------------------------------------------+
void CheckFile()
{
   // อ่าน signal file
   if(!FileIsExist(SigFile, 0)) return;

   int fh = FileOpen(SigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh == INVALID_HANDLE) return;

   string sig = "";
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      if(StringLen(line) > 0) sig = line;
   }
   FileClose(fh);

   if(StringLen(sig) < 5) return;

   // เช็ค done
   if(FileIsExist(DoneFile, 0))
   {
      int dh = FileOpen(DoneFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(dh != INVALID_HANDLE)
      {
         string done = FileReadString(dh);
         FileClose(dh);
         if(done == sig) return;
      }
   }

   // Parse: BUY,0.01,4300.00,4400.00
   //         or SELL,0.01,4400.00,4300.00
   string p[];
   int cnt = StringSplit(sig, StringGetCharacter(",", 0), p);
   if(cnt < 3) return;

   string dir = p[0];
   double lot = StringToDouble(p[1]);
   double sl  = StringToDouble(p[2]);
   double tp  = (cnt >= 4) ? StringToDouble(p[3]) : 0;

   if(lot <= 0) lot = LotSize;
   if(dir != "BUY" && dir != "SELL") return;

   Print("Signal: ", dir, " lot=", lot, " SL=", sl, " TP=", tp);

   bool ok = false;
   if(dir == "BUY")  ok = trade.Buy(lot, _Symbol, 0, sl, tp, "AI_RPG");
   if(dir == "SELL") ok = trade.Sell(lot, _Symbol, 0, sl, tp, "AI_RPG");

   if(ok)
   {
      Print("DONE: ", dir, " @", trade.ResultPrice(), " #", trade.ResultOrder());
      // mark done
      int wh = FileOpen(DoneFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(wh != INVALID_HANDLE) { FileWriteString(wh, sig); FileClose(wh); }
   }
   else Print("FAIL: retcode=", trade.ResultRetcode());
}
//+------------------------------------------------------------------+
