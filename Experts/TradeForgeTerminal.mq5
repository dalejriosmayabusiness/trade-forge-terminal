//+------------------------------------------------------------------+
//| TradeForgeTerminal.mq5                                           |
//| TradeForge terminal: talks only to Maya, only obeys orders.      |
//| Step 1: login, config, heartbeat, candle feed, control panel.    |
//| Step 2: price alerts (terminalPoll / terminalReport).            |
//| (trade execution comes next)                                     |
//+------------------------------------------------------------------+
#property copyright "TradeForge"
#property version   "0.21"
#property description "Terminal of the TradeForge trading system (Maya Business)."
#property strict

#include "../Include/TradeForge/TF_Json.mqh"
#include "../Include/TradeForge/TF_Maya.mqh"
#include "../Include/TradeForge/TF_Candles.mqh"
#include "../Include/TradeForge/TF_Alerts.mqh"
#include "../Include/TradeForge/TF_Panel.mqh"

// Bump on EVERY change: it is shown in the panel (with the compile time) and reported to Maya in each heartbeat,
// so you can tell at a glance that a recompiled EA is the one actually running.
#define TF_VERSION     "0.21.0"
#define TF_BUILD       __DATETIME__
#define TF_GV_ACTIVE   "TradeForge_Active"

input group "Maya connection"
input string MayaUrl       = "https://api-dev-tradeforge.tunnel.maya.business"; // Maya API base URL
input string BridgeKey     = "";   // Bridge key (trading bot)
input string BridgeSecret  = "";   // Bridge secret
input string TerminalToken = "";   // Terminal token (generated in Maya, shown once)
input group "Behaviour"
input bool   StartActive   = true; // Start active the first time (afterwards the panel switch is remembered)
input bool   ShowPanel     = true; // Show the control panel on the chart
input int    PanelX        = 12;   // Panel X
input int    PanelY        = 24;   // Panel Y
input int    PanelScale    = 0;    // Panel size in % (0 = automatic from the screen DPI)

enum TFState
  {
   ST_PAUSED=0,
   ST_CONNECTING,
   ST_ONLINE,
   ST_ERROR
  };

//--- runtime
CMaya       g_maya;
CCandleFeed g_feed;
CAlertMonitor g_alerts;
CTFPanel    g_panel;
bool        g_active=true;
TFState     g_state=ST_PAUSED;
bool        g_configured=false;
string      g_lastError="";
ulong       g_nextConnectMs=0;
ulong       g_nextBeatMs=0;
ulong       g_nextCandlesMs=0;
ulong       g_nextConfigMs=0;
ulong       g_nextPollMs=0;
datetime    g_lastPoll=0;
int         g_connectFails=0;

//--- configuration loaded from Maya (terminalConfig / terminalHeartbeat)
string      g_terminalName="",g_accountLabel="";
string      g_strategyName="",g_strategyKey="",g_mode="";
bool        g_strategyActive=true;
string      g_instrument="",g_symbol="";
string      g_timeframes[];
int         g_heartbeatSec=30;
int         g_pollSec=5;            // how often alerts/trades are asked for (Terminal.pollSeconds in Maya)
bool        g_feeder=false;
long        g_leaseUntil=0;
datetime    g_lastBeat=0;           // local time of the last good heartbeat
datetime    g_lastCandles=0;
int         g_lastCandleCount=0;
int         g_lastCandleMs=0;
int         g_candlesSent=0;
bool        g_disabledInMaya=false;

//+------------------------------------------------------------------+
string Params(const string extra="")
  {
   return "{\"token\":"+TF_JStr(g_maya.Token())+(extra!="" ? ","+extra : "")+"}";
  }

void SetError(const string msg)
  {
   g_lastError=msg;
   if(msg!="")
      Print("TradeForge: ",msg);
  }

//--- Interprets a failure of an Action. Returns true when the terminal must stop retrying fast.
bool IsFatal(const string err)
  {
   return (StringFind(err,"INVALID_TERMINAL_TOKEN")>=0 || StringFind(err,"TERMINAL_DISABLED")>=0);
  }

