/* Cloud follow-up, using the public at-spi2-core 2.52 interfaces. */
#include <atspi/atspi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static GError *error;
static gint64 started, entered;
static unsigned calls, nodes, fields, focused_fields, titles, cancels, openers;
static gboolean failed;
static AtspiAccessible *field, *cancel_button, *text_button;
static GHashTable *seen;
static const char *nonce = "LocalSend accessibility 2754";

static void quoted(const char *s) {
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
    if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
    else if (*p < 32) printf("\\u%04x", *p);
    else putchar(*p);
  }
  putchar('"');
}
static void identity(AtspiAccessible *a) {
  AtspiObject *o = a ? ATSPI_OBJECT(a) : NULL;
  printf("{\"bus\":"); quoted(o && o->app ? o->app->bus_name : NULL);
  printf(",\"path\":"); quoted(o ? o->path : NULL); putchar('}');
}
static gboolean same(AtspiAccessible *a, AtspiAccessible *b) {
  if (!a || !b) return a == b;
  AtspiObject *x = ATSPI_OBJECT(a), *y = ATSPI_OBJECT(b);
  return g_strcmp0(x->path, y->path) == 0 &&
    g_strcmp0(x->app ? x->app->bus_name : NULL, y->app ? y->app->bus_name : NULL) == 0;
}
static void start(const char *op, AtspiAccessible *a, const char *args) {
  entered = g_get_monotonic_time(); calls++;
  printf("{\"kind\":\"call_enter\",\"call_id\":%u,\"op\":", calls); quoted(op);
  printf(",\"identity\":"); identity(a); printf(",\"arguments\":"); quoted(args);
  printf(",\"since_start_ms\":%.3f}\n", (entered-started)/1000.); fflush(stdout);
}
static void finish(void) {
  printf("{\"kind\":\"call_result\",\"call_id\":%u,\"elapsed_ms\":%.3f,\"error\":",
    calls, (g_get_monotonic_time()-entered)/1000.);
  if (error) {
    printf("{\"domain\":"); quoted(g_quark_to_string(error->domain));
    printf(",\"code\":%d,\"message\":", error->code); quoted(error->message); putchar('}'); failed = TRUE;
  } else printf("null");
}
static void end(void) { puts("}"); fflush(stdout); g_clear_error(&error); }
static void require(gboolean condition, const char *reason) {
  printf("{\"kind\":\"postcondition\",\"pass\":%s,\"reason\":", condition ? "true" : "false");
  quoted(reason); puts("}"); fflush(stdout); if (!condition) failed = TRUE;
}
#define INTEGER(op,a,args,expression) ({ start(op,a,args); gint value = (expression); finish(); printf(",\"result\":%d",value); end(); value; })
#define BOOLEAN(op,a,args,expression) ({ start(op,a,args); gboolean value = (expression); finish(); printf(",\"result\":%s",value?"true":"false"); end(); value; })
#define STRING(op,a,args,expression) ({ start(op,a,args); gchar *value = (expression); finish(); printf(",\"result\":"); quoted(value); end(); value; })
#define OBJECT(op,a,args,expression) ({ start(op,a,args); AtspiAccessible *value = (expression); finish(); printf(",\"result\":"); identity(value); end(); value; })

