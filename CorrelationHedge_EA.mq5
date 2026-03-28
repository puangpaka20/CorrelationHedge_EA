//+------------------------------------------------------------------+
//|                                         CorrelationHedge_EA.mq5 |
//|                         Gold/Silver Ratio Imbalance Strategy     |
//|                         Broker: FISG | Platform: MT5 Standard    |
//+------------------------------------------------------------------+
#property copyright "CorrelationHedge EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input int    RatioPeriod         = 50;       // Lookback Period (Min:20 Max:200)
input double ZScoreEntryLevel    = 2.0;      // Z-Score Entry Threshold (Min:1.5 Max:3.0)
input double ZScoreExitLevel     = 0.5;      // Z-Score Exit Threshold (Min:0.1 Max:1.0)
input double GoldLotSize         = 0.05;     // Gold Lot Size (Fixed, Min:0.01)
input double SilverLotSize       = 0.01;     // Silver Lot Size (Fixed, Min:0.01)
input double MaxLossPerTradeUSD  = 20.0;     // Max Loss Per Trade in USD (Min:5.0)
input double MaxDDPortfolioUSD   = 50.0;     // Max Portfolio Drawdown in USD (Min:20.0)
input double MaxSpreadGold       = 50.0;     // Max Spread Gold (points)
input double MaxSpreadSilver     = 30.0;     // Max Spread Silver (points)
input int    MaxTradesPerDay     = 2;        // Max Trades Per Day (Min:1 Max:5)
input int    TradeStartHour      = 8;        // Session Open Hour (Server Time GMT+3)
input int    ForceCloseHour      = 21;       // Force Close Hour (Server Time GMT+3)
input bool   TradeOnFriday       = false;    // Allow Trading on Friday
input int    MagicNumber         = 20250101; // EA Magic Number
input int    MaxRetries          = 3;        // Max Order Retry Attempts
input int    SlippageMax         = 30;       // Max Slippage in Points

//--- Global Variables
CTrade trade;
int    TradesCountToday = 0;
static datetime lastBarTime = 0;

//--- Symbols
const string GOLD_SYM   = "XAUUSD";
const string SILVER_SYM = "XAGUSD";