//+------------------------------------------------------------------+
//| terminalConfig                                                   |
//+------------------------------------------------------------------+
bool LoadConfig(void)
  {
   CJv *d=g_maya.Action("terminalConfig",Params());
   if(d==NULL)
     {
      string e=g_maya.LastError();
      g_disabledInMaya=(StringFind(e,"TERMINAL_DISABLED")>=0);
      SetError(e);
      return false;
     }
   g_disabledInMaya=false;
   CJv *t=d.Get("terminal");
   CJv *s=d.Get("strategy");
   g_terminalName=t.Str("name");
   g_accountLabel=t.Str("accountLabel");
   g_heartbeatSec=(int)MathMax(5,t.Num("heartbeatSeconds",30));
   g_pollSec=(int)MathMax(2,t.Num("pollSeconds",5));
   g_strategyName=s.Str("name");
   g_strategyKey=s.Str("key");
   g_strategyActive=s.Bool("isActive",true);
   g_mode=s.Str("mode");
   g_instrument=d.Get("instrument").Str("key");
   g_symbol=d.Str("symbol");
   g_feeder=d.Bool("feeder");
   CJv *tf=d.Get("timeframes");
   ArrayResize(g_timeframes,tf.Size());
   for(int i=0;i<tf.Size();i++)
      g_timeframes[i]=tf.At(i).AsStr();
   if(g_symbol=="" || ArraySize(g_timeframes)==0)
     {
      SetError("terminalConfig returned no symbol or timeframes");
      return false;
     }
   if(!SymbolSelect(g_symbol,true))
     {
      SetError("Symbol '"+g_symbol+"' does not exist in this broker (set Terminal.symbolMap in Maya)");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| terminalHeartbeat                                                |
//+------------------------------------------------------------------+
bool Heartbeat(void)
  {
   string extra="\"version\":"+TF_JStr(TF_VERSION);
   if(g_lastError!="")
      extra+=",\"error\":"+TF_JStr(StringSubstr(g_lastError,0,400));
   CJv *d=g_maya.Action("terminalHeartbeat",Params(extra));
   if(d==NULL)
     {
      SetError(g_maya.LastError());
      return false;
     }
   bool wasFeeder=g_feeder;
   g_feeder=d.Bool("feeder");
   g_leaseUntil=(long)d.Num("leaseUntilTs",0);
   g_heartbeatSec=(int)MathMax(5,d.Num("heartbeatSeconds",g_heartbeatSec));
   g_pollSec=(int)MathMax(2,d.Num("pollSeconds",g_pollSec));
   g_mode=d.Str("mode",g_mode);
   g_strategyActive=d.Bool("strategyActive",true);
   string instr=d.Str("instrument");
   string sym=d.Str("symbol");
   g_lastBeat=TimeLocal();
   if(g_lastError!="" && !IsFatal(g_lastError))
      g_lastError="";   // reported once, then clear
   if(g_feeder && !wasFeeder)
     {
      g_feed.Reset();           // new feeder: resend the newest candles
      g_nextCandlesMs=0;
      g_nextPollMs=0;
     }
   if(!g_feeder && wasFeeder)
      g_alerts.Clear();
   if(instr!=g_instrument || sym!=g_symbol)
      g_configured=false;       // the strategy of this terminal changed in Maya: reload
   return true;
  }

//+------------------------------------------------------------------+
//| terminalUpsertCandles                                            |
//+------------------------------------------------------------------+
void SendCandles(void)
  {
   int digits=(int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);
   string arr,err="";
   int n=g_feed.Build(g_symbol,g_timeframes,digits,arr,err);
   if(n==0)
     {
      if(err!="") SetError(err);
      return;
     }
   CJv *d=g_maya.Action("terminalUpsertCandles",Params("\"candles\":"+arr),30000);
   if(d==NULL)
     {
      string e=g_maya.LastError();
      if(StringFind(e,"NOT_FEEDER")>=0)
        {
         LoseFeed();               // lost the lease: the next heartbeat tells who has it now
        }
      else
         SetError(e);
      return;
     }
   g_feed.Commit();
   g_lastCandles=TimeLocal();
   g_lastCandleCount=n;
   g_lastCandleMs=g_maya.LastMs();
   g_candlesSent+=n;
   CJv *errs=d.Get("errors");
   if(errs.Size()>0)
      SetError("Candle rejected: "+errs.At(0).Str("message"));
  }

//+------------------------------------------------------------------+
//| terminalReport (alerts) and terminalPoll                         |
//+------------------------------------------------------------------+
void LoseFeed(void)
  {
   g_feeder=false;
   g_alerts.Clear();
   g_nextBeatMs=0;      // ask who has the lease now
  }

void ReportAlerts(void)
  {
   string arr;
   int n=g_alerts.BuildReport(arr);
   if(n==0)
      return;
   CJv *d=g_maya.Action("terminalReport",Params("\"alerts\":"+arr));
   if(d==NULL)
     {
      SetError("Alert report failed: "+g_maya.LastError());   // kept pending: retried on the next step
      return;
     }
   g_alerts.ApplyReport(d.Get("alerts"));
  }

void Poll(void)
  {
   CJv *d=g_maya.Action("terminalPoll",Params());
   if(d==NULL)
     {
      string e=g_maya.LastError();
      if(StringFind(e,"NOT_FEEDER")>=0)
         LoseFeed();
      else
         SetError(e);
      return;
     }
   g_lastPoll=TimeLocal();
   g_alerts.Sync(d.Get("alerts"));
   // (d.Get("trades") is handled by the trade module, next step)
  }

//+------------------------------------------------------------------+
//| Scheduler (called every second)                                  |
//+------------------------------------------------------------------+
void Step(void)
  {
   ulong now=GetTickCount64();
   if(!g_active)
     {
      g_state=ST_PAUSED;
      return;
     }
   if(!g_configured)
     {
      if(now<g_nextConnectMs)
         return;
      g_state=ST_CONNECTING;
      if(LoadConfig())
        {
         g_configured=true;
         g_connectFails=0;
         g_nextBeatMs=0;
         g_nextCandlesMs=0;
         g_nextConfigMs=now+600000;   // refresh the config every 10 minutes
         g_state=ST_ONLINE;
         Print("TradeForge: configured. Terminal=",g_terminalName," strategy=",g_strategyKey," symbol=",g_symbol," mode=",g_mode);
        }
      else
        {
         g_connectFails++;
         g_state=ST_ERROR;
         // fatal errors (bad token, disabled) are retried slowly: someone has to fix them in Maya
         ulong wait=IsFatal(g_lastError) ? 60000 : (ulong)MathMin(60000,5000*g_connectFails);
         g_nextConnectMs=now+wait;
        }
      return;
     }
   if(now>=g_nextConfigMs)
     {
      g_configured=false;
      g_nextConnectMs=0;
      return;
     }
   // Alerts are local work: watch the ticks every second and deliver a crossing before anything else.
   if(g_feeder && g_strategyActive)
     {
      g_alerts.Monitor(g_symbol);
      ReportAlerts();
     }
   if(now>=g_nextBeatMs)
     {
      if(Heartbeat())
        {
         g_state=ST_ONLINE;
         g_nextBeatMs=now+(ulong)g_heartbeatSec*1000;
        }
      else
        {
         g_state=ST_ERROR;
         if(IsFatal(g_lastError))
           {
            g_configured=false;
            g_nextConnectMs=now+60000;
           }
         else
            g_nextBeatMs=now+(ulong)MathMin(g_heartbeatSec,15)*1000;
        }
      return;
     }
   if(g_feeder && g_strategyActive && now>=g_nextPollMs)
     {
      Poll();
      g_nextPollMs=GetTickCount64()+(ulong)g_pollSec*1000;
      return;
     }
   if(g_feeder && g_strategyActive && now>=g_nextCandlesMs)
     {
      SendCandles();
      g_nextCandlesMs=GetTickCount64()+60000;
     }
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
string Ago(const datetime t)
  {
   if(t==0) return "never";
   long s=(long)(TimeLocal()-t);
   if(s<0) s=0;
   if(s<120) return IntegerToString(s)+" s ago";
   return IntegerToString(s/60)+" min ago";
  }

void RefreshPanel(void)
  {
   if(!ShowPanel)
      return;
   TFRow r[TFP_ROWS];
   const color OK=C'80,200,120',BAD=C'235,90,90',WARN=C'240,190,70',TXT=C'210,215,225',DIM=C'130,140,160';

   switch(g_state)
     {
      case ST_PAUSED:     r[0].value="Paused (not talking to Maya)"; r[0].clr=WARN; break;
      case ST_CONNECTING: r[0].value="Connecting...";               r[0].clr=WARN; break;
      case ST_ONLINE:     r[0].value="Online";                      r[0].clr=OK;   break;
      default:            r[0].value=g_disabledInMaya ? "Disabled in Maya (Terminal.enabled)" : "Error - retrying"; r[0].clr=BAD; break;
     }
   string acct=AccountInfoString(ACCOUNT_SERVER)+" #"+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   ENUM_ACCOUNT_TRADE_MODE tm=(ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   string kind=(tm==ACCOUNT_TRADE_MODE_REAL) ? "REAL" : (tm==ACCOUNT_TRADE_MODE_CONTEST) ? "CONTEST" : "DEMO";
   r[1].value=acct+"  ["+kind+"]  "+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+" "+AccountInfoString(ACCOUNT_CURRENCY);
   r[1].clr=(tm==ACCOUNT_TRADE_MODE_REAL) ? WARN : TXT;
   r[2].value=g_configured ? g_terminalName+(g_accountLabel!="" ? "  ("+g_accountLabel+")" : "") : "-";
   r[2].clr=TXT;
   r[3].value=g_configured ? g_strategyKey+(g_strategyActive ? "" : "  [strategy inactive]") : "-";
   r[3].clr=g_strategyActive ? TXT : WARN;
   r[4].value=g_configured ? g_mode : "-";
   r[4].clr=(g_mode=="LIVE") ? BAD : OK;
   r[5].value=g_configured ? g_instrument+(g_symbol!=g_instrument ? "  (broker: "+g_symbol+")" : "") : "-";
   r[5].clr=TXT;
   r[6].value=!g_configured ? "-" : (g_feeder ? "YES - sending candles" : "No - standby (another terminal feeds)");
   r[6].clr=g_feeder ? OK : DIM;
   r[7].value=g_configured ? "every "+IntegerToString(g_heartbeatSec)+" s (poll "+IntegerToString(g_pollSec)+" s) - last "+Ago(g_lastBeat) : "-";
   r[7].clr=TXT;
   r[8].value=g_lastCandles==0 ? "-" : IntegerToString(g_lastCandleCount)+" in "+IntegerToString(g_lastCandleMs)+" ms - "+Ago(g_lastCandles)+" - total "+IntegerToString(g_candlesSent);
   r[8].clr=TXT;
   r[9].value=!g_feeder ? "-" : IntegerToString(g_alerts.Count())+" watching ("+IntegerToString(g_alerts.CountAbove())+" above, "+IntegerToString(g_alerts.Count()-g_alerts.CountAbove())+" below) - "+IntegerToString(g_alerts.TriggeredTotal())+" triggered";
   r[9].clr=TXT;
   r[11].value="v"+TF_VERSION+"  (built "+TimeToString(TF_BUILD,TIME_DATE|TIME_MINUTES)+")";
   r[11].clr=DIM;
   r[10].value=g_lastError=="" ? "-" : StringSubstr(g_lastError,0,50);
   r[10].clr=g_lastError=="" ? DIM : BAD;
   g_panel.SetSwitch(g_active);
   g_panel.SetRows(r);
  }

//+------------------------------------------------------------------+
void SetActive(const bool on)
  {
   g_active=on;
   GlobalVariableSet(TF_GV_ACTIVE,on ? 1.0 : 0.0);
   if(on)
     {
      g_configured=false;      // reload everything when resuming
      g_nextConnectMs=0;
      g_connectFails=0;
      g_state=ST_CONNECTING;
      Print("TradeForge: activated");
     }
   else
     {
      g_state=ST_PAUSED;
      g_feeder=false;
      g_alerts.Clear();
      Print("TradeForge: paused (no more heartbeats; Maya will release the lease)");
     }
   RefreshPanel();
  }

int OnInit()
  {
   if(StringFind(MayaUrl,"http")!=0 || BridgeKey=="" || BridgeSecret=="" || StringFind(TerminalToken,".")<1)
     {
      Print("TradeForge: set MayaUrl, BridgeKey, BridgeSecret and TerminalToken in the EA inputs.");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_maya.Setup(MayaUrl,BridgeKey,BridgeSecret,TerminalToken);
   g_active=GlobalVariableCheck(TF_GV_ACTIVE) ? (GlobalVariableGet(TF_GV_ACTIVE)>0.5) : StartActive;
   g_state=g_active ? ST_CONNECTING : ST_PAUSED;
   if(ShowPanel)
      g_panel.Create(0,PanelX,PanelY,PanelScale);
   RefreshPanel();
   EventSetTimer(1);
   Print("TradeForge terminal v",TF_VERSION," built ",TimeToString(TF_BUILD,TIME_DATE|TIME_MINUTES)," started (",g_active ? "active" : "paused",")");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(ShowPanel)
      g_panel.Destroy();
  }

void OnTimer()
  {
   Step();
   RefreshPanel();
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK || !ShowPanel)
      return;
   TF_PanelAction a=g_panel.OnClick(sparam);
   if(a==TFP_TOGGLE)
      SetActive(!g_active);
  }

void OnTick() {}
