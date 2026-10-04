#include <gtk/gtk.h>
#include <string.h>

static void response(GtkNativeDialog *dialog, gint result, gpointer data) {
  g_print("response=%d\n", result);
  gtk_native_dialog_destroy(dialog);
  gtk_main_quit();
}

int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  const char *mode = argc > 1 ? argv[1] : "file";
  GtkFileChooserAction action = strcmp(mode, "folder") == 0
      ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN;
  GtkFileChooserNative *dialog = gtk_file_chooser_native_new(
      "GTK diagnostic chooser", NULL, action, "Select", "Cancel");
  gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(dialog), strcmp(mode, "multiple") == 0);
  g_signal_connect(dialog, "response", G_CALLBACK(response), NULL);
  g_print("show mode=%s GTK=%u.%u.%u\n", mode,
      gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
  gtk_main();
  return 0;
}
