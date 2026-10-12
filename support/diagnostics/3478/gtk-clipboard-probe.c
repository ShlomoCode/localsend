/* Supplementary observer: reads CLIPBOARD only after focused physical Ctrl+V. */
#include <gtk/gtk.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  const char *name;
  guint timer;
  gboolean pending;
  const char *status;
  gint count;
} Request;

static GtkWidget *window;
static GtkClipboard *clipboard;
static Request requests[] = {
  {"targets", 0, FALSE, "not_requested", -1},
  {"text", 0, FALSE, "not_requested", -1},
  {"uris", 0, FALSE, "not_requested", -1}
};
static guint ctrl_v_seen;
static gboolean started;
static gboolean finished;
static guint lifetime_timer;
static gint exit_status;

static void json_string(const char *s) {
  if (!s) { fputs("null", stdout); return; }
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
    if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
    else if (*p < 0x20) printf("\\u%04x", (unsigned)*p);
    else putchar(*p);
  }
  putchar('"');
}

static void record(const char *event) {
  GdkDisplay *display = gdk_display_get_default();
  printf("{\"mono_us\":%" G_GINT64_FORMAT ",\"pid\":%ld,\"event\":",
         g_get_monotonic_time(), (long)getpid());
  json_string(event);
  fputs(",\"backend\":", stdout);
  json_string(display ? G_OBJECT_TYPE_NAME(display) : NULL);
  printf(",\"mapped\":%s,\"active\":%s,\"toplevel_focus\":%s",
         window && gtk_widget_get_mapped(window) ? "true" : "false",
         window && gtk_window_is_active(GTK_WINDOW(window)) ? "true" : "false",
         window && gtk_window_has_toplevel_focus(GTK_WINDOW(window)) ? "true" : "false");
}

static void end_record(void) { puts("}"); fflush(stdout); }

static void finish(const char *reason) {
  if (finished) return;
  finished = TRUE;
  record("summary");
  fputs(",\"reason\":", stdout); json_string(reason);
  printf(",\"ctrl_v_seen\":%u,\"accepted_ctrl_v\":%s", ctrl_v_seen, started ? "true" : "false");
  for (guint i = 0; i < G_N_ELEMENTS(requests); ++i) {
    printf(",\"%s_status\":", requests[i].name); json_string(requests[i].status);
    printf(",\"%s_count\":%d", requests[i].name, requests[i].count);
    if (requests[i].timer) { g_source_remove(requests[i].timer); requests[i].timer = 0; }
  }
  end_record();
  if (lifetime_timer) { g_source_remove(lifetime_timer); lifetime_timer = 0; }
  gtk_main_quit();
}

static void start_request(guint index);

static void advance(Request *r) {
  guint next = (guint)(r - requests) + 1;
  if (next < G_N_ELEMENTS(requests)) start_request(next);
  else finish("requests_finished");
}

/* GTK has no cancel API here. Static contexts remain valid for late callbacks. */
static gboolean complete_request(Request *r, gint count, gboolean is_null) {
  gboolean timely = r->pending;
  if (timely) {
    r->pending = FALSE;
    r->count = count;
    r->status = is_null ? "callback_null" : "callback_value";
    if (r->timer) { g_source_remove(r->timer); r->timer = 0; }
  }
  record("callback");
  fputs(",\"request\":", stdout); json_string(r->name);
  printf(",\"late\":%s,\"null\":%s,\"count\":%d",
         timely ? "false" : "true", is_null ? "true" : "false", count);
  return timely;
}

static void targets_received(GtkClipboard *cb, GdkAtom *atoms, gint n_atoms, gpointer data) {
  (void)cb;
  Request *r = data;
  gboolean timely = complete_request(r, n_atoms, atoms == NULL);
  fputs(",\"values\":", stdout);
  if (!atoms) fputs("null", stdout);
  else {
    putchar('[');
    for (gint i = 0; i < n_atoms; ++i) {
      if (i) putchar(',');
      gchar *name = gdk_atom_name(atoms[i]);
      json_string(name); g_free(name);
    }
    putchar(']');
  }
  end_record();
  if (timely) advance(r);
}

static void text_received(GtkClipboard *cb, const gchar *text, gpointer data) {
  (void)cb;
  Request *r = data;
  gboolean timely = complete_request(r, text ? (gint)strlen(text) : -1, text == NULL);
  fputs(",\"value\":", stdout); json_string(text);
  end_record();
  if (timely) advance(r);
}

