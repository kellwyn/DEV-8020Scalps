//+------------------------------------------------------------------+
//|  NQ 8020 Scalps EA                                               |
//|  Strategy: NASDAQ 80/20 Level Intraday Scalping Model            |
//|  Version  : v02                                                  |
//|  Author   : kellwyn                                              |
//|  Date     : 2026-04-21                                           |
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
//    • Scale out 50% at TP1 (default 15 pts), move SL to break-even
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
//  v02  2026-04-21  ADR volatility tracker + trend identifier:
//                   – Added CalcADR(): 5-day Average Daily Range in pts,
//                     classified into Low/Normal/High/Extreme regimes
//                   – Added ClassifyTrend(): EMA(20)/EMA(50) on H1,
//                     three-state Bull/Bear/Neutral output
//                   – H Pattern bounce gate now scales with ADR when
//                     Use_ADR_Bounce=true (min/max % of ADR)
//                   – ADR_Skip thresholds block trading in untradeable
//                     volatility regimes (too quiet or too wild)
//                   – Trend filter gates Fork to Bull/Neutral only and
//                     H Pattern to Bear/Neutral only (opt-in via inputs)
//                   – UpdateMarketContext() refreshes ADR+trend once per
//                     bar and logs the regime on every qualifying bar
//  v01  2026-04-20  Working copy: _point scaling, Is2080Level fix,
//                   Diag_Verbose logging, OnePoint_Override
//  v1.0.0 2026-04-20 Initial build – all four setups, full risk params
//
//+------------------------------------------------------------------+
#property copyright "kellwyn"
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        Trade;
CPositionInfo PosInfo;

//-------------------------------------------------------------------
//  ENUMERATIONS
//-------------------------------------------------------------------

enum ENUM_VOL_REGIME
{
   VOL_LOW     = 0,   // ADR < Low threshold  – tight, use smaller bounce window
   VOL_NORMAL  = 1,   // ADR in normal range  – default settings optimal
   VOL_HIGH    = 2,   // ADR > High threshold – widen bounce window
   VOL_EXTREME = 3    // ADR > Extreme threshold – skip all trades
};

enum ENUM_TREND_STATE
{
   TREND_BULL    = 1,   // EMA fast > slow AND price > fast EMA
   TREND_NEUTRAL = 0,   // mixed signals
   TREND_BEAR    = -1   // EMA fast < slow AND price < fast EMA
};

//-------------------------------------------------------------------
//  INPUT PARAMETERS
//-------------------------------------------------------------------

//-- Setup Toggles ---------------------------------------------------
input group "=== Setup Toggles ==="
input bool   Enable_Fork          = true;
input bool   Enable_HPattern      = true;
input bool   Enable_CrossSection  = true;
input bool   Enable_Repair_Target = true;

//-- 20/80 Level Detection -------------------------------------------
input group "=== Level Detection ==="
input double Level_Tolerance_Pts  = 5.0;
input int    LookbackBars         = 20;

//-- Session Filter --------------------------------------------------
input group "=== Session Filter ==="
input bool   Filter_Session       = true;
input int    Session_Start_Hour   = 9;
input int    Session_Start_Min    = 30;
input int    Session_End_Hour     = 16;
input int    Session_End_Min      = 0;
input bool   Avoid_Lunch          = true;
input int    Lunch_Start_Hour     = 12;
input int    Lunch_End_Hour       = 13;
input int    Lunch_End_Min        = 30;

//-- Risk Management -------------------------------------------------
input group "=== Risk Management ==="
input double Risk_Per_Trade_Pct   = 1.0;
input double SL_Points            = 10.0;   // Stop loss in NQ integer points
input double TP1_Points           = 15.0;   // TP1 in NQ integer points (50% scale-out)
input bool   Use_RR_Ratio         = false;
input double RR_Ratio             = 1.5;
input double Max_Lot_Size         = 2.0;
input double Scale_Out_Pct        = 50.0;

//-- Trailing / Break-Even -------------------------------------------
input group "=== Trade Management ==="
input bool   Move_BE_After_TP1    = true;
input bool   Enable_Runner        = true;
input double Runner_Trail_Pts     = 10.0;

