// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Included first as it collides with the X11 headers.
#include "gtest/gtest.h"

#include "flutter/shell/platform/linux/fl_socket_accessible.h"
#include "flutter/shell/platform/linux/testing/fl_test_gtk_logs.h"

namespace {

struct HostGeometry {
  gint screen_x = 137;
  gint screen_y = 251;
  gint window_x = 19;
  gint window_y = 37;
  gint width = 311;
  gint height = 173;
  guint calls = 0;
  AtkCoordType last_coords = ATK_XY_SCREEN;
};

// The unit target mocks GTK window/allocation APIs. Replace only the host's
// component callback, restoring it on exit, to test the real AtkSocket
// forwarding contract without claiming to measure a realized GTK window.
class ScopedHostGeometry {
 public:
  explicit ScopedHostGeometry(AtkObject* host) : host_(host) {
    iface_ = ATK_COMPONENT_GET_IFACE(host);
    original_ = iface_->get_extents;
    g_object_set_data(G_OBJECT(host_), "socket-test-geometry", &geometry);
    iface_->get_extents = GetExtents;
  }

  ~ScopedHostGeometry() {
    iface_->get_extents = original_;
    g_object_set_data(G_OBJECT(host_), "socket-test-geometry", nullptr);
  }

  HostGeometry geometry;

 private:
  static void GetExtents(AtkComponent* component,
                         gint* x,
                         gint* y,
                         gint* width,
                         gint* height,
                         AtkCoordType coords) {
    auto* geometry = static_cast<HostGeometry*>(g_object_get_data(
        G_OBJECT(component), "socket-test-geometry"));
    ASSERT_NE(geometry, nullptr);
    geometry->calls++;
    geometry->last_coords = coords;
    *x = coords == ATK_XY_SCREEN ? geometry->screen_x : geometry->window_x;
    *y = coords == ATK_XY_SCREEN ? geometry->screen_y : geometry->window_y;
    *width = geometry->width;
    *height = geometry->height;
  }

  AtkObject* host_;
  AtkComponentIface* iface_;
  decltype(AtkComponentIface::get_extents) original_;
};

void ExpectExtents(AtkObject* object,
                   AtkCoordType coords,
                   gint expected_x,
                   gint expected_y,
                   gint expected_width,
                   gint expected_height) {
  gint x = 0;
  gint y = 0;
  gint width = 0;
  gint height = 0;
  atk_component_get_extents(ATK_COMPONENT(object), &x, &y, &width, &height,
                            coords);
  EXPECT_EQ(x, expected_x);
  EXPECT_EQ(y, expected_y);
  EXPECT_EQ(width, expected_width);
  EXPECT_EQ(height, expected_height);
}

void MarkFinalized(gpointer data, GObject* object) {
  *static_cast<bool*>(data) = true;
}

}  // namespace

TEST(FlSocketAccessibleTest, ChildHasHostParent) {
  flutter::testing::fl_ensure_gtk_init();
  g_autoptr(GtkWidget) widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  g_object_ref_sink(widget);
  g_autoptr(FlSocketAccessible) host =
      FL_SOCKET_ACCESSIBLE(g_object_new(fl_socket_accessible_get_type(), nullptr));
  atk_object_initialize(ATK_OBJECT(host), widget);

  ASSERT_EQ(atk_object_get_n_accessible_children(ATK_OBJECT(host)), 1);
  g_autoptr(AtkObject) socket =
      atk_object_ref_accessible_child(ATK_OBJECT(host), 0);
  ASSERT_TRUE(ATK_IS_SOCKET(socket));
  EXPECT_EQ(atk_object_get_parent(socket), ATK_OBJECT(host));
  g_object_run_dispose(G_OBJECT(host));
}

TEST(FlSocketAccessibleTest, ForwardsLiveHostGeometry) {
  flutter::testing::fl_ensure_gtk_init();
  g_autoptr(GtkWidget) widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  g_object_ref_sink(widget);
  g_autoptr(FlSocketAccessible) host =
      FL_SOCKET_ACCESSIBLE(g_object_new(fl_socket_accessible_get_type(), nullptr));
  atk_object_initialize(ATK_OBJECT(host), widget);
  g_autoptr(AtkObject) socket =
      atk_object_ref_accessible_child(ATK_OBJECT(host), 0);
  ScopedHostGeometry host_geometry(ATK_OBJECT(host));

  ExpectExtents(socket, ATK_XY_SCREEN, 137, 251, 311, 173);
  EXPECT_EQ(host_geometry.geometry.last_coords, ATK_XY_SCREEN);
  ExpectExtents(socket, ATK_XY_WINDOW, 19, 37, 311, 173);
  EXPECT_EQ(host_geometry.geometry.last_coords, ATK_XY_WINDOW);
  EXPECT_EQ(host_geometry.geometry.calls, 2u);

  // Model host movement and resize between queries. No cached origin or
  // extra socket offset should be introduced, and WINDOW stays host-relative.
  host_geometry.geometry.screen_x += 83;
  host_geometry.geometry.screen_y -= 41;
  host_geometry.geometry.width = 427;
  host_geometry.geometry.height = 229;
  ExpectExtents(socket, ATK_XY_SCREEN, 220, 210, 427, 229);
  EXPECT_EQ(host_geometry.geometry.last_coords, ATK_XY_SCREEN);
  ExpectExtents(socket, ATK_XY_WINDOW, 19, 37, 427, 229);
  EXPECT_EQ(host_geometry.geometry.last_coords, ATK_XY_WINDOW);
  EXPECT_EQ(host_geometry.geometry.calls, 4u);
  g_object_run_dispose(G_OBJECT(host));
}

