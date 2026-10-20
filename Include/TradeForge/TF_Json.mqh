//+------------------------------------------------------------------+
//| TF_Json.mqh - minimal JSON tree parser and string helpers        |
//| MQL5 has no JSON support. Only what the Maya Actions need.       |
//+------------------------------------------------------------------+
#ifndef TF_JSON_MQH
#define TF_JSON_MQH

enum TF_JType
  {
   TF_J_NULL=0,
   TF_J_BOOL=1,
   TF_J_NUM=2,
   TF_J_STR=3,
   TF_J_ARR=4,
   TF_J_OBJ=5
  };

//--- A JSON value. Arrays keep empty keys. Missing keys return a shared null node (never NULL).
class CJv
  {
public:
   TF_JType          t;
   bool              b;
   double            n;
   string            s;
   string            keys[];
   CJv              *vals[];

                     CJv(void);
                    ~CJv(void);
   void              Clear(void);
   int               Size(void);
   void              Push(const string key,CJv *v);
   CJv              *Get(const string key);
   CJv              *At(const int i);
   bool              IsNull(void) { return t==TF_J_NULL; }
   string            Str(const string key,const string def="");
   double            Num(const string key,const double def=0.0);
   bool              Bool(const string key,const bool def=false);
   string            AsStr(const string def="");
  };

CJv g_tf_jnull;

CJv::CJv(void) : t(TF_J_NULL),b(false),n(0.0),s("") {}
CJv::~CJv(void) { Clear(); }

void CJv::Clear(void)
  {
   for(int i=0;i<ArraySize(vals);i++)
      if(CheckPointer(vals[i])==POINTER_DYNAMIC)
         delete vals[i];
   ArrayResize(vals,0);
   ArrayResize(keys,0);
  }

int CJv::Size(void) { return ArraySize(vals); }

void CJv::Push(const string key,CJv *v)
  {
   int k=ArraySize(vals);
   ArrayResize(vals,k+1);
   ArrayResize(keys,k+1);
   vals[k]=v;
   keys[k]=key;
  }

CJv *CJv::Get(const string key)
  {
   if(t!=TF_J_OBJ)
      return GetPointer(g_tf_jnull);
   for(int i=0;i<ArraySize(vals);i++)
      if(keys[i]==key)
         return vals[i];
   return GetPointer(g_tf_jnull);
  }

CJv *CJv::At(const int i)
  {
   if(t!=TF_J_ARR || i<0 || i>=ArraySize(vals))
      return GetPointer(g_tf_jnull);
   return vals[i];
  }

string CJv::AsStr(const string def)
  {
   if(t==TF_J_STR)
      return s;
   if(t==TF_J_NUM)
      return DoubleToString(n,(MathAbs(n-MathRound(n))<1e-9) ? 0 : 8);
   if(t==TF_J_BOOL)
      return b ? "true" : "false";
   return def;
  }

string CJv::Str(const string key,const string def)
  {
   CJv *v=Get(key);
   return v.AsStr(def);
  }

double CJv::Num(const string key,const double def)
  {
   CJv *v=Get(key);
   if(v.t==TF_J_NUM)
      return v.n;
   if(v.t==TF_J_STR)
      return StringToDouble(v.s);
   return def;
  }

bool CJv::Bool(const string key,const bool def)
  {
   CJv *v=Get(key);
   if(v.t==TF_J_BOOL)
      return v.b;
   return def;
  }

//+------------------------------------------------------------------+
//| Parser                                                           |
//+------------------------------------------------------------------+
class CJParser
  {
private:
   string            m_s;
   int               m_p;
   int               m_n;
   bool              m_err;
   ushort            Cur(void);
   void              SkipWs(void);
   string            ReadString(void);
   CJv              *Value(const int depth);
public:
   //--- Returns a tree owned by the caller (delete it), or NULL if the text is not valid JSON.
   CJv              *Parse(const string src);
  };

ushort CJParser::Cur(void)
  {
   return (m_p<m_n) ? StringGetCharacter(m_s,m_p) : 0;
  }

void CJParser::SkipWs(void)
  {
   while(m_p<m_n)
     {
      ushort c=StringGetCharacter(m_s,m_p);
      if(c==' ' || c=='\t' || c=='\r' || c=='\n')
         m_p++;
      else
         break;
     }
  }

