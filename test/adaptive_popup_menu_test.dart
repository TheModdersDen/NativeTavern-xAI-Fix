import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/presentation/widgets/common/adaptive_popup_menu.dart';

void main() {
  testWidgets('iOS action sheet survives a parent rebuild and returns value',
      (tester) async {
    var rebuild = 0;
    String? selected;
    late StateSetter rebuildParent;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuildParent = setState;
            return Scaffold(
              body: Column(
                children: [
                  Text('rebuild-$rebuild'),
                  AdaptivePopupMenuButton<String>(
                    useBottomSheet: true,
                    onSelected: (value) => selected = value,
                    itemBuilder: (context) => const [
                      PopupMenuItem<String>(
                        value: 'edit',
                        child: Text('Edit item'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Edit item'), findsOneWidget);

    rebuildParent(() => rebuild++);
    await tester.pump();
    expect(find.text('Edit item'), findsOneWidget);

    await tester.tap(find.text('Edit item'));
    await tester.pumpAndSettle();
    expect(selected, 'edit');
  });
}
