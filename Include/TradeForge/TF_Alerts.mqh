//+------------------------------------------------------------------+
//| TF_Alerts.mqh - price alerts watched on behalf of the agents     |
//|                                                                  |
//| Flow (contract in docs/trading/03-bot-y-acciones.md):            |
//|   terminalPoll  -> Sync()          alerts ACTIVE / REGISTERED     |
//|   ACTIVE        -> REGISTERED      reported once                  |
//|   crossing      -> TRIGGERED       (+ triggeredAt / Price)        |
//|   expiresAt     -> EXPIRED                                        |
//| A crossing is detected on the TICKS since the last check, not on  |
//| the last price, so a wick between two checks is never missed even |
//| when a blocking WebRequest delayed the timer.                     |
//+------------------------------------------------------------------+
#ifndef TF_ALERTS_MQH
#define TF_ALERTS_MQH

#include "TF_Json.mqh"

#define TF_ALERT_MAX_FAILS 3

struct TFAlert
  {
   string            id;
   double            price;
   bool              above;        // ABOVE: price >= level, BELOW: price <= level
   long              expiresTs;    // UTC epoch, 0 = none
   string            pending;      // status still to report: "", "REGISTERED", "TRIGGERED", "EXPIRED"
   long              trigTs;       // UTC epoch of the crossing
   double            trigPrice;
   int               fails;
  };

//--- "2026-10-20T14:00:00.000Z" -> UTC epoch (0 if empty / invalid)
long TF_ParseIso(const string iso)
  {
   if(StringLen(iso)<19)
      return 0;
   string t=StringSubstr(iso,0,4)+"."+StringSubstr(iso,5,2)+"."+StringSubstr(iso,8,2)+" "+StringSubstr(iso,11,8);
   return (long)StringToTime(t);
  }

class CAlertMonitor
  {
private:
   TFAlert           m_a[];
   ulong             m_lastMsc;      // server time (ms) of the last tick already examined
   int               m_triggered;    // crossings detected since start
   long              m_lastTrigTs;
   int               m_reportIdx[];  // alerts included in the last BuildReport()

   int               Find(const string id);
   void              RemoveAt(const int i);
public:
                     CAlertMonitor(void) : m_lastMsc(0),m_triggered(0),m_lastTrigTs(0) {}
   void              Clear(void) { ArrayResize(m_a,0); m_lastMsc=0; }
   int               Count(void) { return ArraySize(m_a); }
   int               CountAbove(void);
   int               TriggeredTotal(void) { return m_triggered; }
   long              LastTriggerTs(void) { return m_lastTrigTs; }
   //--- Aligns the local list with the alerts Maya still wants watched (poll result).
   void              Sync(CJv *alerts);
   //--- Looks for crossings / expiries. Call every second.
   void              Monitor(const string symbol);
   //--- Builds the JSON array for terminalReport; returns how many entries it holds.
   int               BuildReport(string &json);
   //--- Applies the per-alert result of terminalReport.
   void              ApplyReport(CJv *results);
  };

int CAlertMonitor::Find(const string id)
  {
   for(int i=0;i<ArraySize(m_a);i++)
      if(m_a[i].id==id)
         return i;
   return -1;
  }

void CAlertMonitor::RemoveAt(const int i)
  {
   int n=ArraySize(m_a);
   for(int k=i;k<n-1;k++)
      m_a[k]=m_a[k+1];
   ArrayResize(m_a,n-1);
  }

int CAlertMonitor::CountAbove(void)
  {
   int n=0;
   for(int i=0;i<ArraySize(m_a);i++)
      if(m_a[i].above)
         n++;
   return n;
  }

void CAlertMonitor::Sync(CJv *alerts)
  {
   // 1) drop what Maya no longer lists (cancelled / expired / processed there), unless a report is still owed
   for(int i=ArraySize(m_a)-1;i>=0;i--)
     {
      bool listed=false;
      for(int k=0;k<alerts.Size() && !listed;k++)
         listed=(alerts.At(k).Str("id")==m_a[i].id);
      if(!listed && m_a[i].pending!="TRIGGERED" && m_a[i].pending!="EXPIRED")
         RemoveAt(i);
     }
   // 2) add the new ones
   for(int k=0;k<alerts.Size();k++)
     {
      CJv *r=alerts.At(k);
      string id=r.Str("id");
      if(id=="" || Find(id)>=0)
         continue;
      int n=ArraySize(m_a);
      ArrayResize(m_a,n+1);
      m_a[n].id=id;
      m_a[n].price=r.Num("price");
      m_a[n].above=(r.Str("direction")=="ABOVE");
      m_a[n].expiresTs=TF_ParseIso(r.Str("expiresAt"));
      m_a[n].pending=(r.Str("status")=="ACTIVE") ? "REGISTERED" : "";
      m_a[n].trigTs=0;
      m_a[n].trigPrice=0;
      m_a[n].fails=0;
     }
  }