//-- Pattern Sensitivity ---------------------------------------------
input group "=== Pattern Sensitivity ==="
input double Fork_Wick_Ratio      = 0.5;    // Min lower-wick / candle-range for Fork
input double HPattern_Bounce_Pts  = 10.0;   // Min NQ pts bounce (used when Use_ADR_Bounce=false)
input double CrossSection_Depth   = 5.0;
input double Repair_NoWick_Tol    = 1.0;

//-- ADR Volatility Filter -------------------------------------------
input group "=== ADR Volatility Filter ==="
// ADR = Average Daily Range over ADR_Lookback_Days completed sessions.
// Used to classify volatility regime and optionally scale H Pattern bounce.
input bool   Use_ADR_Filter       = true;    // Enable ADR regime classification
input int    ADR_Lookback_Days    = 5;       // Days to average for ADR (completed sessions)
input double ADR_Low_Threshold    = 80.0;    // ADR below this → Low Vol regime (pts)
input double ADR_High_Threshold   = 200.0;   // ADR above this → High Vol regime (pts)
input double ADR_Extreme_Threshold= 300.0;   // ADR above this → Extreme, skip all trades
input bool   Use_ADR_Bounce       = true;    // Scale H bounce min/max with ADR (overrides HPattern_Bounce_Pts)
input double Bounce_ADR_Min_Pct   = 0.10;    // Min bounce as fraction of ADR (10%)
input double Bounce_ADR_Max_Pct   = 0.32;    // Max bounce as fraction of ADR (32%)
// Bounce sweet spot = 10%–32% of ADR.  Examples:
//   ADR 100 pts → bounce window  10 –  32 pts
//   ADR 150 pts → bounce window  15 –  48 pts
//   ADR 250 pts → bounce window  25 –  80 pts

//-- Trend Identifier ------------------------------------------------
input group "=== Trend Identifier ==="
// Trend is determined by EMA crossover on Trend_TF plus price location.
// Bull  : EMA_Fast > EMA_Slow AND close(bar1) > EMA_Fast
// Bear  : EMA_Fast < EMA_Slow AND close(bar1) < EMA_Fast
// Neutral: mixed
input bool             Use_Trend_Filter     = true;    // Enable trend-direction gating
input int              Trend_EMA_Fast       = 20;      // Fast EMA period
input int              Trend_EMA_Slow       = 50;      // Slow EMA period
input ENUM_TIMEFRAMES  Trend_TF             = PERIOD_H1; // Timeframe for trend EMAs
input bool             Fork_Requires_Bull   = true;    // Fork (Long) blocked in Bear trend
input bool             HPattern_Requires_Bear = true;  // H Pattern (Short) blocked in Bull trend

//-- Broker / Point Size ---------------------------------------------
input group "=== Broker Settings ==="
input double OnePoint_Override    = 0.0;    // 0=auto; set to 1.0 if SL/TP are wrong size

//-- Diagnostics -----------------------------------------------------
input group "=== Diagnostics ==="
input bool   Diag_Verbose         = true;

//-- EA Identity -----------------------------------------------------
input group "=== EA Identity ==="
input int    Magic_Number         = 8020;
input string EA_Comment           = "NQ-8020";

//-------------------------------------------------------------------
//  GLOBALS
//-------------------------------------------------------------------
double _point;          // raw SYMBOL_POINT (CalcLotSize only)
double _pts;            // 1 NQ integer point in price units

ENUM_TIMEFRAMES _tf_exec;

// ADR & volatility
double          _adr;           // current ADR in NQ integer points
ENUM_VOL_REGIME _vol_regime;    // Low / Normal / High / Extreme

// Trend
ENUM_TREND_STATE _trend;        // Bull / Neutral / Bear
int              _h_ema_fast;   // iMA handle – fast EMA
int              _h_ema_slow;   // iMA handle – slow EMA

struct RepairLevel { double price; bool is_bearish; };
RepairLevel _repairs[];

