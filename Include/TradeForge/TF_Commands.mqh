//+------------------------------------------------------------------+
//| TF_Commands.mqh - orders sent from Maya to this terminal          |
//|                                                                  |
//| Maya keeps a queue (object TerminalCommand). The heartbeat       |
//| returns this terminal's PENDING / RUNNING commands; the runner   |
//| executes ONE at a time in small slices (the EA is single         |
//| threaded and must keep watching alerts and trades) and reports   |
//| progress with terminalCommandReport.                             |
//|                                                                  |
//| HOW TO ADD A COMMAND                                             |
//|  1. Describe the type and its params in Maya (_prelude.js,       |
//|     COMMAND_TYPES).                                              |
//|  2. Derive a class from CCommand and implement Step(): do a      |
//|     bounded amount of work and return RUNNING / WAIT / DONE /    |
//|     FAILED.                                                      |
//|  3. Add one line to TF_CreateCommand() below.                    |
//| A type this EA does not know is reported FAILED "unsupported".   |
//+------------------------------------------------------------------+
#ifndef TF_COMMANDS_MQH
#define TF_COMMANDS_MQH

#include "TF_Json.mqh"
#include "TF_Maya.mqh"
#include "TF_Candles.mqh"

enum TFCmdState
  {
   CMD_RUNNING=0,     // more work to do, call Step() again
   CMD_WAIT=1,        // cannot progress right now (e.g. not the feeder); call again later
   CMD_DONE=2,
   CMD_FAILED=3
  };

//--- What a command may use. Filled by the EA before every Step().
class CCmdContext
  {
public:
   CMaya            *maya;
   string            symbol;
   bool              feeder;
   CServerClock      clock;
   string            timeframes[];   // timeframes this terminal is configured to send
   string            Params(const string extra)
     {
      return "{\"token\":"+TF_JStr(maya.Token())+(extra!="" ? ","+extra : "")+"}";
     }
  };

class CCommand
  {
public:
   string            id;
   string            type;
   virtual          ~CCommand(void) {}
   //--- Reads the params. Return false (and set err) to fail the command before it starts.
   virtual bool      Init(CJv *params,string &err) { return true; }
   //--- One slice of work. `progress` 0..100 and `message` are shown in Maya and in the panel.
   virtual TFCmdState Step(CCmdContext &ctx,double &progress,string &message,string &resultJson)=0;
   virtual string    Label(void) { return type; }
  };

//+------------------------------------------------------------------+
//| BACKFILL_CANDLES: loads closed history from MT5 into Maya        |
//+------------------------------------------------------------------+
#define TF_BACKFILL_CHUNK 150

class CBackfillCommand : public CCommand
  {
private:
   string            m_tf[6];
   int               m_bars[6];
   int               m_ntf;
   int               m_f;            // timeframe being sent
   bool              m_loaded;
   int               m_pos;          // next candle of the loaded history
   int               m_loadTries;
   int               m_failures;
   long              m_done;         // candles delivered so far
   long              m_plan;         // candles planned (requested for the ones not loaded yet)
   long              m_inserted;
   long              m_skipped;
   CCandleHistory    m_hist;
   string            m_label;
   void              Plan(void);
public:
                     CBackfillCommand(void) : m_ntf(0),m_f(0),m_loaded(false),m_pos(0),m_loadTries(0),m_failures(0),m_done(0),m_plan(0),m_inserted(0),m_skipped(0) {}
   virtual bool      Init(CJv *params,string &err);
   virtual TFCmdState Step(CCmdContext &ctx,double &progress,string &message,string &resultJson);
   virtual string    Label(void) { return "Backfill "+m_label; }
  };

bool CBackfillCommand::Init(CJv *params,string &err)
  {
   string names[6]={"M5","M15","H1","H4","D1","W1"};
   int defaults[6]={3000,2000,1500,600,365,104};
   CJv *bars=params.Get("bars");
   m_ntf=0;
   for(int i=0;i<6;i++)
     {
      int n=(int)bars.Num(names[i],defaults[i]);
      if(n<=0)
         continue;
      m_tf[m_ntf]=names[i];
      m_bars[m_ntf]=MathMin(n,20000);
      m_ntf++;
     }
   if(m_ntf==0)
     {
      err="No timeframe to load (all bars = 0)";
      return false;
     }
   Plan();
   return true;
  }

void CBackfillCommand::Plan(void)
  {
   m_plan=m_done;
   for(int i=m_f;i<m_ntf;i++)
      m_plan+=m_bars[i];
  }

