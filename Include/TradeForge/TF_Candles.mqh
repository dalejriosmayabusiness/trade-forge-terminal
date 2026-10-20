//+------------------------------------------------------------------+
//| TF_Candles.mqh - builds the candle payload of terminalUpsertCandles
//|                                                                  |
//| Maya stores candles aligned to UTC. MT5 bars follow the broker's |
//| server time, so:                                                 |
//|  - M5/M15/H1 are converted by the server offset (whole hours).   |
//|  - H4/D1/W1 are rebuilt from H1 bars on UTC boundaries (the      |
//|    broker's own D1 bar opens at server midnight, not UTC).       |
//+------------------------------------------------------------------+
#ifndef TF_CANDLES_MQH
#define TF_CANDLES_MQH

#include "TF_Json.mqh"

#define TF_WEEK_OFFSET 345600   // epoch (Thursday) -> first Monday 00:00 UTC
#define TF_BARS_PER_TF 3        // newest bars re-sent per timeframe (current + previous closed + one spare)

struct TFCandle
  {
   long              ts;       // UTC open time
   double            o,h,l,c;
   long              v;
   bool              closed;
  };

class CCandleFeed
  {
private:
   string            m_sig[];     // last confirmed signature per (timeframe, position)
   string            m_new[];     // signature of what the last Build() put in the payload
   bool              m_inPayload[];
   int               m_slots;
   long              m_off;       // broker server time - UTC, in seconds

   ENUM_TIMEFRAMES   MtFrame(const string tf);
   int               StepOf(const string tf);
   bool              IsAggregated(const string tf) { return tf=="H4" || tf=="D1" || tf=="W1"; }
   long              PeriodStart(const string tf,const long t);
   void              UpdateOffset(void);
   int               CollectDirect(const string symbol,const string tf,MqlRates &r[],TFCandle &out[]);
   int               CollectAggregated(const string symbol,const string tf,TFCandle &out[]);
public:
   //--- Forget what was sent (e.g. after becoming feeder again) so the next Build() re-sends everything.
   void              Reset(void);
   long              ServerOffset(void) { return m_off; }
   //--- Builds the JSON array of candles that changed since the last confirmed send. Returns how many.
   int               Build(const string symbol,const string &timeframes[],const int digits,string &candlesJson,string &err);
   //--- Call after Maya accepted the payload.
   void              Commit(void);
  };

ENUM_TIMEFRAMES CCandleFeed::MtFrame(const string tf)
  {
   if(tf=="M5")  return PERIOD_M5;
   if(tf=="M15") return PERIOD_M15;
   if(tf=="H1")  return PERIOD_H1;
   if(tf=="H4")  return PERIOD_H4;
   if(tf=="D1")  return PERIOD_D1;
   if(tf=="W1")  return PERIOD_W1;
   return PERIOD_CURRENT;
  }

int CCandleFeed::StepOf(const string tf)
  {
   if(tf=="M5")  return 300;
   if(tf=="M15") return 900;
   if(tf=="H1")  return 3600;
   if(tf=="H4")  return 14400;
   if(tf=="D1")  return 86400;
   if(tf=="W1")  return 604800;
   return 0;
  }

long CCandleFeed::PeriodStart(const string tf,const long t)
  {
   long step=StepOf(tf);
   if(tf=="W1")
      return ((t-TF_WEEK_OFFSET)/step)*step+TF_WEEK_OFFSET;
   return (t/step)*step;
  }

void CCandleFeed::UpdateOffset(void)
  {
   // TimeTradeServer() keeps ticking with the server clock even when the market is closed.
   long raw=(long)TimeTradeServer()-(long)TimeGMT();
   m_off=(long)MathRound((double)raw/900.0)*900;
  }

void CCandleFeed::Reset(void)
  {
   for(int i=0;i<ArraySize(m_sig);i++)
      m_sig[i]="";
  }

