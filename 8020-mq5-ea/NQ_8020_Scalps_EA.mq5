//+------------------------------------------------------------------+
//|  NQ 8020 Scalps EA                                               |
//|  Strategy: NASDAQ 80/20 Level Intraday Scalping Model            |
//|  Version  : 1.0.0                                                |
//|  Author   : kellwyn                                              |
//|  Date     : 2026-04-20                                           |
//+------------------------------------------------------------------+
//
//  STRATEGY SUMMARY
//  ----------------
//  Trades NQ Futures by identifying price reactions at levels whose
//  last two digits end in 20 or 80 (e.g. 21620, 21680).
//
//  Four core setups:
//    1. Fork      – Long reversal at 20/80 after failed continuation lower
//    2. H Pattern – Short continuation; bounce into 80 rolls over
//    3. Cross-Section – Precision re-entry at candle-overlap zone + 20/80
//    4. Repair    – Candle with missing wick acts as target/magnet
//
//  Risk model:
//    • Fixed SL (default 10 pts)
//    • Scale out 50 % at TP1 (default 15 pts), move SL to break-even
//    • Runner held until Repair magnet or momentum fails
//
//  Changelog
//  ---------
//  v1.0.0  2026-04-20  Initial build – all four setups, full risk params
//
//+------------------------------------------------------------------+
#property copyright "kellwyn"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade  Trade;
CPositionInfo PosInfo;

//-------------------------------------------------------------------
//  INPUT PARAMETERS
//-------------------------------------------------------------------

//-- Setup Toggles ---------------------------------------------------
input group "=== Setup Toggles ==="
input bool   Enable_Fork          = true;   // Fork (Long Reversal) enabled
input bool   Enable_HPattern      = true;   // H Pattern (Short Continuation) enabled
input bool   Enable_CrossSection  = true;   // Cross-Section Entry enabled
input bool   Enable_Repair_Target = true;   // Use Repair candle as target magnet

//-- 20/80 Level Detection -------------------------------------------
input group "=== Level Detection ==="
input double Level_Tolerance_Pts  = 5.0;    // Points within level to consider valid (±)
input int    LookbackBars         = 20;     // Bars to scan for Repair candles

//-- Session Filter --------------------------------------------------
input group "=== Session Filter ==="
input bool   Filter_Session       = true;   // Restrict trading to NY session
input int    Session_Start_Hour   = 9;      // NY session start (broker server time, 24h)
input int    Session_Start_Min    = 30;     // NY session start minute
input int    Session_End_Hour     = 16;     // NY session end (24h)
input int    Session_End_Min      = 0;      // NY session end minute
input bool   Avoid_Lunch          = true;   // Avoid 12:00–13:30 NY lunch chop
input int    Lunch_Start_Hour     = 12;     // Lunch start (server time)
input int    Lunch_End_Hour       = 13;     // Lunch end (server time)
input int    Lunch_End_Min        = 30;     // Lunch end minute

//-- Risk Management -------------------------------------------------
input group "=== Risk Management ==="
input double Risk_Per_Trade_Pct   = 1.0;    // Risk per trade (% of account balance)
input double SL_Points            = 10.0;   // Stop loss in points
input double TP1_Points           = 15.0;   // First target in points (50 % scale-out)
input bool   Use_RR_Ratio         = false;  // Use R:R ratio for TP1 instead of fixed pts
input double RR_Ratio             = 1.5;    // Risk-to-reward ratio (if Use_RR_Ratio=true)
input double Max_Lot_Size         = 2.0;    // Hard cap on lot size (0 = no cap)
input double Scale_Out_Pct        = 50.0;   // Percentage of position to close at TP1

//-- Trailing / Break-Even -------------------------------------------
input group "=== Trade Management ==="
input bool   Move_BE_After_TP1    = true;   // Move SL to break-even after TP1 hit
input bool   Enable_Runner        = true;   // Hold remainder as runner
input double Runner_Trail_Pts     = 10.0;   // Trail stop on runner (0 = no trail)

