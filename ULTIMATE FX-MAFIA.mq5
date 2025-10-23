//+------------------------------------------------------------------+
//|                                              MultiSignalEA.mq5 |
//|                                       Copyright 2025, Gemini Model |
//|                                                                  |
//+------------------------------------------------------------------+
#property strict
#property version   "2.02" // Final bugfix for "first pullback only" logic
#property description "Trades the first valid pullback after a major ZigZag swing."
#property description "V2.02: Corrected logic that prematurely invalidated setups."

#include <Trade/Trade.mqh>

//--- EA Inputs
//--- Indicator Settings
input group "Indicator Settings"
input int    InpZZLarge_Depth       = 52;
input int    InpZZLarge_Deviation   = 15;
input int    InpZZLarge_Backstep    = 9;
input int    InpZZReg_Depth         = 12;
input int    InpZZReg_Deviation     = 5;
input int    InpZZReg_Backstep      = 3;

//--- Partial Profit Settings
input group "Partial Profit Settings"
input bool   InpUsePartialTP          = true;
input double InpPartialTP_RR          = 1.0;
input double InpPartialClosePercent   = 50.0;

//--- Stop Loss Management
input group "Stop Loss Management"
input bool   InpUseBreakEven          = true;
input double InpBreakEven_RR          = 1.0;
input int    InpBreakEven_Pips        = 1;

//--- Daily Loss Limit
input group "Daily Loss Limit (Account-Wide)"
input bool   InpUseDailyLossLimit     = true;
input double InpMaxDailyEquityLossPct = -3.5;
input bool   InpCloseTradesOnLossHit  = true;

//--- FVG Filter Settings
input group "FVG Filter Settings"
input bool   InpUseFVGFilter      = true;
input string InpBullishFVGPrefix  = "FVG OB";
input color  InpBullishFVGColor   = clrLime;
input string InpBearishFVGPrefix  = "FVG OB";
input color  InpBearishFVGColor   = clrChocolate;
input int    InpFVGSearchBars     = 100;

//--- Trade Management
input group "Trade Management"
input ulong  InpMagicNumber         = 123456;
input double InpRiskPercent         = 2.0;
input bool   InpUseFixedRR          = false;
input double InpFixedRR             = 3.0;
input double InpMinRR               = 2.0;
input int    InpSL_BufferPoints     = 20;
input double InpMinLot              = 0.01;
input double InpMaxLot              = 100.0;
input int    InpSlippagePoints      = 10;
input bool   InpCloseOnOpposite     = true;

//--- Session Filter
input group "Session Filter (GMT)"
input bool   InpUseSessionFilter    = true;
input string InpLondonOpen          = "07:00";
input string InpLondonClose         = "16:00";
input string InpNYOpen              = "12:00";
input string InpNYClose             = "21:00";

//--- General
input group "General Settings"
input bool   InpDebug               = true;
input int    InpPatternConfirmBars  = 5;
input int    InpMaxSignalAgeBars    = 10;


//--- Enums & Globals
enum Sig { SIG_NONE=0, SIG_BUY=1, SIG_SELL=2 };

CTrade   g_trade;
datetime g_last_bar_time = 0;
string   g_status_lbl    = "MultiSignalEA_Status";
int      h_zz_large, h_zz_reg, h_supertrend, h_pattern, h_heiken, h_fvg_visual;
string   gv_processed_lzz_idx_name;

//--- Forward Declarations
void StatusLabel(const string text);
double NormalizeLots(double lots);
double CalcLotsByRisk(double entry, double sl);
bool CheckEntryTrigger(Sig direction, int check_from_bar);
bool GetLastTwoZigZagPoints(int handle, int start_shift, double &last_val, int &last_idx, double &prev_val, int &prev_idx);
bool CloseCurrentPosition();

//+------------------------------------------------------------------+
//| Utility Functions                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol,_Period,0);
   if(t!=g_last_bar_time){ g_last_bar_time=t; return true; }
   return false;
}
string SigToStr(Sig s){ return (s==SIG_BUY?"BUY":(s==SIG_SELL?"SELL":"NONE")); }