int CCandleFeed::CollectDirect(const string symbol,const string tf,MqlRates &r[],TFCandle &out[])
  {
   ArraySetAsSeries(r,true);
   int got=CopyRates(symbol,MtFrame(tf),0,TF_BARS_PER_TF,r);
   if(got<=0)
      return 0;
   long now=(long)TimeGMT();
   long step=StepOf(tf);
   ArrayResize(out,got);
   // out[0] = newest
   for(int i=0;i<got;i++)
     {
      out[i].ts=(long)r[i].time-m_off;
      out[i].o=r[i].open;
      out[i].h=r[i].high;
      out[i].l=r[i].low;
      out[i].c=r[i].close;
      out[i].v=(long)r[i].tick_volume;
      out[i].closed=(out[i].ts+step<=now);
     }
   return got;
  }

int CCandleFeed::CollectAggregated(const string symbol,const string tf,TFCandle &out[])
  {
   long now=(long)TimeGMT();
   long step=StepOf(tf);
   long cur=PeriodStart(tf,now);
   long from=cur-(TF_BARS_PER_TF-1)*step;
   MqlRates h1[];
   ArraySetAsSeries(h1,false);   // ascending
   int got=CopyRates(symbol,PERIOD_H1,(datetime)(from+m_off),(datetime)(now+m_off+3600),h1);
   if(got<=0)
      return 0;
   // ascending buckets
   TFCandle tmp[];
   int nb=0;
   for(int i=0;i<got;i++)
     {
      long u=(long)h1[i].time-m_off;
      long ps=PeriodStart(tf,u);
      if(ps<from)
         continue;
      if(nb==0 || tmp[nb-1].ts!=ps)
        {
         ArrayResize(tmp,nb+1);
         tmp[nb].ts=ps;
         tmp[nb].o=h1[i].open;
         tmp[nb].h=h1[i].high;
         tmp[nb].l=h1[i].low;
         tmp[nb].c=h1[i].close;
         tmp[nb].v=(long)h1[i].tick_volume;
         tmp[nb].closed=(ps+step<=now);
         nb++;
        }
      else
        {
         if(h1[i].high>tmp[nb-1].h) tmp[nb-1].h=h1[i].high;
         if(h1[i].low<tmp[nb-1].l)  tmp[nb-1].l=h1[i].low;
         tmp[nb-1].c=h1[i].close;
         tmp[nb-1].v+=(long)h1[i].tick_volume;
        }
     }
   // return newest first, like CollectDirect
   ArrayResize(out,nb);
   for(int i=0;i<nb;i++)
      out[i]=tmp[nb-1-i];
   return nb;
  }

int CCandleFeed::Build(const string symbol,const string &timeframes[],const int digits,string &candlesJson,string &err)
  {
   UpdateOffset();
   int ntf=ArraySize(timeframes);
   m_slots=ntf*TF_BARS_PER_TF;
   if(ArraySize(m_sig)!=m_slots)
     {
      ArrayResize(m_sig,m_slots);
      for(int i=0;i<m_slots;i++) m_sig[i]="";
     }
   ArrayResize(m_new,m_slots);
   ArrayResize(m_inPayload,m_slots);
   ArrayInitialize(m_inPayload,false);

   candlesJson="[";
   int count=0;
   MqlRates r[];
   for(int f=0;f<ntf;f++)
     {
      string tf=timeframes[f];
      if(StepOf(tf)==0)
         continue;
      TFCandle bars[];
      int got=IsAggregated(tf) ? CollectAggregated(symbol,tf,bars) : CollectDirect(symbol,tf,r,bars);
      if(got<=0)
        {
         err="No "+tf+" data for "+symbol+" yet";
         continue;
        }
      for(int k=got-1;k>=0 && k<TF_BARS_PER_TF;k--)   // oldest first
        {
         int slot=f*TF_BARS_PER_TF+k;
         string sig=StringFormat("%I64d|%s|%s|%s|%s|%I64d|%d",bars[k].ts,DoubleToString(bars[k].o,digits),
                                 DoubleToString(bars[k].h,digits),DoubleToString(bars[k].l,digits),
                                 DoubleToString(bars[k].c,digits),bars[k].v,bars[k].closed);
         m_new[slot]=sig;
         if(sig==m_sig[slot])
            continue;
         if(count>0) candlesJson+=",";
         candlesJson+="{\"timeframe\":"+TF_JStr(tf)+",\"openTime\":"+TF_JStr(TF_IsoUtc(bars[k].ts))+
                      ",\"open\":"+DoubleToString(bars[k].o,digits)+",\"high\":"+DoubleToString(bars[k].h,digits)+
                      ",\"low\":"+DoubleToString(bars[k].l,digits)+",\"close\":"+DoubleToString(bars[k].c,digits)+
                      ",\"volume\":"+IntegerToString(bars[k].v)+",\"closed\":"+TF_JBool(bars[k].closed)+"}";
         m_inPayload[slot]=true;
         count++;
        }
     }
   candlesJson+="]";
   return count;
  }