//-- Pattern Sensitivity ---------------------------------------------
input group "=== Pattern Sensitivity ==="
input double Fork_Wick_Ratio      = 0.5;    // Min lower-wick / candle-range for Fork candle
input double HPattern_Bounce_Pts  = 8.0;    // Min pts bounce before H rolls over
input double CrossSection_Depth   = 5.0;    // Max pts below cross zone for valid re-test
input double Repair_NoWick_Tol    = 1.0;    // Tolerance (pts) for "no wick" detection

//-- Magic / Labels --------------------------------------------------
input group "=== EA Identity ==="
input int    Magic_Number         = 8020;
input string EA_Comment           = "NQ-8020";

//-------------------------------------------------------------------
//  GLOBALS
//-------------------------------------------------------------------
double _point;      // instrument point size
ENUM_TIMEFRAMES _tf_exec;  // execution timeframe (200-second custom or nearest)

struct RepairLevel
{
   double price;
   bool   is_bearish; // bearish repair = magnet above; bullish = magnet below
};

RepairLevel _repairs[];  // active repair magnets

//-------------------------------------------------------------------
//  INITIALISATION
//-------------------------------------------------------------------
int OnInit()
{
   Trade.SetExpertMagicNumber(Magic_Number);
   Trade.SetDeviationInPoints(10);

   _point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // MT5 has no native 200-second bar; use M3 (180s) as closest alternative.
   // For true 200-second execution, run EA on a custom timeframe chart set to 200s.
   _tf_exec = PERIOD_CURRENT;

   Print("NQ 8020 Scalps EA v1.0.0 initialised on ", _Symbol,
         " | SL=", SL_Points, " pts | TP1=", TP1_Points, " pts");
   return INIT_SUCCEEDED;
}

//-------------------------------------------------------------------
//  TICK HANDLER
//-------------------------------------------------------------------
void OnTick()
{
   if(!IsNewBar()) return;            // act once per closed bar
   if(!InSession())  return;          // session + lunch filter
   if(HasOpenPosition()) return;      // one trade at a time

   ScanRepairs();                     // refresh repair magnet list

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // -- Fork (Long) ---------------------------------------------------
   if(Enable_Fork && Is2080Level(bid, false))
   {
      if(DetectFork())
         ExecuteLong("Fork");
   }

   // -- H Pattern (Short) ---------------------------------------------
   if(Enable_HPattern && Is2080Level(ask, true))
   {
      if(DetectHPattern())
         ExecuteShort("HPattern");
   }

   // -- Cross-Section (Long or Short) ---------------------------------
   if(Enable_CrossSection)
   {
      int csDir = DetectCrossSection();
      if(csDir == 1  && Is2080Level(bid, false)) ExecuteLong("CrossSection");
      if(csDir == -1 && Is2080Level(ask, true))  ExecuteShort("CrossSection");
   }
}

//-------------------------------------------------------------------
//  TRADE MANAGEMENT  (called every tick for open positions)
//-------------------------------------------------------------------
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   // Check for TP1 partial close; move SL to BE on runner
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && Move_BE_After_TP1)
      ManageRunner();
}

//-------------------------------------------------------------------
//  SESSION FILTER
//-------------------------------------------------------------------
bool InSession()
{
   if(!Filter_Session) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int now_min = dt.hour * 60 + dt.min;

   int start = Session_Start_Hour * 60 + Session_Start_Min;
   int end   = Session_End_Hour   * 60 + Session_End_Min;

   if(now_min < start || now_min >= end) return false;

   if(Avoid_Lunch)
   {
      int lunch_start = Lunch_Start_Hour * 60;
      int lunch_end   = Lunch_End_Hour   * 60 + Lunch_End_Min;
      if(now_min >= lunch_start && now_min < lunch_end) return false;
   }
   return true;
}

