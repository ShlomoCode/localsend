from pathlib import Path
import sys

root = Path(sys.argv[1])
mode = sys.argv[2]
file = root / 'app/lib/config/init.dart'
source = file.read_text()
if mode == 'after':
    imports = [
        "import 'package:localsend_app/pages/progress_page.dart';",
        "import 'package:localsend_app/provider/network/send_provider.dart';",
        "import 'package:localsend_isolates/model/session_status.dart';",
    ]
    source = source.replace("import 'dart:io';", "import 'dart:io';\n" + '\n'.join(imports))
    marker = '    final message = payload.content;'
    block = '''    final navigator = Navigator.of(Routerino.context);
    navigator.popUntil((route) {
      if (route is ModalRoute && route.settings.name == ProgressPage.toString() && ref.read(serverProvider)?.session == null) {
        void closeFinished(Element element) {
          if (element.widget case ProgressPage(:final sessionId)) {
            if (ref.read(sendProvider)[sessionId]?.status == SessionStatus.finished) {
              navigator.removeRoute(route);
              ref.notifier(sendProvider).closeSession(sessionId);
            }
          } else {
            element.visitChildElements(closeFinished);
          }
        }
        route.subtreeContext?.visitChildElements(closeFinished);
      }
      return true;
    });
'''
    assert source.count(marker) == 1
    source = source.replace(marker, block + marker)
    print('Production delta: 20 added nonblank lines, 0 deleted')
elif mode != 'before':
    raise ValueError(mode)
# Test-only seam: same library reaches the actual private action; no copied
# callback logic. Excluded from the proposed production delta.
source += '''
Future<void> protocolShareTestHook(Ref ref, SharedMedia payload) async {
  await ref.global.dispatchAsync(_HandleShareIntentAction(payload: payload));
}
'''
file.write_text(source)
print('Prepared share-navigation fixture', mode)