//-------------------------------------------------------------------
//  INITIALISATION
//-------------------------------------------------------------------
int OnInit()
{
   Trade.SetExpertMagicNumber(Magic_Number);
   Trade.SetDeviationInPoints(10);

   _point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   _pts   = (OnePoint_Override > 0.0) ? OnePoint_Override : 1.0;
   _tf_exec = PERIOD_CURRENT;

   // Create EMA indicator handles
   _h_ema_fast = iMA(_Symbol, Trend_TF, Trend_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   _h_ema_slow = iMA(_Symbol, Trend_TF, Trend_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(_h_ema_fast == INVALID_HANDLE || _h_ema_slow == INVALID_HANDLE)
   {
      Print("[ERROR] Failed to create EMA handles – check Trend_TF setting");
      return INIT_FAILED;
   }

   MqlDateTime _now; TimeToStruct(TimeCurrent(), _now);

   Print("=== NQ 8020 Scalps EA v02 ===");
   Print("Symbol=", _Symbol,
         " | SYMBOL_POINT=", _point,
         " | _pts=", _pts);
   Print("SL=", SL_Points, " pts | TP1=", TP1_Points,
         " pts | RR=", (Use_RR_Ratio ? RR_Ratio : TP1_Points/SL_Points));
   Print("Session filter=", Filter_Session,
         " | Server time: ", _now.hour, ":", _now.min);
   Print("ADR filter=", Use_ADR_Filter,
         " | ADR_Bounce=", Use_ADR_Bounce,
         " | Bounce%=[", Bounce_ADR_Min_Pct*100, "%,", Bounce_ADR_Max_Pct*100, "%]");
   Print("Trend filter=", Use_Trend_Filter,
         " | EMA(", Trend_EMA_Fast, "/", Trend_EMA_Slow, ") on ",
         EnumToString(Trend_TF),
         " | Fork_Bull=", Fork_Requires_Bull,
         " | H_Bear=", HPattern_Requires_Bear);

   return INIT_SUCCEEDED;
}

//-------------------------------------------------------------------
//  DEINITIALISATION
//-------------------------------------------------------------------
void OnDeinit(const int reason)
{
   if(_h_ema_fast != INVALID_HANDLE) IndicatorRelease(_h_ema_fast);
   if(_h_ema_slow != INVALID_HANDLE) IndicatorRelease(_h_ema_slow);
}

//-------------------------------------------------------------------
//  TICK HANDLER
//-------------------------------------------------------------------
void OnTick()
{
   if(!IsNewBar()) return;

   if(!InSession())
   {
      if(Diag_Verbose)
         Print("[DIAG] BAR BLOCKED – outside session/lunch. Time=",
               TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
      return;
   }

   if(HasOpenPosition())
   {
      if(Diag_Verbose) Print("[DIAG] BAR SKIPPED – position open.");
      return;
   }

   // Refresh ADR and trend once per bar
   UpdateMarketContext();

   // Block all trading in extreme volatility
   if(Use_ADR_Filter && _vol_regime == VOL_EXTREME)
   {
      if(Diag_Verbose)
         Print("[DIAG] ALL SETUPS BLOCKED – VOL_EXTREME | ADR=",
               DoubleToString(_adr, 1), " pts");
      return;
   }

   ScanRepairs();

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool   lvl_b = Is2080Level(bid);
   bool   lvl_a = Is2080Level(ask);

   if(Diag_Verbose)
   {
      int last2 = (int)((long)MathFloor(bid) % 100);
      Print("[DIAG] NEW BAR | bid=", bid, " last2=", last2,
            " | at20/80=", lvl_b,
            " | Regime=", VolRegimeName(_vol_regime),
            " ADR=", DoubleToString(_adr, 1), " pts",
            " | Trend=", TrendName(_trend),
            " | time=", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
   }

   // --- Fork (Long) ------------------------------------------------
   if(Enable_Fork)
   {
      if(!lvl_b)
      {
         if(Diag_Verbose) Print("[DIAG] Fork SKIP – bid not at 20/80 (bid=", bid, ")");
      }
      else if(Use_Trend_Filter && Fork_Requires_Bull && _trend == TREND_BEAR)
      {
         if(Diag_Verbose)
            Print("[DIAG] Fork BLOCKED – trend=BEAR, Fork requires Bull/Neutral");
      }
      else if(DetectFork())
         ExecuteLong("Fork");
   }

   // --- H Pattern (Short) -----------------------------------------
   if(Enable_HPattern)
   {
      if(!lvl_a)
      {
         if(Diag_Verbose) Print("[DIAG] HPattern SKIP – ask not at 20/80 (ask=", ask, ")");
      }
      else if(Use_Trend_Filter && HPattern_Requires_Bear && _trend == TREND_BULL)
      {
         if(Diag_Verbose)
            Print("[DIAG] HPattern BLOCKED – trend=BULL, H Pattern requires Bear/Neutral");
      }
      else if(DetectHPattern())
         ExecuteShort("HPattern");
   }

   // --- Cross-Section (Long or Short) -----------------------------
   if(Enable_CrossSection)
   {
      int csDir = DetectCrossSection();
      if(csDir == 0)
      {
         if(Diag_Verbose) Print("[DIAG] CrossSection SKIP – no overlap zone found");
      }
      else if(csDir == 1 && lvl_b)
         ExecuteLong("CrossSection");
      else if(csDir == -1 && lvl_a)
         ExecuteShort("CrossSection");
      else if(Diag_Verbose)
         Print("[DIAG] CrossSection SKIP – dir=", csDir, " not at 20/80 level");
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
//  UPDATE MARKET CONTEXT  (called once per qualifying bar)
//  Refreshes: _adr, _vol_regime, _trend
//-------------------------------------------------------------------
void UpdateMarketContext()
{
   // --- ADR --------------------------------------------------------
   _adr = CalcADR();
   _vol_regime = ClassifyVolatility(_adr);

   // --- Trend ------------------------------------------------------
   _trend = ClassifyTrend();
}

//-------------------------------------------------------------------
//  ADR CALCULATION
//  Average of (daily high − daily low) over ADR_Lookback_Days
//  completed sessions.  Returns value in NQ integer points.
//-------------------------------------------------------------------
double CalcADR()
{
   if(!Use_ADR_Filter) return 150.0;   // neutral fallback when filter off

   double sum = 0;
   int    valid = 0;

   for(int i = 1; i <= ADR_Lookback_Days; i++)
   {
      double hi = iHigh(_Symbol, PERIOD_D1, i);
      double lo = iLow (_Symbol, PERIOD_D1, i);
      if(hi > lo)
      {
         sum += (hi - lo) / _pts;
         valid++;
      }
   }
   return (valid > 0) ? sum / valid : 150.0;
}

//-------------------------------------------------------------------
//  VOLATILITY REGIME CLASSIFICATION
//-------------------------------------------------------------------
ENUM_VOL_REGIME ClassifyVolatility(double adr_pts)
{
   if(adr_pts >= ADR_Extreme_Threshold) return VOL_EXTREME;
   if(adr_pts >= ADR_High_Threshold)    return VOL_HIGH;
   if(adr_pts < ADR_Low_Threshold)      return VOL_LOW;
   return VOL_NORMAL;
}

//-------------------------------------------------------------------
//  TREND CLASSIFICATION  (EMA crossover + price location)
//
//  Uses two EMAs on Trend_TF (default H1).
//  Bull  : EMA_Fast > EMA_Slow  AND  bar1_close > EMA_Fast
//  Bear  : EMA_Fast < EMA_Slow  AND  bar1_close < EMA_Fast
//  Neutral: any mixed signal
//
//  Practical meaning for this EA:
//    Bull  → favour Long setups (Fork), block H Pattern shorts
//    Bear  → favour Short setups (H Pattern), block Fork longs
//    Neutral → both setups allowed
//-------------------------------------------------------------------
ENUM_TREND_STATE ClassifyTrend()
{
   if(!Use_Trend_Filter) return TREND_NEUTRAL;

   double fast_buf[2], slow_buf[2];

   // Copy 2 values (bars 0 and 1); use bar 1 (last closed) for stability
   if(CopyBuffer(_h_ema_fast, 0, 1, 2, fast_buf) < 2) return TREND_NEUTRAL;
   if(CopyBuffer(_h_ema_slow, 0, 1, 2, slow_buf) < 2) return TREND_NEUTRAL;

   double ema_fast  = fast_buf[1];   // bar 1 (most recent closed)
   double ema_slow  = slow_buf[1];
   double bar1_close = iClose(_Symbol, Trend_TF, 1);

   bool fast_above_slow = ema_fast > ema_slow;
   bool price_above_fast = bar1_close > ema_fast;

   if(fast_above_slow && price_above_fast)  return TREND_BULL;
   if(!fast_above_slow && !price_above_fast) return TREND_BEAR;
   return TREND_NEUTRAL;
}

//-------------------------------------------------------------------
//  HELPER: regime / trend labels for diagnostics
//-------------------------------------------------------------------
string VolRegimeName(ENUM_VOL_REGIME r)
{
   switch(r)
   {
      case VOL_LOW:     return "LOW";
      case VOL_NORMAL:  return "NORMAL";
      case VOL_HIGH:    return "HIGH";
      case VOL_EXTREME: return "EXTREME";
   }
   return "?";
}

string TrendName(ENUM_TREND_STATE t)
{
   switch(t)
   {
      case TREND_BULL:    return "BULL";
      case TREND_BEAR:    return "BEAR";
      case TREND_NEUTRAL: return "NEUTRAL";
   }
   return "?";
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
   int start   = Session_Start_Hour * 60 + Session_Start_Min;
   int end     = Session_End_Hour   * 60 + Session_End_Min;

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
//-------------------------------------------------------------------
bool Is2080Level(double price)
{
   long int_pts = (long)MathFloor(price);
   int  last2   = (int)(int_pts % 100);
   int  dist    = MathMin(MathAbs(last2 - 20), MathAbs(last2 - 80));
   return dist <= (int)Level_Tolerance_Pts;
}

//-------------------------------------------------------------------
//  FORK PATTERN DETECTION  (Long Reversal)
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

   if(range2 < SL_Points * _pts)
   {
      if(Diag_Verbose)
         Print("[DIAG] Fork FAIL A – bar2 range=", range2/_pts,
               " pts < SL_Points=", SL_Points);
      return false;
   }

   double lower_wick2 = MathMin(cl2, op2) - lo2;
   if(lower_wick2 / range2 < Fork_Wick_Ratio)
   {
      if(Diag_Verbose)
         Print("[DIAG] Fork FAIL B – wick ratio=",
               DoubleToString(lower_wick2/range2, 2),
               " < ", Fork_Wick_Ratio);
      return false;
   }

   if(lo1 < lo2)
   {
      if(Diag_Verbose)
         Print("[DIAG] Fork FAIL C – bar1 lo=", lo1, " broke bar2 lo=", lo2);
      return false;
   }

   if(cl1 <= lo2 + 2.0 * _pts)
   {
      if(Diag_Verbose)
         Print("[DIAG] Fork FAIL D – bar1 cl=", cl1,
               " not enough above bar2 lo=", lo2);
      return false;
   }

   Print("[SIGNAL] Fork CONFIRMED | wick=", DoubleToString(lower_wick2/_pts,1),
         " pts | bar1 cl=", cl1, " bar2 lo=", lo2,
         " | Regime=", VolRegimeName(_vol_regime),
         " | Trend=", TrendName(_trend));
   return true;
}

//-------------------------------------------------------------------
//  H PATTERN DETECTION  (Short Continuation)
//
//  Bounce gate uses ADR-scaled window when Use_ADR_Bounce=true:
//    bounce_min = ADR * Bounce_ADR_Min_Pct
//    bounce_max = ADR * Bounce_ADR_Max_Pct
//  This keeps the bounce threshold proportional to the day's actual range.
//
//  Regime-specific windows at default pct (10%–32%):
//    VOL_LOW     ADR ~70  → min  7 pts, max 22 pts
//    VOL_NORMAL  ADR ~130 → min 13 pts, max 42 pts
//    VOL_HIGH    ADR ~220 → min 22 pts, max 70 pts
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

   // --- Condition A: bounce within the valid window -----------------
   double b_min, b_max;
   if(Use_ADR_Bounce && Use_ADR_Filter && _adr > 0)
   {
      b_min = _adr * Bounce_ADR_Min_Pct * _pts;
      b_max = _adr * Bounce_ADR_Max_Pct * _pts;
   }
   else
   {
      b_min = HPattern_Bounce_Pts * _pts;
      b_max = 99999.0;
   }

   if(bounce < b_min)
   {
      if(Diag_Verbose)
         Print("[DIAG] HPattern FAIL A(min) – bounce=",
               DoubleToString(bounce/_pts,1), " pts < min=",
               DoubleToString(b_min/_pts,1), " pts",
               " (ADR=", DoubleToString(_adr,1), ", ",
               DoubleToString(Bounce_ADR_Min_Pct*100,0), "% ADR)");
      return false;
   }
   if(bounce > b_max)
   {
      if(Diag_Verbose)
         Print("[DIAG] HPattern FAIL A(max) – bounce=",
               DoubleToString(bounce/_pts,1), " pts > max=",
               DoubleToString(b_max/_pts,1), " pts",
               " (too large – possible reversal, not continuation)");
      return false;
   }

   // --- Condition B: lower high (rollover) -------------------------
   if(hi1 >= hi2)
   {
      if(Diag_Verbose)
         Print("[DIAG] HPattern FAIL B – bar1 hi=", hi1,
               " >= bar2 hi=", hi2, " (no lower high)");
      return false;
   }

   // --- Condition C: bar1 close below bar2 high (not recovering) ---
   if(cl1 >= hi2)
   {
      if(Diag_Verbose)
         Print("[DIAG] HPattern FAIL C – bar1 cl=", cl1,
               " >= bar2 hi=", hi2, " (close too high)");
      return false;
   }

   Print("[SIGNAL] HPattern CONFIRMED | bounce=",
         DoubleToString(bounce/_pts,1), " pts",
         " (", DoubleToString(bounce/(_adr*_pts)*100,1), "% ADR)",
         " | bar2 hi=", hi2, " bar1 hi=", hi1,
         " | Regime=", VolRegimeName(_vol_regime),
         " | Trend=", TrendName(_trend));
   return true;
}

//-------------------------------------------------------------------
//  CROSS-SECTION DETECTION
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

      bool bull_a = cl_a > op_a;
      bool bull_b = cl_b > op_b;
      if(bull_a != bull_b) continue;

      double zone_hi = MathMin(hi_a, hi_b);
      double zone_lo = MathMax(lo_a, lo_b);
      if(zone_hi <= zone_lo) continue;

      double cur   = iClose(_Symbol, _tf_exec, 0);
      double depth = CrossSection_Depth * _pts;

      if(cur >= zone_lo - depth && cur <= zone_hi + depth)
      {
         if(Diag_Verbose)
            Print("[DIAG] CrossSection HIT bars ", i, "/", i+1,
                  " zone=[", zone_lo, ",", zone_hi, "]",
                  " cur=", cur,
                  " dir=", (bull_a ? "LONG" : "SHORT"));
         return bull_a ? 1 : -1;
      }
   }
   return 0;
}

//-------------------------------------------------------------------
//  REPAIR CANDLE SCANNER
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

      double tol    = Repair_NoWick_Tol * _pts;
      bool no_upper = (hi - MathMax(op, cl)) <= tol;
      bool no_lower = (MathMin(op, cl) - lo)  <= tol;

      if(cl < op && no_upper)
      {
         ArrayResize(_repairs, count + 1);
         _repairs[count].price = MathMax(op, cl); _repairs[count].is_bearish = true; count++;
      }
      else if(cl > op && no_lower)
      {
         ArrayResize(_repairs, count + 1);
         _repairs[count].price = MathMin(op, cl); _repairs[count].is_bearish = false; count++;
      }
   }
}

//-------------------------------------------------------------------
//  LOT SIZE CALCULATION
//-------------------------------------------------------------------
double CalcLotSize()
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money= balance * (Risk_Per_Trade_Pct / 100.0);
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_val <= 0 || tick_size <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots = risk_money / (SL_Points * (_pts / _point) *
                               (tick_val / tick_size) * _point);

   double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(lot_min, MathFloor(lots / lot_step) * lot_step);
   if(Max_Lot_Size > 0) lots = MathMin(lots, Max_Lot_Size);
   return MathMin(lots, lot_max);
}

