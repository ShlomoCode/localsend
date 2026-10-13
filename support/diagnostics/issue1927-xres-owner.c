/* Diagnostic only: authoritative local X client owner, without WM PID hints. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/XRes.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int x_error;
static volatile sig_atomic_t running = 1;

static int record_x_error(Display *display, XErrorEvent *event) {
  (void)display;
  x_error = event->error_code;
  fprintf(stderr, "x_error=%d request=%d minor=%d resource=%lu resource_hex=0x%lx serial=%lu\n",
          event->error_code, event->request_code, event->minor_code,
          event->resourceid, event->resourceid, event->serial);
  return 0;
}

static void stop_fixture(int signal_number) {
  (void)signal_number;
  running = 0;
}

static int fixture(Display *display) {
  Window root = DefaultRootWindow(display);
  XSetWindowAttributes attributes = {.override_redirect = True};
  Window window = XCreateWindow(display, root, 1100, 730, 150, 50, 0,
                                CopyFromParent, InputOutput, CopyFromParent,
                                CWOverrideRedirect, &attributes);
  XClassHint hint = {.res_name = "ownership-control",
                     .res_class = "OwnershipControl"};
  XSetClassHint(display, window, &hint);
  XStoreName(display, window, "Autostart ownership control");
  XMapWindow(display, window);
  /* Keep this client's range live while this exact resource no longer exists. */
  Window destroyed = XCreateSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0);
  XDestroyWindow(display, destroyed);
  XSync(display, False);
  if (x_error) return 5;
  Window unmapped = XCreateSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0);
  Window managed = XCreateSimpleWindow(display, root, 1100, 650, 150, 50, 0, 0, 0);
  XSetClassHint(display, managed, &hint);
  XStoreName(display, managed, "Ownership selection control");
  XMapWindow(display, managed);
  XSync(display, False);
  if (x_error) return 5;
  printf("%lu %ld %lu %lu %lu\n", window, (long)getpid(), destroyed, unmapped, managed);
  fflush(stdout);
  signal(SIGTERM, stop_fixture);
  signal(SIGINT, stop_fixture);
  while (running) {
    /* Notice the old server closing after relogin; never kill a stored PID. */
    XSync(display, False);
    sleep(1);
  }
  return 0;
}

static int window_owner(Display *display, Window window, pid_t *owner_out,
                        XWindowAttributes *attributes_out) {
  unsigned long resource = window;
  int event_base, error_base, major = 0, minor = 0;
  if (!XResQueryExtension(display, &event_base, &error_base) ||
      !XResQueryVersion(display, &major, &minor) || major != 1 || minor < 2)
    return 2;
  fprintf(stderr, "window=%lu xres_version=%d.%d\n", resource, major, minor);
  XWindowAttributes before, after;
  if (!XGetWindowAttributes(display, window, &before)) return 3;
  int count = 0;
  XResClient *clients = NULL;
  if (!XResQueryClients(display, &count, &clients)) return 2;
  unsigned long base = 0, mask = 0;
  int matches = 0;
  for (int index = 0; index < count; index++) {
    if ((resource & ~clients[index].resource_mask) == clients[index].resource_base) {
      base = clients[index].resource_base;
      mask = clients[index].resource_mask;
      matches++;
    }
  }
  XFree(clients);
  if (matches != 1) return 4;
  fprintf(stderr, "client_base=%lu resource_mask=%lu matches=%d\n", base, mask, matches);
  XResClientIdSpec spec = {.client = window, .mask = XRES_CLIENT_ID_PID_MASK};
  long ids_count = 0;
  XResClientIdValue *ids = NULL;
  if (XResQueryClientIds(display, 1, &spec, &ids_count, &ids) != Success) return 2;
  pid_t owner = -1;
  int valid = ids_count == 1 && ids &&
              ids[0].spec.mask == XRES_CLIENT_ID_PID_MASK &&
              ids[0].length == (long)sizeof(uint32_t) &&
              (ids[0].spec.client & ~mask) == base;
  if (valid) owner = XResGetClientPid(&ids[0]);
  fprintf(stderr, "reply_count=%ld reply_client=%lu reply_mask=%u reply_length=%ld owner_pid=%ld\n",
          ids_count, ids_count > 0 && ids ? ids[0].spec.client : 0,
          ids_count > 0 && ids ? ids[0].spec.mask : 0,
          ids_count > 0 && ids ? ids[0].length : 0, (long)owner);
  if (ids) XResClientIdsDestroy(ids_count, ids);
  if (!valid || owner <= 0) return 4;
  if (!XGetWindowAttributes(display, window, &after)) return 3;
  XSync(display, False);
  fprintf(stderr, "attributes_before root=%lu class=%d map_state=%d x=%d y=%d width=%d height=%d\n",
          before.root, before.class, before.map_state, before.x, before.y, before.width, before.height);
  fprintf(stderr, "attributes_after root=%lu class=%d map_state=%d x=%d y=%d width=%d height=%d\n",
          after.root, after.class, after.map_state, after.x, after.y, after.width, after.height);
  if (x_error || before.root != after.root || before.class != after.class ||
      before.map_state != after.map_state || before.width != after.width ||
      before.height != after.height) return 5;

  *owner_out = owner;
  *attributes_out = after;
  return 0;
}

static void print_state(Window window, pid_t owner, XWindowAttributes *state) {
  printf("%lu %ld %d %d %d %d %d\n", window, (long)owner, state->map_state,
         state->x, state->y, state->width, state->height);
}

/* Cinnamon publishes managed client IDs through EWMH. Select the exact XRes
 * client range before asking for window attributes; unrelated desktop windows
 * cannot produce a BadWindow while this observer inspects the app. */
