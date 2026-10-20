//+------------------------------------------------------------------+
//| TF_Trades.mqh - executes the trades of Maya on the broker        |
//|                                                                  |
//| The terminal ONLY OBEYS: Maya (the trigger) already validated    |
//| the trade and computed risk and lot size. The EA does not check  |
//| the account type, the mode or the lot minimum; it places what    |
//| it is told on the account it is attached to, and reports what    |
//| the broker did.                                                  |
//|                                                                  |
//| Design: no event handlers. Every second the cached list of live  |
//| trades (from terminalPoll) is RECONCILED with the broker state.  |
//| That makes restarts, lost reports and late fills self-healing.   |
//|                                                                  |
//|   PENDING  -> LIMIT order sent    -> PLACED (ticket) | REJECTED   |
//|   PLACED   -> order filled        -> OPEN (fill time / price)     |
//|            -> validUntil passed   -> order removed -> EXPIRED     |
//|   OPEN     -> position closed     -> CLOSED_TP / CLOSED_SL        |
//|   CANCEL_REQUESTED -> order removed -> CANCELLED (or OPEN if it   |
//|                       had been filled meanwhile)                  |
//| Idempotency: the Trade id travels in the order comment, so an     |
//| order that was sent but never reported is found, not re-sent.     |
//+------------------------------------------------------------------+
#ifndef TF_TRADES_MQH
#define TF_TRADES_MQH

#include "TF_Json.mqh"
#include "TF_Alerts.mqh"

#define TF_TRADE_MAX_FAILS 3

//--- broker server time -> UTC (the broker clock is not UTC)
long TF_ServerOffset(void)
  {
   long raw=(long)TimeTradeServer()-(long)TimeGMT();
   return (long)MathRound((double)raw/900.0)*900;
  }

struct TFTrade
  {
   string            id;
   string            status;     // as Maya has it (or as we last reported it successfully)
   bool              buy;
   double            entry,sl,tp,volume;
   long              validTs;    // UTC epoch, 0 = none
   ulong             ticket;     // broker order ticket (externalOrderId)
   ulong             posId;      // broker position identifier once filled
   int               fails;
   long              retryAfter; // UTC epoch: do not touch this trade before
  };

class CTradeBook
  {
private:
   TFTrade           m_t[];
   string            m_symbol;
   long              m_magic;
   string            m_issue;

   // report batch built by Reconcile()
   int               m_eIdx[];
   string            m_eStatus[];
   ulong             m_eTicket[];
   ulong             m_ePos[];
   string            m_eJson[];

   int               Find(const string id);
   void              RemoveAt(const int i);
   void              ClearBatch(void);
   void              Add(const int i,const string status,const ulong ticket,const ulong pos,const string extra);
   void              Evaluate(const int i,const long nowUtc);
   bool              Expired(const int i,const long nowUtc);
   ulong             FindOrderByComment(const string id);
   bool              Place(const int i,ulong &ticket,string &msg,bool &transient);
   bool              RemoveOrder(const ulong ticket,string &msg,bool &transient);
   bool              LiveOrder(const ulong ticket);
   bool              PositionOpen(const ulong posId);
   bool              Deals(const ulong posId,bool &hasIn,long &inTs,double &inPx,bool &hasOut,long &outTs,double &outPx,double &pnl,ENUM_DEAL_REASON &reason);
   double            NormVolume(const double v);
   string            Msg(const MqlTradeResult &rs);
   bool              IsTransient(const uint retcode);
   string            Iso(const long serverTs);
public:
                     CTradeBook(void) : m_magic(0) {}
   void              Clear(void) { ArrayResize(m_t,0); ClearBatch(); }
   int               Count(void) { return ArraySize(m_t); }
   string            LastIssue(void) { return m_issue; }
   void              ClearIssue(void) { m_issue=""; }
   //--- Aligns the local list with the live trades Maya returned (terminalPoll).
   void              Sync(CJv *trades);
   //--- Compares every live trade with the broker; returns how many report entries were produced.
   int               Reconcile(const string symbol,const long magic);
   //--- JSON array for terminalReport (entries are in order: a trade may have OPEN then CLOSED_*).
   string            BuildReport(void);
   void              ApplyReport(CJv *results);
   void              Stats(int &pending,int &placed,int &open,double &floating);
  };