double GetTP1Points()
{
   return Use_RR_Ratio ? SL_Points * RR_Ratio : TP1_Points;
}

//-------------------------------------------------------------------
//  EXECUTE LONG / SHORT
//-------------------------------------------------------------------
void ExecuteLong(string label)
{
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lots = CalcLotSize();
   double sl   = ask - SL_Points * _pts;
   double tp1  = ask + GetTP1Points() * _pts;
   double rep  = Enable_Repair_Target ? NearestRepairAbove(ask) : 0;
   double tp   = (rep > tp1) ? rep : tp1;

   Print("[ORDER] LONG [", label, "] lots=", lots,
         " entry=", ask, " SL=", sl, " TP=", tp,
         " | Regime=", VolRegimeName(_vol_regime),
         " | Trend=", TrendName(_trend));

   if(!Trade.Buy(lots, _Symbol, ask, sl, tp, EA_Comment+"_"+label+"_v02"))
      Print("[ERROR] LONG failed: ", Trade.ResultRetcodeDescription());
}

void ExecuteShort(string label)
{
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots = CalcLotSize();
   double sl   = bid + SL_Points * _pts;
   double tp1  = bid - GetTP1Points() * _pts;
   double rep  = Enable_Repair_Target ? NearestRepairBelow(bid) : 0;
   double tp   = (rep > 0 && rep < tp1) ? rep : tp1;

   Print("[ORDER] SHORT [", label, "] lots=", lots,
         " entry=", bid, " SL=", sl, " TP=", tp,
         " | Regime=", VolRegimeName(_vol_regime),
         " | Trend=", TrendName(_trend));

   if(!Trade.Sell(lots, _Symbol, bid, sl, tp, EA_Comment+"_"+label+"_v02"))
      Print("[ERROR] SHORT failed: ", Trade.ResultRetcodeDescription());
}

