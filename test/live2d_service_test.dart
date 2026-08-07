import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_character_view.dart';
import 'package:path/path.dart' as p;

void main() {
  const service = Live2DService();

  group('bundled Live2D models', () {
    for (final definition in Live2DService.bundledModels) {
      test('${definition.id} manifest and references are valid', () {
        final modelFile = File(
          p.join(definition.modelDirectory, definition.modelFileName),
        );
        final manifest = service.parseManifest(modelFile.readAsStringSync());

        expect(manifest.version, 3);
        expect(manifest.mocFile, endsWith('.moc3'));
        expect(manifest.textures, isNotEmpty);
        expect(manifest.motions, isNotEmpty);
        expect(manifest.findMotion(const ['idle']), isNotNull);

        for (final reference in manifest.referencedFiles) {
          expect(
            File(p.join(definition.modelDirectory, reference)).existsSync(),
            isTrue,
            reason: '${definition.id} references missing file $reference',
          );
        }
      });
    }

    test('bundled model identifiers and paths are unique', () {
      final models = Live2DService.bundledModels;
      expect(models.map((model) => model.id).toSet(), hasLength(models.length));
      expect(
        models.map((model) => model.modelDirectory).toSet(),
        hasLength(models.length),
      );
      expect(models.map((model) => model.id), contains('hiyori_free'));
    });
  });

  test('Live2D character configuration round-trips through JSON', () {
    const motion = Live2DMotionRef(
      group: '',
      index: 3,
      file: 'motions/idle.motion3.json',
      name: 'idle',
    );
    const config = Live2DConfig(
      modelId: 'hiyori_free',
      displayName: 'Hiyori Momose (Official Sample)',
      modelDirectory: 'assets/live2d/hiyori_free/',
      modelFileName: 'hiyori_free_t08.model3.json',
      scale: 1.2,
      offsetX: 0.1,
      idleMotion: motion,
    );

    final restored = Live2DConfig.fromJson(config.toJson());
    expect(restored.modelId, config.modelId);
    expect(restored.scale, config.scale);
    expect(restored.offsetX, config.offsetX);
    expect(restored.idleMotion?.group, '');
    expect(restored.idleMotion?.index, 3);
    expect(restored.idleMotion?.file, motion.file);
  });

  testWidgets('unsupported platforms use the supplied fallback',
      (tester) async {
    if (Live2DCharacterView.isPlatformSupported) return;
    const config = Live2DConfig(
      modelId: 'test',
      displayName: 'Test',
      modelDirectory: 'assets/live2d/test/',
      modelFileName: 'test.model3.json',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Live2DCharacterView(
          config: config,
          fallback: Text('Static fallback'),
        ),
      ),
    );

    expect(find.text('Static fallback'), findsOneWidget);
  });
}
