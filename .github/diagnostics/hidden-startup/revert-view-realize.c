// Diagnostic-only LD_PRELOAD shim for Flutter engine commit
// 3443af6a5ca032a1693ce2e1902650f5eb12a9e7 (PR 54703).
// Build on Linux: cc -shared -fPIC -o revert-view-realize.so \
//   revert-view-realize.c $(pkg-config --cflags --libs gtk+-3.0) -ldl
// Enable with LS_REVERT_VIEW_REALIZE=1 before launching the application.

#define _GNU_SOURCE

#include <dlfcn.h>
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*GtkContainerAddFn)(GtkContainer *, GtkWidget *);

void gtk_container_add(GtkContainer *container, GtkWidget *child) {
  static GtkContainerAddFn original_add;
  static gboolean patched_fl_view;

  if (original_add == NULL) {
    dlerror();
    void *symbol = dlsym(RTLD_NEXT, "gtk_container_add");
    const char *error = dlerror();
    if (error != NULL || symbol == NULL) {
      fprintf(stderr, "[revert-view-realize] ERROR: cannot resolve gtk_container_add: %s\n",
              error != NULL ? error : "symbol not found");
      abort();
    }
    original_add = (GtkContainerAddFn)symbol;
  }

  // Leave every call untouched unless the experiment is explicitly enabled.
  if (!patched_fl_view && strcmp(getenv("LS_REVERT_VIEW_REALIZE") ?: "", "1") == 0 &&
      child != NULL && strcmp(G_OBJECT_TYPE_NAME(child), "FlView") == 0) {
    GtkWidgetClass *klass = GTK_WIDGET_GET_CLASS(child);
    GtkWidgetClass *parent_klass = g_type_class_peek_parent(klass);
    if (parent_klass == NULL || G_TYPE_FROM_CLASS(parent_klass) != GTK_TYPE_BOX || parent_klass->realize == NULL) {
      fprintf(stderr, "[revert-view-realize] ERROR: FlView's direct parent is not a usable GtkBox class\n");
      abort();
    }

    gboolean already_realized = gtk_widget_get_realized(child);
    fprintf(stderr,
            "[revert-view-realize] FlView type=%s parent=%s previous_realize=%p parent_realize=%p already_realized=%d\n",
            G_OBJECT_TYPE_NAME(child), g_type_name(G_TYPE_FROM_CLASS(parent_klass)),
            (void *)klass->realize, (void *)parent_klass->realize, already_realized);
    if (already_realized) {
      fprintf(stderr, "[revert-view-realize] ERROR: FlView was realized before gtk_container_add; reversal is too late\n");
      abort();
    }

    klass->realize = parent_klass->realize;
    patched_fl_view = TRUE;
    fprintf(stderr, "[revert-view-realize] patched FlView.realize to GtkBox.realize before gtk_container_add\n");
  }

  original_add(container, child);
}
