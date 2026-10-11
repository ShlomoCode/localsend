/* Cloud-only negative control: the unpatched public plug geometry method
 * synchronously sends GetExtents to this same bus connection. The runner must
 * interrupt the observed default 25-second wait, not accept a quick return. */
#define spi_initialize_socket stock_probe_initialize_socket
#include "atk-adaptor/adaptors/socket-adaptor.c"
#undef spi_initialize_socket
#include "accessible-register.h"
#include <stdio.h>

int
main (void)
{
  DBusError error;
  DBusMessage *message, *reply;
  AtkObject *plug, *socket;
  gchar *plug_path, *socket_path;
  const gchar *unique;
  gint x, y, w, h;
  spi_global_app_data = g_new0 (SpiBridge, 1);
  dbus_error_init (&error);
  spi_global_app_data->bus = dbus_bus_get_private (DBUS_BUS_SESSION, &error);
  if (!spi_global_app_data->bus || dbus_error_is_set (&error)) return 10;
  dbus_connection_set_exit_on_disconnect (spi_global_app_data->bus, FALSE);
  spi_global_register = g_object_new (SPI_REGISTER_TYPE, NULL);
  plug = atk_plug_new ();
  socket = atk_socket_new ();
  plug_path = spi_register_object_to_path (spi_global_register, G_OBJECT (plug));
  socket_path = spi_register_object_to_path (spi_global_register, G_OBJECT (socket));
  unique = dbus_bus_get_unique_name (spi_global_app_data->bus);
  ATK_SOCKET (socket)->embedded_plug_id = g_strdup_printf ("%s:%s", unique, plug_path);
  message = dbus_message_new_method_call (unique, plug_path, ATSPI_DBUS_INTERFACE_SOCKET, "Embedded");
  dbus_message_set_serial (message, 1);
  dbus_message_set_sender (message, unique);
  dbus_message_append_args (message, DBUS_TYPE_STRING, &socket_path, DBUS_TYPE_INVALID);
  reply = impl_Embedded (spi_global_app_data->bus, message, plug);
  if (!reply) return 11;
  dbus_message_unref (reply);
  dbus_message_unref (message);
  printf ("stock_same_process_query bus=%s socket=%s plug=%s\n", unique, socket_path, plug_path);
  fflush (stdout);
  atk_component_get_extents (ATK_COMPONENT (plug), &x, &y, &w, &h, ATK_XY_SCREEN);
  printf ("unexpected_stock_return x=%d y=%d w=%d h=%d\n", x, y, w, h);
  return 12;
}