string CTradeBook::Iso(const long serverTs) { return TF_IsoUtc(serverTs-TF_ServerOffset()); }

int CTradeBook::Find(const string id)
  {
   for(int i=0;i<ArraySize(m_t);i++)
      if(m_t[i].id==id)
         return i;
   return -1;
  }

void CTradeBook::RemoveAt(const int i)
  {
   int n=ArraySize(m_t);
   for(int k=i;k<n-1;k++)
      m_t[k]=m_t[k+1];
   ArrayResize(m_t,n-1);
  }

void CTradeBook::ClearBatch(void)
  {
   ArrayResize(m_eIdx,0);
   ArrayResize(m_eStatus,0);
   ArrayResize(m_eTicket,0);
   ArrayResize(m_ePos,0);
   ArrayResize(m_eJson,0);
  }

void CTradeBook::Add(const int i,const string status,const ulong ticket,const ulong pos,const string extra)
  {
   int k=ArraySize(m_eJson);
   ArrayResize(m_eIdx,k+1);
   ArrayResize(m_eStatus,k+1);
   ArrayResize(m_eTicket,k+1);
   ArrayResize(m_ePos,k+1);
   ArrayResize(m_eJson,k+1);
   m_eIdx[k]=i;
   m_eStatus[k]=status;
   m_eTicket[k]=ticket;
   m_ePos[k]=pos;
   m_eJson[k]="{\"id\":"+TF_JStr(m_t[i].id)+",\"status\":"+TF_JStr(status)+(extra!="" ? ","+extra : "")+"}";
  }

void CTradeBook::Sync(CJv *trades)
  {
   // drop what Maya no longer lists as live
   for(int i=ArraySize(m_t)-1;i>=0;i--)
     {
      bool listed=false;
      for(int k=0;k<trades.Size() && !listed;k++)
         listed=(trades.At(k).Str("id")==m_t[i].id);
      if(!listed)
         RemoveAt(i);
     }
   for(int k=0;k<trades.Size();k++)
     {
      CJv *r=trades.At(k);
      string id=r.Str("id");
      if(id=="")
         continue;
      int i=Find(id);
      if(i<0)
        {
         i=ArraySize(m_t);
         ArrayResize(m_t,i+1);
         m_t[i].id=id;
         m_t[i].status="";
         m_t[i].ticket=0;
         m_t[i].posId=0;
         m_t[i].fails=0;
         m_t[i].retryAfter=0;
        }
      string st=r.Str("status");
      if(st!=m_t[i].status)
        {
         m_t[i].status=st;     // Maya is the authority on the state
         m_t[i].fails=0;
         m_t[i].retryAfter=0;
        }
      m_t[i].buy=(r.Str("direction")=="BUY");
      m_t[i].entry=r.Num("entryPrice");
      m_t[i].sl=r.Num("stopLoss");
      m_t[i].tp=r.Num("takeProfit");
      m_t[i].volume=r.Num("positionSize");
      m_t[i].validTs=TF_ParseIso(r.Str("validUntil"));
      string ext=r.Str("externalOrderId");
      if(ext!="")
         m_t[i].ticket=(ulong)StringToInteger(ext);
     }
  }

bool CTradeBook::Expired(const int i,const long nowUtc)
  {
   return (m_t[i].validTs>0 && nowUtc>=m_t[i].validTs);
  }

double CTradeBook::NormVolume(const double v)
  {
   double step=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
   if(step<=0)
      return v;
   double r=MathFloor(v/step+1e-9)*step;
   int digits=0;
   while(digits<8 && MathAbs(step*MathPow(10,digits)-MathRound(step*MathPow(10,digits)))>1e-9)
      digits++;
   return NormalizeDouble(r,digits);
  }