static void uris_received(GtkClipboard *cb, gchar **uris, gpointer data) {
  (void)cb;
  Request *r = data;
  gint count = 0;
  if (uris) while (uris[count]) ++count;
  gboolean timely = complete_request(r, uris ? count : -1, uris == NULL);
  fputs(",\"values\":", stdout);
  if (!uris) fputs("null", stdout);
  else {
    putchar('[');
    for (gint i = 0; i < count; ++i) { if (i) putchar(','); json_string(uris[i]); }
    putchar(']');
  }
  end_record();
  if (timely) advance(r);
}

static gboolean request_timeout(gpointer data) {
  Request *r = data;
  r->timer = 0;
  r->pending = FALSE;
  r->status = "timeout";
  exit_status = 2;
  record("timeout");
  fputs(",\"request\":", stdout); json_string(r->name);
  fputs(",\"limit_ms\":5000", stdout); end_record();
  advance(r);
  return G_SOURCE_REMOVE;
}

static void start_request(guint index) {
  Request *r = &requests[index];
  r->pending = TRUE;
  r->status = "pending";
  record("request");
  fputs(",\"request\":", stdout); json_string(r->name);
  fputs(",\"limit_ms\":5000", stdout); end_record();
  r->timer = g_timeout_add_full(G_PRIORITY_HIGH, 5000, request_timeout, r, NULL);
  if (index == 0) gtk_clipboard_request_targets(clipboard, targets_received, r);
  else if (index == 1) gtk_clipboard_request_text(clipboard, text_received, r);
  else gtk_clipboard_request_uris(clipboard, uris_received, r);
}

static gboolean key_pressed(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget; (void)data;
  gboolean ctrl_v = (event->state & GDK_CONTROL_MASK) &&
                      (event->keyval == GDK_KEY_v || event->keyval == GDK_KEY_V);
  if (ctrl_v) ++ctrl_v_seen;
  record("key_press");
  printf(",\"keyval\":%u,\"hardware_keycode\":%u,\"modifiers\":%u,\"gdk_time_ms\":%u,\"send_event\":%s,\"ctrl_v\":%s",
         event->keyval, (unsigned)event->hardware_keycode, (unsigned)event->state,
         event->time, event->send_event ? "true" : "false", ctrl_v ? "true" : "false");
  end_record();
  if (!ctrl_v) return FALSE;
  if (started || !gtk_widget_get_mapped(window) ||
      !gtk_window_is_active(GTK_WINDOW(window)) ||
      !gtk_window_has_toplevel_focus(GTK_WINDOW(window))) {
    record("ctrl_v_rejected"); end_record(); return TRUE;
  }
  started = TRUE;
  gtk_label_set_text(GTK_LABEL(data), "Reading targets, text, then URIs. See the retained JSON log.");
  start_request(0);
  return TRUE;
}

static gboolean focus_changed(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)widget; (void)data;
  record(event->in ? "focus_in" : "focus_out"); end_record();
  return FALSE;
}

static void mapped(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  record("mapped"); end_record();
}

static gboolean closed(GtkWidget *widget, GdkEvent *event, gpointer data) {
  (void)widget; (void)event; (void)data;
  exit_status = 3; finish("window_closed"); return TRUE;
}

static gboolean lifetime_timeout(gpointer data) {
  (void)data;
  lifetime_timer = 0;
  exit_status = 3;
  finish(!ctrl_v_seen ? "no_ctrl_v" : !started ? "no_accepted_ctrl_v" : "lifetime_timeout");
  return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  if (!gtk_init_check(&argc, &argv)) {
    record("init_failed"); end_record(); return 4;
  }
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), "LocalSend 3478 GTK clipboard observer");
  gtk_window_set_default_size(GTK_WINDOW(window), 620, 160);
  GtkWidget *label = gtk_label_new("Supplementary read-only GTK observer\n"
      "Re-copy the same file in Nautilus. Physically focus this window, then press Ctrl+V.\n"
      "No read starts until this mapped window has keyboard focus. Exits within 120 seconds.");
  gtk_container_add(GTK_CONTAINER(window), label);
  clipboard = gtk_clipboard_get_default(gdk_display_get_default());
  g_signal_connect(window, "key-press-event", G_CALLBACK(key_pressed), label);
  g_signal_connect(window, "focus-in-event", G_CALLBACK(focus_changed), NULL);
  g_signal_connect(window, "focus-out-event", G_CALLBACK(focus_changed), NULL);
  g_signal_connect(window, "map", G_CALLBACK(mapped), NULL);
  g_signal_connect(window, "delete-event", G_CALLBACK(closed), NULL);
  record("ready");
  printf(",\"gtk_version\":\"%u.%u.%u\",\"max_duration_s\":120", gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
  end_record();
  lifetime_timer = g_timeout_add_full(G_PRIORITY_HIGH, 120000, lifetime_timeout, NULL, NULL);
  gtk_widget_show_all(window);
  gtk_main();
  return exit_status;
}