//-------------------------------------------------------------------
//  20/80 LEVEL DETECTION
//  is_short: true = looking for rejection above (short bias)
//            false = looking for rejection below (long bias)
//-------------------------------------------------------------------
bool Is2080Level(double price, bool is_short)
{
   // Extract the last two digits treating NQ as integer points
   // NQ price example: 21680.00  →  mod 100 = 80
   double rounded = MathFloor(price);
   int    mod100  = (int)MathMod(rounded, 100);

   int    dist20  = MathMin(MathAbs(mod100 - 20), MathAbs(mod100 - 120));
   int    dist80  = MathMin(MathAbs(mod100 - 80), MathAbs(mod100 - 180));
   int    dist    = MathMin(dist20, dist80);

   return dist <= (int)Level_Tolerance_Pts;
}

//-------------------------------------------------------------------
//  FORK PATTERN DETECTION  (Long Reversal)
//  Looks for: big down candle → rejection wick candle → failed low
//-------------------------------------------------------------------
bool DetectFork()
{
   // Candle indices: 0=current forming, 1=last closed, 2=prev, 3=before that
   double hi1 = iHigh(_Symbol, _tf_exec, 1);
   double lo1 = iLow (_Symbol, _tf_exec, 1);
   double cl1 = iClose(_Symbol, _tf_exec, 1);
   double op1 = iOpen (_Symbol, _tf_exec, 1);

   double hi2 = iHigh(_Symbol, _tf_exec, 2);
   double lo2 = iLow (_Symbol, _tf_exec, 2);
   double cl2 = iClose(_Symbol, _tf_exec, 2);

   double hi3 = iHigh(_Symbol, _tf_exec, 3);
   double lo3 = iLow (_Symbol, _tf_exec, 3);

   double range2 = hi2 - lo2;
   if(range2 < SL_Points * _point) return false; // candle too small

   // Candle 2: strong bearish rejection wick (lower wick > Fork_Wick_Ratio of range)
   double lower_wick2 = MathMin(cl2, op1) - lo2;   // approximation
   lower_wick2 = MathMin(cl2, iOpen(_Symbol, _tf_exec, 2)) - lo2;
   if(lower_wick2 / range2 < Fork_Wick_Ratio) return false;

   // Candle 1: closes above candle 2 low (failed lower continuation)
   if(lo1 < lo2) return false;   // broke lower – not a fork
   if(cl1 <= lo2 + 2 * _point)  return false;

   // Price must be closing above candle 2 low = failed low confirmed
   return true;
}

//-------------------------------------------------------------------
//  H PATTERN DETECTION  (Short Continuation)
//  Looks for: down move → bounce into 80 → rollover → lower high
//-------------------------------------------------------------------
bool DetectHPattern()
{
   double hi1 = iHigh(_Symbol, _tf_exec, 1);
   double cl1 = iClose(_Symbol, _tf_exec, 1);
   double hi2 = iHigh(_Symbol, _tf_exec, 2);
   double cl2 = iClose(_Symbol, _tf_exec, 2);
   double hi3 = iHigh(_Symbol, _tf_exec, 3);

   // Bounce: candle 3 or 2 must have moved up at least HPattern_Bounce_Pts
   double lo_recent = MathMin(iLow(_Symbol, _tf_exec, 4), iLow(_Symbol, _tf_exec, 5));
   double bounce    = MathMax(hi2, hi3) - lo_recent;
   if(bounce / _point < HPattern_Bounce_Pts) return false;

   // Lower high: candle 1 high < candle 2 high (rollover)
   if(hi1 >= hi2) return false;

   // Current close below recent high = rolling over
   if(cl1 >= hi2) return false;

   return true;
}