static void walk(AtspiAccessible *a, AtspiAccessible *expected_parent, gint index, unsigned depth) {
  if (nodes >= 160 || depth > 14) { require(FALSE,"tree traversal exceeded its bound"); return; }
  AtspiObject *o = ATSPI_OBJECT(a);
  gchar *key = g_strdup_printf("%s:%s",o->app ? o->app->bus_name : "",o->path ? o->path : "");
  if (g_hash_table_contains(seen,key)) { require(FALSE,"repeated live tree identity"); g_free(key); return; }
  g_hash_table_add(seen,key); nodes++;
  start("ClearCacheSingle",a,""); atspi_accessible_clear_cache_single(a); finish(); end();
  gchar *name = STRING("GetName",a,"",atspi_accessible_get_name(a,&error));
  gint role = INTEGER("GetRole",a,"",atspi_accessible_get_role(a,&error));
  if (expected_parent) {
    AtspiAccessible *parent = OBJECT("GetParent",a,"",atspi_accessible_get_parent(a,&error));
    require(same(parent,expected_parent),"live parent matches advertised child edge");
    if (parent) g_object_unref(parent);
    gint actual_index = INTEGER("GetIndexInParent",a,"",atspi_accessible_get_index_in_parent(a,&error));
    require(actual_index == index,"live index matches advertised child edge");
  }
  start("GetStateSet",a,""); AtspiStateSet *states = atspi_accessible_get_state_set(a); finish();
  printf(",\"available\":%s",states?"true":"false"); end();
  gboolean visible = states && atspi_state_set_contains(states,ATSPI_STATE_VISIBLE);
  gboolean showing = states && atspi_state_set_contains(states,ATSPI_STATE_SHOWING);
  gboolean defunct = states && atspi_state_set_contains(states,ATSPI_STATE_DEFUNCT);
  gboolean focused = states && atspi_state_set_contains(states,ATSPI_STATE_FOCUSED);
  start("EditableTextInterface",a,""); AtspiEditableText *editable = atspi_accessible_get_editable_text_iface(a); finish();
  printf(",\"supported\":%s",editable?"true":"false"); end();
  start("TextInterface",a,""); AtspiText *text = atspi_accessible_get_text_iface(a); finish();
  printf(",\"supported\":%s",text?"true":"false"); end();
  start("ActionInterface",a,""); AtspiAction *action = atspi_accessible_get_action_iface(a); finish();
  printf(",\"supported\":%s",action?"true":"false"); end();
  printf("{\"kind\":\"node\",\"identity\":"); identity(a);
  printf(",\"depth\":%u,\"name\":",depth); quoted(name);
  printf(",\"role\":%d,\"visible\":%s,\"showing\":%s,\"defunct\":%s,\"focused\":%s}\n",
    role,visible?"true":"false",showing?"true":"false",defunct?"true":"false",focused?"true":"false");
  if (visible && showing && !defunct) {
    if (g_strcmp0(name,"Type message") == 0) titles++;
    if (editable && text) { fields++; if (focused) { focused_fields++; g_set_object(&field,a); } }
    if (action && role == ATSPI_ROLE_PUSH_BUTTON && g_strcmp0(name,"Cancel") == 0) { cancels++; g_set_object(&cancel_button,a); }
    if (action && role == ATSPI_ROLE_PUSH_BUTTON && g_strcmp0(name,"Text") == 0) { openers++; g_set_object(&text_button,a); }
  }
  if (editable) g_object_unref(editable);
  if (text) g_object_unref(text);
  if (action) g_object_unref(action);
  if (states) g_object_unref(states);
  g_free(name);
  gint count = INTEGER("GetChildCount",a,"",atspi_accessible_get_child_count(a,&error));
  require(count >= 0,"child count is valid");
  for (gint i=0; i<count && nodes<160; i++) {
    gchar args[32]; snprintf(args,sizeof args,"index=%d",i);
    AtspiAccessible *child = OBJECT("GetChildAtIndex",a,args,atspi_accessible_get_child_at_index(a,i,&error));
    require(child != NULL,"advertised child resolves");
    if (child) { walk(child,a,i,depth+1); g_object_unref(child); }
  }
  if (count && nodes>=160) require(FALSE,"tree traversal may be truncated");
}
static void snapshot(AtspiAccessible *app) {
  nodes=fields=focused_fields=titles=cancels=openers=0;
  g_clear_object(&field); g_clear_object(&cancel_button); g_clear_object(&text_button);
  g_hash_table_remove_all(seen);
  walk(app,NULL,-1,0);
  printf("{\"kind\":\"tree_summary\",\"nodes\":%u,\"visible_editable_fields\":%u,\"focused_editable_fields\":%u,\"dialog_titles\":%u,\"cancel_buttons\":%u,\"text_buttons\":%u}\n",
    nodes,fields,focused_fields,titles,cancels,openers);
}
/* Flutter dispatches mutations asynchronously; observe the later semantics
 * update through public readback instead of treating the reply as that update. */
