import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
class BeforeEntry extends StatelessWidget {
  final String label;
  final Widget child;
  final String? description;

  const BeforeEntry({required this.label, required this.child, this.description});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (description != null)
                  Text(
                    description!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 150,
            child: child,
          ),
        ],
      ),
    );
  }
}

class AfterEntry extends StatelessWidget {
  final String label;
  final Widget child;
  final String? description;

  const AfterEntry({required this.label, required this.child, this.description});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (description != null)
                  Text(
                    description!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: child,
          ),
        ],
      ),
    );
  }
}


const destination='(Завантаження)';
Widget fixture(bool patched, double width, double scale, TextDirection direction, VoidCallback onTap, {bool toggle=false}) {
  return MaterialApp(home: Scaffold(body: Align(alignment:Alignment.topLeft, child:SizedBox(width:width, child:MediaQuery(data:MediaQueryData(textScaler:TextScaler.linear(scale)), child:Directionality(textDirection:direction,child:Builder(builder:(context) {
    final child=toggle ? SizedBox(height:50,child:Center(child:Switch(value:false,onChanged:(_)=>onTap()))) : TextButton(style:TextButton.styleFrom(padding:const EdgeInsets.symmetric(horizontal:16,vertical:8)),onPressed:onTap,child:Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Text(destination,style:Theme.of(context).textTheme.titleMedium)));
    return patched ? AfterEntry(label:'Зберігати в папку',child:child) : BeforeEntry(label:'Зберігати в папку',child:child);
  })))))));
}
void main() {
  testWidgets('fixed150 layout wraps Ukrainian destination; flexible layout preserves full label on desktop', (tester) async {
    await tester.pumpWidget(fixture(false,570,1,TextDirection.ltr,(){}));
    expect(tester.takeException(),isNull);
    final before=tester.renderObject<RenderParagraph>(find.text(destination));
    final beforeLines=before.getBoxesForSelection(const TextSelection(baseOffset:0,extentOffset:13)).map((b)=>b.top).toSet().length;
    await tester.pumpWidget(fixture(true,570,1,TextDirection.ltr,(){}));
    expect(tester.takeException(),isNull);
    final after=tester.renderObject<RenderParagraph>(find.text(destination));
    final afterLines=after.getBoxesForSelection(const TextSelection(baseOffset:0,extentOffset:13)).map((b)=>b.top).toSet().length;
    print('settings-label beforeLines=$beforeLines afterLines=$afterLines');
    expect(beforeLines,greaterThan(afterLines));expect(afterLines,1);
  });
  for(final width in [280.0,320.0,570.0]) {
    for(final scale in [1.0,2.0,3.0]) {
      for(final direction in [TextDirection.ltr,TextDirection.rtl]) {
        for(final toggle in [false,true]) {
          testWidgets('layout width=$width scale=$scale dir=$direction toggle=$toggle',(tester)async {
            var taps=0;
            await tester.pumpWidget(fixture(true,width,scale,direction,()=>taps++,toggle:toggle));
            expect(tester.takeException(),isNull);
            final control=find.byType(toggle?Switch:TextButton);
            final rect=tester.getRect(control);expect(rect.left,greaterThanOrEqualTo(0));expect(rect.right,lessThanOrEqualTo(width));
            await tester.tap(control);await tester.pump();expect(taps,1);
            if(!toggle)expect(find.text(destination),findsOneWidget);
          });
        }
      }
    }
  }
}