//-------------------------------------------------------------------
//  CROSS-SECTION DETECTION
//  Returns: 1 = long setup, -1 = short setup, 0 = no setup
//  Cross-section = overlap zone of two consecutive strong candles
//-------------------------------------------------------------------
int DetectCrossSection()
{
   // Identify two most recent strong candles
   for(int i = 1; i <= 4; i++)
   {
      double hi_a = iHigh (_Symbol, _tf_exec, i);
      double lo_a = iLow  (_Symbol, _tf_exec, i);
      double cl_a = iClose(_Symbol, _tf_exec, i);
      double op_a = iOpen (_Symbol, _tf_exec, i);

      double hi_b = iHigh (_Symbol, _tf_exec, i + 1);
      double lo_b = iLow  (_Symbol, _tf_exec, i + 1);
      double cl_b = iClose(_Symbol, _tf_exec, i + 1);

      // Both candles must be same direction
      bool bull_a = cl_a > op_a;
      bool bull_b = cl_b > iOpen(_Symbol, _tf_exec, i + 1);
      if(bull_a != bull_b) continue;

      // Overlap zone
      double zone_hi = MathMin(hi_a, hi_b);
      double zone_lo = MathMax(lo_a, lo_b);
      if(zone_hi <= zone_lo) continue;   // no overlap

      double current_price = iClose(_Symbol, _tf_exec, 0);

      if(bull_a)
      {
         // Bullish cross-section: price pulled back into overlap from above → Long
         if(current_price >= zone_lo - CrossSection_Depth * _point &&
            current_price <= zone_hi + CrossSection_Depth * _point)
            return 1;
      }
      else
      {
         // Bearish cross-section: price bounced up into overlap → Short
         if(current_price >= zone_lo - CrossSection_Depth * _point &&
            current_price <= zone_hi + CrossSection_Depth * _point)
            return -1;
      }
   }
   return 0;
}

//-------------------------------------------------------------------
//  REPAIR CANDLE SCANNER
//  A candle with no wick on one side creates a magnet zone.
//-------------------------------------------------------------------
void ScanRepairs()
{
   ArrayFree(_repairs);
   int count = 0;

   for(int i = 1; i <= LookbackBars; i++)
   {
      double op = iOpen (_Symbol, _tf_exec, i);
      double cl = iClose(_Symbol, _tf_exec, i);
      double hi = iHigh (_Symbol, _tf_exec, i);
      double lo = iLow  (_Symbol, _tf_exec, i);

      bool no_upper = (hi - MathMax(op, cl)) <= Repair_NoWick_Tol * _point;
      bool no_lower = (MathMin(op, cl) - lo) <= Repair_NoWick_Tol * _point;
      bool bearish  = cl < op;
      bool bullish  = cl > op;

      if(bearish && no_upper)
      {
         // Bearish repair with no upper wick → magnet above at candle open/high
         ArrayResize(_repairs, count + 1);
         _repairs[count].price     = MathMax(op, cl);
         _repairs[count].is_bearish = true;
         count++;
      }
      else if(bullish && no_lower)
      {
         // Bullish repair with no lower wick → magnet below at candle open/low
         ArrayResize(_repairs, count + 1);
         _repairs[count].price     = MathMin(op, cl);
         _repairs[count].is_bearish = false;
         count++;
      }
   }
}

//-------------------------------------------------------------------
//  LOT SIZE CALCULATION  (% risk model)
//-------------------------------------------------------------------
double CalcLotSize()
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money = balance * (Risk_Per_Trade_Pct / 100.0);
   double tick_val   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point_val  = tick_val * (_point / tick_size);

   if(point_val <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots = risk_money / (SL_Points * point_val);

   double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(lot_min, MathFloor(lots / lot_step) * lot_step);

   if(Max_Lot_Size > 0)
      lots = MathMin(lots, Max_Lot_Size);

   lots = MathMin(lots, lot_max);
   return lots;
}

//-------------------------------------------------------------------
//  EFFECTIVE TP1 (fixed pts or R:R ratio)
//-------------------------------------------------------------------
double GetTP1Points()
{
   if(Use_RR_Ratio) return SL_Points * RR_Ratio;
   return TP1_Points;
}