string CTradeBook::Msg(const MqlTradeResult &rs)
  {
   return IntegerToString(rs.retcode)+": "+rs.comment;
  }

//--- Errors that say "not now" (no connection, algo trading off...) rather than "the broker refuses this order".
bool CTradeBook::IsTransient(const uint retcode)
  {
   return (retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION || retcode==TRADE_RETCODE_SERVER_DISABLES_AT ||
           retcode==TRADE_RETCODE_CLIENT_DISABLES_AT || retcode==TRADE_RETCODE_TRADE_DISABLED || retcode==TRADE_RETCODE_TOO_MANY_REQUESTS ||
           retcode==TRADE_RETCODE_LOCKED);
  }

bool CTradeBook::LiveOrder(const ulong ticket)
  {
   return (ticket>0 && OrderSelect(ticket));
  }

bool CTradeBook::PositionOpen(const ulong posId)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0)
         continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==posId)
         return true;
     }
   return false;
  }

ulong CTradeBook::FindOrderByComment(const string id)
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong t=OrderGetTicket(i);
      if(t==0)
         continue;
      if(OrderGetString(ORDER_SYMBOL)==m_symbol && OrderGetInteger(ORDER_MAGIC)==m_magic && OrderGetString(ORDER_COMMENT)==id)
         return t;
     }
   if(HistorySelect(TimeCurrent()-14*86400,TimeCurrent()+86400))
      for(int i=HistoryOrdersTotal()-1;i>=0;i--)
        {
         ulong t=HistoryOrderGetTicket(i);
         if(t==0)
            continue;
         if(HistoryOrderGetString(t,ORDER_SYMBOL)==m_symbol && HistoryOrderGetInteger(t,ORDER_MAGIC)==m_magic && HistoryOrderGetString(t,ORDER_COMMENT)==id)
            return t;
        }
   return 0;
  }

bool CTradeBook::Place(const int i,ulong &ticket,string &msg,bool &transient)
  {
   transient=false;
   int digits=(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
   MqlTradeRequest rq;
   MqlTradeResult  rs;
   ZeroMemory(rq);
   ZeroMemory(rs);
   rq.action=TRADE_ACTION_PENDING;
   rq.symbol=m_symbol;
   rq.magic=m_magic;
   rq.comment=StringSubstr(m_t[i].id,0,31);
   rq.type=m_t[i].buy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   rq.volume=NormVolume(m_t[i].volume);
   rq.price=NormalizeDouble(m_t[i].entry,digits);
   rq.sl=NormalizeDouble(m_t[i].sl,digits);
   rq.tp=NormalizeDouble(m_t[i].tp,digits);
   rq.type_time=ORDER_TIME_GTC;          // expiry is handled here (validUntil), brokers differ in what they accept
   rq.type_filling=ORDER_FILLING_RETURN;
   ResetLastError();
   bool sent=OrderSend(rq,rs);
   if(sent && (rs.retcode==TRADE_RETCODE_PLACED || rs.retcode==TRADE_RETCODE_DONE))
     {
      ticket=rs.order;
      return true;
     }
   msg=Msg(rs);
   if(rs.retcode==0)
      msg="OrderSend failed, error "+IntegerToString(GetLastError());
   transient=(rs.retcode==0 || IsTransient(rs.retcode));
   return false;
  }

bool CTradeBook::RemoveOrder(const ulong ticket,string &msg,bool &transient)
  {
   transient=false;
   MqlTradeRequest rq;
   MqlTradeResult  rs;
   ZeroMemory(rq);
   ZeroMemory(rs);
   rq.action=TRADE_ACTION_REMOVE;
   rq.order=ticket;
   bool sent=OrderSend(rq,rs);
   if(sent && (rs.retcode==TRADE_RETCODE_DONE || rs.retcode==TRADE_RETCODE_PLACED))
      return true;
   msg=Msg(rs);
   transient=(rs.retcode==0 || IsTransient(rs.retcode));
   return false;
  }

//--- Fill, close and net result of a position from its deals (all broker times are SERVER time).
bool CTradeBook::Deals(const ulong posId,bool &hasIn,long &inTs,double &inPx,bool &hasOut,long &outTs,double &outPx,double &pnl,ENUM_DEAL_REASON &reason)
  {
   hasIn=false;
   hasOut=false;
   pnl=0;
   reason=DEAL_REASON_CLIENT;
   if(!HistorySelectByPosition(posId))
      return false;
   int n=HistoryDealsTotal();
   for(int k=0;k<n;k++)
     {
      ulong d=HistoryDealGetTicket(k);
      if(d==0)
         continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      pnl+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_FEE);
      if(e==DEAL_ENTRY_IN && !hasIn)
        {
         hasIn=true;
         inTs=(long)HistoryDealGetInteger(d,DEAL_TIME);
         inPx=HistoryDealGetDouble(d,DEAL_PRICE);
        }
      if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY || e==DEAL_ENTRY_INOUT)
        {
         hasOut=true;
         outTs=(long)HistoryDealGetInteger(d,DEAL_TIME);
         outPx=HistoryDealGetDouble(d,DEAL_PRICE);
         reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(d,DEAL_REASON);
        }
     }
   return true;
  }