void CCandleFeed::Commit(void)
  {
   for(int i=0;i<ArraySize(m_inPayload);i++)
      if(m_inPayload[i])
         m_sig[i]=m_new[i];
  }

//+------------------------------------------------------------------+
//| Candle HISTORY (backfill): closed candles, ascending, UTC-aligned |
//+------------------------------------------------------------------+
enum TF_DstRule
  {
   TF_DST_EU=0,     // server clock follows European summer time (last Sun Mar -> last Sun Oct)
   TF_DST_US=1,     // server clock follows US summer time (2nd Sun Mar -> 1st Sun Nov)
   TF_DST_NONE=2    // fixed offset all year
  };

int TF_StepSec(const string tf)
  {
   if(tf=="M5")  return 300;
   if(tf=="M15") return 900;
   if(tf=="H1")  return 3600;
   if(tf=="H4")  return 14400;
   if(tf=="D1")  return 86400;
   if(tf=="W1")  return 604800;
   return 0;
  }

ENUM_TIMEFRAMES TF_MtFrame(const string tf)
  {
   if(tf=="M5")  return PERIOD_M5;
   if(tf=="M15") return PERIOD_M15;
   if(tf=="H1")  return PERIOD_H1;
   return PERIOD_CURRENT;
  }

long TF_PeriodStartOf(const string tf,const long t)
  {
   long step=TF_StepSec(tf);
   if(tf=="W1")
      return ((t-TF_WEEK_OFFSET)/step)*step+TF_WEEK_OFFSET;
   return (t/step)*step;
  }

//--- Nth Sunday (n=-1: last) of a month at the given UTC hour, as a UTC epoch
long TF_SundayOf(const int year,const int month,const int n,const int hourUtc)
  {
   MqlDateTime d;
   d.year=year; d.mon=month; d.day=1; d.hour=0; d.min=0; d.sec=0;
   if(n>0)
     {
      datetime first=StructToTime(d);
      TimeToStruct(first,d);
      int add=(7-d.day_of_week)%7;                 // days until the first Sunday
      return (long)first+(long)(add+7*(n-1))*86400+hourUtc*3600;
     }
   d.mon=month+1;                                   // last Sunday: step back from the 1st of next month
   if(d.mon>12) { d.mon=1; d.year=year+1; }
   datetime next=StructToTime(d);
   TimeToStruct(next-86400,d);                      // last day of the month
   int back=d.day_of_week;                          // Sunday=0
   return (long)(next-86400)-(long)back*86400+hourUtc*3600-86400*0;
  }

bool TF_DstActive(const long utc,const TF_DstRule rule)
  {
   if(rule==TF_DST_NONE)
      return false;
   MqlDateTime d;
   TimeToStruct((datetime)utc,d);
   long from,to;
   if(rule==TF_DST_EU)
     {
      from=TF_SundayOf(d.year,3,-1,1);
      to=TF_SundayOf(d.year,10,-1,1);
     }
   else
     {
      from=TF_SundayOf(d.year,3,2,7);
      to=TF_SundayOf(d.year,11,1,6);
     }
   return (utc>=from && utc<to);
  }

