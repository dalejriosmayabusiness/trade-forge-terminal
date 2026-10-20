//+------------------------------------------------------------------+
//| TF_Panel.mqh - on-chart control panel (status + ON/OFF switch)  |
//| Plain chart objects only, no Standard Library controls.          |
//+------------------------------------------------------------------+
#ifndef TF_PANEL_MQH
#define TF_PANEL_MQH

#define TFP_PREFIX "TFP_"
#define TFP_ROWS   10

enum TF_PanelAction
  {
   TFP_NONE=0,
   TFP_TOGGLE=1,
   TFP_COLLAPSE=2
  };

//--- One row of the panel: label, value and the color of the value
struct TFRow
  {
   string            value;
   color             clr;
  };

class CTFPanel
  {
private:
   long              m_chart;
   int               m_x,m_y;
   int               m_w;
   double            m_scale;
   int               m_rowH;
   int               m_headH;
   int               U(const double v) { return (int)MathRound(v*m_scale); }
   bool              m_collapsed;
   string            m_labels[TFP_ROWS];

   string            N(const string s) { return TFP_PREFIX+s; }
   void              Rect(const string name,const int x,const int y,const int w,const int h,const color bg,const color border);
   void              Label(const string name,const int x,const int y,const string text,const color clr,const int size=9,const string font="Arial");
   void              Button(const string name,const int x,const int y,const int w,const int h,const string text,const color bg,const color fg);
   void              ApplyCollapse(void);
public:
                     CTFPanel(void) : m_chart(0),m_x(12),m_y(24),m_w(480),m_scale(1.0),m_rowH(22),m_headH(40),m_collapsed(false) {}
   void              Create(const long chart,const int x,const int y,const int scalePercent);
   void              Destroy(void);
   //--- Updates the title bar: `active` colors the switch, `stateText/stateClr` the headline.
   void              SetSwitch(const bool active);
   void              SetRows(const TFRow &rows[]);
   TF_PanelAction    OnClick(const string objectName);
   bool              Collapsed(void) { return m_collapsed; }
  };

void CTFPanel::Rect(const string name,const int x,const int y,const int w,const int h,const color bg,const color border)
  {
   if(ObjectFind(m_chart,name)<0)
      ObjectCreate(m_chart,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,border);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,0);
  }

void CTFPanel::Label(const string name,const int x,const int y,const string text,const color clr,const int size,const string font)
  {
   if(ObjectFind(m_chart,name)<0)
      ObjectCreate(m_chart,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chart,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,size);
   ObjectSetString(m_chart,name,OBJPROP_FONT,font);
   ObjectSetString(m_chart,name,OBJPROP_TEXT,text);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,1);
  }

void CTFPanel::Button(const string name,const int x,const int y,const int w,const int h,const string text,const color bg,const color fg)
  {
   if(ObjectFind(m_chart,name)<0)
      ObjectCreate(m_chart,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_BORDER_COLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,fg);
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,9);
   ObjectSetString(m_chart,name,OBJPROP_FONT,"Arial Bold");
   ObjectSetString(m_chart,name,OBJPROP_TEXT,text);
   ObjectSetInteger(m_chart,name,OBJPROP_STATE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,2);
  }

