/* Diagnostic intervention only: preserve icon, menu, and status operations. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>

void *app_indicator_new(const char *id, const char *icon, int category) {
  typedef void *(*create_fn)(const char *, const char *, int);
  create_fn create = (create_fn)dlsym(RTLD_NEXT, "app_indicator_new");
  fprintf(stderr, "[3546 intervention] SNI id %s -> org.localsend.localsend_app\n", id);
  return create("org.localsend.localsend_app", icon, category);
}