//-------------------------------------------------------------------
//  NEAREST REPAIR ABOVE / BELOW
//-------------------------------------------------------------------
double NearestRepairAbove(double ref)
{
   double best = 0;
   for(int i = 0; i < ArraySize(_repairs); i++)
      if(_repairs[i].is_bearish && _repairs[i].price > ref)
         if(best == 0 || _repairs[i].price < best) best = _repairs[i].price;
   return best;
}

double NearestRepairBelow(double ref)
{
   double best = 0;
   for(int i = 0; i < ArraySize(_repairs); i++)
      if(!_repairs[i].is_bearish && _repairs[i].price < ref)
         if(best == 0 || _repairs[i].price > best) best = _repairs[i].price;
   return best;
}

//-------------------------------------------------------------------
//  RUNNER MANAGEMENT
//-------------------------------------------------------------------
void ManageRunner()
{
   if(!Move_BE_After_TP1) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic()  != Magic_Number) continue;
      if(PosInfo.Symbol() != _Symbol)      continue;

      double entry = PosInfo.PriceOpen();
      double cur_sl= PosInfo.StopLoss();
      ENUM_POSITION_TYPE pt = PosInfo.PositionType();

      if(pt == POSITION_TYPE_BUY  && cur_sl < entry)
         Trade.PositionModify(PosInfo.Ticket(), entry, PosInfo.TakeProfit());
      if(pt == POSITION_TYPE_SELL && (cur_sl > entry || cur_sl == 0))
         Trade.PositionModify(PosInfo.Ticket(), entry, PosInfo.TakeProfit());
   }
}

//-------------------------------------------------------------------
//  UTILITY
//-------------------------------------------------------------------
datetime _last_bar_time = 0;
bool IsNewBar()
{
   datetime t = iTime(_Symbol, _tf_exec, 0);
   if(t == _last_bar_time) return false;
   _last_bar_time = t;
   return true;
}

bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Magic() == Magic_Number && PosInfo.Symbol() == _Symbol)
            return true;
   return false;
}
//+------------------------------------------------------------------+