static gboolean poll_query(gint64 deadline) {
  gint64 remaining = deadline-g_get_monotonic_time();
  if (failed || remaining <= 0) return FALSE;
  gint timeout_ms=(gint)MIN(1500,(remaining+999)/1000);
  gchar args[80]; snprintf(args,sizeof args,"timeout=%d,startup=1500,poll_deadline_ms=5000",timeout_ms);
  start("SetPollQueryTimeout",field,args); atspi_set_timeout(timeout_ms,1500); finish(); end();
  return TRUE;
}
static void poll_pause(gint64 deadline) {
  for (unsigned i=0;i<32 && g_main_context_iteration(NULL,FALSE);i++);
  gint64 remaining=deadline-g_get_monotonic_time();
  if (remaining>0) g_usleep((gulong)MIN(100000,remaining));
}
static gboolean poll_result(gboolean match, const char *reason) {
  start("RestoreQueryTimeout",field,"timeout=1500,startup=1500");
  atspi_set_timeout(1500,1500); finish(); end();
  require(match && !failed,reason);
  return match && !failed;
}
static gboolean readback(AtspiText *text, const char *expected) {
  gint64 deadline=g_get_monotonic_time()+5*G_TIME_SPAN_SECOND;
  gboolean match=FALSE;
  while (poll_query(deadline)) {
    gchar *actual=STRING("GetText",field,"start=0,end=-1",atspi_text_get_text(text,0,-1,&error));
    gboolean text_matches=actual && strcmp(actual,expected)==0;
    g_free(actual);
    if (!poll_query(deadline)) break;
    gint count=INTEGER("GetCharacterCount",field,"",atspi_text_get_character_count(text,&error));
    match=!failed && text_matches && count==g_utf8_strlen(expected,-1) && g_get_monotonic_time()<=deadline;
    if (match || failed) break;
    poll_pause(deadline);
  }
  return poll_result(match,"text and character count converge to expected content within five seconds");
}
static gboolean caret_readback(AtspiText *text, gint expected) {
  gint64 deadline=g_get_monotonic_time()+5*G_TIME_SPAN_SECOND;
  gboolean match=FALSE;
  while (poll_query(deadline)) {
    gint actual=INTEGER("GetCaretOffset",field,"",atspi_text_get_caret_offset(text,&error));
    match=!failed && actual==expected && g_get_monotonic_time()<=deadline;
    if (match || failed) break;
    poll_pause(deadline);
  }
  return poll_result(match,"caret converges to expected offset within five seconds");
}
static gboolean selection_readback(AtspiText *text) {
  gint64 deadline=g_get_monotonic_time()+5*G_TIME_SPAN_SECOND;
  gboolean match=FALSE;
  while (poll_query(deadline)) {
    gint count=INTEGER("GetNSelections",field,"",atspi_text_get_n_selections(text,&error));
    if (failed) break;
    if (count==1 && poll_query(deadline)) {
      start("GetSelection",field,"selection=0"); AtspiRange *range=atspi_text_get_selection(text,0,&error); finish();
      if (range) printf(",\"result\":{\"start\":%d,\"end\":%d}",range->start_offset,range->end_offset);
      else printf(",\"result\":null"); end();
      match=!failed && range && range->start_offset==0 && range->end_offset==9 && g_get_monotonic_time()<=deadline;
      if (range) g_boxed_free(ATSPI_TYPE_RANGE,range);
    }
    if (match || failed) break;
    poll_pause(deadline);
  }
  return poll_result(match,"one selection converges to expected range within five seconds");
}
static void edit(gboolean prepare_speech) {
  require(fields==1 && focused_fields==1 && field,"one visible focused editable target");
  if (failed || !field) return;
  AtspiEditableText *editable = atspi_accessible_get_editable_text_iface(field);
  AtspiText *text = atspi_accessible_get_text_iface(field);
  gchar *original = STRING("GetText",field,"start=0,end=-1",atspi_text_get_text(text,0,-1,&error));
  if (!original || failed) goto out;
  require(BOOLEAN("SetTextContents",field,nonce,atspi_editable_text_set_text_contents(editable,nonce,&error)),"set text returned success");
  if (!readback(text,nonce)) goto out;
  if (!prepare_speech) {
    gint length = (gint)strlen(nonce);
    gchar args[80]; snprintf(args,sizeof args,"position=%d,text= verified,length=9 bytes",length);
    require(BOOLEAN("InsertText",field,args,atspi_editable_text_insert_text(editable,length," verified",9,&error)),"insert text returned success");
    gchar *combined = g_strconcat(nonce," verified",NULL);
    gboolean inserted=readback(text,combined); g_free(combined);
    if (!inserted) goto out;
    snprintf(args,sizeof args,"start=%d,end=%d",length,length+9);
    require(BOOLEAN("DeleteText",field,args,atspi_editable_text_delete_text(editable,length,length+9,&error)),"delete text returned success");
    if (!readback(text,nonce)) goto out;
    require(BOOLEAN("SetCaretOffset",field,"offset=5",atspi_text_set_caret_offset(text,5,&error)),"set caret returned success");
    if (!caret_readback(text,5)) goto out;
    gint selections = INTEGER("GetNSelections",field,"",atspi_text_get_n_selections(text,&error));
    require(selections==0 || selections==1,"selection count is supported");
    if (failed) goto out;
    if (selections==1) require(BOOLEAN("SetSelection",field,"selection=0,start=0,end=9",atspi_text_set_selection(text,0,0,9,&error)),"set selection returned success");
    if (selections==0) require(BOOLEAN("AddSelection",field,"start=0,end=9",atspi_text_add_selection(text,0,9,&error)),"add selection returned success");
    if (!selection_readback(text)) goto out;
    require(BOOLEAN("SetTextContentsRestore",field,original,atspi_editable_text_set_text_contents(editable,original,&error)),"restore text returned success");
    readback(text,original);
  }
out:
  g_free(original); g_object_unref(editable); g_object_unref(text);
}
static void invoke(AtspiAccessible *target) {
  if (!target || failed) return;
  AtspiAction *action = atspi_accessible_get_action_iface(target);
  gint count = INTEGER("GetNActions",target,"",atspi_action_get_n_actions(action,&error));
  gint selected=-1, matches=0;
  for (gint i=0;i<count && i<32;i++) {
    gchar args[32]; snprintf(args,sizeof args,"index=%d",i);
    gchar *name = STRING("GetActionName",target,args,atspi_action_get_action_name(action,i,&error));
    gchar *description = STRING("GetActionDescription",target,args,atspi_action_get_action_description(action,i,&error));
    /* Flutter's pinned action_mapping advertises the semantic tap as "Tap". */
    if (name && (!g_ascii_strcasecmp(name,"Tap") || !g_ascii_strcasecmp(name,"click") || !g_ascii_strcasecmp(name,"press") || !g_ascii_strcasecmp(name,"activate"))) { selected=i; matches++; }
    g_free(name); g_free(description);
  }
  require(count<=32 && matches==1,"exactly one observed activation action");
  if (!failed) {
    gchar args[32]; snprintf(args,sizeof args,"index=%d",selected);
    require(BOOLEAN("DoAction",target,args,atspi_action_do_action(action,selected,&error)),"accessible action returned success");
  }
  g_object_unref(action);
}
static void event_callback(AtspiEvent *event, void *unused) {
  (void)unused;
  printf("{\"kind\":\"event\",\"type\":"); quoted(event->type);
  printf(",\"source\":"); identity(event->source);
  printf(",\"detail1\":%d,\"detail2\":%d,\"since_start_ms\":%.3f,\"string_data\":",
    event->detail1,event->detail2,(g_get_monotonic_time()-started)/1000.);
  quoted(G_VALUE_HOLDS_STRING(&event->any_data) ? g_value_get_string(&event->any_data) : NULL);
  printf(",\"payload_type\":"); quoted(G_VALUE_TYPE_NAME(&event->any_data));
  printf(",\"child_identity\":");
  if (G_VALUE_HOLDS(&event->any_data,ATSPI_TYPE_ACCESSIBLE)) identity(g_value_get_object(&event->any_data));
  else printf("null");
  puts("}"); fflush(stdout);
  g_boxed_free(atspi_event_get_type(),event);
}
int main(int argc, char **argv) {
  if (argc!=4) { fprintf(stderr,"usage: interaction-client PID MODE LABEL\n"); return 2; }
  if (!getenv("PROBE_CLOUD_INTERACTIONS") || strcmp(getenv("PROBE_CLOUD_INTERACTIONS"),"1") ||
      strcmp(g_get_user_name(),"mint") || access("/home/mint/evidence/bootstrap-complete",R_OK)) return 8;
  char *end_pid; unsigned long pid = strtoul(argv[1],&end_pid,10); if (!pid || *end_pid) return 2;
  const char *mode=argv[2];
  if (strcmp(mode,"snapshot") && strcmp(mode,"edit") && strcmp(mode,"speech-text") && strcmp(mode,"cancel") &&
      strcmp(mode,"open") && strcmp(mode,"closed") && strcmp(mode,"absent") && strcmp(mode,"events")) return 2;
  setvbuf(stdout,NULL,_IOLBF,0); started=g_get_monotonic_time();
  printf("{\"kind\":\"session\",\"pid\":%lu,\"mode\":",pid); quoted(mode);
  printf(",\"label\":"); quoted(argv[3]); puts(",\"speech_status\":\"untested\"}");
  gint major,minor,micro;
  start("GetVersion",NULL,""); atspi_get_version(&major,&minor,&micro); finish();
  printf(",\"result\":\"%d.%d.%d\"",major,minor,micro); end();
  require(major==2 && minor==52,"libatspi version is 2.52.x"); if (failed) return 3;
  start("SetTimeout",NULL,"timeout=1500,startup=1500"); atspi_set_timeout(1500,1500); finish(); end();
  if (INTEGER("Init",NULL,"",atspi_init())) return 4;
  seen=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,NULL);
  AtspiAccessible *desktop=OBJECT("GetDesktop",NULL,"index=0",atspi_get_desktop(0)), *app=NULL;
  if (!desktop) { require(FALSE,"AT-SPI desktop exists"); goto done; }
  gint count=INTEGER("DesktopChildCount",desktop,"",atspi_accessible_get_child_count(desktop,&error));
  require(count>=0 && count<=80,"desktop enumeration is bounded");
  for (gint i=0;i<count && i<80;i++) {
    gchar args[32]; snprintf(args,sizeof args,"index=%d",i);
    AtspiAccessible *candidate=OBJECT("DesktopChildAtIndex",desktop,args,atspi_accessible_get_child_at_index(desktop,i,&error));
    if (!candidate) continue;
    start("GetProcessId",candidate,""); guint actual=atspi_accessible_get_process_id(candidate,&error);
    gboolean match=!error && actual==pid; finish(); printf(",\"result\":%u",actual); end();
    if (match) { require(app==NULL,"application PID resolves uniquely"); g_set_object(&app,candidate); }
    g_object_unref(candidate);
  }
  if (!strcmp(mode,"absent")) { require(app==NULL,"old application PID is absent from desktop tree"); goto done; }
  require(app!=NULL,"target application is present"); if (!app) goto done;
  start("SetCacheMaskNone",app,""); atspi_accessible_set_cache_mask(app,ATSPI_CACHE_NONE); finish(); end();
  if (!strcmp(mode,"events")) {
    AtspiEventListener *listener=atspi_event_listener_new(event_callback,NULL,NULL);
    const char *types[]={"object:state-changed","object:text-changed","object:text-caret-moved","object:children-changed","window"};
    for (unsigned i=0;i<G_N_ELEMENTS(types);i++) {
      if (!strcmp(types[i],"object:children-changed")) {
        /* Desktop removal belongs to the registry, not the exiting app. */
        require(BOOLEAN("RegisterEventGlobal",app,types[i],atspi_event_listener_register(listener,types[i],&error)),"desktop lifecycle subscription succeeds");
      } else require(BOOLEAN("RegisterEvent",app,types[i],atspi_event_listener_register_with_app(listener,types[i],NULL,app,&error)),"event subscription succeeds");
    }
    if (!failed) puts("{\"kind\":\"events_ready\"}");
    gint64 deadline=g_get_monotonic_time()+1200*G_TIME_SPAN_SECOND;
    while (!failed && g_get_monotonic_time()<deadline) {
      for (unsigned i=0;i<32 && g_main_context_iteration(NULL,FALSE);i++);
      g_usleep(20000);
    }
    for (unsigned i=0;i<G_N_ELEMENTS(types);i++) BOOLEAN("DeregisterEvent",app,types[i],atspi_event_listener_deregister(listener,types[i],&error));
    g_object_unref(listener);
  } else {
    snapshot(app);
    if (!strcmp(mode,"edit") || !strcmp(mode,"speech-text")) edit(!strcmp(mode,"speech-text"));
    if (!strcmp(mode,"cancel")) { require(titles>=1 && fields==1 && cancels==1,"one open dialog and Cancel target"); invoke(cancel_button); }
    if (!strcmp(mode,"open")) { require(titles==0 && fields==0 && openers==1,"closed dialog and one Text target"); invoke(text_button); }
    if (!strcmp(mode,"closed")) require(titles==0 && fields==0 && openers==1,"modal absent and Text opener present in fresh tree");
    if (!strcmp(mode,"snapshot")) require(titles>=1 && fields==1 && focused_fields==1,"reopened dialog has one focused editable field");
  }
done:
  printf("{\"kind\":\"result\",\"status\":\"%s\",\"speech_status\":\"untested\"}\n",failed?"fail":"pass");
  g_clear_object(&field); g_clear_object(&cancel_button); g_clear_object(&text_button);
  g_clear_object(&app); g_clear_object(&desktop); g_hash_table_unref(seen);
  INTEGER("Exit",NULL,"",atspi_exit());
  return failed?5:0;
}