TFCmdState CBackfillCommand::Step(CCmdContext &ctx,double &progress,string &message,string &resultJson)
  {
   if(!ctx.feeder)
     {
      message="Waiting: this terminal is not the feeder of its instrument";
      return CMD_WAIT;
     }
   if(m_f>=m_ntf)
     {
      progress=100;
      message="Loaded "+IntegerToString((int)m_inserted)+" new candles ("+IntegerToString((int)m_skipped)+" already existed)";
      resultJson="{\"inserted\":"+IntegerToString((int)m_inserted)+",\"skipped\":"+IntegerToString((int)m_skipped)+"}";
      return CMD_DONE;
     }
   string tf=m_tf[m_f];
   m_label=tf;
   if(!m_loaded)
     {
      int n=m_hist.Load(ctx.symbol,tf,m_bars[m_f],ctx.clock);
      if(n<=0)
        {
         // MT5 downloads history on demand: the first request may return nothing. Retry a few times.
         m_loadTries++;
         if(m_loadTries>=6)
           {
            message="MT5 has no "+tf+" history for "+ctx.symbol;
            return CMD_FAILED;
           }
         message="Waiting for MT5 to download "+tf+" history ("+IntegerToString(m_loadTries)+"/6)";
         return CMD_WAIT;
        }
      m_loaded=true;
      m_loadTries=0;
      m_pos=0;
      m_plan=m_plan-m_bars[m_f]+n;           // what is really there replaces what was requested
      m_bars[m_f]=n;
     }
   int digits=(int)SymbolInfoInteger(ctx.symbol,SYMBOL_DIGITS);
   int end=MathMin(m_pos+TF_BACKFILL_CHUNK,m_hist.Size());
   string arr="[";
   for(int i=m_pos;i<end;i++)
     {
      TFCandle c;
      if(!m_hist.Get(i,c))
         continue;
      if(i>m_pos) arr+=",";
      arr+="{\"timeframe\":"+TF_JStr(tf)+",\"openTime\":"+TF_JStr(TF_IsoUtc(c.ts))+",\"open\":"+DoubleToString(c.o,digits)+
           ",\"high\":"+DoubleToString(c.h,digits)+",\"low\":"+DoubleToString(c.l,digits)+",\"close\":"+DoubleToString(c.c,digits)+
           ",\"volume\":"+IntegerToString(c.v)+",\"closed\":true}";
     }
   arr+="]";
   CJv *d=ctx.maya.Action("terminalBackfillCandles",ctx.Params("\"candles\":"+arr),90000);
   if(d==NULL)
     {
      string e=ctx.maya.LastError();
      if(StringFind(e,"NOT_FEEDER")>=0)
        {
         ctx.feeder=false;
         message="Waiting: lost the feeder role";
         return CMD_WAIT;
        }
      m_failures++;
      if(m_failures>=3)
        {
         message="Maya rejected the load: "+StringSubstr(e,0,200);
         return CMD_FAILED;
        }
      message="Retrying after error: "+StringSubstr(e,0,120);
      return CMD_WAIT;
     }
   m_failures=0;
   m_inserted+=(long)d.Num("inserted");
   m_skipped+=(long)d.Num("skipped");
   m_done+=(end-m_pos);
   m_pos=end;
   if(m_pos>=m_hist.Size())
     {
      m_f++;
      m_loaded=false;
     }
   progress=(m_plan>0) ? 100.0*(double)m_done/(double)m_plan : 0;
   if(progress>99) progress=99;             // 100 is reserved for DONE
   message=tf+": "+IntegerToString(m_pos)+" of "+IntegerToString(m_hist.Size())+" - "+IntegerToString((int)m_inserted)+" new, "+IntegerToString((int)m_skipped)+" existing";
   return CMD_RUNNING;
  }

//+------------------------------------------------------------------+
//| Factory: the one place that knows which types this EA supports   |
//+------------------------------------------------------------------+
CCommand *TF_CreateCommand(const string type)
  {
   if(type=="BACKFILL_CANDLES")
      return new CBackfillCommand();
   // if(type=="NEW_TYPE") return new CNewTypeCommand();
   return NULL;
  }

