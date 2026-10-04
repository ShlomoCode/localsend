/* SPDX-License-Identifier: MIT */

#include <gio/gio.h>
#include <glib.h>
#include <string.h>

#define PORTAL_BUS "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define BACKGROUND_IFACE "org.freedesktop.portal.Background"
#define REQUEST_IFACE "org.freedesktop.portal.Request"

typedef struct
{
  GMainLoop *loop;
  gboolean timed_out;
  gboolean received;
  guint32 response;
  gboolean background;
  gboolean autostart;
} ProbeResult;

static gboolean
on_timeout (gpointer user_data)
{
  ProbeResult *result = user_data;

  result->timed_out = TRUE;
  g_main_loop_quit (result->loop);
  return G_SOURCE_REMOVE;
}

static void
on_response (GDBusConnection *connection,
             const gchar     *sender_name,
             const gchar     *object_path,
             const gchar     *interface_name,
             const gchar     *signal_name,
             GVariant        *parameters,
             gpointer         user_data)
{
  ProbeResult *result = user_data;
  g_autoptr(GVariant) values = NULL;

  (void) connection;
  (void) sender_name;
  (void) object_path;
  (void) interface_name;
  (void) signal_name;

  g_variant_get (parameters, "(u@a{sv})", &result->response, &values);
  g_variant_lookup (values, "background", "b", &result->background);
  g_variant_lookup (values, "autostart", "b", &result->autostart);
  result->received = TRUE;
  g_main_loop_quit (result->loop);
}

static gchar *
request_path_for_connection (GDBusConnection *connection,
                             const gchar     *token)
{
  const gchar *unique_name = g_dbus_connection_get_unique_name (connection);
  g_autoptr(GString) sender = g_string_new (NULL);

  if (unique_name == NULL || unique_name[0] != ':')
    return NULL;

  for (const gchar *cursor = unique_name + 1; *cursor != '\0'; cursor++)
    g_string_append_c (sender, *cursor == '.' ? '_' : *cursor);

  return g_strdup_printf (PORTAL_PATH "/request/%s/%s", sender->str, token);
}

int
main (int argc, char **argv)
{
  const gboolean enable = argc == 2 && g_strcmp0 (argv[1], "enable") == 0;
  const gboolean disable = argc == 2 && g_strcmp0 (argv[1], "disable") == 0;
  const gchar *token = enable ? "localsend_autostart_enable" : "localsend_autostart_disable";
  const gchar *commandline[] = { "localsend", "--hidden", NULL };
  g_autoptr(GError) error = NULL;
  g_autoptr(GDBusConnection) connection = NULL;
  g_autofree gchar *expected_path = NULL;
  g_autoptr(GVariant) reply = NULL;
  GVariantBuilder options;
  const gchar *returned_path = NULL;
  ProbeResult result = { 0 };
  guint subscription_id;
  guint timeout_id;

  if (!enable && !disable)
    {
      g_printerr ("usage: portal-probe enable|disable\n");
      return 64;
    }

  connection = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, &error);
  if (connection == NULL)
    {
      g_printerr ("session bus: %s\n", error->message);
      return 1;
    }

  expected_path = request_path_for_connection (connection, token);
  if (expected_path == NULL)
    {
      g_printerr ("session bus has no unique name\n");
      return 1;
    }

  result.loop = g_main_loop_new (NULL, FALSE);
  subscription_id = g_dbus_connection_signal_subscribe (
    connection,
    PORTAL_BUS,
    REQUEST_IFACE,
    "Response",
    expected_path,
    NULL,
    G_DBUS_SIGNAL_FLAGS_NONE,
    on_response,
    &result,
    NULL);

  g_variant_builder_init (&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add (&options, "{sv}", "handle_token", g_variant_new_string (token));
  g_variant_builder_add (&options, "{sv}", "reason", g_variant_new_string ("Start LocalSend automatically after login"));
  g_variant_builder_add (&options, "{sv}", "autostart", g_variant_new_boolean (enable));
  if (enable)
    g_variant_builder_add (&options, "{sv}", "commandline", g_variant_new_strv (commandline, -1));

  reply = g_dbus_connection_call_sync (
    connection,
    PORTAL_BUS,
    PORTAL_PATH,
    BACKGROUND_IFACE,
    "RequestBackground",
    g_variant_new ("(s@a{sv})", "", g_variant_builder_end (&options)),
    G_VARIANT_TYPE ("(o)"),
    G_DBUS_CALL_FLAGS_NONE,
    30000,
    NULL,
    &error);
  if (reply == NULL)
    {
      g_printerr ("RequestBackground: %s\n", error->message);
      g_dbus_connection_signal_unsubscribe (connection, subscription_id);
      g_main_loop_unref (result.loop);
      return 1;
    }

  g_variant_get (reply, "(&o)", &returned_path);
  if (g_strcmp0 (returned_path, expected_path) != 0)
    {
      g_printerr ("unexpected request path: %s\n", returned_path);
      g_dbus_connection_signal_unsubscribe (connection, subscription_id);
      g_main_loop_unref (result.loop);
      return 1;
    }

  timeout_id = g_timeout_add_seconds (30, on_timeout, &result);
  g_main_loop_run (result.loop);
  if (!result.timed_out)
    g_source_remove (timeout_id);

  g_dbus_connection_signal_unsubscribe (connection, subscription_id);
  g_main_loop_unref (result.loop);

  if (result.timed_out || !result.received)
    {
      g_printerr ("timed out waiting for portal response\n");
      return 1;
    }

  g_print ("response=%u background=%s autostart=%s\n",
           result.response,
           result.background ? "true" : "false",
           result.autostart ? "true" : "false");

  if (result.response != 0 || !result.background || result.autostart != enable)
    return 1;

  return 0;
}
