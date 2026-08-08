import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/vector_storage.dart';
import 'package:native_tavern/domain/services/image_generation_service.dart';
import 'package:native_tavern/domain/services/stt_service.dart';
import 'package:native_tavern/domain/services/tts_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations_en.dart';
import 'package:native_tavern/l10n/generated/app_localizations_zh.dart';

void main() {
  test('uses OAI Compatible for user-facing provider names', () {
    expect(AppLocalizationsEn().openai, 'OAI Compatible');
    expect(STTProvider.openAICompatible.displayName, 'OAI Compatible');
    expect(TTSProvider.openaiCompatible.displayName, 'OAI Compatible');
    expect(ImageGenProvider.openai.displayName, 'OAI Compatible');
    expect(ImageGenProvider.openaiChat.displayName, 'OAI Compatible Chat');
    expect(EmbeddingProvider.openai.displayName, 'OAI Compatible');
    expect(
      EmbeddingProvider.custom.displayName,
      'Custom API (OAI Compatible)',
    );
  });

  test('provides Chinese translations for recently added features', () {
    final l10n = AppLocalizationsZh();

    expect(l10n.memoryInbox, '记忆收件箱');
    expect(l10n.dataBank, '资料库');
    expect(l10n.rpgScenarioEditor, 'RPG 剧本编辑器');
    expect(l10n.capabilityCheck, '功能检查');
    expect(l10n.mcpServers, 'MCP 服务器');
    expect(l10n.storageManagement, '存储管理');
    expect(l10n.live2dModelsCount(2), '2 个模型');
  });
}