void CTradeBook::Evaluate(const int i,const long nowUtc)
  {
   string st=m_t[i].status;
   ulong tk=m_t[i].ticket;
   ulong pos=m_t[i].posId;
   int digits=(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);

   for(int guard=0;guard<4;guard++)
     {
      //------------------------------------------------------------ PENDING
      if(st=="PENDING")
        {
         if(Expired(i,nowUtc))
           {
            Add(i,"EXPIRED",0,0,"\"botMessage\":\"validUntil passed before the order was placed\"");
            return;
           }
         ulong found=FindOrderByComment(m_t[i].id);      // sent earlier but never reported?
         if(found>0)
           {
            Add(i,"PLACED",found,0,"\"externalOrderId\":"+TF_JStr(IntegerToString((long)found)));
            st="PLACED";
            tk=found;
            continue;
           }
         ulong t2=0;
         string msg;
         bool transient;
         if(Place(i,t2,msg,transient))
           {
            Add(i,"PLACED",t2,0,"\"externalOrderId\":"+TF_JStr(IntegerToString((long)t2)));
            return;                                      // fills are looked at on the next pass
           }
         if(transient)
           {
            m_issue="Order not sent (will retry): "+msg;
            m_t[i].retryAfter=nowUtc+10;
            return;
           }
         Add(i,"REJECTED",0,0,"\"botMessage\":"+TF_JStr(StringSubstr(msg,0,200)));
         return;
        }
      //------------------------------------------------------------ PLACED
      if(st=="PLACED")
        {
         if(tk==0)
            return;
         if(LiveOrder(tk))
           {
            if(Expired(i,nowUtc))
              {
               string msg;
               bool transient;
               if(RemoveOrder(tk,msg,transient))
                  Add(i,"EXPIRED",tk,0,"\"botMessage\":\"validUntil passed, order removed\"");
               else
                  m_issue="Could not remove expired order: "+msg;
              }
            return;                                      // still waiting for price
           }
         if(!HistorySelect(TimeCurrent()-14*86400,TimeCurrent()+86400) || !HistoryOrderSelect(tk))
            return;                                      // history not there yet: ask again next second
         ENUM_ORDER_STATE os=(ENUM_ORDER_STATE)HistoryOrderGetInteger(tk,ORDER_STATE);
         ulong pid=(ulong)HistoryOrderGetInteger(tk,ORDER_POSITION_ID);
         if(os==ORDER_STATE_FILLED || os==ORDER_STATE_PARTIAL)
           {
            bool hasIn,hasOut;
            long inTs,outTs;
            double inPx,outPx,pnl;
            ENUM_DEAL_REASON why;
            if(pid==0 || !Deals(pid,hasIn,inTs,inPx,hasOut,outTs,outPx,pnl,why) || !hasIn)
               return;
            Add(i,"OPEN",tk,pid,"\"filledAt\":"+TF_JStr(Iso(inTs))+",\"filledPrice\":"+DoubleToString(inPx,digits));
            st="OPEN";
            pos=pid;
            continue;
           }
         if(os==ORDER_STATE_CANCELED || os==ORDER_STATE_EXPIRED || os==ORDER_STATE_REJECTED)
           {
            if(Expired(i,nowUtc))
               Add(i,"EXPIRED",tk,0,"\"botMessage\":\"validUntil passed\"");
            else
               Add(i,"REJECTED",tk,0,"\"botMessage\":\"Order is no longer in the broker (state "+EnumToString(os)+")\"");
           }
         return;
        }
      //------------------------------------------------------------ OPEN
      if(st=="OPEN")
        {
         if(pos==0 && tk>0 && HistorySelect(TimeCurrent()-14*86400,TimeCurrent()+86400) && HistoryOrderSelect(tk))
            pos=(ulong)HistoryOrderGetInteger(tk,ORDER_POSITION_ID);
         if(pos==0)
            return;
         if(PositionOpen(pos))
           {
            m_t[i].posId=pos;
            return;                                      // still running, SL/TP live in the broker
           }
         bool hasIn,hasOut;
         long inTs,outTs;
         double inPx,outPx,pnl;
         ENUM_DEAL_REASON why;
         if(!Deals(pos,hasIn,inTs,inPx,hasOut,outTs,outPx,pnl,why) || !hasOut)
            return;
         string reasonText="OTHER";
         bool tp=false;
         switch(why)
           {
            case DEAL_REASON_TP:     reasonText="TP";        tp=true;  break;
            case DEAL_REASON_SL:     reasonText="SL";        tp=false; break;
            case DEAL_REASON_SO:     reasonText="STOP_OUT";  tp=(pnl>=0); break;
            case DEAL_REASON_CLIENT:
            case DEAL_REASON_MOBILE:
            case DEAL_REASON_WEB:    reasonText="MANUAL";    tp=(pnl>=0); break;
            case DEAL_REASON_EXPERT: reasonText="EXPERT";    tp=(pnl>=0); break;
            default:                                          tp=(pnl>=0); break;
           }
         Add(i,tp ? "CLOSED_TP" : "CLOSED_SL",tk,pos,
             "\"closedAt\":"+TF_JStr(Iso(outTs))+",\"exitPrice\":"+DoubleToString(outPx,digits)+",\"pnl\":"+DoubleToString(pnl,2)+
             ",\"closeReason\":"+TF_JStr(reasonText));
         return;
        }
      //------------------------------------------------------------ CANCEL_REQUESTED (by the agent)
      if(st=="CANCEL_REQUESTED")
        {
         if(tk==0)
            tk=FindOrderByComment(m_t[i].id);
         if(tk==0)
           {
            Add(i,"CANCELLED",0,0,"\"botMessage\":\"order had not been placed\"");
            return;
           }
         if(LiveOrder(tk))
           {
            string msg;
            bool transient;
            if(RemoveOrder(tk,msg,transient))
               Add(i,"CANCELLED",tk,0,"\"botMessage\":\"order removed on request\"");
            else
               m_issue="Could not cancel order: "+msg;
            return;
           }
         if(!HistorySelect(TimeCurrent()-14*86400,TimeCurrent()+86400) || !HistoryOrderSelect(tk))
            return;
         ENUM_ORDER_STATE os=(ENUM_ORDER_STATE)HistoryOrderGetInteger(tk,ORDER_STATE);
         ulong pid=(ulong)HistoryOrderGetInteger(tk,ORDER_POSITION_ID);
         if(os==ORDER_STATE_FILLED || os==ORDER_STATE_PARTIAL)
           {
            // it filled before the cancel arrived: Maya allows CANCEL_REQUESTED -> OPEN
            bool hasIn,hasOut;
            long inTs,outTs;
            double inPx,outPx,pnl;
            ENUM_DEAL_REASON why;
            if(pid==0 || !Deals(pid,hasIn,inTs,inPx,hasOut,outTs,outPx,pnl,why) || !hasIn)
               return;
            Add(i,"OPEN",tk,pid,"\"filledAt\":"+TF_JStr(Iso(inTs))+",\"filledPrice\":"+DoubleToString(inPx,digits));
            st="OPEN";
            pos=pid;
            continue;
           }
         Add(i,"CANCELLED",tk,0,"\"botMessage\":\"order already gone from the broker\"");
         return;
        }
      return;
     }
  }

