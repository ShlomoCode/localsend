from pathlib import Path
import shutil,subprocess,sys
repo=Path(sys.argv[1]).resolve()
fixture=Path(__file__).resolve().parent
patch=fixture.parent/'fresh-ui-input-1735-complete.patch'
# Run only in disposable pinned checkout, never the user's host checkout.
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
if head!='9529e915f438d8edd8bdf23e9f7aab2261a8b3e6': raise SystemExit('Wrong pinned HEAD: '+head)
subprocess.run(['git','apply','--check',str(patch)],cwd=repo,check=True)
subprocess.run(['git','apply',str(patch)],cwd=repo,check=True)
target=repo/'app/test/widget'; target.mkdir(parents=True,exist_ok=True)
shutil.copyfile(fixture/'fresh_windows_theme_integration_test.dart',target/'fresh_windows_theme_integration_test.dart')
source=(repo/'app/lib/main.dart').read_text()
start=source.index('              builder: (context, child) {')
end=source.index('              title: t.appName,',start)
builder=source[start:end].strip()
if not builder.endswith('},'): raise SystemExit('Cannot extract builder')
closure=builder[len('builder: '):-1]
(target/'windows_theme_builder.dart').write_text("import 'dart:async';\nimport 'package:flutter/material.dart';\nimport 'package:localsend_app/config/theme.dart';\nimport 'package:localsend_app/util/native/platform_check.dart';\n\nWidget fixtureApp(ThemeMode mode) => MaterialApp(\n theme: ThemeData(brightness: Brightness.light),\n darkTheme: ThemeData(brightness: Brightness.dark),\n themeMode: mode,\n builder: "+closure+",\n home: const SizedBox(),\n);\n")
print('Prepared actual-helper/native-Windows fixture at',target)