//+------------------------------------------------------------------+
//| Trade Management Functions                                       |
//+------------------------------------------------------------------+
void ManageActiveTrades()
{
   if(!InpUsePartialTP && !InpUseBreakEven) return;
   if(!PositionSelect(_Symbol) || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) return;

   ulong              ticket         = PositionGetInteger(POSITION_TICKET);
   ENUM_POSITION_TYPE type           = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double             open_price     = PositionGetDouble(POSITION_PRICE_OPEN);
   double             initial_sl     = PositionGetDouble(POSITION_SL);
   double             initial_tp     = PositionGetDouble(POSITION_TP);
   double             initial_volume = PositionGetDouble(POSITION_VOLUME);

   if(initial_sl == 0) return;

   // --- 1. PARTIAL TAKE PROFIT LOGIC ---
   if(InpUsePartialTP)
     {
      string gv_partial_name = StringFormat("EA_Partial_%I64u", ticket);
      if(!GlobalVariableCheck(gv_partial_name))
        {
         double risk_dist_p = 0, partial_tp_price = 0, current_price = 0;
         bool partial_target_hit = false;
         if(type == POSITION_TYPE_BUY)
           {
            risk_dist_p = open_price - initial_sl;
            if(risk_dist_p > 0){ partial_tp_price = open_price + (risk_dist_p * InpPartialTP_RR); current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID); if(current_price >= partial_tp_price) partial_target_hit = true; }
           }
         else
           {
            risk_dist_p = initial_sl - open_price;
            if(risk_dist_p > 0){ partial_tp_price = open_price - (risk_dist_p * InpPartialTP_RR); current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); if(current_price <= partial_tp_price) partial_target_hit = true; }
           }
         if(partial_target_hit)
           {
            double volume_to_close = NormalizeLots(initial_volume * (InpPartialClosePercent / 100.0));
            if(volume_to_close > 0 && volume_to_close < initial_volume)
              {
               if(InpDebug) PrintFormat("Partial TP hit for Ticket #%I64u. Closing %.2f lots.", ticket, volume_to_close);
               if(g_trade.PositionClosePartial(ticket, volume_to_close, (ulong)InpSlippagePoints)) { GlobalVariableSet(gv_partial_name, 1); }
               else { if(InpDebug) PrintFormat("Failed to partially close Ticket #%I64u. Error: %d, %s", ticket, (int)g_trade.ResultRetcode(), g_trade.ResultComment()); }
              }
           }
        }
     }

   // --- 2. BREAK-EVEN LOGIC ---
   if(InpUseBreakEven && PositionSelect(_Symbol))
     {
      string gv_be_name = StringFormat("EA_BreakEven_%I64u", ticket);
      if(!GlobalVariableCheck(gv_be_name))
        {
         double risk_dist_p = 0, be_trigger_price = 0, new_sl_price = 0, current_price = 0;
         bool be_target_hit = false;
         double current_sl = PositionGetDouble(POSITION_SL);
         if(type == POSITION_TYPE_BUY)
           {
            risk_dist_p = open_price - initial_sl;
            if(risk_dist_p > 0) { be_trigger_price = open_price + (risk_dist_p * InpBreakEven_RR); current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID); new_sl_price = open_price + (InpBreakEven_Pips * _Point); if(current_price >= be_trigger_price && current_sl < new_sl_price) be_target_hit = true; }
           }
         else
           {
            risk_dist_p = initial_sl - open_price;
            if(risk_dist_p > 0) { be_trigger_price = open_price - (risk_dist_p * InpBreakEven_RR); current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); new_sl_price = open_price - (InpBreakEven_Pips * _Point); if(current_price <= be_trigger_price && current_sl > new_sl_price) be_target_hit = true; }
           }
         if(be_target_hit)
           {
            if(InpDebug) PrintFormat("Break-Even trigger hit for Ticket #%I64u. Moving SL to %.5f", ticket, new_sl_price);
            if(g_trade.PositionModify(ticket, new_sl_price, initial_tp)) { GlobalVariableSet(gv_be_name, 1); }
            else { if(InpDebug) PrintFormat("Ticket #%I64u: Failed to move SL to BE. Error: %d, %s", ticket, (int)g_trade.ResultRetcode(), g_trade.ResultComment()); }
           }
        }
     }
}

//+------------------------------------------------------------------+
//| Daily Loss Limit Functions                                       |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         CTrade localTrade;
         localTrade.SetExpertMagicNumber(InpMagicNumber);
         if(localTrade.PositionClose(ticket, (ulong)InpSlippagePoints)) PrintFormat("Position #%I64u closed due to daily loss limit.", ticket);
         else PrintFormat("Error closing position #%I64u. Error: %d", ticket, (int)localTrade.ResultRetcode());
      }
     }
}

