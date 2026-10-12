/* Source-only diagnostic. Compile in cloud with gio-2.0 and gio-unix-2.0.
 * Usage: dbus-owner READY_FILE LIFETIME_SECONDS (1..900)
 * Redirect stdout to a new segment TSV file; READY_FILE must not exist.
 */
#define _GNU_SOURCE
#include <gio/gio.h>
#include <glib-unix.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define BUS "org.freedesktop.DBus"
#define OBJ "/org/freedesktop/DBus"
#define OWNER_MATCH "type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'"
#define MAX_NAMES 4096u
#define MAX_ROWS 12300u
#define MAX_PENDING 64u
#define MAX_EVENTS 32768u
#define QUERY_MS 2000
typedef struct {
  char *name;
  guint32 pid, uid;
  guint64 ticks;
  gint64 began;
  gboolean own, recheck;
} Capture;
static GMainLoop *loop;
static GDBusConnection *observation, *control;
static GCancellable *cancel;
static GHashTable *seen;
static const char *ready_path;
static guint rows, pending, own_ok, subscription, events;
static gboolean armed, ready, stopping;
static int result = 1;
static gboolean row(const char *fmt, ...) {
  if (rows >= MAX_ROWS) return FALSE;
  va_list ap;
  va_start(ap, fmt);
  int n = vfprintf(stdout, fmt, ap);
  va_end(ap);
  rows++;
  return n >= 0 && fflush(stdout) == 0;
}
static void stop(const char *status, int code) {
  if (stopping) return;
  stopping = TRUE;
  result = code;
  if (!row("TERMINAL\t%s\t%" G_GINT64_FORMAT "\n", status, g_get_monotonic_time())) result = 1;
  g_cancellable_cancel(cancel);
  g_main_loop_quit(loop);
}
static gboolean lifetime(gpointer unused) {
  (void)unused; stop("lifetime-expired", 1); return G_SOURCE_REMOVE;
}
static gboolean terminate(gpointer unused) {
  (void)unused;
  stop(ready && pending == 0 ? "stopped" : "stopped-incomplete", ready && pending == 0 ? 0 : 1);
  return G_SOURCE_REMOVE;
}
static void closed(GDBusConnection *connection, gboolean vanished, GError *error, gpointer unused) {
  (void)connection; (void)vanished; (void)error; (void)unused;
  stop("connection-closed", 1);
}
/* Parse field 22 after the last ')' of comm; bound every proc read. */
static gboolean startticks(guint32 pid, guint32 uid, guint64 *ticks) {
  char path[64], buf[4096];
  g_snprintf(path, sizeof path, "/proc/%u/stat", pid);
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return FALSE;
  struct stat st;
  ssize_t n = read(fd, buf, sizeof buf - 1);
  gboolean valid = fstat(fd, &st) == 0 && st.st_uid == uid;
  close(fd);
  if (!valid || n <= 0 || n >= (ssize_t)sizeof buf - 1) return FALSE;
  buf[n] = 0;
  char *p = strrchr(buf, ')');
  if (!p || p[1] != ' ') return FALSE;
  p += 2;
  for (unsigned field = 3; field < 22; field++) {
    p = strchr(p, ' ');
    if (!p) return FALSE;
    while (*p == ' ') p++;
  }
  if (!g_ascii_isdigit(*p)) return FALSE;
  errno = 0;
  char *end;
  guint64 value = g_ascii_strtoull(p, &end, 10);
  if (errno || !value || (*end != ' ' && *end != '\n')) return FALSE;
  *ticks = value;
  return TRUE;
}
static void maybe_ready(void) {
  if (!armed || own_ok != 2 || ready || stopping) return;
  guint64 ticks;
  if (!startticks((guint32)getpid(), (guint32)getuid(), &ticks)) { stop("own-startticks-error", 1); return; }
  char text[1024];
  int n = g_snprintf(text, sizeof text, "READY\t%u\t%" G_GUINT64_FORMAT "\t%s\t%s\t%" G_GINT64_FORMAT "\n",
      (guint)getpid(), ticks, g_dbus_connection_get_unique_name(observation),
      g_dbus_connection_get_unique_name(control), g_get_monotonic_time());
  if (n < 0 || n >= (int)sizeof text) { stop("ready-record-too-long", 1); return; }
  int fd = open(ready_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) { stop("ready-file-error", 1); return; }
  gboolean ok = write(fd, text, (size_t)n) == n && fsync(fd) == 0;
  if (close(fd) != 0) ok = FALSE;
  if (!ok) { stop("ready-file-error", 1); return; }
  ready = TRUE;
}
static void free_capture(Capture *c) { g_free(c->name); g_free(c); pending--; }
static void finish(Capture *c, const char *status) {
  if (!row("CREDENTIAL\t%s\t%s\t%u\t%u\t%" G_GUINT64_FORMAT "\t%" G_GINT64_FORMAT "\t%" G_GINT64_FORMAT "\n",
      c->name, status, c->pid, c->uid, c->ticks, c->began, g_get_monotonic_time())) stop("record-write-or-limit", 1);
  gboolean own = c->own;
  free_capture(c);
  if (own && !stopping) {
    if (strcmp(status, "collector-own") != 0) stop("own-control-failed", 1);
    else { own_ok++; maybe_ready(); }
  }
}
static void credentials_done(GObject *source, GAsyncResult *res, gpointer data);
static void query(Capture *c) {
  g_dbus_connection_call(control, BUS, OBJ, BUS, "GetConnectionCredentials",
      g_variant_new("(s)", c->name), G_VARIANT_TYPE("(a{sv})"),
      G_DBUS_CALL_FLAGS_NO_AUTO_START, QUERY_MS, cancel, credentials_done, c);
}
static void credentials_done(GObject *source, GAsyncResult *res, gpointer data) {
  Capture *c = data;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);
  if (stopping) { g_clear_pointer(&reply, g_variant_unref); g_clear_error(&error); free_capture(c); return; }
  if (!reply) {
    char *remote = error ? g_dbus_error_get_remote_error(error) : NULL;
    gboolean gone = remote && strcmp(remote, "org.freedesktop.DBus.Error.NameHasNoOwner") == 0;
    gboolean timeout = error && (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT) ||
        g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_NO_REPLY) ||
        g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_TIMEOUT));
    finish(c, gone ? "vanished" : timeout ? "query-timeout" : "query-error");
    g_free(remote); g_clear_error(&error);
    if (!gone && !timeout) stop("control-query-error", 1);
    return;
  }
  GVariant *dict = g_variant_get_child_value(reply, 0);
  guint32 pid = 0, uid = 0;
  gboolean valid = g_variant_lookup(dict, "ProcessID", "u", &pid) && pid > 0 &&
      g_variant_lookup(dict, "UnixUserID", "u", &uid);
  g_variant_unref(dict); g_variant_unref(reply);
  if (!valid) { finish(c, "missing-credentials"); return; }
  guint64 ticks = 0;
  if (!startticks(pid, uid, &ticks)) { finish(c, "proc-unavailable"); return; }
  if (c->recheck) {
    if (pid != c->pid || uid != c->uid || ticks != c->ticks) { finish(c, "identity-changed"); return; }
    if (c->own && (pid != (guint32)getpid() || uid != (guint32)getuid())) { finish(c, "own-mismatch"); return; }
    finish(c, c->own ? "collector-own" : "captured");
    return;
  }
  c->pid = pid; c->uid = uid; c->ticks = ticks; c->recheck = TRUE;
  query(c);
}
static void capture(const char *name, gboolean own) {
  if (stopping) return;
  if (g_hash_table_contains(seen, name)) { stop("duplicate-unique-acquisition", 1); return; }
  if (g_hash_table_size(seen) >= MAX_NAMES || pending >= MAX_PENDING) { stop("name-or-pending-limit", 1); return; }
  g_hash_table_add(seen, g_strdup(name));
  Capture *c = g_new0(Capture, 1);
  c->name = g_strdup(name); c->own = own; c->began = g_get_monotonic_time();
  pending++; query(c);
}
static void owner_changed(GDBusConnection *connection, const char *sender, const char *path,
    const char *interface, const char *member, GVariant *parameters, gpointer unused) {
  (void)connection; (void)sender; (void)path; (void)interface; (void)member; (void)unused;
  if (stopping) return;
  if (++events > MAX_EVENTS) { stop("event-limit", 1); return; }
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(sss)"))) { stop("signal-type-error", 1); return; }
  const char *name, *old, *new_owner;
  g_variant_get(parameters, "(&s&s&s)", &name, &old, &new_owner);
  if (!g_dbus_is_unique_name(name)) return;
  if (strcmp(name, g_dbus_connection_get_unique_name(observation)) == 0 ||
      strcmp(name, g_dbus_connection_get_unique_name(control)) == 0) return;
  if (!*old && strcmp(name, new_owner) == 0) capture(name, FALSE);
  else if (!*new_owner && strcmp(name, old) == 0) {
    if (!row("RELEASE\t%s\t%" G_GINT64_FORMAT "\n", name, g_get_monotonic_time())) stop("record-write-or-limit", 1);
  } else stop("unique-transition-error", 1);
}
static void match_done(GObject *source, GAsyncResult *res, gpointer unused) {
  (void)unused;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);
  if (!reply) { g_clear_error(&error); stop("add-match-error", 1); return; }
  g_variant_unref(reply);
  if (stopping) return;
  armed = TRUE;
  capture(g_dbus_connection_get_unique_name(observation), TRUE);
  capture(g_dbus_connection_get_unique_name(control), TRUE);
}
static void connect_done(GObject *source, GAsyncResult *res, gpointer data) {
  (void)source;
  GError *error = NULL;
  GDBusConnection *connection = g_dbus_connection_new_for_address_finish(res, &error);
  if (!connection) { g_clear_error(&error); stop("connect-error", 1); return; }
  g_dbus_connection_set_exit_on_close(connection, FALSE);
  g_signal_connect(connection, "closed", G_CALLBACK(closed), NULL);
  if (stopping) { g_object_unref(connection); return; }
  if (!data) {
    observation = connection;
    g_dbus_connection_new_for_address(g_getenv("DBUS_SESSION_BUS_ADDRESS"),
        G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
        NULL, cancel, connect_done, GINT_TO_POINTER(1));
  } else {
    control = connection;
    subscription = g_dbus_connection_signal_subscribe(observation, BUS, BUS, "NameOwnerChanged", OBJ, NULL,
        G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, owner_changed, NULL, NULL);
    g_dbus_connection_call(observation, BUS, OBJ, BUS, "AddMatch", g_variant_new("(s)", OWNER_MATCH),
        G_VARIANT_TYPE("()"), G_DBUS_CALL_FLAGS_NO_AUTO_START, QUERY_MS, cancel, match_done, NULL);
  }
}
int main(int argc, char **argv) {
  if (argc != 3 || !g_getenv("DBUS_SESSION_BUS_ADDRESS")) return 2;
  char *end;
  errno = 0;
  unsigned long seconds = strtoul(argv[2], &end, 10);
  if (errno || !*argv[2] || *end || seconds < 1 || seconds > 900) return 2;
  struct stat output;
  if (fstat(STDOUT_FILENO, &output) != 0 || !S_ISREG(output.st_mode)) return 2;
  ready_path = argv[1];
  loop = g_main_loop_new(NULL, FALSE);
  cancel = g_cancellable_new();
  seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  g_timeout_add_seconds((guint)seconds, lifetime, NULL);
  g_unix_signal_add(SIGTERM, terminate, NULL);
  g_unix_signal_add(SIGINT, terminate, NULL);
  g_dbus_connection_new_for_address(g_getenv("DBUS_SESSION_BUS_ADDRESS"),
      G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
      NULL, cancel, connect_done, NULL);
  g_main_loop_run(loop);
  if (subscription) g_dbus_connection_signal_unsubscribe(observation, subscription);
  /* Process exit closes both owned connections and removes their match rule.
   * No peer process or connection is modified. Pending callbacks cannot append
   * after TERMINAL because stopping is checked before every completion. */
  g_clear_object(&observation);
  g_clear_object(&control);
  if (fsync(STDOUT_FILENO) != 0 || fclose(stdout) != 0) result = 1;
  return result;
}