string CJParser::ReadString(void)
  {
   // positioned on the opening quote
   m_p++;
   string out="";
   int run=m_p;
   while(m_p<m_n)
     {
      ushort c=StringGetCharacter(m_s,m_p);
      if(c=='"')
        {
         out+=StringSubstr(m_s,run,m_p-run);
         m_p++;
         return out;
        }
      if(c=='\\')
        {
         out+=StringSubstr(m_s,run,m_p-run);
         m_p++;
         if(m_p>=m_n) break;
         ushort e=StringGetCharacter(m_s,m_p);
         m_p++;
         switch(e)
           {
            case 'n': out+="\n"; break;
            case 't': out+="\t"; break;
            case 'r': out+="\r"; break;
            case 'b': out+=ShortToString(8); break;
            case 'f': out+=ShortToString(12); break;
            case 'u':
              {
               if(m_p+4>m_n) { m_err=true; return out; }
               int code=0;
               for(int i=0;i<4;i++)
                 {
                  ushort h=StringGetCharacter(m_s,m_p+i);
                  int d=(h>='0' && h<='9') ? h-'0' : (h>='a' && h<='f') ? h-'a'+10 : (h>='A' && h<='F') ? h-'A'+10 : -1;
                  if(d<0) { m_err=true; return out; }
                  code=code*16+d;
                 }
               m_p+=4;
               out+=ShortToString((ushort)code);
               break;
              }
            default: out+=ShortToString(e); break; // \" \\ \/
           }
         run=m_p;
         continue;
        }
      m_p++;
     }
   m_err=true;
   return out;
  }

CJv *CJParser::Value(const int depth)
  {
   SkipWs();
   if(m_p>=m_n || depth>32)
     {
      m_err=true;
      return NULL;
     }
   ushort c=StringGetCharacter(m_s,m_p);
   CJv *v=new CJv();
   if(c=='{')
     {
      m_p++;
      v.t=TF_J_OBJ;
      SkipWs();
      if(Cur()=='}') { m_p++; return v; }
      while(!m_err)
        {
         SkipWs();
         if(Cur()!='"') { m_err=true; break; }
         string k=ReadString();
         if(m_err) break;
         SkipWs();
         if(Cur()!=':') { m_err=true; break; }
         m_p++;
         CJv *child=Value(depth+1);
         if(m_err) { if(child!=NULL) delete child; break; }
         v.Push(k,child);
         SkipWs();
         ushort d=Cur();
         m_p++;
         if(d==',') continue;
         if(d=='}') break;
         m_err=true;
        }
      return v;
     }
   if(c=='[')
     {
      m_p++;
      v.t=TF_J_ARR;
      SkipWs();
      if(Cur()==']') { m_p++; return v; }
      while(!m_err)
        {
         CJv *child=Value(depth+1);
         if(m_err) { if(child!=NULL) delete child; break; }
         v.Push("",child);
         SkipWs();
         ushort d=Cur();
         m_p++;
         if(d==',') continue;
         if(d==']') break;
         m_err=true;
        }
      return v;
     }
   if(c=='"')
     {
      v.t=TF_J_STR;
      v.s=ReadString();
      return v;
     }
   if(StringSubstr(m_s,m_p,4)=="true")  { v.t=TF_J_BOOL; v.b=true;  m_p+=4; return v; }
   if(StringSubstr(m_s,m_p,5)=="false") { v.t=TF_J_BOOL; v.b=false; m_p+=5; return v; }
   if(StringSubstr(m_s,m_p,4)=="null")  { m_p+=4; return v; }
   int start=m_p;
   while(m_p<m_n)
     {
      ushort d=StringGetCharacter(m_s,m_p);
      if((d>='0' && d<='9') || d=='-' || d=='+' || d=='.' || d=='e' || d=='E') m_p++;
      else break;
     }
   if(m_p==start) { m_err=true; return v; }
   v.t=TF_J_NUM;
   v.n=StringToDouble(StringSubstr(m_s,start,m_p-start));
   return v;
  }

CJv *CJParser::Parse(const string src)
  {
   m_s=src;
   m_p=0;
   m_n=StringLen(src);
   m_err=false;
   CJv *v=Value(0);
   if(m_err)
     {
      if(v!=NULL) delete v;
      return NULL;
     }
   return v;
  }

//+------------------------------------------------------------------+
//| Writer helpers (JSON is assembled with string concatenation)     |
//+------------------------------------------------------------------+
string TF_JStr(const string s)
  {
   string out="\"";
   int n=StringLen(s);
   for(int i=0;i<n;i++)
     {
      ushort c=StringGetCharacter(s,i);
      if(c=='"')       out+="\\\"";
      else if(c=='\\') out+="\\\\";
      else if(c=='\n') out+="\\n";
      else if(c=='\r') out+="\\r";
      else if(c=='\t') out+="\\t";
      else if(c<0x20)  out+=StringFormat("\\u%04x",c);
      else             out+=ShortToString(c);
     }
   return out+"\"";
  }

string TF_JBool(const bool v) { return v ? "true" : "false"; }

//--- ISO-8601 UTC ("2026-10-20T10:05:00Z") from a UTC epoch
string TF_IsoUtc(const long ts)
  {
   MqlDateTime d;
   TimeToStruct((datetime)ts,d);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",d.year,d.mon,d.day,d.hour,d.min,d.sec);
  }

#endif