bool DailyLossLimitHit()
{
   if(!InpUseDailyLossLimit) return false;
   long account_num = AccountInfoInteger(ACCOUNT_LOGIN);
   string gv_start_equity_name = StringFormat("EA_StartEquity_%d", account_num);
   string gv_stopped_flag_name = StringFormat("EA_TradingStopped_%d", account_num);
   string gv_last_day_name     = StringFormat("EA_LastDay_%d", account_num);
   MqlDateTime current_time;
   TimeCurrent(current_time);
   int current_day = current_time.day_of_year;
   int last_day = (int)GlobalVariableGet(gv_last_day_name);
   if(current_day != last_day)
     {
      GlobalVariableSet(gv_start_equity_name, AccountInfoDouble(ACCOUNT_EQUITY));
      GlobalVariableSet(gv_stopped_flag_name, 0);
      GlobalVariableSet(gv_last_day_name, current_day);
      if(InpDebug) PrintFormat("New Day %d. Daily equity loss limit has been reset. Starting Equity: %.2f", current_day, AccountInfoDouble(ACCOUNT_EQUITY));
      return false;
     }
   if(GlobalVariableGet(gv_stopped_flag_name) == 1) return true;
   double start_equity = GlobalVariableGet(gv_start_equity_name);
   if(start_equity <= 0) { GlobalVariableSet(gv_start_equity_name, AccountInfoDouble(ACCOUNT_EQUITY)); return false; }
   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double equity_change_pct = ((current_equity / start_equity) - 1.0) * 100.0;
   if(equity_change_pct <= InpMaxDailyEquityLossPct)
     {
      PrintFormat("!!! DAILY EQUITY LOSS LIMIT HIT !!! Start Equity: %.2f, Current Equity: %.2f (%.2f%%). Stopping trading.", start_equity, current_equity, equity_change_pct);
      GlobalVariableSet(gv_stopped_flag_name, 1);
      if(InpCloseTradesOnLossHit) CloseAllPositions();
      return true;
     }
   return false;
}

//+------------------------------------------------------------------+
//| Indicator Handling & Analysis                                    |
//+------------------------------------------------------------------+
bool AttachIndicators()
{
   h_zz_large = iCustom(_Symbol, _Period, "ZigZag_Large", InpZZLarge_Depth, InpZZLarge_Deviation, InpZZLarge_Backstep);
   if(h_zz_large == INVALID_HANDLE) { Print("Error attaching ZigZag_Large."); return false; }
   h_zz_reg = iCustom(_Symbol, _Period, "Examples\\ZigZag", InpZZReg_Depth, InpZZReg_Deviation, InpZZReg_Backstep);
   if(h_zz_reg == INVALID_HANDLE) { Print("Error attaching ZigZag."); return false; }
   h_supertrend = iCustom(_Symbol, _Period, "supertrend");
   if(h_supertrend == INVALID_HANDLE) { Print("Error attaching supertrend.ex5."); return false; }
   h_pattern = iCustom(_Symbol, _Period, "bheurekso-pattern-indicator");
   if(h_pattern == INVALID_HANDLE) { Print("Error attaching bheurekso-pattern-indicator.ex5."); return false; }
   h_heiken = iCustom(_Symbol, _Period, "Examples\\Heiken_Ashi");
   if(h_heiken == INVALID_HANDLE) { Print("Error attaching Heiken_Ashi.ex5."); return false; }
   h_fvg_visual = iCustom(_Symbol, _Period, "FVG MT5 By TFlab");
   if(h_fvg_visual == INVALID_HANDLE) { Print("Error attaching 'FVG MT5 By TFlab.ex5'."); return false; }
   ChartIndicatorAdd(0,0,h_zz_large); ChartIndicatorAdd(0,0,h_zz_reg); ChartIndicatorAdd(0,0,h_supertrend);
   ChartIndicatorAdd(0,0,h_pattern); ChartIndicatorAdd(0,0,h_heiken); ChartIndicatorAdd(0,0,h_fvg_visual);
   Print("All indicators attached successfully.");
   return true;
}

