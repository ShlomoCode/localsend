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
static unsigned call_id;
static AtspiAccessible *chain[15];
static AtspiComponent *chain_components[15];
static gboolean chain_eligible[15];
static unsigned cycles, revisits;
static gboolean tree_gap;

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
static gint64 enter(const char *op, AtspiAccessible *a) {
  gint64 t = g_get_monotonic_time();
  printf("{\"kind\":\"query_enter\",\"call_id\":%u,\"op\":",++call_id); string(op);
  printf(",\"identity\":"); identity(a);
  printf(",\"since_start_ms\":%.3f}\n",(t-started)/1000.);
  fflush(stdout);
  return t;
}
static void begin(const char *op, AtspiAccessible *a, gint64 t, GError *e) {
  printf("{\"kind\":\"query\",\"call_id\":%u,\"op\":",call_id); string(op);
  printf(",\"identity\":"); identity(a);
  printf(",\"elapsed_ms\":%.3f,\"since_start_ms\":%.3f,\"error\":", (g_get_monotonic_time()-t)/1000., (g_get_monotonic_time()-started)/1000.);
  if (e) { printf("{\"domain\":"); string(g_quark_to_string(e->domain)); printf(",\"code\":%d,\"message\":", e->code); string(e->message); putchar('}'); }
  else printf("null");
}
static void end(GError **e) { puts("}"); fflush(stdout); g_clear_error(e); }
static gboolean state_contains(AtspiAccessible *a, AtspiStateSet *state, AtspiStateType value, const char *op) {
  gint64 t = enter(op,a);
  gboolean result = atspi_state_set_contains(state,value);
  begin(op,a,t,NULL); printf(",\"result\":%s",result ? "true" : "false"); puts("}"); fflush(stdout);
  return result;
}
static void rect(const AtspiRect *r) {
  if (!r) { printf("null"); return; }
  printf("{\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d}", r->x,r->y,r->width,r->height);
}
static void geometry(AtspiAccessible *a, AtspiComponent *c, gboolean target, gboolean focused_target, gboolean eligible, unsigned depth) {
  for (int coord = 0; coord < 2; coord++) {
    GError *e = NULL; gint64 t = enter(coord == 0 ? "GetExtentsSCREEN" : "GetExtentsWINDOW",a);
    AtspiRect *r = atspi_component_get_extents(c, coord == 0 ? ATSPI_COORD_TYPE_SCREEN : ATSPI_COORD_TYPE_WINDOW, &e);
    gboolean extent_ok = e == NULL;
    begin("GetExtents", a,t,e); printf(",\"coordinate\":\"%s\",\"result\":",coord == 0 ? "SCREEN" : "WINDOW"); rect(r); end(&e);
    if (target && eligible && extent_ok && r && r->width > 0 && r->height > 0 && r->x != -1 && r->y != -1) {
      int x = r->x + r->width/2, y = r->y + r->height/2;
      for (int outside = 0; outside < 2; outside++) {
        int px = outside ? r->x - 2 : x, py = outside ? r->y - 2 : y;
        t = enter(outside ? "ContainsOutside" : "ContainsInside",a); gboolean contains = atspi_component_contains(c,px,py,coord,&e);
        begin("Contains",a,t,e); printf(",\"coordinate\":\"%s\",\"point\":[%d,%d],\"probe\":\"%s\",\"result\":%s",coord == 0 ? "SCREEN" : "WINDOW",px,py,outside ? "outside" : "inside",contains ? "true" : "false"); end(&e);
      }
      t = enter(coord == 0 ? "GetAccessibleAtPointSCREEN" : "GetAccessibleAtPointWINDOW",a); AtspiAccessible *hit = atspi_component_get_accessible_at_point(c,x,y,coord,&e);
      begin("GetAccessibleAtPoint",a,t,e); printf(",\"coordinate\":\"%s\",\"point\":[%d,%d],\"result\":",coord == 0 ? "SCREEN" : "WINDOW",x,y); if(hit) identity(hit); else printf("null"); end(&e); if(hit) g_object_unref(hit);
      /* Public contract returns a child, not necessarily the deepest field.
       * Keep its identity and the traversal chain; validation checks routing. */
      if (focused_target) for(unsigned j=0;j<depth;j++) {
        if(!chain_components[j] || !chain_eligible[j]) {
          printf("{\"kind\":\"ancestor_skipped\",\"identity\":"); identity(chain[j]);
          printf(",\"target_identity\":"); identity(a);
          printf(",\"coordinate\":\"%s\",\"reason\":\"no Component or ineligible state\"}\n",coord==0?"SCREEN":"WINDOW");
          continue;
        }
        t=enter("AncestorContains",chain[j]);
        gboolean contains=atspi_component_contains(chain_components[j],x,y,coord,&e);
        begin("AncestorContains",chain[j],t,e); printf(",\"target_identity\":"); identity(a);
        printf(",\"coordinate\":\"%s\",\"point\":[%d,%d],\"result\":%s",coord==0?"SCREEN":"WINDOW",x,y,contains?"true":"false"); end(&e);
        t=enter("AncestorGetAccessibleAtPoint",chain[j]);
        hit=atspi_component_get_accessible_at_point(chain_components[j],x,y,coord,&e);
        begin("AncestorGetAccessibleAtPoint",chain[j],t,e); printf(",\"target_identity\":"); identity(a);
        printf(",\"coordinate\":\"%s\",\"point\":[%d,%d],\"result\":",coord==0?"SCREEN":"WINDOW",x,y);
        if(hit) identity(hit); else printf("null"); end(&e); if(hit) g_object_unref(hit);
      }
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
  if (g_hash_table_contains(seen,key)) {
    gboolean cycle=FALSE;
    for(unsigned j=0;j<depth;j++) {
      AtspiObject *ancestor=ATSPI_OBJECT(chain[j]);
      if(g_strcmp0(o->path,ancestor->path)==0 && o->app==ancestor->app) cycle=TRUE;
    }
    if(cycle) cycles++; else revisits++;
    printf("{\"kind\":\"%s\",\"identity\":",cycle?"cycle":"revisit"); identity(a);
    printf(",\"parent_identity\":"); identity(depth?chain[depth-1]:NULL); puts("}"); fflush(stdout);
    g_free(key); return;
  }
  chain[depth]=a;
  g_hash_table_add(seen,key); nodes++;
  GError *e = NULL; gint64 t = enter("ClearCacheSingle",a);
  atspi_accessible_clear_cache_single(a);
  begin("ClearCacheSingle",a,t,NULL); end(&e);
  t = enter("GetName",a);
  gchar *name = atspi_accessible_get_name(a,&e); begin("GetName",a,t,e); printf(",\"result\":"); string(name); end(&e);
  t = enter("GetRole",a); AtspiRole role = atspi_accessible_get_role(a,&e); begin("GetRole",a,t,e); printf(",\"result\":%d",role); end(&e);
  /* Name/role can dispatch cache hydration. Clear again so this public getter
   * requests fresh GetState even when the application caches states. */
  t = enter("ClearCacheBeforeState",a);
  atspi_accessible_clear_cache_single(a);
  begin("ClearCacheBeforeState",a,t,NULL); printf(",\"cached_properties\":%u",a->cached_properties); end(&e);
  t = enter("GetStateSet",a); AtspiStateSet *state = atspi_accessible_get_state_set(a);
  begin("GetStateSet",a,t,NULL); printf(",\"state_available\":%s,\"cached_properties\":%u",state?"true":"false",a->cached_properties); end(&e);
  gboolean focused = state_contains(a,state,ATSPI_STATE_FOCUSED,"StateContainsFocused");
  gboolean editable = state_contains(a,state,ATSPI_STATE_EDITABLE,"StateContainsEditable");
  gboolean defunct = state_contains(a,state,ATSPI_STATE_DEFUNCT,"StateContainsDefunct");
  gboolean visible = state_contains(a,state,ATSPI_STATE_VISIBLE,"StateContainsVisible");
  gboolean showing = state_contains(a,state,ATSPI_STATE_SHOWING,"StateContainsShowing");
  t = enter("ComponentInterface",a); AtspiComponent *c = atspi_accessible_get_component_iface(a);
  begin("ComponentInterface",a,t,NULL); printf(",\"supported\":%s",c?"true":"false"); end(&e);
  t = enter("EditableTextInterface",a); AtspiEditableText *et = atspi_accessible_get_editable_text_iface(a);
  begin("EditableTextInterface",a,t,NULL); printf(",\"supported\":%s",et?"true":"false"); end(&e);
  t = enter("RoleName",a);
  gchar *role_name = atspi_role_get_name(role);
  begin("RoleName",a,t,NULL); printf(",\"result\":"); string(role_name); end(&e);
  printf("{\"kind\":\"node\",\"identity\":"); identity(a); printf(",\"depth\":%u,\"role\":%d,\"name\":",depth,role); string(name);
  printf(",\"role_name\":"); string(role_name); g_free(role_name);
  printf(",\"component\":%s,\"editable_text\":%s,\"focused\":%s,\"editable_state\":%s,\"defunct\":%s,\"visible\":%s,\"showing\":%s,\"geometry_eligible\":%s,\"ancestry\":[",c?"true":"false",et?"true":"false",focused?"true":"false",editable?"true":"false",defunct?"true":"false",visible?"true":"false",showing?"true":"false",state && !defunct && visible && showing?"true":"false");
  for(unsigned j=0;j<depth;j++) {if(j) putchar(','); identity(chain[j]);}
  puts("]}"); fflush(stdout);
  t = enter("GetInterfaces",a); GArray *interfaces = atspi_accessible_get_interfaces(a);
  begin("GetInterfaces",a,t,NULL); printf(",\"result\":[");
  if (interfaces) for (guint i = 0; i < interfaces->len; i++) {
    if (i) putchar(',');
    gchar *interface_name = g_array_index(interfaces,gchar *,i);
    string(interface_name); g_free(interface_name);
  }
  printf("]"); end(&e); if (interfaces) g_array_free(interfaces,TRUE);
  if (et) { editable_nodes++; if(focused) focused_editable++; }
  chain_components[depth]=c; chain_eligible[depth]=state && !defunct && visible && showing;
  if(c) geometry(a,c,et != NULL || focused,et != NULL && focused,chain_eligible[depth],depth);
  if(et) g_object_unref(et);
  if(state) g_object_unref(state);
  g_free(name);
  t = enter("GetChildCount",a); int count = atspi_accessible_get_child_count(a,&e); begin("GetChildCount",a,t,e); printf(",\"result\":%d",count); end(&e);
  if(count<0) {
    tree_gap=TRUE;
    printf("{\"kind\":\"tree_gap\",\"identity\":"); identity(a); puts(",\"reason\":\"negative child count\"}"); fflush(stdout);
  }
  for(int i=0;i<count && nodes<max_nodes;i++) {
    t = enter("GetChildAtIndex",a); AtspiAccessible *child = atspi_accessible_get_child_at_index(a,i,&e);
    begin("GetChildAtIndex",a,t,e); printf(",\"index\":%d,\"result\":",i); if(child) identity(child); else printf("null"); end(&e);
    if(child) {
      printf("{\"kind\":\"edge\",\"identity\":"); identity(a); printf(",\"index\":%d,\"child_identity\":",i); identity(child); puts("}"); fflush(stdout);
      walk(child,depth+1); g_object_unref(child);
    } else {
      tree_gap=TRUE;
      printf("{\"kind\":\"tree_gap\",\"identity\":"); identity(a);
      printf(",\"index\":%d,\"reason\":\"advertised child returned null\"}\n",i); fflush(stdout);
    }
  }
  if(count > 0 && nodes>=max_nodes) truncated=TRUE;
  if(c) g_object_unref(c);
}
int main(int argc, char **argv) {
  if(argc != 3) { fprintf(stderr,"usage: geometry-client PID LABEL\n"); return 2; }
  char *pid_end = NULL; unsigned long pid = strtoul(argv[1],&pid_end,10);
  if(!pid || *pid_end) return 2;
  const char *cache_policy = getenv("ATSPI_OBSERVER_CACHE_POLICY");
  if (!cache_policy) cache_policy = "NONE";
  AtspiCache cache_mask;
  if (strcmp(cache_policy,"NONE") == 0) cache_mask = ATSPI_CACHE_NONE;
  else if (strcmp(cache_policy,"STATES") == 0) cache_mask = ATSPI_CACHE_STATES;
  else { fprintf(stderr,"ATSPI_OBSERVER_CACHE_POLICY must be NONE or STATES\n"); return 2; }
  setvbuf(stdout,NULL,_IOLBF,0); started = g_get_monotonic_time();
  GError *e = NULL; gint64 t = enter("GetVersion",NULL);
  gint major,minor,micro; atspi_get_version(&major,&minor,&micro);
  begin("GetVersion",NULL,t,NULL); printf(",\"result\":\"%d.%d.%d\"",major,minor,micro); end(&e);
  printf("{\"kind\":\"session\",\"pid\":%lu,\"label\":",pid); string(argv[2]);
  printf(",\"cache_policy\":"); string(cache_policy);
  printf(",\"cache_mask\":%u,\"libatspi_version\":\"%d.%d.%d\",\"timeout_ms\":1500,\"max_nodes\":160,\"max_depth\":14}\n",(unsigned)cache_mask,major,minor,micro);
  if(major != 2 || minor != 52) { puts("{\"kind\":\"failure\",\"reason\":\"requires libatspi 2.52.x\"}"); return 3; }
  t = enter("SetTimeout",NULL); atspi_set_timeout(1500,1500); begin("SetTimeout",NULL,t,NULL); end(&e);
  t = enter("Init",NULL); int init_status = atspi_init(); begin("Init",NULL,t,NULL); printf(",\"result\":%d",init_status); end(&e);
  if(init_status) { puts("{\"kind\":\"failure\",\"reason\":\"atspi_init failed\"}"); return 4; }
  seen = g_hash_table_new_full(g_str_hash,g_str_equal,g_free,NULL);
  t = enter("GetDesktop",NULL); AtspiAccessible *desktop = atspi_get_desktop(0);
  begin("GetDesktop",NULL,t,NULL); printf(",\"result\":"); if(desktop) identity(desktop); else printf("null"); end(&e);
  if (!desktop) {
    puts("{\"kind\":\"failure\",\"reason\":\"no AT-SPI desktop\"}");
    t=enter("Exit",NULL); int exit_status=atspi_exit(); begin("Exit",NULL,t,NULL); printf(",\"result\":%d",exit_status); end(&e);
    return 4;
  }
  t=enter("DesktopChildCount",desktop); int count = atspi_accessible_get_child_count(desktop,&e); begin("DesktopChildCount",desktop,t,e); printf(",\"result\":%d",count); end(&e);
  gboolean found = FALSE;
  for(int i=0;i<count && i<80;i++) {
    t=enter("DesktopChildAtIndex",desktop); AtspiAccessible *app = atspi_accessible_get_child_at_index(desktop,i,&e);
    begin("DesktopChildAtIndex",desktop,t,e); printf(",\"index\":%d,\"result\":",i); if(app) identity(app); else printf("null"); end(&e);
    if(!app) continue;
    t=enter("GetProcessId",app); guint app_pid=atspi_accessible_get_process_id(app,&e);
    gboolean match = !e && app_pid == pid; begin("GetProcessId",app,t,e); printf(",\"result\":%u",app_pid); end(&e);
    if(match) {
      found=TRUE;
      printf("{\"kind\":\"root_public_snapshot\",\"identity\":"); identity(app);
      printf(",\"source\":\"public cached fields, not a live property query\",\"cached_name\":"); string(app->name);
      printf(",\"cached_role\":%d,\"cached_properties\":%u,\"is_application_root\":%s}\n",app->role,app->cached_properties,app->parent.app && app->parent.app->root == app ? "true" : "false"); fflush(stdout);
      /* 2.52 documents this setter for desktop/application root only. */
      const char *cache_op = cache_mask == ATSPI_CACHE_NONE ? "SetCacheMaskNone" : "SetCacheMaskStates";
      t=enter(cache_op,app); atspi_accessible_set_cache_mask(app,cache_mask);
      begin(cache_op,app,t,NULL); printf(",\"cache_policy\":"); string(cache_policy);
      printf(",\"cache_mask\":%u",(unsigned)cache_mask); end(&e);
      walk(app,0);
    }
    g_object_unref(app);
  }
  printf("{\"kind\":\"summary\",\"application_found\":%s,\"nodes\":%u,\"editable_nodes\":%u,\"focused_editable_nodes\":%u,\"cycles\":%u,\"revisits\":%u,\"truncated\":%s,\"screen_reader_speech_tested\":false,\"editing_actions_tested\":false}\n",found?"true":"false",nodes,editable_nodes,focused_editable,cycles,revisits,truncated?"true":"false");
  g_object_unref(desktop); g_hash_table_unref(seen);
  t=enter("Exit",NULL); int exit_status=atspi_exit(); begin("Exit",NULL,t,NULL); printf(",\"result\":%d",exit_status); end(&e);
  return found && !truncated && !cycles && !tree_gap ? 0 : 5;
}