//--- Broker server time -> UTC for a PAST time, honouring the daylight-saving switch of the server clock.
class CServerClock
  {
private:
   long              m_winter;     // server offset in winter, seconds
   TF_DstRule        m_rule;
public:
   void              Init(const TF_DstRule rule)
     {
      m_rule=rule;
      long now=(long)TimeGMT();
      long cur=(long)MathRound((double)((long)TimeTradeServer()-now)/900.0)*900;
      m_winter=cur-(TF_DstActive(now,rule) ? 3600 : 0);
     }
   long              ToUtc(const long serverTs)
     {
      long guess=serverTs-m_winter;
      return TF_DstActive(guess-3600,m_rule) ? serverTs-m_winter-3600 : guess;
     }
   long              Winter(void) { return m_winter; }
  };

class CCandleHistory
  {
private:
   TFCandle          m_c[];
   int               m_n;
public:
                     CCandleHistory(void) : m_n(0) {}
   int               Size(void) { return m_n; }
   bool              Get(const int i,TFCandle &c)
     {
      if(i<0 || i>=m_n)
         return false;
      c=m_c[i];
      return true;
     }
   //--- Loads up to `count` closed candles of `tf` (oldest first). H4/D1/W1 are rebuilt from H1 on UTC boundaries.
   int               Load(const string symbol,const string tf,const int count,CServerClock &clock);
  };

int CCandleHistory::Load(const string symbol,const string tf,const int count,CServerClock &clock)
  {
   m_n=0;
   ArrayResize(m_c,0);
   if(count<=0 || TF_StepSec(tf)==0)
      return 0;
   long now=(long)TimeGMT();
   long step=TF_StepSec(tf);
   MqlRates r[];
   ArraySetAsSeries(r,false);
   if(tf=="H4" || tf=="D1" || tf=="W1")
     {
      long perH1=step/3600;
      int need=(int)MathMin(100000.0,(double)(count+2)*(double)perH1);
      int got=CopyRates(symbol,PERIOD_H1,0,need,r);       // oldest first, last element = bar in progress
      if(got<=0)
         return 0;
      TFCandle tmp[];
      int nb=0;
      long firstHour=0;
      for(int i=0;i<got;i++)
        {
         long u=clock.ToUtc((long)r[i].time);
         long ps=TF_PeriodStartOf(tf,u);
         if(nb==0 || tmp[nb-1].ts!=ps)
           {
            ArrayResize(tmp,nb+1);
            tmp[nb].ts=ps;
            tmp[nb].o=r[i].open;
            tmp[nb].h=r[i].high;
            tmp[nb].l=r[i].low;
            tmp[nb].c=r[i].close;
            tmp[nb].v=(long)r[i].tick_volume;
            tmp[nb].closed=(ps+step<=now);
            if(nb==0) firstHour=u;
            nb++;
           }
         else
           {
            if(r[i].high>tmp[nb-1].h) tmp[nb-1].h=r[i].high;
            if(r[i].low<tmp[nb-1].l)  tmp[nb-1].l=r[i].low;
            tmp[nb-1].c=r[i].close;
            tmp[nb-1].v+=(long)r[i].tick_volume;
           }
        }
      int from=(nb>0 && firstHour>tmp[0].ts) ? 1 : 0;   // the oldest bucket may start mid-period: drop it
      ArrayResize(m_c,nb);
      for(int i=from;i<nb;i++)
         if(tmp[i].closed)
            m_c[m_n++]=tmp[i];
      if(m_n>count)                                            // keep the newest `count`
        {
         int drop=m_n-count;
         for(int i=0;i<count;i++)
            m_c[i]=m_c[i+drop];
         m_n=count;
        }
      ArrayResize(m_c,m_n);
      return m_n;
     }
   // direct timeframes: skip bar 0 (still forming)
   int got=CopyRates(symbol,TF_MtFrame(tf),1,count,r);
   if(got<=0)
      return 0;
   ArrayResize(m_c,got);
   for(int i=0;i<got;i++)
     {
      m_c[i].ts=clock.ToUtc((long)r[i].time);
      m_c[i].o=r[i].open;
      m_c[i].h=r[i].high;
      m_c[i].l=r[i].low;
      m_c[i].c=r[i].close;
      m_c[i].v=(long)r[i].tick_volume;
      m_c[i].closed=true;
     }
   m_n=got;
   return m_n;
  }

#endif