//--- Setup Enum
enum HEDGE_SETUP
{
   SELL_GOLD_BUY_SILVER = 0,
   BUY_GOLD_SELL_SILVER = 1
};

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate Symbols exist in Market Watch
   if(!SymbolSelect(GOLD_SYM, true))
   {
      Print("[ERROR] ", TimeToString(TimeCurrent()), " | Cannot select ", GOLD_SYM);
      return INIT_FAILED;
   }
   if(!SymbolSelect(SILVER_SYM, true))
   {
      Print("[ERROR] ", TimeToString(TimeCurrent()), " | Cannot select ", SILVER_SYM);
      return INIT_FAILED;
   }

   //--- Validate Account Currency
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   if(currency != "USD")
   {
      Print("[ERROR] ", TimeToString(TimeCurrent()), " | Account currency must be USD, current: ", currency);
      return INIT_FAILED;
   }

   //--- Initialize CTrade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippageMax);
   trade.SetTypeFilling(ORDER_FILLING_FOK);  // Fill or Kill per broker spec

   //--- Load today's trade count from history
   TradesCountToday = LoadTradesCountToday();

   Print("[INIT]  ", TimeToString(TimeCurrent()),
         " | EA Initialized | MagicNumber:", MagicNumber,
         " | TradesCountToday:", TradesCountToday);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("[DEINIT] ", TimeToString(TimeCurrent()),
         " | EA Stopped — Positions remain open | Reason:", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only process on new M15 bar open
   datetime currentBarTime = iTime(GOLD_SYM, PERIOD_M15, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   //--- Exit Priority Order (must follow this sequence)
   CheckForceClose();
   CheckMaxLoss();
   CheckNormalExit();
   CheckEntrySignal();
}

//+------------------------------------------------------------------+
//| Calculate Z-Score of current Gold/Silver Ratio                   |
//+------------------------------------------------------------------+
double CalcZScore()
{
   //--- Validate Silver price
   double silverPrice = SymbolInfoDouble(SILVER_SYM, SYMBOL_BID);
   if(silverPrice <= 0.0)
   {
      Print("[WARN]  ", TimeToString(TimeCurrent()), " | Silver price invalid");
      return 0.0;
   }

   //--- Copy historical closes
   double goldArray[];
   double silverArray[];
   ArraySetAsSeries(goldArray,   false);
   ArraySetAsSeries(silverArray, false);

   int copiedGold   = CopyClose(GOLD_SYM,   PERIOD_H1, 1, RatioPeriod, goldArray);
   int copiedSilver = CopyClose(SILVER_SYM, PERIOD_H1, 1, RatioPeriod, silverArray);

   if(copiedGold < RatioPeriod || copiedSilver < RatioPeriod)
   {
      Print("[WARN]  ", TimeToString(TimeCurrent()),
            " | Not enough history data. Got Gold:", copiedGold,
            " Silver:", copiedSilver, " Need:", RatioPeriod);
      return 0.0;
   }

   //--- Build Ratio Array
   double ratioArray[];
   ArrayResize(ratioArray, RatioPeriod);

   for(int i = 0; i < RatioPeriod; i++)
   {
      if(silverArray[i] <= 0.0)
      {
         Print("[WARN]  ", TimeToString(TimeCurrent()),
               " | Silver historical price[", i, "] is zero or negative");
         return 0.0;
      }
      ratioArray[i] = goldArray[i] / silverArray[i];
   }

   //--- Calculate Mean
   double sum = 0.0;
   for(int i = 0; i < RatioPeriod; i++)
      sum += ratioArray[i];
   double mean = sum / RatioPeriod;

   //--- Calculate StdDev (population)
   double sumSq = 0.0;
   for(int i = 0; i < RatioPeriod; i++)
      sumSq += MathPow(ratioArray[i] - mean, 2);
   double stddev = MathSqrt(sumSq / RatioPeriod);

   if(stddev <= 0.0)
   {
      Print("[WARN]  ", TimeToString(TimeCurrent()), " | StdDev is zero — flat ratio history");
      return 0.0;
   }

   //--- Current Ratio
   double goldBid   = SymbolInfoDouble(GOLD_SYM,   SYMBOL_BID);
   double silverBid = SymbolInfoDouble(SILVER_SYM, SYMBOL_BID);

   if(silverBid <= 0.0)
   {
      Print("[WARN]  ", TimeToString(TimeCurrent()), " | Silver bid is zero");
      return 0.0;
   }

   double currentRatio = goldBid / silverBid;
   return (currentRatio - mean) / stddev;
}

//+------------------------------------------------------------------+
//| Check and execute entry signal                                    |
//+------------------------------------------------------------------+
void CheckEntrySignal()
{
   //--- Pre-Trade Checklist — every condition must pass
   if(HasOpenPosition())
   {
      Print("[SKIP]  ", TimeToString(TimeCurrent()), " | Reason: Position already open");
      return;
   }
   if(TradesCountToday >= MaxTradesPerDay)
   {
      Print("[SKIP]  ", TimeToString(TimeCurrent()),
            " | Reason: Max trades per day reached (", TradesCountToday, "/", MaxTradesPerDay, ")");
      return;
   }
   if(!IsSessionOpen())
   {
      return; // Silent — outside session hours is expected
   }
   if(IsFriday() && !TradeOnFriday)
   {
      Print("[SKIP]  ", TimeToString(TimeCurrent()), " | Reason: Friday trading disabled");
      return;
   }

   double spreadGold = GetSpread(GOLD_SYM);
   if(spreadGold > MaxSpreadGold)
   {
      Print("[SKIP]  ", TimeToString(TimeCurrent()),
            " | Reason: Gold spread too high (", DoubleToString(spreadGold, 1), " > ", MaxSpreadGold, ")");
      return;
   }

   double spreadSilver = GetSpread(SILVER_SYM);
   if(spreadSilver > MaxSpreadSilver)
   {
      Print("[SKIP]  ", TimeToString(TimeCurrent()),
            " | Reason: Silver spread too high (", DoubleToString(spreadSilver, 1), " > ", MaxSpreadSilver, ")");
      return;
   }

   double portfolioLoss = GetPortfolioFloatingLoss();
   if(portfolioLoss > MaxDDPortfolioUSD)
   {
      Print("[SKIP]  ", TimeToString(TimeCurrent()),
            " | Reason: Portfolio DD exceeded (", DoubleToString(portfolioLoss, 2), " > ", MaxDDPortfolioUSD, ")");
      return;
   }

   if(!HasEnoughMargin())
   {
      Print("[WARN]  ", TimeToString(TimeCurrent()), " | Insufficient free margin for new trade");
      return;
   }

   double zscore = CalcZScore();
   if(zscore == 0.0)
      return; // Warning already logged inside CalcZScore()

   //--- Setup A: Ratio too high → Sell Gold + Buy Silver
   if(zscore > ZScoreEntryLevel)
   {
      OpenHedgePair(SELL_GOLD_BUY_SILVER, zscore);
      return;
   }

   //--- Setup B: Ratio too low → Buy Gold + Sell Silver
   if(zscore < -ZScoreEntryLevel)
   {
      OpenHedgePair(BUY_GOLD_SELL_SILVER, zscore);
      return;
   }
}

//+------------------------------------------------------------------+
//| Open a pair of hedged positions                                   |
//+------------------------------------------------------------------+
void OpenHedgePair(HEDGE_SETUP setup, double zscore)
{
   string comment = (setup == SELL_GOLD_BUY_SILVER) ? "CHedge_A" : "CHedge_B";

   double goldBid   = SymbolInfoDouble(GOLD_SYM,   SYMBOL_BID);
   double silverBid = SymbolInfoDouble(SILVER_SYM, SYMBOL_BID);
   double ratio     = (silverBid > 0.0) ? goldBid / silverBid : 0.0;

   if(setup == SELL_GOLD_BUY_SILVER)
   {
      //--- Order A: Sell Gold
      if(!SendOrderWithRetry(GOLD_SYM, ORDER_TYPE_SELL, GoldLotSize, comment))
      {
         Print("[SKIP]  ", TimeToString(TimeCurrent()),
               " | Reason: Order A (Sell Gold) failed after ", MaxRetries, " retries");
         return;
      }

      //--- Order B: Buy Silver
      if(!SendOrderWithRetry(SILVER_SYM, ORDER_TYPE_BUY, SilverLotSize, comment))
      {
         Print("[ERROR] ", TimeToString(TimeCurrent()),
               " | Order B (Buy Silver) failed — closing Order A (Sell Gold)");
         ClosePositionBySymbol(GOLD_SYM);
         return;  // Not counted as trade
      }
   }
   else  // BUY_GOLD_SELL_SILVER
   {
      //--- Order A: Buy Gold
      if(!SendOrderWithRetry(GOLD_SYM, ORDER_TYPE_BUY, GoldLotSize, comment))
      {
         Print("[SKIP]  ", TimeToString(TimeCurrent()),
               " | Reason: Order A (Buy Gold) failed after ", MaxRetries, " retries");
         return;
      }

      //--- Order B: Sell Silver
      if(!SendOrderWithRetry(SILVER_SYM, ORDER_TYPE_SELL, SilverLotSize, comment))
      {
         Print("[ERROR] ", TimeToString(TimeCurrent()),
               " | Order B (Sell Silver) failed — closing Order A (Buy Gold)");
         ClosePositionBySymbol(GOLD_SYM);
         return;  // Not counted as trade
      }
   }

   //--- Both orders successful
   TradesCountToday++;
   Print("[OPEN]  ", TimeToString(TimeCurrent()),
         " | Setup:", comment,
         " | ZScore:", DoubleToString(zscore, 2),
         " | Ratio:", DoubleToString(ratio, 2),
         " | GoldLot:", DoubleToString(GoldLotSize, 2),
         " | SilverLot:", DoubleToString(SilverLotSize, 2));
}

//+------------------------------------------------------------------+
//| Send order with retry logic                                       |
//+------------------------------------------------------------------+
bool SendOrderWithRetry(string symbol, ENUM_ORDER_TYPE type, double lot, string comment)
{
   for(int attempt = 1; attempt <= MaxRetries; attempt++)
   {
      bool result = false;

      if(type == ORDER_TYPE_BUY)
         result = trade.Buy(lot, symbol, 0, 0, 0, comment);
      else
         result = trade.Sell(lot, symbol, 0, 0, 0, comment);

      if(result)
         return true;

      int err = GetLastError();
      Print("[RETRY] ", TimeToString(TimeCurrent()),
            " | Attempt:", attempt, "/", MaxRetries,
            " | Symbol:", symbol,
            " | Error:", err, " (", ErrorDescription(err), ")");
      ResetLastError();
      Sleep(1000);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Normal exit when Z-Score reverts to mean                         |
//+------------------------------------------------------------------+
void CheckNormalExit()
{
   if(!HasOpenPosition())
      return;

   double zscore = CalcZScore();
   if(zscore == 0.0)
      return;

   if(zscore > -ZScoreExitLevel && zscore < ZScoreExitLevel)
   {
      double pnl = GetTotalFloatingPnL();
      CloseAllPositions("Normal Exit");
      Print("[EXIT]  ", TimeToString(TimeCurrent()),
            " | Reason: Normal Exit",
            " | ZScore:", DoubleToString(zscore, 2),
            " | PnL:", DoubleToString(pnl, 2), " USD");
   }
}

//+------------------------------------------------------------------+
//| Max loss stop-out                                                 |
//+------------------------------------------------------------------+
void CheckMaxLoss()
{
   if(!HasOpenPosition())
      return;

   double floatingLoss = GetTotalFloatingPnL();

   if(floatingLoss < -MaxLossPerTradeUSD)
   {
      CloseAllPositions("Max Loss");
      TradesCountToday = MaxTradesPerDay;  // Stop trading for the day
      Print("[EXIT]  ", TimeToString(TimeCurrent()),
            " | Reason: Max Loss Cut",
            " | PnL:", DoubleToString(floatingLoss, 2), " USD");
   }
}

//+------------------------------------------------------------------+
//| Force close all positions at end of session                      |
//+------------------------------------------------------------------+
void CheckForceClose()
{
   if(!HasOpenPosition())
      return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentHour = dt.hour;

   if(currentHour >= ForceCloseHour)
   {
      double pnl = GetTotalFloatingPnL();
      CloseAllPositions("Force Close");
      Print("[EXIT]  ", TimeToString(TimeCurrent()),
            " | Reason: Force Close",
            " | PnL:", DoubleToString(pnl, 2), " USD");
   }
}

//+------------------------------------------------------------------+
//| Close all positions managed by this EA                           |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      bool success = false;
      for(int attempt = 1; attempt <= MaxRetries; attempt++)
      {
         success = trade.PositionClose(ticket);
         if(success)
            break;

         int err = GetLastError();
         Print("[RETRY] ", TimeToString(TimeCurrent()),
               " | Close attempt:", attempt, "/", MaxRetries,
               " | Ticket:", ticket,
               " | Error:", err, " (", ErrorDescription(err), ")");
         ResetLastError();
         Sleep(1000);
      }

      if(!success)
      {
         Print("[CRITICAL] ", TimeToString(TimeCurrent()),
               " | Cannot close Ticket:", ticket,
               " | Reason:", reason);
         Alert("CRITICAL: Cannot close position ", ticket, " — Manual intervention required!");
      }
   }
}

//+------------------------------------------------------------------+
//| Close position by symbol                                         |
//+------------------------------------------------------------------+
void ClosePositionBySymbol(string symbol)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      bool success = false;
      for(int attempt = 1; attempt <= MaxRetries; attempt++)
      {
         success = trade.PositionClose(ticket);
         if(success)
            break;

         int err = GetLastError();
         Print("[RETRY] ", TimeToString(TimeCurrent()),
               " | CloseBySymbol attempt:", attempt, "/", MaxRetries,
               " | Symbol:", symbol,
               " | Ticket:", ticket,
               " | Error:", err, " (", ErrorDescription(err), ")");
         ResetLastError();
         Sleep(1000);
      }

      if(!success)
      {
         Print("[CRITICAL] ", TimeToString(TimeCurrent()),
               " | Cannot close Symbol:", symbol,
               " | Ticket:", ticket);
         Alert("CRITICAL: Cannot close position ", ticket, " Symbol:", symbol);
      }
      return;  // Close only the first matching position
   }
}