bool GetLastTwoZigZagPoints(int handle, int start_shift, double &last_val, int &last_idx, double &prev_val, int &prev_idx)
{
    double zz_buff[];
    ArraySetAsSeries(zz_buff, true);
    if(CopyBuffer(handle, 0, start_shift, 300, zz_buff) < 2) return false;
    int found = 0;
    for(int i = 0; i < 300; i++)
    {
        if(zz_buff[i] > 0)
        {
            if(found == 0) { last_val = zz_buff[i]; last_idx = start_shift + i; found++; }
            else if(found == 1) { prev_val = zz_buff[i]; prev_idx = start_shift + i; return true; }
        }
    }
    return false;
}

bool FindTouchingFVG(int bar_index_to_check, double price_to_check, Sig direction, double &fvg_top, double &fvg_bottom)
{
   string prefix_to_find = (direction == SIG_BUY) ? InpBullishFVGPrefix : InpBearishFVGPrefix;
   color  color_to_find  = (direction == SIG_BUY) ? InpBullishFVGColor : InpBearishFVGColor;
   datetime bar_time_to_check = iTime(_Symbol, _Period, bar_index_to_check);
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i);
      if(StringFind(name, prefix_to_find) == -1) continue;
      if((color)ObjectGetInteger(0, name, OBJPROP_COLOR) != color_to_find) continue;
      datetime time1 = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 0);
      datetime time2 = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 1);
      double   price1 = ObjectGetDouble(0, name, OBJPROP_PRICE, 0);
      double   price2 = ObjectGetDouble(0, name, OBJPROP_PRICE, 1);
      if(time1 > time2) { datetime temp_t = time1; time1 = time2; time2 = temp_t; }
      if(price1 < price2) { double temp_p = price1; price1 = price2; price2 = temp_p; }
      if(bar_time_to_check >= time1 && bar_time_to_check <= time2 && price_to_check <= price1 && price_to_check >= price2)
      {
         fvg_top = price1; fvg_bottom = price2;
         if(InpDebug) PrintFormat("FVG Check PASSED: ZZ point at bar %d is inside FVG '%s'.", bar_index_to_check, name);
         return true;
      }
     }
   return false;
}

bool CheckFVGViolation(int signal_bar_index, double fvg_top, double fvg_bottom, Sig direction)
{
   int bars_to_check = signal_bar_index - 1;
   if(bars_to_check <= 0) return false;
   double close_prices[];
   if(CopyClose(_Symbol, _Period, 1, bars_to_check, close_prices) <= 0) return true;
   ArraySetAsSeries(close_prices, true);
   for(int i = 0; i < bars_to_check; i++)
     {
      if(direction == SIG_BUY && close_prices[i] < fvg_bottom) { if(InpDebug) Print("FVG VIOLATION: Closed below bullish FVG."); return true; }
      if(direction == SIG_SELL && close_prices[i] > fvg_top) { if(InpDebug) Print("FVG VIOLATION: Closed above bearish FVG."); return true; }
     }
   return false;
}

bool ExtractLatestPattern(int ref_shift, Sig &dir_out, datetime &time_out, int &bar_idx_out)
{
   dir_out = SIG_NONE;
   time_out = 0;
   datetime cutoff = iTime(_Symbol,_Period,ref_shift);
   int total = ObjectsTotal(0,0,-1);
   if(total<=0) return false;
   datetime best_time = 0;
   Sig      best_dir  = SIG_NONE;
   for(int i=total-1;i>=0;--i)
   {
      string nm = ObjectName(0,i);
      if(nm=="") continue;
      long type = (long)ObjectGetInteger(0,nm,OBJPROP_TYPE);
      if(type!=OBJ_TEXT && type!=OBJ_ARROW) continue;
      datetime ot = (datetime)ObjectGetInteger(0,nm,OBJPROP_TIME);
      if(ot==0 || ot>cutoff) continue;
      Sig sig = SIG_NONE;
      if(type==OBJ_TEXT) {
         string txt = ObjectGetString(0,nm,OBJPROP_TEXT);
         string lo  = StringToLower(txt);
         if(StringFind(lo,"bull",0)!=-1) sig=SIG_BUY; else if(StringFind(lo,"bear",0)!=-1) sig=SIG_SELL;
      } else if(type==OBJ_ARROW) {
         long code = (long)ObjectGetInteger(0,nm,OBJPROP_ARROWCODE);
         if(code==233) sig = SIG_BUY; else if(code==234) sig = SIG_SELL;
      }
      if(sig!=SIG_NONE && ot>=best_time) { best_time = ot; best_dir  = sig; }
   }
   if(best_time>0) { dir_out = best_dir; time_out= best_time; bar_idx_out = iBarShift(_Symbol, _Period, best_time); return true; }
   return false;
}