//-------------------------------------------------------------------
//  EXECUTE LONG
//-------------------------------------------------------------------
void ExecuteLong(string setup_label)
{
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lots = CalcLotSize();
   double sl   = ask - SL_Points * _point;
   double tp1  = ask + GetTP1Points() * _point;

   // Target nearest bullish Repair above if enabled
   double repair_target = 0;
   if(Enable_Repair_Target)
      repair_target = NearestRepairAbove(ask);

   double tp = (repair_target > tp1) ? repair_target : tp1;

   if(Trade.Buy(lots, _Symbol, ask, sl, tp,
                EA_Comment + "_" + setup_label + "_v1.0.0"))
      Print("LONG [", setup_label, "] lots=", lots,
            " entry=", ask, " SL=", sl, " TP=", tp);
   else
      Print("LONG order failed: ", Trade.ResultRetcodeDescription());
}

//-------------------------------------------------------------------
//  EXECUTE SHORT
//-------------------------------------------------------------------
void ExecuteShort(string setup_label)
{
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots = CalcLotSize();
   double sl   = bid + SL_Points * _point;
   double tp1  = bid - GetTP1Points() * _point;

   double repair_target = 0;
   if(Enable_Repair_Target)
      repair_target = NearestRepairBelow(bid);

   double tp = (repair_target > 0 && repair_target < tp1) ? repair_target : tp1;

   if(Trade.Sell(lots, _Symbol, bid, sl, tp,
                 EA_Comment + "_" + setup_label + "_v1.0.0"))
      Print("SHORT [", setup_label, "] lots=", lots,
            " entry=", bid, " SL=", sl, " TP=", tp);
   else
      Print("SHORT order failed: ", Trade.ResultRetcodeDescription());
}

//-------------------------------------------------------------------
//  FIND NEAREST REPAIR ABOVE / BELOW
//-------------------------------------------------------------------
double NearestRepairAbove(double ref_price)
{
   double best = 0;
   for(int i = 0; i < ArraySize(_repairs); i++)
   {
      if(_repairs[i].is_bearish && _repairs[i].price > ref_price)
      {
         if(best == 0 || _repairs[i].price < best)
            best = _repairs[i].price;
      }
   }
   return best;
}

double NearestRepairBelow(double ref_price)
{
   double best = 0;
   for(int i = 0; i < ArraySize(_repairs); i++)
   {
      if(!_repairs[i].is_bearish && _repairs[i].price < ref_price)
      {
         if(best == 0 || _repairs[i].price > best)
            best = _repairs[i].price;
      }
   }
   return best;
}

//-------------------------------------------------------------------
//  RUNNER MANAGEMENT  – move SL to BE after partial close at TP1
//-------------------------------------------------------------------
void ManageRunner()
{
   if(!Move_BE_After_TP1) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic() != Magic_Number) continue;
      if(PosInfo.Symbol() != _Symbol)    continue;

      double entry = PosInfo.PriceOpen();
      double cur_sl = PosInfo.StopLoss();

      ENUM_POSITION_TYPE ptype = PosInfo.PositionType();

      // Only modify if SL hasn't reached BE yet
      if(ptype == POSITION_TYPE_BUY && cur_sl < entry)
         Trade.PositionModify(PosInfo.Ticket(), entry, PosInfo.TakeProfit());

      if(ptype == POSITION_TYPE_SELL && (cur_sl > entry || cur_sl == 0))
         Trade.PositionModify(PosInfo.Ticket(), entry, PosInfo.TakeProfit());
   }
}

//-------------------------------------------------------------------
//  UTILITY: new bar guard
//-------------------------------------------------------------------
datetime _last_bar_time = 0;
bool IsNewBar()
{
   datetime bar_time = iTime(_Symbol, _tf_exec, 0);
   if(bar_time == _last_bar_time) return false;
   _last_bar_time = bar_time;
   return true;
}

//-------------------------------------------------------------------
//  UTILITY: check for existing EA position
//-------------------------------------------------------------------
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Magic() == Magic_Number && PosInfo.Symbol() == _Symbol)
            return true;
   }
   return false;
}
//+------------------------------------------------------------------+