//+------------------------------------------------------------------+
//| Runner                                                           |
//+------------------------------------------------------------------+
class CCommandRunner
  {
private:
   CCommand         *m_cur;
   ulong             m_nextReportMs;
   string            m_lastMsg;
   double            m_lastProgress;
   string            m_status;       // text for the panel
   bool              Report(CCmdContext &ctx,const string status,const double progress,const string message,const string resultJson);
   void              Drop(void);
public:
                     CCommandRunner(void) : m_cur(NULL),m_nextReportMs(0),m_lastProgress(0) {}
                    ~CCommandRunner(void) { Drop(); }
   bool              Active(void) { return m_cur!=NULL; }
   string            Status(void) { return m_cur==NULL ? "-" : m_status; }
   //--- Called with the commands the heartbeat returned.
   void              Sync(CJv *commands,CCmdContext &ctx);
   //--- Runs one slice of the current command (if any).
   void              Tick(CCmdContext &ctx);
   void              Abort(void) { Drop(); }
  };

void CCommandRunner::Drop(void)
  {
   if(m_cur!=NULL)
     {
      delete m_cur;
      m_cur=NULL;
     }
  }

bool CCommandRunner::Report(CCmdContext &ctx,const string status,const double progress,const string message,const string resultJson)
  {
   if(m_cur==NULL)
      return false;
   string extra="\"commandId\":"+TF_JStr(m_cur.id)+",\"status\":"+TF_JStr(status)+",\"progress\":"+DoubleToString(progress,0)+
                ",\"message\":"+TF_JStr(StringSubstr(message,0,290));
   if(resultJson!="")
      extra+=",\"result\":"+resultJson;
   CJv *d=ctx.maya.Action("terminalCommandReport",ctx.Params(extra));
   if(d==NULL)
      return true;                       // could not tell Maya (network): keep going, the next report will
   string st=d.Str("status");
   if(st=="CANCELLED")
     {
      Print("TradeForge: command ",m_cur.type," cancelled in Maya");
      Drop();
      return false;
     }
   return true;
  }

void CCommandRunner::Sync(CJv *commands,CCmdContext &ctx)
  {
   // the running command disappeared from the list (cancelled in Maya): stop it
   if(m_cur!=NULL)
     {
      bool listed=false;
      for(int i=0;i<commands.Size() && !listed;i++)
         listed=(commands.At(i).Str("id")==m_cur.id);
      if(!listed)
        {
         Print("TradeForge: command ",m_cur.type," is no longer pending in Maya: stopped");
         Drop();
        }
      return;
     }
   if(commands.Size()==0)
      return;
   CJv *c=commands.At(0);                // oldest first: one at a time
   string id=c.Str("id");
   string type=c.Str("type");
   CCommand *cmd=TF_CreateCommand(type);
   if(cmd==NULL)
     {
      // report and forget: Maya moves it to FAILED so it does not come back
      string extra="\"commandId\":"+TF_JStr(id)+",\"status\":\"FAILED\",\"progress\":0,\"message\":"+TF_JStr("Unsupported command type '"+type+"' (this EA does not know it)");
      ctx.maya.Action("terminalCommandReport",ctx.Params(extra));
      return;
     }
   cmd.id=id;
   cmd.type=type;
   string err="";
   m_cur=cmd;
   if(!cmd.Init(c.Get("params"),err))
     {
      Report(ctx,"FAILED",0,err,"");
      Drop();
      return;
     }
   m_status="starting";
   m_lastMsg="";
   m_lastProgress=0;
   m_nextReportMs=0;
   PrintFormat("TradeForge: command %s started (%s)",type,id);
   Report(ctx,"RUNNING",0,"Started","");
  }

void CCommandRunner::Tick(CCmdContext &ctx)
  {
   if(m_cur==NULL)
      return;
   double progress=m_lastProgress;
   string message=m_lastMsg;
   string result="";
   TFCmdState st=m_cur.Step(ctx,progress,message,result);
   m_lastProgress=progress;
   m_lastMsg=message;
   m_status=m_cur.Label()+" "+DoubleToString(progress,0)+"% - "+StringSubstr(message,0,40);
   if(st==CMD_DONE || st==CMD_FAILED)
     {
      Report(ctx,st==CMD_DONE ? "DONE" : "FAILED",progress,message,result);
      PrintFormat("TradeForge: command %s %s: %s",m_cur!=NULL ? m_cur.type : "",st==CMD_DONE ? "done" : "failed",message);
      Drop();
      return;
     }
   ulong now=GetTickCount64();
   if(now>=m_nextReportMs)
     {
      m_nextReportMs=now+3000;
      Report(ctx,"RUNNING",progress,message,"");
     }
  }

#endif
