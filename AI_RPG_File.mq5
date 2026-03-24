//+------------------------------------------------------------------+
//| AI_RPG_File.mq5 — AI Trading RPG EA (File-based, no WebRequest) |
//| Reads signal from C:\AI\signal.txt written by Python bridge     |
//+------------------------------------------------------------------+
#property copyright "AI Trading RPG"
#property version   "1.00"
#include <Trade\Trade.mqh>

input double LotSize  = 0.01;
input int    Magic    = 20240101;
input int    PollSec  = 5;
input string SigFile  = "C:\\AI\\signal.txt";
input string DoneFile = "C:\\AI\\signal_done.txt";

CTrade trade;

int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   Print("AI_RPG_File started | reading: ", SigFile);
   EventSetTimer(PollSec);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r) { EventKillTimer(); }

void OnTimer()
{
   CheckSignalFile();
}

void CheckSignalFile()
{
   // อ่าน signal.txt
   int fh = FileOpen(SigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh == INVALID_HANDLE) return;

   string content = "";
   while(!FileIsEnding(fh))
      content += FileReadString(fh) + "\n";
   FileClose(fh);

   StringTrimRight(content);
   StringTrimLeft(content);
   if(StringLen(content) < 3) return;

   // Check ว่า done แล้วหรือยัง
   int dfh = FileOpen(DoneFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(dfh != INVALID_HANDLE)
   {
      string done = FileReadString(dfh);
      FileClose(dfh);
      if(done == content) return; // already executed
   }

   // Parse: ACTION,LOT,SL,TP,TICKET
   // Example: SELL,0.01,4400.00,4350.00,abc123
   string parts[];
   int n = StringSplit(content, ',', parts);
   if(n < 4) return;

   string action = parts[0];
   double lot    = StringToDouble(parts[1]);
   double sl     = StringToDouble(parts[2]);
   double tp     = StringToDouble(parts[3]);

   if(lot <= 0) lot = LotSize;
   if(action != "BUY" && action != "SELL") return;

   Print("Signal from file: ", action, " lot=", lot, " SL=", sl, " TP=", tp);

   bool ok = false;
   if(action == "BUY")  ok = trade.Buy(lot, _Symbol, 0, sl, tp, "AI_RPG");
   if(action == "SELL") ok = trade.Sell(lot, _Symbol, 0, sl, tp, "AI_RPG");

   if(ok)
   {
      Print("EXECUTED: ", action, " @ ", trade.ResultPrice(), " #", trade.ResultOrder());
      // เขียน done file ป้องกัน execute ซ้ำ
      int wfh = FileOpen(DoneFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(wfh != INVALID_HANDLE) { FileWriteString(wfh, content); FileClose(wfh); }
   }
   else
      Print("FAILED retcode=", trade.ResultRetcode());
}
//+------------------------------------------------------------------+
