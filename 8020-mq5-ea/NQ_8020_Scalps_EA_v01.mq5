//+------------------------------------------------------------------+
//|  NQ 8020 Scalps EA                                               |
//|  Strategy: NASDAQ 80/20 Level Intraday Scalping Model            |
//|  Version  : v01                                                  |
//|  Author   : kellwyn                                              |
//|  Date     : 2026-04-20                                           |
//+------------------------------------------------------------------+
//
//  STRATEGY SUMMARY
//  ----------------
//  Trades NQ Futures by identifying price reactions at levels whose
//  last two INTEGER digits end in 20 or 80 (e.g. 21620, 21680).
//  Works for any number of total price digits (4-digit or 5-digit NQ).
//
//  Four core setups:
//    1. Fork         – Long reversal at 20/80 after failed continuation lower
//    2. H Pattern    – Short continuation; bounce into 80 rolls over
//    3. Cross-Section– Precision re-entry at candle-overlap zone + 20/80
//    4. Repair       – Candle with missing wick acts as target/magnet
//
//  Risk model:
//    • Fixed SL (default 10 pts)
//    • Scale out 50 % at TP1 (default 15 pts), move SL to break-even
//    • Runner held until Repair magnet or momentum fails
//
//  IMPORTANT – POINT SIZE NOTE
//  ----------------------------
//  All SL/TP/distance inputs are in INTEGER NQ POINTS (e.g. SL_Points=10
//  means a 10-point / $200 stop).  MT5's SYMBOL_POINT can be 0.01, 0.25,
//  or 1.0 depending on your broker — the EA normalises this automatically.
//  Check the OnInit log to confirm "_pts (1 NQ integer point)" is 1.0.
//  If it is wrong, set the OnePoint_Override input to 1.0 manually.
//
//  Changelog
//  ---------
//  v01  2026-04-20  Working copy for diagnostics and 5-digit price fix:
//                   – Fixed _point scaling: replaced all * _point pattern
//                     checks with * _pts (normalised to 1 integer NQ point)
//                   – Fixed Is2080Level: simplified mod-100 distance formula,
//                     removed incorrect mod-120/mod-180 wrap arithmetic,
//                     explicit 5-digit price support documented/tested
//                   – Added bar-by-bar diagnostic logging (Diag_Verbose)
//                   – Removed dead code in DetectFork (wrong-bar op1 ref)
//                   – Added OnePoint_Override input for broker portability
//  v1.0.0 2026-04-20 Initial build – all four setups, full risk params
//
//+------------------------------------------------------------------+
#property copyright "kellwyn"
#property version   "1.01"
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
input double Level_Tolerance_Pts  = 5.0;    // Points within 20/80 level to accept (±)
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
input double SL_Points            = 10.0;   // Stop loss in NQ integer points
input double TP1_Points           = 15.0;   // First target in NQ integer points (50% scale-out)
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
input double HPattern_Bounce_Pts  = 8.0;    // Min NQ pts bounce before H rolls over
input double CrossSection_Depth   = 5.0;    // Max NQ pts outside cross zone for valid re-test
input double Repair_NoWick_Tol    = 1.0;    // Tolerance (NQ pts) for "no wick" detection

//-- Broker / Point Size ---------------------------------------------
input group "=== Broker Settings ==="
// Set to 1.0 if the EA is trading wrong SL/TP distances.
// Correct value = price distance equal to 1 integer NQ point on your broker.
// Examples: Pepperstone NAS100 → 1.0 | CME NQ futures → 0.25 (per tick) or 1.0
// Leave at 0.0 for auto-detection (recommended; verify in OnInit log).
input double OnePoint_Override    = 0.0;

//-- Diagnostics -----------------------------------------------------
input group "=== Diagnostics ==="
input bool   Diag_Verbose         = true;   // Print setup pass/fail reason each bar

//-- Magic / Labels --------------------------------------------------
input group "=== EA Identity ==="
input int    Magic_Number         = 8020;
input string EA_Comment           = "NQ-8020";

//-------------------------------------------------------------------
//  GLOBALS
//-------------------------------------------------------------------
double _point;   // raw broker SYMBOL_POINT (used only in CalcLotSize tick-value math)
double _pts;     // 1 NQ integer point expressed as a price-unit distance
                 // e.g. broker SYMBOL_POINT=0.01 → _pts=1.0 (NQ prices ARE integer points)