void CTFPanel::Create(const long chart,const int x,const int y,const int scalePercent)
  {
   m_chart=chart;
   // Fonts follow the OS DPI but chart pixel coordinates do not: measure the real text height and scale the layout.
   m_scale=1.0;
   if(scalePercent>0)
      m_scale=scalePercent/100.0;
   else
     {
      uint tw=0,th=0;
      if(TextSetFont("Arial",-90,0,0) && TextGetSize("Ag",tw,th) && th>0)
         m_scale=MathMax(1.0,MathMin(3.0,th/12.0));
     }
   m_w=U(480);
   m_rowH=U(22);
   m_headH=U(40);
   m_x=x;
   m_y=y;
   string names[TFP_ROWS]={"Status","Account","Terminal","Strategy","Mode","Instrument","Feeder","Heartbeat","Candles","Last error"};
   for(int i=0;i<TFP_ROWS;i++)
      m_labels[i]=names[i];

   const color bg=C'24,28,36';
   const color border=C'58,66,82';
   Rect(N("bg"),m_x,m_y,m_w,m_headH+TFP_ROWS*m_rowH+U(12),bg,border);
   Rect(N("head"),m_x,m_y,m_w,m_headH,C'33,39,52',border);
   Label(N("title"),m_x+U(12),m_y+U(11),"TradeForge Terminal",C'230,234,242',10,"Arial Bold");
   Button(N("collapse"),m_x+m_w-U(40),m_y+U(7),U(28),U(26),"-",C'58,66,82',clrWhite);
   Button(N("toggle"),m_x+m_w-U(40+110),m_y+U(7),U(100),U(26),"...",C'90,90,90',clrWhite);
   for(int i=0;i<TFP_ROWS;i++)
     {
      int ry=m_y+m_headH+U(8)+i*m_rowH;
      Label(N("k"+IntegerToString(i)),m_x+U(12),ry,m_labels[i],C'130,140,160',9);
      Label(N("v"+IntegerToString(i)),m_x+U(120),ry,"-",C'210,215,225',9);
     }
   ApplyCollapse();
   ChartRedraw(m_chart);
  }

void CTFPanel::Destroy(void)
  {
   ObjectsDeleteAll(m_chart,TFP_PREFIX);
   ChartRedraw(m_chart);
  }

void CTFPanel::SetSwitch(const bool active)
  {
   ObjectSetString(m_chart,N("toggle"),OBJPROP_TEXT,active ? "ACTIVE" : "PAUSED");
   ObjectSetInteger(m_chart,N("toggle"),OBJPROP_BGCOLOR,active ? C'30,130,76' : C'160,60,60');
   ObjectSetInteger(m_chart,N("toggle"),OBJPROP_BORDER_COLOR,active ? C'30,130,76' : C'160,60,60');
   ObjectSetInteger(m_chart,N("toggle"),OBJPROP_STATE,false);
  }

void CTFPanel::SetRows(const TFRow &rows[])
  {
   int n=MathMin(ArraySize(rows),TFP_ROWS);
   for(int i=0;i<n;i++)
     {
      ObjectSetString(m_chart,N("v"+IntegerToString(i)),OBJPROP_TEXT,rows[i].value);
      ObjectSetInteger(m_chart,N("v"+IntegerToString(i)),OBJPROP_COLOR,rows[i].clr);
     }
   ChartRedraw(m_chart);
  }

void CTFPanel::ApplyCollapse(void)
  {
   int h=m_collapsed ? m_headH : m_headH+TFP_ROWS*m_rowH+U(12);
   ObjectSetInteger(m_chart,N("bg"),OBJPROP_YSIZE,h);
   ObjectSetString(m_chart,N("collapse"),OBJPROP_TEXT,m_collapsed ? "+" : "-");
   long vis=m_collapsed ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS;
   for(int i=0;i<TFP_ROWS;i++)
     {
      ObjectSetInteger(m_chart,N("k"+IntegerToString(i)),OBJPROP_TIMEFRAMES,vis);
      ObjectSetInteger(m_chart,N("v"+IntegerToString(i)),OBJPROP_TIMEFRAMES,vis);
     }
  }

TF_PanelAction CTFPanel::OnClick(const string objectName)
  {
   if(objectName==N("toggle"))
     {
      ObjectSetInteger(m_chart,objectName,OBJPROP_STATE,false);
      return TFP_TOGGLE;
     }
   if(objectName==N("collapse"))
     {
      ObjectSetInteger(m_chart,objectName,OBJPROP_STATE,false);
      m_collapsed=!m_collapsed;
      ApplyCollapse();
      ChartRedraw(m_chart);
      return TFP_COLLAPSE;
     }
   return TFP_NONE;
  }

#endif
