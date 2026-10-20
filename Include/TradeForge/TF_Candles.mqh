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

#endif