void CAlertMonitor::Monitor(const string symbol)
  {
   int n=ArraySize(m_a);
   if(n==0)
     {
      // keep the cursor current so a new alert is only compared with ticks AFTER it appeared
      m_lastMsc=(ulong)SymbolInfoInteger(symbol,SYMBOL_TIME_MSC);
      return;
     }
   long now=(long)TimeGMT();

   // expiry first
   for(int i=0;i<n;i++)
      if(m_a[i].pending!="TRIGGERED" && m_a[i].pending!="EXPIRED" && m_a[i].expiresTs>0 && now>=m_a[i].expiresTs)
         m_a[i].pending="EXPIRED";

   ulong nowMsc=(ulong)SymbolInfoInteger(symbol,SYMBOL_TIME_MSC);
   if(m_lastMsc==0)
      m_lastMsc=nowMsc;
   if(nowMsc<=m_lastMsc)
      return;                       // no new ticks
   MqlTick ticks[];
   int got=CopyTicksRange(symbol,ticks,COPY_TICKS_INFO,m_lastMsc+1,nowMsc);
   m_lastMsc=nowMsc;
   if(got<=0)
      return;
   double hi=0,lo=0;
   bool any=false;
   for(int i=0;i<got;i++)
     {
      double b=ticks[i].bid;
      if(b<=0)
         continue;
      if(!any) { hi=b; lo=b; any=true; }
      if(b>hi) hi=b;
      if(b<lo) lo=b;
     }
   if(!any)
      return;
   for(int i=0;i<n;i++)
     {
      if(m_a[i].pending=="TRIGGERED" || m_a[i].pending=="EXPIRED")
         continue;
      bool hit=m_a[i].above ? (hi>=m_a[i].price) : (lo<=m_a[i].price);
      if(!hit)
         continue;
      m_a[i].pending="TRIGGERED";
      m_a[i].trigTs=now;
      m_a[i].trigPrice=m_a[i].above ? hi : lo;
      m_triggered++;
      m_lastTrigTs=now;
      PrintFormat("TradeForge: alert %s crossed (%s %s, seen %s)",m_a[i].id,m_a[i].above ? ">=" : "<=",
                  DoubleToString(m_a[i].price,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS)),
                  DoubleToString(m_a[i].trigPrice,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS)));
     }
  }

int CAlertMonitor::BuildReport(string &json)
  {
   json="[";
   ArrayResize(m_reportIdx,0);
   int count=0;
   for(int i=0;i<ArraySize(m_a) && count<100;i++)
     {
      if(m_a[i].pending=="")
         continue;
      if(count>0) json+=",";
      json+="{\"id\":"+TF_JStr(m_a[i].id)+",\"status\":"+TF_JStr(m_a[i].pending);
      if(m_a[i].pending=="TRIGGERED")
         json+=",\"triggeredAt\":"+TF_JStr(TF_IsoUtc(m_a[i].trigTs))+",\"triggeredPrice\":"+DoubleToString(m_a[i].trigPrice,8);
      json+="}";
      int k=ArraySize(m_reportIdx);
      ArrayResize(m_reportIdx,k+1);
      m_reportIdx[k]=i;
      count++;
     }
   json+="]";
   return count;
  }

void CAlertMonitor::ApplyReport(CJv *results)
  {
   for(int r=0;r<results.Size();r++)
     {
      CJv *x=results.At(r);
      int i=Find(x.Str("id"));
      if(i<0)
         continue;
      if(x.Bool("ok"))
        {
         if(m_a[i].pending=="REGISTERED")
            m_a[i].pending="";                 // now watched, nothing owed
         else
           {
            RemoveAt(i);                       // TRIGGERED / EXPIRED delivered: done with it
            continue;
           }
        }
      else
        {
         m_a[i].fails++;
         PrintFormat("TradeForge: alert %s not accepted (%s): %s",m_a[i].id,m_a[i].pending,x.Str("error"));
         if(m_a[i].fails>=TF_ALERT_MAX_FAILS)
            RemoveAt(i);                       // Maya refuses this transition (e.g. cancelled meanwhile): stop insisting
        }
     }
  }

#endif