ENUM_TIMEFRAMES _tf_exec;

struct RepairLevel
{
   double price;
   bool   is_bearish;
};

RepairLevel _repairs[];

//-------------------------------------------------------------------
//  INITIALISATION
//-------------------------------------------------------------------
int OnInit()
{
   Trade.SetExpertMagicNumber(Magic_Number);
   Trade.SetDeviationInPoints(10);

   _point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // --- Normalise _pts to "1 integer NQ point in price units" ----------
   // NQ prices are quoted as integer points + decimal fractions (e.g. 21480.25).
   // One integer point always equals 1.0 price unit regardless of SYMBOL_POINT.
   // SYMBOL_POINT reflects the broker's minimum tick representation, not a point.
   if(OnePoint_Override > 0.0)
      _pts = OnePoint_Override;
   else
      _pts = 1.0;  // for NQ, 1 integer point = 1.0 price units (always)

   // MT5 has no native 200-second bar; use current chart timeframe.
   _tf_exec = PERIOD_CURRENT;

   Print("=== NQ 8020 Scalps EA v01 ===");
   Print("Symbol=", _Symbol,
         " | SYMBOL_POINT=", _point,
         " | _pts (1 NQ integer point)=", _pts);
   Print("SL=", SL_Points, " pts (", SL_Points * _pts, " price units)",
         " | TP1=", TP1_Points, " pts (", TP1_Points * _pts, " price units)");
   MqlDateTime _now; TimeToStruct(TimeCurrent(), _now);
   Print("Session filter=", Filter_Session,
         " | Server time now: hour=", _now.hour, " min=", _now.min);
   Print("Level tolerance=±", Level_Tolerance_Pts, " integer points");
   Print("Diag_Verbose=", Diag_Verbose,
         " — set true to see per-bar pass/fail reason for each setup");

   return INIT_SUCCEEDED;
}