//+------------------------------------------------------------------+
//| Helper: Check if any position managed by this EA is open         |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Check if current time is within trading session          |
//+------------------------------------------------------------------+
bool IsSessionOpen()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   return (hour >= TradeStartHour && hour < ForceCloseHour);
}

//+------------------------------------------------------------------+
//| Helper: Check if today is Friday                                  |
//+------------------------------------------------------------------+
bool IsFriday()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 5);
}

//+------------------------------------------------------------------+
//| Helper: Get spread in points for a symbol                        |
//+------------------------------------------------------------------+
double GetSpread(string symbol)
{
   double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(point <= 0.0)
      return 0.0;

   return (ask - bid) / point;
}

//+------------------------------------------------------------------+
//| Helper: Get total floating P&L of all EA positions               |
//+------------------------------------------------------------------+
double GetTotalFloatingPnL()
{
   double total = 0.0;
   int count    = PositionsTotal();
   for(int i = 0; i < count; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         total += PositionGetDouble(POSITION_PROFIT);
   }
   return total;
}

//+------------------------------------------------------------------+
//| Helper: Get absolute portfolio floating loss (0 if in profit)    |
//+------------------------------------------------------------------+
double GetPortfolioFloatingLoss()
{
   double pnl = GetTotalFloatingPnL();
   return (pnl < 0.0) ? MathAbs(pnl) : 0.0;
}