int CTradeBook::Reconcile(const string symbol,const long magic)
  {
   m_symbol=symbol;
   m_magic=magic;
   ClearBatch();
   long nowUtc=(long)TimeGMT();
   for(int i=0;i<ArraySize(m_t);i++)
     {
      if(nowUtc<m_t[i].retryAfter)
         continue;
      Evaluate(i,nowUtc);
     }
   return ArraySize(m_eJson);
  }

string CTradeBook::BuildReport(void)
  {
   string json="[";
   int n=MathMin(ArraySize(m_eJson),100);
   for(int k=0;k<n;k++)
     {
      if(k>0) json+=",";
      json+=m_eJson[k];
     }
   return json+"]";
  }

void CTradeBook::ApplyReport(CJv *results)
  {
   long nowUtc=(long)TimeGMT();
   int n=MathMin(ArraySize(m_eJson),100);
   // results come back in the order of the entries; walk backwards so removals do not shift pending indexes
   bool remove[];
   ArrayResize(remove,ArraySize(m_t));
   ArrayInitialize(remove,false);
   for(int k=0;k<n;k++)
     {
      int i=m_eIdx[k];
      if(i<0 || i>=ArraySize(m_t))
         continue;
      CJv *x=results.At(k);
      if(x.Bool("ok"))
        {
         m_t[i].status=m_eStatus[k];
         if(m_eTicket[k]>0) m_t[i].ticket=m_eTicket[k];
         if(m_ePos[k]>0)    m_t[i].posId=m_ePos[k];
         m_t[i].fails=0;
         string s=m_eStatus[k];
         if(s=="CLOSED_TP" || s=="CLOSED_SL" || s=="CANCELLED" || s=="EXPIRED" || s=="REJECTED")
            remove[i]=true;
        }
      else
        {
         m_t[i].fails++;
         m_issue="Trade "+m_t[i].id+" -> "+m_eStatus[k]+" rejected by Maya: "+x.Str("error");
         PrintFormat("TradeForge: %s",m_issue);
         if(m_t[i].fails>=TF_TRADE_MAX_FAILS)
            m_t[i].retryAfter=nowUtc+30;      // Maya refuses this transition: pause, the next poll shows its real state
        }
     }
   for(int i=ArraySize(m_t)-1;i>=0;i--)
      if(remove[i])
         RemoveAt(i);
  }

void CTradeBook::Stats(int &pending,int &placed,int &open,double &floating)
  {
   pending=0;
   placed=0;
   open=0;
   floating=0;
   for(int i=0;i<ArraySize(m_t);i++)
     {
      if(m_t[i].status=="PENDING")
         pending++;
      else if(m_t[i].status=="PLACED" || m_t[i].status=="CANCEL_REQUESTED")
         placed++;
      else if(m_t[i].status=="OPEN")
        {
         open++;
         for(int p=PositionsTotal()-1;p>=0;p--)
           {
            ulong t=PositionGetTicket(p);
            if(t>0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER)==m_t[i].posId)
               floating+=PositionGetDouble(POSITION_PROFIT);
           }
        }
     }
  }

#endif
