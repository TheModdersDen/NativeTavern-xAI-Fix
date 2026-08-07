import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_stage_gestures.dart';

void main() {
  group('Live2D stage transform math', () {
    const initial = Live2DStageTransform(
      scale: 1,
      offsetX: 0,
      offsetY: 0,
    );
    const size = Size(200, 100);

    test('keeps an off-center focal point anchored while scaling', () {
      final transformed = Live2DStageTransform.applyGesture(
        start: initial,
        startFocalPoint: const Offset(150, 50),
        currentFocalPoint: const Offset(150, 50),
        scaleDelta: 2,
        size: size,
      );

      expect(transformed.scale, 2);
      expect(transformed.offsetX, -0.25);
      expect(transformed.offsetY, 0);
    });

    test('normalizes pan deltas to the stage dimensions', () {
      final transformed = Live2DStageTransform.applyGesture(
        start: initial,
        startFocalPoint: const Offset(100, 50),
        currentFocalPoint: const Offset(120, 60),
        scaleDelta: 1,
        size: size,
      );

      expect(transformed.scale, 1);
      expect(transformed.offsetX, closeTo(0.1, 0.000001));
      expect(transformed.offsetY, closeTo(0.1, 0.000001));
    });

    test('clamps scale and offsets to supported limits', () {
      final transformed = Live2DStageTransform.applyGesture(
        start: const Live2DStageTransform(
          scale: 10,
          offsetX: 10,
          offsetY: -10,
        ),
        startFocalPoint: Offset.zero,
        currentFocalPoint: const Offset(100000, -100000),
        scaleDelta: 100,
        size: size,
      );

      expect(transformed.scale, Live2DStageTransform.maxScale);
      expect(transformed.offsetX, Live2DStageTransform.maxOffset);
      expect(transformed.offsetY, -Live2DStageTransform.maxOffset);
    });
  });

  testWidgets('one-finger drag scrolls without transforming the stage',
      (tester) async {
    final scrollController = ScrollController();
    final completed = <Live2DStageTransform>[];
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 320,
          child: Live2DTwoFingerGestureRegion(
            initialTransform: const Live2DStageTransform(
              scale: 1,
              offsetX: 0,
              offsetY: 0,
            ),
            onTransformEnd: completed.add,
            builder: (context, transform) => ListView(
              controller: scrollController,
              children: const [SizedBox(height: 1200)],
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -140));
    await tester.pumpAndSettle();

    expect(scrollController.offset, greaterThan(0));
    expect(completed, isEmpty);
  });

  testWidgets('two fingers scale the stage and emit one completed transform',
      (tester) async {
    final completed = <Live2DStageTransform>[];
    final scrollController = ScrollController();
    Live2DStageTransform? displayed;
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 320,
          child: Live2DTwoFingerGestureRegion(
            initialTransform: const Live2DStageTransform(
              scale: 1,
              offsetX: 0,
              offsetY: 0,
            ),
            onTransformEnd: completed.add,
            builder: (context, transform) {
              displayed = transform;
              return ListView(
                key: const ValueKey('gesture-surface'),
                controller: scrollController,
                children: const [SizedBox(height: 1200)],
              );
            },
          ),
        ),
      ),
    );

    final center =
        tester.getCenter(find.byKey(const ValueKey('gesture-surface')));
    final first = await tester.startGesture(
      center - const Offset(20, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 2,
    );
    await first.moveTo(center - const Offset(40, 0));
    await second.moveTo(center + const Offset(40, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();

    expect(displayed?.scale, closeTo(2, 0.000001));
    expect(scrollController.offset, 0);
    expect(completed, hasLength(1));
    expect(completed.single.scale, closeTo(2, 0.000001));
  });
}