//+------------------------------------------------------------------+
//| Helper: Check if free margin is sufficient                       |
//+------------------------------------------------------------------+
bool HasEnoughMargin()
{
   double freeMargin  = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   double totalEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- Require at least 20% of equity as free margin buffer
   double required = totalEquity * 0.20;
   if(freeMargin <= required)
      return false;

   //--- Additionally check we have enough for the actual orders
   double marginGold   = 0.0, marginSilver = 0.0;
   double goldAsk      = SymbolInfoDouble(GOLD_SYM, SYMBOL_ASK);
   double silverAsk    = SymbolInfoDouble(SILVER_SYM, SYMBOL_ASK);

   if(!OrderCalcMargin(ORDER_TYPE_BUY, GOLD_SYM,   GoldLotSize,   goldAsk,   marginGold))
      marginGold = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, SILVER_SYM, SilverLotSize, silverAsk, marginSilver))
      marginSilver = 0.0;

   double totalRequired = marginGold + marginSilver;
   return (freeMargin > totalRequired * 1.2);  // 20% safety buffer
}

//+------------------------------------------------------------------+
//| Load today's completed trade count from deal history             |
//+------------------------------------------------------------------+
int LoadTradesCountToday()
{
   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);

   //--- Build start of today (00:00:00 server time)
   MqlDateTime dtStart;
   dtStart.year        = dtNow.year;
   dtStart.mon         = dtNow.mon;
   dtStart.day         = dtNow.day;
   dtStart.hour        = 0;
   dtStart.min         = 0;
   dtStart.sec         = 0;
   dtStart.day_of_week = 0;
   dtStart.day_of_year = 0;

   datetime startOfDay = StructToTime(dtStart);
   datetime now        = TimeCurrent();

   if(!HistorySelect(startOfDay, now))
   {
      Print("[WARN]  ", TimeToString(TimeCurrent()), " | HistorySelect failed in LoadTradesCountToday");
      return 0;
   }

   int count    = 0;
   int total    = HistoryDealsTotal();
   long magicLong = (long)MagicNumber;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != magicLong)
         continue;

      //--- Count only entry deals (opening a position)
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
         count++;
   }

   //--- Each pair = 2 entry deals, so divide by 2
   return count / 2;
}

