# Native desktop environment review

Independent Sol 6.1 medium reviewer inspected the official v1.8.0 AppImage as an archive without executing it locally. Its hash matches `49eb71c34bab7c90a21c8f8cb3e220ae88b508b0a00741f906c57a464c7204c1`.

`AppRun.env` prepends `$APPDIR/usr/local/share:$APPDIR/usr/share` to inherited `XDG_DATA_DIRS`, with similar treatment of config directories. It also sets `GTK_EXE_PREFIX` and `GTK_DATA_PREFIX` to bundled paths. The archive does not contain icon themes or pixbuf loader modules/cache. The native VM had hicolor, Adwaita and Yaru packages installed.

Run 38141730938 inherited only part of the GNOME session through SSH. `XDG_DATA_DIRS` was omitted, leaving bundle-only icon paths. GTK aborted before a visible app or file selection. This is an infrastructure launch failure, not issue 402.

Historical commit `0a3be73b` (April 29, 2023), PR 415, explicitly adds host `/usr/local/share` and `/usr/share` paths and changes AppImage dependency packaging. It supports the data-path diagnosis but does not prove that PR 415 fixed issue 402.

Run 38143315209 restores actual GNOME desktop data/config and existing GTK/pixbuf variables from the real session. It supplies no fabricated defaults and changes no AppImage bytes. The ordinary FUSE launch and all three real GUI transfers pass, preserving exact received names and target bytes. Native environment and archived outputs are under `run15/issue402-historical-picker-evidence`.

The initial PNG cache failure was not causally isolated. Upstream gdk-pixbuf 2.40 uses `GDK_PIXBUF_MODULE_FILE` or its compiled library path; `GTK_EXE_PREFIX` alone was not established as a cache redirect. No cache override was applied or attributed as a fix.
