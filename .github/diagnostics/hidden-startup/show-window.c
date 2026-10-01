#include <gtk/gtk.h>
#include <glib-unix.h>
#include <signal.h>

/* Diagnostic-only trigger: the same GTK show/present APIs used by window_manager. */
static gboolean show_window(gpointer unused) {
  GList* windows = gtk_window_list_toplevels();
  for (GList* entry = windows; entry; entry = entry->next) {
    GtkWindow* window = GTK_WINDOW(entry->data);
    if (g_strcmp0(gtk_window_get_title(window), "LocalSend") == 0) {
      g_printerr("[LS-REPRO] GTK_SHOW_TRIGGER before visible=%d mapped=%d\n",
                 gtk_widget_get_visible(GTK_WIDGET(window)), gtk_widget_get_mapped(GTK_WIDGET(window)));
      gtk_widget_show(GTK_WIDGET(window));
      gtk_window_present(window);
      g_printerr("[LS-REPRO] GTK_SHOW_TRIGGER after visible=%d mapped=%d\n",
                 gtk_widget_get_visible(GTK_WIDGET(window)), gtk_widget_get_mapped(GTK_WIDGET(window)));
    }
  }
  g_list_free(windows);
  return G_SOURCE_CONTINUE;
}

__attribute__((constructor)) static void install_trigger(void) {
  g_unix_signal_add(SIGUSR1, show_window, NULL);
}
