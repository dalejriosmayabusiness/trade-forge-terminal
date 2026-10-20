//+------------------------------------------------------------------+
//| TF_Maya.mqh - Maya client: Bridge login + global Actions         |
//| Never logs the Bridge secret, the session token or the terminal  |
//| token.                                                           |
//+------------------------------------------------------------------+
#ifndef TF_MAYA_MQH
#define TF_MAYA_MQH

#include "TF_Json.mqh"

#define TF_SESSION_MAX_AGE 518400   // renew the session after 6 days (Maya tokens last 7)

class CMaya
  {
private:
   string            m_url;
   string            m_bridgeKey;
   string            m_secret;
   string            m_terminalToken;
   string            m_jwt;
   datetime          m_jwtAt;
   CJv              *m_last;          // last parsed response (owned)
   CJv              *m_lastData;      // owned when the Action returned data as a JSON string
   string            m_error;
   int               m_ms;
   bool              m_authError;

   bool              Http(const string body,const int timeoutMs,string &resp,int &status);
   bool              Login(void);
   void              Release(void);
public:
                     CMaya(void) : m_jwtAt(0),m_last(NULL),m_lastData(NULL),m_ms(0),m_authError(false) {}
                    ~CMaya(void) { Release(); }
   void              Setup(const string url,const string bridgeKey,const string secret,const string terminalToken);
   string            Token(void) { return m_terminalToken; }
   string            LastError(void) { return m_error; }
   int               LastMs(void) { return m_ms; }
   //--- True when the last failure came from the Maya session (not from the Action itself)
   bool              AuthFailed(void) { return m_authError; }
   void              DropSession(void) { m_jwt=""; }
   //--- Runs a global Action. `paramsJson` is a JSON object. On success returns the node `data`
   //--- (owned by the client, valid until the next call); on failure returns NULL and sets LastError().
   CJv              *Action(const string key,const string paramsJson,const int timeoutMs=10000);
  };

void CMaya::Setup(const string url,const string bridgeKey,const string secret,const string terminalToken)
  {
   m_url=url;
   while(StringLen(m_url)>0 && StringGetCharacter(m_url,StringLen(m_url)-1)=='/')
      m_url=StringSubstr(m_url,0,StringLen(m_url)-1);
   m_bridgeKey=bridgeKey;
   m_secret=secret;
   m_terminalToken=terminalToken;
   m_jwt="";
  }

void CMaya::Release(void)
  {
   if(m_last!=NULL)     { delete m_last;     m_last=NULL; }
   if(m_lastData!=NULL) { delete m_lastData; m_lastData=NULL; }
  }

bool CMaya::Http(const string body,const int timeoutMs,string &resp,int &status)
  {
   char data[],result[];
   string resHeaders;
   int n=StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8);
   ArrayResize(data,n>0 ? n-1 : 0);   // drop the terminating zero
   string headers="Content-Type: application/json\r\n";
   if(m_jwt!="")
      headers+="Authorization: Bearer "+m_jwt+"\r\n";
   ResetLastError();
   uint t0=GetTickCount();
   status=WebRequest("POST",m_url+"/graphql",headers,timeoutMs,data,result,resHeaders);
   m_ms=(int)(GetTickCount()-t0);
   if(status==-1)
     {
      int err=GetLastError();
      if(err==4014)
         m_error="WebRequest blocked: add "+m_url+" in Tools > Options > Expert Advisors > Allow WebRequest";
      else
         m_error="Network error "+IntegerToString(err);
      return false;
     }
   resp=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   return true;
  }

bool CMaya::Login(void)
  {
   m_jwt="";
   string body="{\"query\":"+TF_JStr("mutation($k:String!,$s:String!){loginWithBridge(bridgeKey:$k,secret:$s){token}}")+
               ",\"variables\":{\"k\":"+TF_JStr(m_bridgeKey)+",\"s\":"+TF_JStr(m_secret)+"}}";
   string resp;
   int status;
   if(!Http(body,10000,resp,status))
      return false;
   CJParser p;
   CJv *root=p.Parse(resp);
   if(root==NULL)
     {
      m_error="Login: invalid response (HTTP "+IntegerToString(status)+")";
      return false;
     }
   string tok=root.Get("data").Get("loginWithBridge").Str("token");
   string msg=root.Get("errors").At(0).Str("message");
   delete root;
   if(tok=="")
     {
      m_error="Bridge login failed"+(msg!="" ? ": "+msg : " (HTTP "+IntegerToString(status)+")");
      m_authError=true;
      return false;
     }
   m_jwt=tok;
   m_jwtAt=TimeLocal();
   return true;
  }

CJv *CMaya::Action(const string key,const string paramsJson,const int timeoutMs)
  {
   Release();
   m_authError=false;
   m_error="";
   const string query="mutation($k:String!,$p:JSON){executeGlobalAction(key:$k,params:$p){success data error}}";
   string body="{\"query\":"+TF_JStr(query)+",\"variables\":{\"k\":"+TF_JStr(key)+",\"p\":"+paramsJson+"}}";

   for(int attempt=0;attempt<2;attempt++)
     {
      if(m_jwt=="" || (TimeLocal()-m_jwtAt)>TF_SESSION_MAX_AGE)
         if(!Login())
            return NULL;
      string resp;
      int status;
      if(!Http(body,timeoutMs,resp,status))
         return NULL;
      CJParser p;
      CJv *root=p.Parse(resp);
      if(root==NULL)
        {
         m_error="Invalid response (HTTP "+IntegerToString(status)+")";
         return NULL;
        }
      // GraphQL / session errors
      CJv *errs=root.Get("errors");
      if(status==401 || errs.Size()>0)
        {
         string msg=errs.At(0).Str("message");
         string code=errs.At(0).Get("extensions").Str("code");
         bool unauth=(status==401 || code=="UNAUTHENTICATED" || StringFind(msg,"UNAUTHENTICATED")>=0);
         delete root;
         if(unauth && attempt==0)
           {
            m_jwt="";   // expired or revoked session: log in again once
            continue;
           }
         m_authError=unauth;
         m_error=(msg!="") ? msg : "HTTP "+IntegerToString(status);
         return NULL;
        }
      CJv *act=root.Get("data").Get("executeGlobalAction");
      if(!act.Bool("success"))
        {
         m_error=act.Str("error","Action failed");
         delete root;
         return NULL;
        }
      m_last=root;
      CJv *d=act.Get("data");
      if(d.t==TF_J_STR)
        {
         CJParser p2;
         m_lastData=p2.Parse(d.s);
         return (m_lastData!=NULL) ? m_lastData : GetPointer(g_tf_jnull);
        }
      return d;
     }
   return NULL;
  }

#endif