//+------------------------------------------------------------------+
//| Helper: Human-readable error description                         |
//+------------------------------------------------------------------+
string ErrorDescription(int code)
{
   switch(code)
   {
      case 0:     return "No error";
      case 4756:  return "Trade request failed";
      case 10004: return "Requote";
      case 10006: return "Request rejected";
      case 10007: return "Request cancelled";
      case 10008: return "Order placed";
      case 10009: return "Request completed";
      case 10010: return "Request partially completed";
      case 10011: return "Request processing error";
      case 10012: return "Request cancelled by timeout";
      case 10013: return "Invalid request";
      case 10014: return "Invalid volume";
      case 10015: return "Invalid price";
      case 10016: return "Invalid stops";
      case 10017: return "Trade disabled";
      case 10018: return "Market closed";
      case 10019: return "Insufficient funds";
      case 10020: return "Prices changed";
      case 10021: return "No quotes";
      case 10022: return "Invalid order expiration";
      case 10023: return "Order state changed";
      case 10024: return "Too frequent requests";
      case 10025: return "No changes";
      case 10026: return "Autotrading disabled by server";
      case 10027: return "Autotrading disabled by client";
      case 10028: return "Request locked";
      case 10029: return "Order or position frozen";
      case 10030: return "Invalid fill type";
      case 10031: return "No connection";
      case 10032: return "Allowed only for live";
      case 10033: return "Limit of pending orders reached";
      case 10034: return "Volume limit for symbol reached";
      case 10035: return "Invalid or prohibited order type";
      case 10036: return "Position already closed";
      case 10038: return "Close volume exceeds open volume";
      case 10039: return "Close order already exists";
      case 10040: return "Limit of open positions reached";
      case 10041: return "Pending order activation rejected";
      case 10042: return "Position can only be closed by FIFO rule";
      case 10043: return "Opposite position closed";
      default:    return "Unknown error " + IntegerToString(code);
   }
}
//+------------------------------------------------------------------+
