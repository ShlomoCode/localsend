"""Port only PR2929's native hidden-startup behavior onto instrumented v1.17."""
from pathlib import Path
import difflib

p = Path('app/linux/my_application.cc')
original = p.read_text()
text = original
changes = [
    ('#include <flutter_linux/flutter_linux.h>', '#include <cstddef>\n#include <flutter_linux/flutter_linux.h>'),
    ('  // Use a header bar when running in GNOME', '''  bool start_hidden = false;
  if (self->dart_entrypoint_arguments != nullptr) {
    for (int i = 0; self->dart_entrypoint_arguments[i] != nullptr; i++) {
      if (strcmp(self->dart_entrypoint_arguments[i], "--hidden") == 0) {
        start_hidden = true;
        break;
      }
    }
  }

  // Use a header bar when running in GNOME'''),
    ('  gtk_widget_show(GTK_WIDGET(window));', '''  if (!start_hidden) {
    gtk_widget_show(GTK_WIDGET(window));
  } else {
    gtk_widget_realize(GTK_WIDGET(window));
  }'''),
    ('  gtk_widget_grab_focus(GTK_WIDGET(view));', '''  if (!start_hidden) {
    gtk_widget_grab_focus(GTK_WIDGET(view));
  }'''),
]
for old, new in changes:
    assert text.count(old) == 1, old
    text = text.replace(old, new, 1)
p.write_text(text)
Path('/tmp/ls-evidence/native-2929-only.diff').write_text(''.join(difflib.unified_diff(
    original.splitlines(True), text.splitlines(True), fromfile='v1.17-instrumented', tofile='v1.17-plus-native-2929')))