static int owned_windows(Display *display, pid_t expected,
                         const Window *control_windows, unsigned long control_count) {
  int event_base, error_base, major = 0, minor = 0;
  if (!XResQueryExtension(display, &event_base, &error_base) ||
      !XResQueryVersion(display, &major, &minor) || major != 1 || minor < 2) return 2;
  Atom actual_type;
  int format;
  unsigned long count = 0, remaining = 0;
  unsigned char *data = NULL;
  const Window *windows;
  if (control_windows) {
    windows = control_windows;
    count = control_count;
    fprintf(stderr, "selection_source=diagnostic_control\n");
  } else {
    Atom property = XInternAtom(display, "_NET_CLIENT_LIST", True);
    if (property == None || XGetWindowProperty(display, DefaultRootWindow(display),
      property, 0, 4096, False, XA_WINDOW, &actual_type, &format, &count,
      &remaining, &data) != Success || actual_type != XA_WINDOW ||
      format != 32 || remaining || (!data && count)) return 2;
    windows = (Window *)data;
    fprintf(stderr, "selection_source=native_ewmh\n");
  }
  /* The protocol permits None to select all clients in one server request.
   * Do not query snapshot client IDs individually: a departing unrelated
   * client would make that request invalid and abort an app observation. */
  XResClientIdSpec spec = {.client = None, .mask = XRES_CLIENT_ID_PID_MASK};
  long ids_count = 0;
  XResClientIdValue *ids = NULL;
  int identity_result = XResQueryClientIds(display, 1, &spec, &ids_count, &ids);
  fprintf(stderr, "client_identity_snapshot result=%d reply_count=%ld\n", identity_result, ids_count);
  if (identity_result != Success || x_error) {
    if (ids) XResClientIdsDestroy(ids_count, ids);
    if (data) XFree(data);
    return 5;
  }
  int clients_count = 0;
  XResClient *clients = NULL;
  if (!XResQueryClients(display, &clients_count, &clients)) {
    if (ids) XResClientIdsDestroy(ids_count, ids);
    if (data) XFree(data);
    return 2;
  }
  int found = 0, result = 0, owned_clients = 0;
  for (int client = 0; client < clients_count && !result; client++) {
    int owned = 0;
    for (long id = 0; id < ids_count; id++) {
      if (ids[id].spec.client == clients[client].resource_base &&
          ids[id].spec.mask == XRES_CLIENT_ID_PID_MASK &&
          ids[id].length == (long)sizeof(uint32_t) &&
          XResGetClientPid(&ids[id]) == expected) owned++;
    }
    if (!owned) continue;
    if (owned != 1) { result = 4; break; }
    owned_clients++;
    for (unsigned long i = 0; i < count; i++) {
      Window window = windows[i];
      fprintf(stderr, "listed_window=%lu expected_pid=%ld client_base=%lu mask=%lu\n",
              window, (long)expected, clients[client].resource_base, clients[client].resource_mask);
      if ((window & ~clients[client].resource_mask) != clients[client].resource_base) continue;
      pid_t owner;
      XWindowAttributes state;
      result = window_owner(display, window, &owner, &state);
      if (result) break;
      if (owner != expected) { result = 6; break; }
      print_state(window, owner, &state);
      found++;
    }
  }
  XFree(clients);
  if (ids) XResClientIdsDestroy(ids_count, ids);
  if (data) XFree(data);
  XSync(display, False);
  if (x_error) return result ? result : 5;
  fprintf(stderr, "owned_windows=%d owned_client_ranges=%d expected_pid=%ld result=%d\n",
          found, owned_clients, (long)expected, result);
  return result ? result : found ? 0 : 1;
}

static unsigned long numeric(const char *text) {
  char *end;
  errno = 0;
  unsigned long value = strtoul(text, &end, 10);
  return errno || *end || !value || value > UINT_MAX ? 0 : value;
}

int main(int argc, char **argv) {
  if (argc < 2 || argc > 4) return 2;
  Display *display = XOpenDisplay(NULL);
  if (!display) return 2;
  XSetErrorHandler(record_x_error);
  int result;
  if (argc == 2 && strcmp(argv[1], "--fixture") == 0) {
    result = fixture(display);
  } else if (argc == 3 && strcmp(argv[1], "--owned-windows") == 0) {
    unsigned long pid = numeric(argv[2]);
    result = pid && pid <= INT_MAX ? owned_windows(display, (pid_t)pid, NULL, 0) : 2;
  } else if (argc == 4 && strcmp(argv[1], "--owned-control") == 0) {
    unsigned long pid = numeric(argv[2]);
    Window window = (Window)numeric(argv[3]);
    result = pid && pid <= INT_MAX && window ?
        owned_windows(display, (pid_t)pid, &window, 1) : 2;
  } else {
    int state_mode = argc == 4 && strcmp(argv[1], "--state") == 0;
    unsigned long resource = numeric(argv[state_mode ? 2 : 1]);
    unsigned long expected = state_mode ? numeric(argv[3]) : 0;
    pid_t owner;
    XWindowAttributes attributes;
    if (!resource || (state_mode && (!expected || expected > INT_MAX)) ||
        (!state_mode && argc != 2)) result = 2;
    else {
      result = window_owner(display, (Window)resource, &owner, &attributes);
      if (!result && state_mode && owner != (pid_t)expected) result = 6;
      if (!result) {
        if (state_mode) print_state((Window)resource, owner, &attributes);
        else printf("%ld\n", (long)owner);
      }
    }
  }
  XCloseDisplay(display);
  return result;
}
