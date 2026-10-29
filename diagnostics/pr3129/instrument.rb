p='app/lib/main.dart'
s=File.read(p); s="import 'probe.dart';\n"+s; s=s.sub('  runApp(',"  startProbe();\n  runApp("); File.write(p,s)
p='app/lib/pages/home_page.dart'; s=File.read(p);s="import '../probe.dart';\n"+s
s=s.sub('return Scaffold(',"return PaintProbe(name: 'scaffold', child: Scaffold(")
s=s.sub('    final vm = context.watch(homePageControllerProvider);', "    final vm = context.watch(homePageControllerProvider);\n    currentTab = vm.currentTab.name;")
s=s.sub('body: Row(',"body: PaintProbe(name: 'body', child: Row(")
s=s.sub("            ),\n            bottomNavigationBar:","            )),\n            bottomNavigationBar:")
s=s.sub("          );\n        },","          ));\n        },")
%w[ReceiveTab SendTab SettingsTab].each { |name| s=s.gsub("#{name}()","PaintProbe(name: '#{name}', child: #{name}())") }
File.write(p,s)
p='app/lib/widget/rotating_widget.dart';s=File.read(p);s="import '../probe.dart';\n"+s;s=s.sub('return Transform.rotate(',"return PaintProbe(name: 'rotation', child: Transform.rotate(");s=s.sub("      child: widget.child,\n    );","      child: widget.child,\n    ));");File.write(p,s)
File.write('app/lib/probe.dart',File.read('diagnostics/pr3129/probe.dart'))
