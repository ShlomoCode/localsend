Disposable Windows VM only. No user-host installation/registry modifications.
1. Checkout repository pin 9529e915f438d8edd8bdf23e9f7aab2261a8b3e6 and place fixture directory + sibling fresh-ui-input-1735-complete.patch on runner.
2. python prepare_fixture.py <repo-path> (verifies pin, applies patch, copies tests and extracts exact MaterialApp builder closure from patched main.dart).
3. In MSVC developer environment: cl /nologo /EHsc /std:c++17 native_host.cpp /Fe:native_host.exe
4. Install Flutter3.41.9 on disposable runner as root workflow already supports. flutter pub get --offline from repo workspace. Lockfile packages ffi2.2.0 and win325.15.0 must already exist on runner cache; otherwise standard flutter pub get on runner.
5. Set PowerShell $env:LOCALSEND_THEME_HOST=(Resolve-Path native_host.exe).Path
6. From repo/app: flutter test --no-pub test/widget/fresh_windows_theme_integration_test.dart --reporter expanded
Tests import actual app config/theme.dart; only window_manager getId channel is mocked to native child process HWND. Real Dart FFI crosses to real DWM Windows APIs. Hidden HWND child host uses normal Win32 message pump; teardown posts WM_CLOSE. No registry changes in this Flutter fixture. Native matrix fixture separately tests OS/app combinations plus native overwrite removal. Five tests expected.