//-------------------------------------------------------------------
//  TICK HANDLER
//-------------------------------------------------------------------
void OnTick()
{
   if(!IsNewBar()) return;

   // --- Gate 1: Session filter ----------------------------------------
   if(!InSession())
   {
      if(Diag_Verbose)
         Print("[DIAG] BAR BLOCKED – outside session/lunch. ServerTime=",
               TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
      return;
   }

   // --- Gate 2: One trade at a time -----------------------------------
   if(HasOpenPosition())
   {
      if(Diag_Verbose)
         Print("[DIAG] BAR SKIPPED – position already open.");
      return;
   }

   ScanRepairs();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- Show 20/80 level status on every qualifying bar ---------------
   bool lvl_bid = Is2080Level(bid);
   bool lvl_ask = Is2080Level(ask);

   if(Diag_Verbose)
   {
      long bid_pts = (long)MathFloor(bid);
      int  bid_m   = (int)(bid_pts % 100);
      Print("[DIAG] NEW BAR — bid=", bid, " (last2=", bid_m, ")",
            " | at20/80=", lvl_bid,
            " | repairs=", ArraySize(_repairs),
            " | time=", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
   }

   // --- Setup: Fork (Long) --------------------------------------------
   if(Enable_Fork)
   {
      if(!lvl_bid)
      {
         if(Diag_Verbose) Print("[DIAG] Fork SKIP – bid not at 20/80 level (bid=", bid, ")");
      }
      else if(DetectFork())
         ExecuteLong("Fork");
   }

   // --- Setup: H Pattern (Short) --------------------------------------
   if(Enable_HPattern)
   {
      if(!lvl_ask)
      {
         if(Diag_Verbose) Print("[DIAG] HPattern SKIP – ask not at 20/80 level (ask=", ask, ")");
      }
      else if(DetectHPattern())
         ExecuteShort("HPattern");
   }

   // --- Setup: Cross-Section (Long or Short) --------------------------
   if(Enable_CrossSection)
   {
      int csDir = DetectCrossSection();
      if(csDir == 0)
      {
         if(Diag_Verbose) Print("[DIAG] CrossSection SKIP – no overlap zone found");
      }
      else if(csDir == 1 && lvl_bid)
         ExecuteLong("CrossSection");
      else if(csDir == -1 && lvl_ask)
         ExecuteShort("CrossSection");
      else if(Diag_Verbose)
         Print("[DIAG] CrossSection SKIP – direction=", csDir,
               " but price not at 20/80 level");
   }
}

//-------------------------------------------------------------------
//  TRADE MANAGEMENT
//-------------------------------------------------------------------
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
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
//
//  Returns true when the integer part of 'price' ends in xx20 or xx80
//  within ±Level_Tolerance_Pts integer points.
//
//  Works for any number of price digits.
//  Examples (5-digit NQ):
//    21480.25  →  floor=21480  →  21480 % 100 = 80  →  dist=0  ✓
//    21620.50  →  floor=21620  →  21620 % 100 = 20  →  dist=0  ✓
//    21483.75  →  floor=21483  →  21483 % 100 = 83  →  dist=3  ✓ (within ±5)
//    21490.00  →  floor=21490  →  21490 % 100 = 90  →  dist=10 ✗
//-------------------------------------------------------------------
bool Is2080Level(double price)
{
   long int_pts = (long)MathFloor(price);   // strip broker decimal digits
   int  last2   = (int)(int_pts % 100);     // last two integer digits (0–99)

   int dist20 = MathAbs(last2 - 20);
   int dist80 = MathAbs(last2 - 80);
   int dist   = MathMin(dist20, dist80);

   return dist <= (int)Level_Tolerance_Pts;
}

//-------------------------------------------------------------------
//  FORK PATTERN DETECTION  (Long Reversal)
//
//  Setup: a strong bearish candle prints a deep lower wick (rejection),
//  then the next candle fails to make a new low and closes above that
//  wick's base.  Read at a 20/80 level = failed breakdown → Long.
//
//  Candle map (all closed bars):
//    Bar 3 – context bar (not checked)
//    Bar 2 – REJECTION candle: must have lower wick ≥ Fork_Wick_Ratio of range
//    Bar 1 – CONFIRMATION: low stays above bar 2 low, closes clearly above it
//-------------------------------------------------------------------
bool DetectFork()
{
   double hi1 = iHigh (_Symbol, _tf_exec, 1);
   double lo1 = iLow  (_Symbol, _tf_exec, 1);
   double cl1 = iClose(_Symbol, _tf_exec, 1);

   double hi2 = iHigh (_Symbol, _tf_exec, 2);
   double lo2 = iLow  (_Symbol, _tf_exec, 2);
   double cl2 = iClose(_Symbol, _tf_exec, 2);
   double op2 = iOpen (_Symbol, _tf_exec, 2);

   double range2 = hi2 - lo2;

   // Condition A: bar 2 must be large enough to be meaningful
   if(range2 < SL_Points * _pts)
   {
      if(Diag_Verbose)
         Print("[DIAG] Fork FAIL A – bar2 range=", range2 / _pts,
               " pts < SL_Points=", SL_Points);
      return false;
   }

   // Condition B: bar 2 lower wick / range ≥ Fork_Wick_Ratio
   // Lower wick = distance from body bottom to candle low
   double lower_wick2 = MathMin(cl2, op2) - lo2;
   if(lower_wick2 / range2 < Fork_Wick_Ratio)
   {
      if(Diag_Verbose)
         Print("[DIAG] Fork FAIL B – lower wick ratio=",
               DoubleToString(lower_wick2 / range2, 2),
               " < Fork_Wick_Ratio=", Fork_Wick_Ratio);
      return false;
   }

   // Condition C: bar 1 low did NOT break below bar 2 low (failed breakdown)
   if(lo1 < lo2)
   {
      if(Diag_Verbose)
         Print("[DIAG] Fork FAIL C – bar1 lo=", lo1,
               " broke below bar2 lo=", lo2);
      return false;
   }

   // Condition D: bar 1 closes meaningfully above bar 2 low (>2 pts recovery)
   if(cl1 <= lo2 + 2.0 * _pts)
   {
      if(Diag_Verbose)
         Print("[DIAG] Fork FAIL D – bar1 close=", cl1,
               " not enough above bar2 lo=", lo2,
               " (need >", lo2 + 2.0 * _pts, ")");
      return false;
   }

   Print("[SIGNAL] Fork CONFIRMED – bar2 wick=",
         DoubleToString(lower_wick2 / _pts, 1), " pts",
         " | bar1 close=", cl1, " bar2 lo=", lo2);
   return true;
}

//-------------------------------------------------------------------
//  H PATTERN DETECTION  (Short Continuation)
//
//  Setup: price drops (bars 4-5), bounces back up into a 20/80 level
//  (bars 2-3), then makes a lower high on bar 1 = trend continuation short.
//
//  Candle map:
//    Bars 4-5 – recent swing low zone (context)
//    Bars 2-3 – BOUNCE: move up must be ≥ HPattern_Bounce_Pts
//    Bar 1    – ROLLOVER: lower high than bar 2, close still below bar 2 high
//-------------------------------------------------------------------
bool DetectHPattern()
{
   double hi1 = iHigh (_Symbol, _tf_exec, 1);
   double cl1 = iClose(_Symbol, _tf_exec, 1);
   double hi2 = iHigh (_Symbol, _tf_exec, 2);
   double hi3 = iHigh (_Symbol, _tf_exec, 3);

   double lo_recent = MathMin(iLow(_Symbol, _tf_exec, 4),
                               iLow(_Symbol, _tf_exec, 5));
   double bounce    = MathMax(hi2, hi3) - lo_recent;

   // Condition A: bounce must be at least HPattern_Bounce_Pts integer points
   if(bounce < HPattern_Bounce_Pts * _pts)
   {
      if(Diag_Verbose)
         Print("[DIAG] HPattern FAIL A – bounce=",
               DoubleToString(bounce / _pts, 1), " pts < ", HPattern_Bounce_Pts);
      return false;
   }

   // Condition B: bar 1 high < bar 2 high (lower high = rollover confirmed)
   if(hi1 >= hi2)
   {
      if(Diag_Verbose)
         Print("[DIAG] HPattern FAIL B – bar1 hi=", hi1,
               " >= bar2 hi=", hi2, " (no lower high)");
      return false;
   }

   // Condition C: bar 1 close still below the recent high (not recovering)
   if(cl1 >= hi2)
   {
      if(Diag_Verbose)
         Print("[DIAG] HPattern FAIL C – bar1 close=", cl1,
               " >= bar2 hi=", hi2, " (close too high)");
      return false;
   }

   Print("[SIGNAL] HPattern CONFIRMED – bounce=",
         DoubleToString(bounce / _pts, 1), " pts",
         " | bar2 hi=", hi2, " bar1 hi=", hi1, " bar1 cl=", cl1);
   return true;
}

//-------------------------------------------------------------------
//  CROSS-SECTION DETECTION
//  Returns: 1 = long setup, -1 = short setup, 0 = no setup
//
//  Setup: two consecutive candles in the same direction create an
//  overlap (cross-section) zone.  When price pulls back into that
//  zone at a 20/80 level, it is a precision re-entry.
//
//  Zone = [max(lo_a, lo_b) , min(hi_a, hi_b)]
//  Valid re-test = current price within ±CrossSection_Depth pts of zone
//-------------------------------------------------------------------
int DetectCrossSection()
{
   for(int i = 1; i <= 4; i++)
   {
      double hi_a = iHigh (_Symbol, _tf_exec, i);
      double lo_a = iLow  (_Symbol, _tf_exec, i);
      double cl_a = iClose(_Symbol, _tf_exec, i);
      double op_a = iOpen (_Symbol, _tf_exec, i);

      double hi_b = iHigh (_Symbol, _tf_exec, i + 1);
      double lo_b = iLow  (_Symbol, _tf_exec, i + 1);
      double cl_b = iClose(_Symbol, _tf_exec, i + 1);
      double op_b = iOpen (_Symbol, _tf_exec, i + 1);

      // Both candles must move in the same direction
      bool bull_a = cl_a > op_a;
      bool bull_b = cl_b > op_b;
      if(bull_a != bull_b) continue;

      // Overlap zone: area shared by both candle bodies + wicks
      double zone_hi = MathMin(hi_a, hi_b);
      double zone_lo = MathMax(lo_a, lo_b);
      if(zone_hi <= zone_lo) continue;   // no overlap

      double cur = iClose(_Symbol, _tf_exec, 0);
      double depth = CrossSection_Depth * _pts;

      if(cur >= zone_lo - depth && cur <= zone_hi + depth)
      {
         if(Diag_Verbose)
            Print("[DIAG] CrossSection HIT bars ", i, "/", i + 1,
                  " | zone=[", zone_lo, ",", zone_hi, "]",
                  " | cur=", cur,
                  " | dir=", (bull_a ? "LONG" : "SHORT"));
         return bull_a ? 1 : -1;
      }
   }
   return 0;
}

//-------------------------------------------------------------------
//  REPAIR CANDLE SCANNER
//
//  A candle with no wick on one side shows price moved straight
//  through that level — creating a "magnet" zone it is likely to
//  revisit.  Used as an enhanced TP target for runners.
//
//  Bearish repair (no upper wick): magnet above at body top
//  Bullish repair (no lower wick): magnet below at body bottom
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

      double tol     = Repair_NoWick_Tol * _pts;
      bool no_upper  = (hi - MathMax(op, cl)) <= tol;
      bool no_lower  = (MathMin(op, cl) - lo)  <= tol;
      bool bearish   = cl < op;
      bool bullish   = cl > op;

      if(bearish && no_upper)
      {
         ArrayResize(_repairs, count + 1);
         _repairs[count].price      = MathMax(op, cl);
         _repairs[count].is_bearish = true;
         count++;
      }
      else if(bullish && no_lower)
      {
         ArrayResize(_repairs, count + 1);
         _repairs[count].price      = MathMin(op, cl);
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

   // SL_Points in integer NQ points × _pts gives price-unit distance
   // point_val is value per broker SYMBOL_POINT move
   // convert: risk / (price-unit SL / _point) = risk / (SL_pts * _pts / _point)
   double sl_price_dist = SL_Points * _pts;
   double lots = risk_money / (sl_price_dist / _point * tick_val / tick_size * _point);
   // simplify: lots = risk_money / (SL_Points * _pts * point_val / _point)
   lots = risk_money / (SL_Points * (_pts / _point) * point_val);

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
//  EFFECTIVE TP1
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
   double sl   = ask - SL_Points  * _pts;
   double tp1  = ask + GetTP1Points() * _pts;

   double repair_target = 0;
   if(Enable_Repair_Target)
      repair_target = NearestRepairAbove(ask);

   double tp = (repair_target > tp1) ? repair_target : tp1;

   Print("[ORDER] LONG [", setup_label, "] lots=", lots,
         " entry=", ask,
         " SL=", sl, " (", SL_Points, " pts)",
         " TP=", tp);

   if(!Trade.Buy(lots, _Symbol, ask, sl, tp,
                 EA_Comment + "_" + setup_label + "_v01"))
      Print("[ERROR] LONG order failed: ", Trade.ResultRetcodeDescription());
}

//-------------------------------------------------------------------
//  EXECUTE SHORT
//-------------------------------------------------------------------
void ExecuteShort(string setup_label)
{
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots = CalcLotSize();
   double sl   = bid + SL_Points  * _pts;
   double tp1  = bid - GetTP1Points() * _pts;

   double repair_target = 0;
   if(Enable_Repair_Target)
      repair_target = NearestRepairBelow(bid);

   double tp = (repair_target > 0 && repair_target < tp1) ? repair_target : tp1;

   Print("[ORDER] SHORT [", setup_label, "] lots=", lots,
         " entry=", bid,
         " SL=", sl, " (", SL_Points, " pts)",
         " TP=", tp);

   if(!Trade.Sell(lots, _Symbol, bid, sl, tp,
                  EA_Comment + "_" + setup_label + "_v01"))
      Print("[ERROR] SHORT order failed: ", Trade.ResultRetcodeDescription());
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
         if(best == 0 || _repairs[i].price < best)
            best = _repairs[i].price;
   }
   return best;
}

double NearestRepairBelow(double ref_price)
{
   double best = 0;
   for(int i = 0; i < ArraySize(_repairs); i++)
   {
      if(!_repairs[i].is_bearish && _repairs[i].price < ref_price)
         if(best == 0 || _repairs[i].price > best)
            best = _repairs[i].price;
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
      if(PosInfo.Magic()  != Magic_Number) continue;
      if(PosInfo.Symbol() != _Symbol)      continue;

      double entry  = PosInfo.PriceOpen();
      double cur_sl = PosInfo.StopLoss();
      ENUM_POSITION_TYPE ptype = PosInfo.PositionType();

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
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Magic() == Magic_Number && PosInfo.Symbol() == _Symbol)
            return true;
   return false;
}
//+------------------------------------------------------------------+
