#include <X11/Xlib.h>
#include <X11/extensions/XRes.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

int main(int argc, char **argv) {
    char *end = NULL;
    unsigned long window_id;
    Display *display;
    int event_base = 0;
    int error_base = 0;
    int major = 0;
    int minor = 0;
    XResClientIdSpec spec;
    XResClientIdValue *values = NULL;
    long value_count = 0;
    int exit_code = 6;

    if (argc != 2)
        return 2;
    errno = 0;
    window_id = strtoul(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0' || window_id == 0 || window_id > 0xffffffffUL)
        return 2;

    display = XOpenDisplay(NULL);
    if (display == NULL)
        return 3;
    if (!XResQueryExtension(display, &event_base, &error_base) ||
        !XResQueryVersion(display, &major, &minor) ||
        (major < 1 || (major == 1 && minor < 2))) {
        XCloseDisplay(display);
        return 4;
    }

    spec.client = (XID)window_id;
    spec.mask = XRES_CLIENT_ID_PID_MASK;
    if (XResQueryClientIds(display, 1, &spec, &value_count, &values) != Success) {
        XCloseDisplay(display);
        return 5;
    }

    for (long i = 0; i < value_count; i++) {
        if ((values[i].spec.mask & XRES_CLIENT_ID_PID_MASK) != 0) {
            pid_t pid = XResGetClientPid(&values[i]);
            if (pid > 0) {
                printf("%ld\n", (long)pid);
                exit_code = 0;
                break;
            }
        }
    }

    if (values != NULL)
        XResClientIdsDestroy(value_count, values);
    XCloseDisplay(display);
    return exit_code;
}
