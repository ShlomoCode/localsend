#include <gtk/gtk.h>

int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), "issue2690-native-GTK-X11-control");
  gtk_window_set_default_size(GTK_WINDOW(window), 640, 300);
  GtkWidget *label = gtk_label_new("Gentoo native GTK works on X11 without Wayland");
  gtk_container_add(GTK_CONTAINER(window), label);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
  gtk_widget_show_all(window);
  gtk_main();
  return 0;
}
