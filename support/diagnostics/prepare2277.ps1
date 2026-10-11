param([string]$SourceDirectory,[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null
$path="$SourceDirectory/app/lib/pages/web_send_page.dart"
$source=[IO.File]::ReadAllText($path).Replace("`r`n","`n")
$source="import 'dart:io' as diagnostic;`n"+$source
$source=$source.Replace('  bool _encrypted = false;',@'
  bool _encrypted = false;
  void _trace(String event) {
    final path = diagnostic.Platform.environment['BUG2277_TRACE'];
    if (path != null) {
      final route = ModalRoute.of(context);
      diagnostic.File(path).writeAsStringSync('${DateTime.now().toUtc().toIso8601String()} event=$event state=${_stateEnum.name} mounted=$mounted current=${route?.isCurrent} canPop=${Navigator.of(context).canPop()}\n', mode: diagnostic.FileMode.append);
    }
  }
'@)
$source=$source.Replace('onPopInvokedWithResult: (_, __) async {',"onPopInvokedWithResult: (didPop, result) async {`n        _trace('callback didPop=' + didPop.toString());")
$source=$source.Replace('          context.pop();',"          _trace('before context.pop');`n          context.pop();")
[IO.File]::WriteAllText($path,$source)
[IO.File]::WriteAllText("$EvidenceDirectory/instrumented-baseline.dart",$source)
$mainPath="$SourceDirectory/app/lib/main.dart"
$main=[IO.File]::ReadAllText($mainPath).Replace("`r`n","`n")
$main="import 'dart:io' as diagnostic;`n"+$main
$main=$main.Replace('navigatorKey: Routerino.navigatorKey,','navigatorKey: Routerino.navigatorKey, navigatorObservers: [Diagnostic2277Observer()],')
$main+=@'

class Diagnostic2277Observer extends NavigatorObserver {
  void _write(String action, Route route, Route? previous) {
    final path = diagnostic.Platform.environment['BUG2277_TRACE'];
    if (path != null) {
      diagnostic.File(path).writeAsStringSync('${DateTime.now().toUtc().toIso8601String()} NAV $action route=${route.settings.name} previous=${previous?.settings.name}\n', mode: diagnostic.FileMode.append);
    }
  }
  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    _write('push', route, previousRoute);
  }
  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    _write('pop', route, previousRoute);
  }
  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    _write('remove', route, previousRoute);
  }
}
'@
[IO.File]::WriteAllText($mainPath,$main)
[IO.File]::WriteAllText("$EvidenceDirectory/instrumented-main.dart",$main)
