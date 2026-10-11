/* Diagnostic only: authoritative local X client owner, without WM PID hints. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
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
  fprintf(stderr, "x_error=%d request=%d resource=%lu\n", event->error_code,
          event->request_code, event->resourceid);
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
  printf("%lu %ld %lu\n", window, (long)getpid(), destroyed);
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

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  Display *display = XOpenDisplay(NULL);
  if (!display) return 2;
  XSetErrorHandler(record_x_error);
  if (strcmp(argv[1], "--fixture") == 0) {
    int result = fixture(display);
    XCloseDisplay(display);
    return result;
  }
  char *end;
  errno = 0;
  unsigned long resource = strtoul(argv[1], &end, 10);
  if (errno || *end || !resource || resource > UINT_MAX) return 3;
  Window window = (Window)resource;
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
  if (x_error || before.root != after.root || before.class != after.class) return 5;
  printf("%ld\n", (long)owner);
  XCloseDisplay(display);
  return 0;
}
