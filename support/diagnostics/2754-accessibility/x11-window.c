/* Independent X11 client-origin observation; cloud compilation only. */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>

static int failed;
static int xerror(Display *d, XErrorEvent *e) {
  char message[256]; XGetErrorText(d,e->error_code,message,sizeof message);
  fprintf(stderr,"X11 error request=%u resource=%lu: %s\n",e->request_code,e->resourceid,message);
  failed=1; return 0;
}
static int bounds(Display *d, Window w, Window root) {
  XWindowAttributes a; int x=0,y=0; Window child=None;
  if (!XGetWindowAttributes(d,w,&a) || !XTranslateCoordinates(d,w,root,0,0,&x,&y,&child)) return 0;
  printf("{\"window_id\":%lu,\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d,\"border_width\":%d,\"map_state\":%d}",w,x,y,a.width,a.height,a.border_width,a.map_state);
  return 1;
}
static int cardinals(Display *d, Window w, const char *name, unsigned long expected, unsigned long *values) {
  Atom property=XInternAtom(d,name,True), actual=None; int format=0;
  unsigned long n=0,left=0; unsigned char *data=NULL;
  if(property==None) return 0;
  int status=XGetWindowProperty(d,w,property,0,(long)expected,False,XA_CARDINAL,&actual,&format,&n,&left,&data);
  int ok=status==Success && actual==XA_CARDINAL && format==32 && n==expected && left==0 && data;
  if(ok) for(unsigned long i=0;i<n;i++) values[i]=((unsigned long *)data)[i];
  if(data) XFree(data);
  return ok;
}
int main(int argc,char **argv) {
  if(argc!=2) return 2;
  setvbuf(stdout,NULL,_IONBF,0);
  char *end=NULL; unsigned long id=strtoul(argv[1],&end,10);
  if(!id || *end) return 2;
  Display *d=XOpenDisplay(NULL); if(!d) {fputs("XOpenDisplay failed\n",stderr);return 3;}
  XSetErrorHandler(xerror); Window w=(Window)id,root=None,parent=None,*children=NULL; unsigned int n=0;
  if(!XQueryTree(d,w,&root,&parent,&children,&n)) {XCloseDisplay(d);return 4;}
  if(children) XFree(children);
  unsigned long pid[1],frame[4];
  printf("{\"source\":\"XGetWindowAttributes + XTranslateCoordinates(client, root, 0, 0)\",\"root_id\":%lu,\"client\":",root);
  if(!bounds(d,w,root)) {XCloseDisplay(d);return 4;}
  printf(",\"client_pid\":"); if(cardinals(d,w,"_NET_WM_PID",1,pid)) printf("%lu",pid[0]); else printf("null");
  printf(",\"frame_extents\":");
  if(cardinals(d,w,"_NET_FRAME_EXTENTS",4,frame)) printf("{\"left\":%lu,\"right\":%lu,\"top\":%lu,\"bottom\":%lu}",frame[0],frame[1],frame[2],frame[3]); else printf("null");
  printf(",\"ancestors\":["); unsigned int depth=0; Window visited[32]; int cycle=0;
  while(parent!=None && parent!=root && depth<32) {
    for(unsigned int i=0;i<depth;i++) if(visited[i]==parent) cycle=1;
    if(cycle) break;
    visited[depth]=parent; if(depth) putchar(','); depth++;
    if(!bounds(d,parent,root)) {XCloseDisplay(d);return 4;}
    Window ancestor=parent;
    if(!XQueryTree(d,ancestor,&root,&parent,&children,&n)) {XCloseDisplay(d);return 4;}
    if(children) XFree(children);
  }
  printf("],\"ancestry_cycle\":%s,\"ancestry_truncated\":%s}",cycle?"true":"false",depth==32 && parent!=root?"true":"false");
  XSync(d,False); XCloseDisplay(d); putchar('\n');
  return failed || cycle || (depth==32 && parent!=root) ? 4 : 0;
}