TEST(FlSocketAccessibleTest, WidgetUnsetBreaksParentOwnershipCycle) {
  flutter::testing::fl_ensure_gtk_init();
  g_autoptr(GtkWidget) widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  g_object_ref_sink(widget);
  FlSocketAccessible* host =
      FL_SOCKET_ACCESSIBLE(g_object_new(fl_socket_accessible_get_type(), nullptr));
  gtk_accessible_set_widget(GTK_ACCESSIBLE(host), widget);
  atk_object_initialize(ATK_OBJECT(host), widget);
  AtkObject* socket = atk_object_ref_accessible_child(ATK_OBJECT(host), 0);
  bool host_finalized = false;
  bool socket_finalized = false;
  g_object_weak_ref(G_OBJECT(host), MarkFinalized, &host_finalized);
  g_object_weak_ref(G_OBJECT(socket), MarkFinalized, &socket_finalized);

  // GtkWidget's teardown unsets its accessible's widget before dropping its
  // owning reference. Exercise that public lifecycle without forcing dispose.
  gtk_accessible_set_widget(GTK_ACCESSIBLE(host), nullptr);
  EXPECT_EQ(atk_object_get_parent(socket), nullptr);
  gtk_accessible_set_widget(GTK_ACCESSIBLE(host), nullptr);
  g_object_unref(host);
  EXPECT_TRUE(host_finalized);
  EXPECT_FALSE(socket_finalized);
  ExpectExtents(socket, ATK_XY_SCREEN, -1, -1, -1, -1);
  ExpectExtents(socket, ATK_XY_WINDOW, -1, -1, -1, -1);

  // Keep a failing candidate from leaking or leaving weak callback data on
  // the stack. The assertion above still reports a retained ownership cycle.
  if (!host_finalized) {
    g_object_run_dispose(G_OBJECT(host));
  }
  g_object_unref(socket);
  EXPECT_TRUE(socket_finalized);
}

TEST(FlSocketAccessibleTest, DisposeDetachesExternallyReferencedSocket) {
  flutter::testing::fl_ensure_gtk_init();
  g_autoptr(GtkWidget) widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  g_object_ref_sink(widget);
  FlSocketAccessible* host =
      FL_SOCKET_ACCESSIBLE(g_object_new(fl_socket_accessible_get_type(), nullptr));
  atk_object_initialize(ATK_OBJECT(host), widget);
  AtkObject* socket = atk_object_ref_accessible_child(ATK_OBJECT(host), 0);
  bool host_finalized = false;
  bool socket_finalized = false;
  g_object_weak_ref(G_OBJECT(host), MarkFinalized, &host_finalized);
  g_object_weak_ref(G_OBJECT(socket), MarkFinalized, &socket_finalized);

  {
    ScopedHostGeometry host_geometry(ATK_OBJECT(host));
    ExpectExtents(socket, ATK_XY_SCREEN, 137, 251, 311, 173);
    g_object_run_dispose(G_OBJECT(host));
    EXPECT_EQ(atk_object_get_parent(socket), nullptr);
    ExpectExtents(socket, ATK_XY_SCREEN, -1, -1, -1, -1);
    ExpectExtents(socket, ATK_XY_WINDOW, -1, -1, -1, -1);
    EXPECT_EQ(host_geometry.geometry.calls, 1u);

    // GObject allows dispose more than once; the held child must remain valid.
    g_object_run_dispose(G_OBJECT(host));
    EXPECT_EQ(atk_object_get_parent(socket), nullptr);
  }
  g_object_unref(host);
  EXPECT_TRUE(host_finalized);
  EXPECT_FALSE(socket_finalized);
  ExpectExtents(socket, ATK_XY_SCREEN, -1, -1, -1, -1);
  ExpectExtents(socket, ATK_XY_WINDOW, -1, -1, -1, -1);
  g_object_unref(socket);
  EXPECT_TRUE(socket_finalized);
}

TEST(FlSocketAccessibleTest, DisposePreservesAnotherParent) {
  flutter::testing::fl_ensure_gtk_init();
  g_autoptr(GtkWidget) widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  g_object_ref_sink(widget);
  g_autoptr(FlSocketAccessible) host =
      FL_SOCKET_ACCESSIBLE(g_object_new(fl_socket_accessible_get_type(), nullptr));
  gtk_accessible_set_widget(GTK_ACCESSIBLE(host), widget);
  atk_object_initialize(ATK_OBJECT(host), widget);
  g_autoptr(AtkObject) socket =
      atk_object_ref_accessible_child(ATK_OBJECT(host), 0);
  g_autoptr(AtkObject) other_parent = atk_socket_new();
  atk_object_set_parent(socket, other_parent);

  gtk_accessible_set_widget(GTK_ACCESSIBLE(host), nullptr);
  EXPECT_EQ(atk_object_get_parent(socket), other_parent);
  g_object_run_dispose(G_OBJECT(host));
  EXPECT_EQ(atk_object_get_parent(socket), other_parent);
  g_object_run_dispose(G_OBJECT(host));
  EXPECT_EQ(atk_object_get_parent(socket), other_parent);
  atk_object_set_parent(socket, nullptr);
}
