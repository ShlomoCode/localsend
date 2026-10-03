import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/dialogs/text_field_with_actions.dart';
import 'package:localsend_app/util/alias_generator.dart';
class AliasStore { String alias = 'Original'; int writes = 0; Future<void> setAlias(String s) async { alias=s; writes++; } }
class RefAdapter { final AliasStore service; RefAdapter(this.service); AliasStore notifier(Object _) => service; }
class VmAdapter { final TextEditingController aliasController; VmAdapter(this.aliasController); }
final settingsProvider = Object();

void main() {
 for(final action in ['typing','random','system']) {
  for(final confirm in [false,true]) {
   testWidgets('$action changes persist only on confirmation; confirm=$confirm', (tester) async {
    final store=AliasStore(); final ref=RefAdapter(store);
    final controller=TextEditingController(text:store.alias); final vm=VmAdapter(controller);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:TextFieldWithActions(
      name:'Device name', controller:controller,
      onChanged:(s) async { await ref.notifier(settingsProvider).setAlias(s); },
      actions:[
        IconButton(key:const Key('random'),onPressed:() async { 
                            // Generates random alias
                            final newAlias = generateRandomAlias();

                            // Update the TextField with the new alias
                            vm.aliasController.text = newAlias;

 },icon:const Icon(Icons.casino)),
        IconButton(key:const Key('system'),onPressed:() async { 
                            final String newAlias;
                            if (Platform.isMacOS) {
                              final result = await Process.run('scutil', ['--get', 'ComputerName']);
                              newAlias = result.stdout.toString().trim();
                            } else {
                              newAlias = Platform.localHostname;
                            }

                            vm.aliasController.text = newAlias;
 },icon:const Icon(Icons.desktop_windows)),
      ],
    ))));
    await tester.tap(find.text('Original')); await tester.pumpAndSettle();
    if(action=='typing') { await tester.enterText(find.byType(TextFormField),'Draft'); }
    else { await tester.tap(find.byKey(Key(action))); }
    await tester.pumpAndSettle();
    final draft=controller.text;
    expect(draft,isNot('Original'));
    expect(store.alias,'Original',reason:'Editing or an action must not persist before Confirm');
    expect(store.writes,0);
    if(confirm) { await tester.tap(find.byType(ElevatedButton)); }
    else { await tester.tapAt(const Offset(5,5)); }
    await tester.pumpAndSettle();
    expect(store.alias,confirm?draft:'Original');
    expect(controller.text,confirm?draft:'Original');
    expect(store.writes,confirm?1:0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
   });
  }
 }
}