bool CheckEntryTrigger(Sig direction, int check_from_bar)
{
    double ha_open[], ha_close[];
    if(CopyBuffer(h_heiken, 0, check_from_bar, 1, ha_open) > 0 && CopyBuffer(h_heiken, 3, check_from_bar, 1, ha_close) > 0)
    {
        if(direction == SIG_BUY && ha_close[0] > ha_open[0]) { if(InpDebug) Print("Entry trigger: Bullish Heiken Ashi confirmed."); return true; }
        if(direction == SIG_SELL && ha_close[0] < ha_open[0]) { if(InpDebug) Print("Entry trigger: Bearish Heiken Ashi confirmed."); return true; }
    }
    Sig p_sig;
    datetime p_time; int p_idx;
    for(int i = check_from_bar; i < check_from_bar + InpPatternConfirmBars; i++)
    {
        if(ExtractLatestPattern(i, p_sig, p_time, p_idx))
        {
            if(p_sig == direction)
            {
                int confirm_idx = p_idx - 1;
                if(confirm_idx < 0) continue;
                double c_open[], c_close[];
                if(CopyOpen(_Symbol, _Period, confirm_idx, 1, c_open) > 0 && CopyClose(_Symbol, _Period, confirm_idx, 1, c_close) > 0)
                {
                    if(direction == SIG_BUY && c_close[0] > c_open[0]) { if(InpDebug) PrintFormat("Entry trigger: Bullish pattern confirmed at %s.", TimeToString(p_time)); return true; }
                    if(direction == SIG_SELL && c_close[0] < c_open[0]) { if(InpDebug) PrintFormat("Entry trigger: Bearish pattern confirmed at %s.", TimeToString(p_time)); return true; }
                }
            }
        }
    }
    return false;
}

bool IsTradeTime()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime srv_time; TimeCurrent(srv_time);
   int now_in_minutes = srv_time.hour * 60 + srv_time.min;
   int lon_open_in_minutes = (int)StringSubstr(InpLondonOpen, 0, 2) * 60 + (int)StringSubstr(InpLondonOpen, 3, 2);
   int lon_close_in_minutes = (int)StringSubstr(InpLondonClose, 0, 2) * 60 + (int)StringSubstr(InpLondonClose, 3, 2);
   int ny_open_in_minutes = (int)StringSubstr(InpNYOpen, 0, 2) * 60 + (int)StringSubstr(InpNYOpen, 3, 2);
   int ny_close_in_minutes = (int)StringSubstr(InpNYClose, 0, 2) * 60 + (int)StringSubstr(InpNYClose, 3, 2);
   bool in_london = (now_in_minutes >= lon_open_in_minutes && now_in_minutes < lon_close_in_minutes);
   bool in_ny = (now_in_minutes >= ny_open_in_minutes && now_in_minutes < ny_close_in_minutes);
   return (in_london || in_ny);
}

