/* Cloud diagnostic; compiled against the public at-spi2-core 2.52 headers. */
#include <atspi/atspi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned nodes, editable_nodes, focused_editable;
static const unsigned max_nodes = 160, max_depth = 14;
static GHashTable *seen;
static gboolean truncated;
static gint64 started;

static void string(const char *s) {
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
    if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
    else if (*p < 32) printf("\\u%04x", *p);
    else putchar(*p);
  }
  putchar('"');
}
static void identity(AtspiAccessible *a) {
  /* These fields are exposed by installed public atspi-object/application.h. */
  AtspiObject *o = a ? ATSPI_OBJECT(a) : NULL;
  printf("{\"bus\":"); string(o && o->app ? o->app->bus_name : NULL);
  printf(",\"path\":"); string(o ? o->path : NULL); putchar('}');
}
static void begin(const char *op, AtspiAccessible *a, gint64 t, GError *e) {
  printf("{\"kind\":\"query\",\"op\":"); string(op);
  printf(",\"identity\":"); identity(a);
  printf(",\"elapsed_ms\":%.3f,\"since_start_ms\":%.3f,\"error\":", (g_get_monotonic_time()-t)/1000., (g_get_monotonic_time()-started)/1000.);
  if (e) { printf("{\"domain\":"); string(g_quark_to_string(e->domain)); printf(",\"code\":%d,\"message\":", e->code); string(e->message); putchar('}'); }
  else printf("null");
}
static void end(GError **e) { puts("}"); fflush(stdout); g_clear_error(e); }
static void rect(const AtspiRect *r) {
  if (!r) { printf("null"); return; }
  printf("{\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d}", r->x,r->y,r->width,r->height);
}
static void geometry(AtspiAccessible *a, AtspiComponent *c, gboolean target, gboolean eligible) {
  for (int coord = 0; coord < 2; coord++) {
    GError *e = NULL; gint64 t = g_get_monotonic_time();
    AtspiRect *r = atspi_component_get_extents(c, coord == 0 ? ATSPI_COORD_TYPE_SCREEN : ATSPI_COORD_TYPE_WINDOW, &e);
    gboolean extent_ok = e == NULL;
    begin("GetExtents", a,t,e); printf(",\"coordinate\":\"%s\",\"result\":",coord == 0 ? "SCREEN" : "WINDOW"); rect(r); end(&e);
    if (target && eligible && extent_ok && r && r->width > 0 && r->height > 0 && r->x != -1 && r->y != -1) {
      int x = r->x + r->width/2, y = r->y + r->height/2;
      for (int outside = 0; outside < 2; outside++) {
        int px = outside ? r->x - 2 : x, py = outside ? r->y - 2 : y;
        t = g_get_monotonic_time(); gboolean contains = atspi_component_contains(c,px,py,coord,&e);
        begin("Contains",a,t,e); printf(",\"coordinate\":\"%s\",\"point\":[%d,%d],\"probe\":\"%s\",\"result\":%s",coord == 0 ? "SCREEN" : "WINDOW",px,py,outside ? "outside" : "inside",contains ? "true" : "false"); end(&e);
      }
      t = g_get_monotonic_time(); AtspiAccessible *hit = atspi_component_get_accessible_at_point(c,x,y,coord,&e);
      begin("GetAccessibleAtPoint",a,t,e); printf(",\"coordinate\":\"%s\",\"point\":[%d,%d],\"result\":",coord == 0 ? "SCREEN" : "WINDOW",x,y); if(hit) identity(hit); else printf("null"); end(&e); if(hit) g_object_unref(hit);
    }
    if (target && (!eligible || !extent_ok || !r || r->width <= 0 || r->height <= 0 || r->x == -1 || r->y == -1)) {
      printf("{\"kind\":\"skipped\",\"op\":\"Contains/GetAccessibleAtPoint\",\"identity\":"); identity(a);
      printf(",\"coordinate\":\"%s\",\"reason\":\"%s\"}\n",coord == 0 ? "SCREEN" : "WINDOW",eligible ? "missing or invalid extents" : "state is not visible/showing or is defunct");
    }
    if (r) g_boxed_free(ATSPI_TYPE_RECT,r);
  }
}
static void walk(AtspiAccessible *a, unsigned depth) {
  if (nodes >= max_nodes || depth > max_depth) { truncated = TRUE; return; }
  AtspiObject *o = ATSPI_OBJECT(a); char *key = g_strdup_printf("%s:%s",o->app && o->app->bus_name ? o->app->bus_name : "",o->path ? o->path : "");
  if (g_hash_table_contains(seen,key)) { g_free(key); return; }
  g_hash_table_add(seen,key); nodes++;
  atspi_accessible_set_cache_mask(a,ATSPI_CACHE_NONE);
  atspi_accessible_clear_cache_single(a);
  GError *e = NULL; gint64 t = g_get_monotonic_time();
  gchar *name = atspi_accessible_get_name(a,&e); begin("GetName",a,t,e); printf(",\"result\":"); string(name); end(&e);
  t = g_get_monotonic_time(); AtspiRole role = atspi_accessible_get_role(a,&e); begin("GetRole",a,t,e); printf(",\"result\":%d",role); end(&e);
  t = g_get_monotonic_time(); AtspiStateSet *state = atspi_accessible_get_state_set(a);
  gboolean focused = state && atspi_state_set_contains(state,ATSPI_STATE_FOCUSED);
  gboolean editable = state && atspi_state_set_contains(state,ATSPI_STATE_EDITABLE);
  gboolean defunct = state && atspi_state_set_contains(state,ATSPI_STATE_DEFUNCT);
  gboolean visible = state && atspi_state_set_contains(state,ATSPI_STATE_VISIBLE);
  gboolean showing = state && atspi_state_set_contains(state,ATSPI_STATE_SHOWING);
  begin("GetStateSet",a,t,NULL); printf(",\"result\":{\"focused\":%s,\"editable\":%s,\"defunct\":%s,\"visible\":%s,\"showing\":%s},\"state_available\":%s",focused?"true":"false",editable?"true":"false",defunct?"true":"false",visible?"true":"false",showing?"true":"false",state?"true":"false"); end(&e);
  t = g_get_monotonic_time(); AtspiComponent *c = atspi_accessible_get_component_iface(a);
  begin("ComponentInterface",a,t,NULL); printf(",\"supported\":%s",c?"true":"false"); end(&e);
  t = g_get_monotonic_time(); AtspiEditableText *et = atspi_accessible_get_editable_text_iface(a);
  begin("EditableTextInterface",a,t,NULL); printf(",\"supported\":%s",et?"true":"false"); end(&e);
  printf("{\"kind\":\"node\",\"identity\":"); identity(a); printf(",\"depth\":%u,\"role\":%d,\"name\":",depth,role); string(name);
  gchar *role_name = atspi_role_get_name(role);
  printf(",\"role_name\":"); string(role_name); g_free(role_name);
  printf(",\"component\":%s,\"editable_text\":%s,\"focused\":%s,\"editable_state\":%s,\"defunct\":%s,\"visible\":%s,\"showing\":%s,\"geometry_eligible\":%s}\n",c?"true":"false",et?"true":"false",focused?"true":"false",editable?"true":"false",defunct?"true":"false",visible?"true":"false",showing?"true":"false",state && !defunct && visible && showing?"true":"false"); fflush(stdout);
  t = g_get_monotonic_time(); GArray *interfaces = atspi_accessible_get_interfaces(a);
  begin("GetInterfaces",a,t,NULL); printf(",\"result\":[");
  if (interfaces) for (guint i = 0; i < interfaces->len; i++) {
    if (i) putchar(',');
    gchar *interface_name = g_array_index(interfaces,gchar *,i);
    string(interface_name); g_free(interface_name);
  }
  printf("]"); end(&e); if (interfaces) g_array_free(interfaces,TRUE);
  if (et) { editable_nodes++; if(focused) focused_editable++; }
  if(c) { geometry(a,c,et != NULL || focused,state && !defunct && visible && showing); g_object_unref(c); }
  if(et) g_object_unref(et);
  if(state) g_object_unref(state);
  g_free(name);
  t = g_get_monotonic_time(); int count = atspi_accessible_get_child_count(a,&e); begin("GetChildCount",a,t,e); printf(",\"result\":%d",count); end(&e);
  for(int i=0;i<count && nodes<max_nodes;i++) {
    t = g_get_monotonic_time(); AtspiAccessible *child = atspi_accessible_get_child_at_index(a,i,&e);
    begin("GetChildAtIndex",a,t,e); printf(",\"index\":%d,\"result\":",i); if(child) identity(child); else printf("null"); end(&e);
    if(child) { walk(child,depth+1); g_object_unref(child); }
  }
  if(count > 0 && nodes>=max_nodes) truncated=TRUE;
}
int main(int argc, char **argv) {
  if(argc != 3) { fprintf(stderr,"usage: geometry-client PID LABEL\n"); return 2; }
  char *pid_end = NULL; unsigned long pid = strtoul(argv[1],&pid_end,10);
  if(!pid || *pid_end) return 2;
  setvbuf(stdout,NULL,_IOLBF,0); started = g_get_monotonic_time();
  gint major,minor,micro; atspi_get_version(&major,&minor,&micro);
  printf("{\"kind\":\"session\",\"pid\":%lu,\"label\":",pid); string(argv[2]); printf(",\"libatspi_version\":\"%d.%d.%d\",\"timeout_ms\":1500,\"max_nodes\":160,\"max_depth\":14}\n",major,minor,micro);
  if(major != 2 || minor != 52) { puts("{\"kind\":\"failure\",\"reason\":\"requires libatspi 2.52.x\"}"); return 3; }
  atspi_set_timeout(1500,1500);
  if(atspi_init()) { puts("{\"kind\":\"failure\",\"reason\":\"atspi_init failed\"}"); return 4; }
  seen = g_hash_table_new_full(g_str_hash,g_str_equal,g_free,NULL);
  AtspiAccessible *desktop = atspi_get_desktop(0); GError *e = NULL;
  if (!desktop) { puts("{\"kind\":\"failure\",\"reason\":\"no AT-SPI desktop\"}"); atspi_exit(); return 4; }
  gint64 t=g_get_monotonic_time(); int count = atspi_accessible_get_child_count(desktop,&e); begin("DesktopChildCount",desktop,t,e); printf(",\"result\":%d",count); end(&e);
  gboolean found = FALSE;
  for(int i=0;i<count && i<80;i++) {
    t=g_get_monotonic_time(); AtspiAccessible *app = atspi_accessible_get_child_at_index(desktop,i,&e);
    begin("DesktopChildAtIndex",desktop,t,e); printf(",\"index\":%d,\"result\":",i); if(app) identity(app); else printf("null"); end(&e);
    if(!app) continue;
    t=g_get_monotonic_time(); guint app_pid=atspi_accessible_get_process_id(app,&e);
    gboolean match = !e && app_pid == pid; begin("GetProcessId",app,t,e); printf(",\"result\":%u",app_pid); end(&e);
    if(match) { found=TRUE; walk(app,0); } g_object_unref(app);
  }
  printf("{\"kind\":\"summary\",\"application_found\":%s,\"nodes\":%u,\"editable_nodes\":%u,\"focused_editable_nodes\":%u,\"truncated\":%s,\"screen_reader_speech_tested\":false,\"editing_actions_tested\":false}\n",found?"true":"false",nodes,editable_nodes,focused_editable,truncated?"true":"false");
  g_object_unref(desktop); g_hash_table_unref(seen); atspi_exit(); return found && !truncated ? 0 : 5;
}
