from pathlib import Path
import sys
file = Path(sys.argv[1]) / 'app/lib/pages/progress_page.dart'
s = file.read_text()
if sys.argv[2] == 'after':
    marker = '    final sendSession = ref.read(sendProvider)[widget.sessionId];'
    # Only first occurrence: _exit, not build().
    s = s.replace(marker, "    if (receiveSession != null && receiveSession.sessionId != widget.sessionId) {\n      return;\n    }\n" + marker, 1)
    marker = '    if (result && mounted) {'
    s = s.replace(marker, "    if (ref.read(serverProvider)?.session case final session? when session.sessionId != widget.sessionId) {\n      return;\n    }\n" + marker, 1)
    marker = '      final sendState = ref.read(sendProvider)[widget.sessionId];'
    s = s.replace(marker, "      if (receiveSession != null && receiveSession.sessionId != widget.sessionId) {\n        return false;\n      }\n" + marker, 1)
    print('Production 9 added 0 deleted nonblank lines')
# Same-library seam reaches actual async _exit. Its existing return type is void.
s += "\nvoid protocolStaleExitHook(State state) {\n  (state as _ProgressPageState)._exit(closeSession: true);\n}\n"
file.write_text(s)