//+------------------------------------------------------------------+
//| Trading Functions                                                |
//+------------------------------------------------------------------+
void OpenTrade(Sig side, double sl_price, double tp_price, int lzz_last_idx)
{
    double entry_price = (side == SIG_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lots = NormalizeLots(CalcLotsByRisk(entry_price, sl_price));
    
    if(side == SIG_BUY) g_trade.Buy(lots, _Symbol, entry_price, sl_price, tp_price, "Buy Signal");
    else g_trade.Sell(lots, _Symbol, entry_price, sl_price, tp_price, "Sell Signal");

    if(g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
    {
        if(InpDebug) PrintFormat("OPEN %s: lots=%.2f, entry=%.5f, SL=%.5f, TP=%.5f", SigToStr(side), lots, entry_price, sl_price, tp_price);
        GlobalVariableSet(gv_processed_lzz_idx_name, lzz_last_idx);
        if(InpDebug) PrintFormat("Large ZZ swing at bar %d has been processed. Waiting for new swing.", lzz_last_idx);
    }
    else
    {
       if(InpDebug) PrintFormat(" -> FAILED to open trade: %d, %s", (int)g_trade.ResultRetcode(), g_trade.ResultComment());
    }
}

bool CloseCurrentPosition()
{
   if(!PositionSelect(_Symbol)) return true;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) return true;
   
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   bool ok = g_trade.PositionClose(ticket, (ulong)InpSlippagePoints);
   if(InpDebug)
   {
      string side_str = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
      PrintFormat("CLOSE %s -> %s", side_str, (ok ? "OK" : "FAIL"));
   }
   return ok;
}

void HandleTradeExecution(Sig side, double sl_price, double tp_price, int lzz_last_idx)
{
    if(PositionSelect(_Symbol))
    {
       if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
       {
          ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
          Sig current_side = (pos_type == POSITION_TYPE_BUY) ? SIG_BUY : SIG_SELL;

          if(current_side == side)
          {
             if(InpDebug) Print("Signal ignored. A trade in the same direction is already open.");
             return;
          }
          else // Opposite Signal
          {
             if(InpCloseOnOpposite)
             {
                if(InpDebug) Print("Opposite signal detected. Closing current position to reverse.");
                if(CloseCurrentPosition())
                {
                   OpenTrade(side, sl_price, tp_price, lzz_last_idx);
                }
                else
                {
                   if(InpDebug) Print("Failed to close existing position. Cannot open new reverse trade.");
                }
             }
             else
             {
                if(InpDebug) Print("Opposite signal ignored because 'InpCloseOnOpposite' is false.");
             }
          }
       }
       else
       {
          if(InpDebug) Print("Signal ignored. A position with a different Magic Number already exists.");
       }
    }
    else // No position exists
    {
        OpenTrade(side, sl_price, tp_price, lzz_last_idx);
    }
}

//+------------------------------------------------------------------+
//| Main Logic Check (Corrected)                                     |
//+------------------------------------------------------------------+
void CheckForSignal()
{
    if(!IsTradeTime()) return;
    
    bool position_is_open = (PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber);

    // Get latest confirmed Large ZigZag swing
    double lzz_last_val=0, lzz_prev_val=0;
    int lzz_last_idx=0, lzz_prev_idx=0;
    if(!GetLastTwoZigZagPoints(h_zz_large, 2, lzz_last_val, lzz_last_idx, lzz_prev_val, lzz_prev_idx)) return;

    // If we don't have an open position, we must not trade on an already processed swing.
    if(!position_is_open && lzz_last_idx == (int)GlobalVariableGet(gv_processed_lzz_idx_name)) return;
    
    // Get latest confirmed Regular ZigZag pullback
    double rzz_last_val=0, rzz_prev_val=0;
    int rzz_last_idx=0, rzz_prev_idx=0;
    
    // Check if any confirmed RZZ point has formed AFTER the LZZ point
    if(!GetLastTwoZigZagPoints(h_zz_reg, 2, rzz_last_val, rzz_last_idx, rzz_prev_val, rzz_prev_idx) || rzz_last_idx >= lzz_last_idx)
    {
        // This is normal. A new LZZ swing has formed, but the pullback hasn't happened yet. We just wait.
        return;
    }
    
    // --- At this point, a pullback exists. We now evaluate it. ---
    
    // This is the FIRST TIME we are evaluating this specific LZZ swing.
    // From now on, any failure in the setup means this LZZ swing is invalid and should be marked as processed.
    if(lzz_last_idx != (int)GlobalVariableGet(gv_processed_lzz_idx_name))
    {
        Sig direction = SIG_NONE;
        bool is_valid_structure = false;

        // Check for a valid Higher Low or Lower High structure
        if(lzz_last_val < lzz_prev_val && rzz_last_val < rzz_prev_val && rzz_last_val > lzz_last_val)
        {
            direction = SIG_BUY;
            is_valid_structure = true;
        }
        else if(lzz_last_val > lzz_prev_val && rzz_last_val > rzz_prev_val && rzz_last_val < lzz_last_val)
        {
            direction = SIG_SELL;
            is_valid_structure = true;
        }

        // If the very first pullback available doesn't form the right structure, this LZZ swing is invalid.
        if(!is_valid_structure)
        {
            if(InpDebug) PrintFormat("First RZZ pullback at bar %d is not a valid structure. Marking LZZ swing at %d as processed.", rzz_last_idx, lzz_last_idx);
            GlobalVariableSet(gv_processed_lzz_idx_name, lzz_last_idx);
            return;
        }

        // --- Structure is valid. Now check all other filters. ---
        if(InpDebug) PrintFormat("Found first valid pullback for %s at bar %d. Validating filters...", SigToStr(direction), rzz_last_idx);

        // Age Filter
        if(rzz_last_idx > InpMaxSignalAgeBars)
        {
           if(InpDebug) Print(" -> AGE FAILED. Marking LZZ swing as processed."); 
           GlobalVariableSet(gv_processed_lzz_idx_name, lzz_last_idx); 
           return;
        }

        // FVG Filter
        if(InpUseFVGFilter)
        {
           double fvg_top = 0, fvg_bottom = 0;
           int fvg_signal_bar = -1;
           bool fvg_touch_valid = false;
           
           if(FindTouchingFVG(lzz_last_idx, lzz_last_val, direction, fvg_top, fvg_bottom)) { fvg_touch_valid = true; fvg_signal_bar = lzz_last_idx; }
           else if(FindTouchingFVG(rzz_last_idx, rzz_last_val, direction, fvg_top, fvg_bottom)) { fvg_touch_valid = true; fvg_signal_bar = rzz_last_idx; }

           if(!fvg_touch_valid || CheckFVGViolation(fvg_signal_bar, fvg_top, fvg_bottom, direction)) 
           { if(InpDebug) Print(" -> FVG FAILED. Marking LZZ swing as processed."); GlobalVariableSet(gv_processed_lzz_idx_name, lzz_last_idx); return; }
           if(InpDebug) Print(" -> FVG PASSED.");
        }
        
        // Supertrend Filter at setup time
        double st_setup_buff[], close_setup[];
        if(CopyBuffer(h_supertrend, 0, rzz_last_idx, 1, st_setup_buff) <= 0) return;
        if(CopyClose(_Symbol, _Period, rzz_last_idx, 1, close_setup) <= 0) return;
        if((direction == SIG_BUY && st_setup_buff[0] >= close_setup[0]) || (direction == SIG_SELL && st_setup_buff[0] != 0 && st_setup_buff[0] <= close_setup[0]))
        {
            if(InpDebug) PrintFormat(" -> Supertrend FAILED at setup. Marking LZZ swing as processed."); GlobalVariableSet(gv_processed_lzz_idx_name, lzz_last_idx); return;
        }
        if(InpDebug) Print(" -> Supertrend at setup PASSED.");
        
        // --- All filters passed. Now we just need an entry trigger. ---
        if(CheckEntryTrigger(direction, 1))
        {
            double st_entry_buff[], close_entry[];
            if(CopyBuffer(h_supertrend, 0, 1, 1, st_entry_buff) <= 0) return;
            if(CopyClose(_Symbol, _Period, 1, 1, close_entry) <= 0) return;
            bool st_ok = false;
            if(direction == SIG_BUY && st_entry_buff[0] > 0 && st_entry_buff[0] < close_entry[0]) st_ok = true;
            if(direction == SIG_SELL && st_entry_buff[0] > close_entry[0]) st_ok = true;
            
            if(st_ok)
            {
                if(InpDebug) Print(" -> Final Supertrend check PASSED. Preparing trade.");
                double sl=0, entry=0, sl_dist=0, tp_target=0;
                if(direction == SIG_BUY)
                {
                   sl = lzz_last_val - (InpSL_BufferPoints * _Point) - (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point);
                   entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                   sl_dist = entry - sl;
                   if(sl_dist <= 0) { if(InpDebug) Print("SL distance is zero or negative. Aborting trade."); return; }
                   if(InpUseFixedRR) { tp_target = entry + (sl_dist * InpFixedRR); }
                   else { tp_target = lzz_prev_val; if((tp_target - entry) / sl_dist < InpMinRR) { tp_target = entry + (sl_dist * InpMinRR); } }
                }
                else
                {
                   sl = lzz_last_val + (InpSL_BufferPoints * _Point) + (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point);
                   entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                   sl_dist = sl - entry;
                   if(sl_dist <= 0) { if(InpDebug) Print("SL distance is zero or negative. Aborting trade."); return; }
                   if(InpUseFixedRR) { tp_target = entry - (sl_dist * InpFixedRR); }
                   else { tp_target = lzz_prev_val; if((entry - tp_target) / sl_dist < InpMinRR) { tp_target = entry - (sl_dist * InpMinRR); } }
                }
                HandleTradeExecution(direction, sl, tp_target, lzz_last_idx);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| MQL5 Functions                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   gv_processed_lzz_idx_name = StringFormat("EA_%d_%s_%s_ProcLZZ", InpMagicNumber, _Symbol, EnumToString(_Period));
   if(!AttachIndicators()){ return(INIT_FAILED); }
   if(InpUseDailyLossLimit)
     {
      long account_num = AccountInfoInteger(ACCOUNT_LOGIN);
      MqlDateTime current_time; TimeCurrent(current_time);
      string gv_last_day_name = StringFormat("EA_LastDay_%d", account_num);
      if(!GlobalVariableCheck(gv_last_day_name) || (int)GlobalVariableGet(gv_last_day_name) != current_time.day_of_year)
        {
         GlobalVariableSet(gv_last_day_name, current_time.day_of_year);
         GlobalVariableSet(StringFormat("EA_StartEquity_%d", account_num), AccountInfoDouble(ACCOUNT_EQUITY));
         GlobalVariableSet(StringFormat("EA_TradingStopped_%d", account_num), 0);
        }
      Print("Daily equity loss limit initialized.");
     }
   StatusLabel("MultiSignalEA Initialized...");
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectDelete(0,g_status_lbl);
   IndicatorRelease(h_zz_large); IndicatorRelease(h_zz_reg); IndicatorRelease(h_supertrend);
   IndicatorRelease(h_pattern); IndicatorRelease(h_heiken); IndicatorRelease(h_fvg_visual);

   if(reason == REASON_REMOVE)
   {
      GlobalVariableDel(gv_processed_lzz_idx_name);
       for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            ulong ticket = PositionGetTicket(i);
            GlobalVariableDel(StringFormat("EA_Partial_%I64u", ticket));
            GlobalVariableDel(StringFormat("EA_BreakEven_%I64u", ticket));
           }
        }
   }
}

void OnTick()
{
   if(DailyLossLimitHit())
     {
      StatusLabel("DAILY LOSS LIMIT HIT. Trading stopped.");
      return;
     }
   ManageActiveTrades();
   if(!IsNewBar()) return;
   
   string session_status = "Inactive";
   if(!InpUseSessionFilter) session_status = "Filter Off";
   else if(IsTradeTime()) session_status = "Active";
   
   int last_processed_bar = (int)GlobalVariableGet(gv_processed_lzz_idx_name);

   string lbl = StringFormat("MultiSignalEA v2.0.2 | %s | %s\nLast Bar: %s\nSession: %s\nProcessed LZZ: %d",
      _Symbol, EnumToString(_Period), TimeToString(g_last_bar_time, TIME_DATE|TIME_MINUTES),
      session_status, last_processed_bar);
   StatusLabel(lbl);
   
   CheckForSignal();
}

//+------------------------------------------------------------------+
//| Helper Functions (Risk Calc, Status Label, etc.)                 |
//+------------------------------------------------------------------+
double CalcLotsByRisk(double entry, double sl)
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money = bal * (InpRiskPercent/100.0);
   if(risk_money<=0) return InpMinLot;
   double dist = MathAbs(entry - sl);
   if(dist < 2*_Point) dist = 2*_Point;
   double tick_val  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_val<=0 || tick_size<=0) return InpMinLot;
   double ticks = dist / tick_size;
   double money_per_lot = ticks * tick_val;
   if(money_per_lot<=0) return InpMinLot;
   return NormalizeLots(risk_money / money_per_lot);
}
//---
double NormalizeLots(double lots)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minv=MathMax(InpMinLot,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   double maxv=MathMin(InpMaxLot,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX));
   if(step<=0) step=0.01;
   lots = MathMax(minv, MathMin(maxv, lots));
   return(MathRound(lots/step)*step);
}
//---
void StatusLabel(const string text)
{
   if(ObjectFind(0,g_status_lbl)==-1)
   {
      ObjectCreate(0,g_status_lbl,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,g_status_lbl,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,g_status_lbl,OBJPROP_XDISTANCE,8);
      ObjectSetInteger(0,g_status_lbl,OBJPROP_YDISTANCE,18);
      ObjectSetInteger(0,g_status_lbl,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,g_status_lbl,OBJPROP_FONTSIZE,9);
      ObjectSetString (0,g_status_lbl,OBJPROP_FONT,"Arial");
   }
   ObjectSetString(0,g_status_lbl,OBJPROP_TEXT,text);
}