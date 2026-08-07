import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:native_tavern/domain/services/live2d_import_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/character_providers.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_character_view.dart';
import 'package:url_launcher/url_launcher.dart';

class Live2DSettingsScreen extends ConsumerWidget {
  final String characterId;

  const Live2DSettingsScreen({
    super.key,
    required this.characterId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return ref.watch(characterDetailProvider(characterId)).when(
          data: (character) {
            if (character == null) {
              return Scaffold(
                appBar: AppBar(title: const Text('Live2D')),
                body: Center(child: Text(l10n.characterNotFound)),
              );
            }
            return _Live2DSettingsEditor(
              key: ValueKey(character.id),
              character: character,
            );
          },
          loading: () => Scaffold(
            appBar: AppBar(title: const Text('Live2D')),
            body: const Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Scaffold(
            appBar: AppBar(title: const Text('Live2D')),
            body: Center(child: Text('${l10n.error}: $error')),
          ),
        );
  }
}

class _Live2DSettingsEditor extends ConsumerStatefulWidget {
  final Character character;

  const _Live2DSettingsEditor({
    super.key,
    required this.character,
  });

  @override
  ConsumerState<_Live2DSettingsEditor> createState() =>
      _Live2DSettingsEditorState();
}

class _Live2DSettingsEditorState extends ConsumerState<_Live2DSettingsEditor> {
  static const _noneModel = '__none__';
  late final Live2DService _service;
  late final Live2DImportService _importService;
  final Live2DCharacterController _previewController =
      Live2DCharacterController();

  List<Live2DModelDefinition> _availableModels =
      List.of(Live2DService.bundledModels);
  Live2DConfig? _config;
  Live2DModelManifest? _manifest;
  Live2DMotionRef? _selectedMotion;
  bool _isLoadingModel = false;
  bool _isImporting = false;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = ref.read(live2DServiceProvider);
    _importService = ref.read(live2DImportServiceProvider);
    _config = widget.character.assets?.live2d;
    _loadImportedModels();
    if (_config != null) _loadCurrentManifest();
  }

  Future<void> _loadImportedModels() async {
    try {
      final imported = await _importService.listImportedModels();
      if (!mounted) return;
      setState(() {
        _availableModels = [
          ...Live2DService.bundledModels,
          ...imported,
        ];
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Live2DModelDefinition? _definitionForConfig(Live2DConfig config) {
    for (final definition in Live2DService.bundledModels) {
      if (definition.id == config.modelId) return definition;
    }
    if (config.modelDirectory.isEmpty || config.modelFileName.isEmpty) {
      return null;
    }
    return Live2DModelDefinition(
      id: config.modelId,
      displayName: config.displayName,
      modelDirectory: config.modelDirectory,
      modelFileName: config.modelFileName,
      source: config.source,
    );
  }

  Future<void> _loadCurrentManifest() async {
    final config = _config;
    if (config == null) return;
    final definition = _definitionForConfig(config);
    if (definition == null) return;
    await _loadManifest(definition, replaceConfig: false);
  }

  Future<void> _selectModel(String id) async {
    if (id == _noneModel) {
      setState(() {
        _config = null;
        _manifest = null;
        _selectedMotion = null;
        _error = null;
      });
      return;
    }
    final definition = _availableModels.firstWhere((model) => model.id == id);
    await _loadManifest(definition, replaceConfig: true);
  }

  Future<void> _importZip() async {
    if (_isImporting) return;
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      final path = selection?.files.single.path;
      if (path == null || !mounted) return;
      setState(() {
        _isImporting = true;
        _error = null;
      });
      final imported = await _importService.importZip(File(path));
      if (!mounted) return;
      final allImported = await _importService.listImportedModels();
      if (!mounted) return;
      setState(() {
        _availableModels = [
          ...Live2DService.bundledModels,
          ...allImported,
        ];
      });
      if (imported.isNotEmpty) {
        await _loadManifest(imported.first, replaceConfig: true);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              imported.length == 1
                  ? 'Live2D model imported'
                  : '${imported.length} Live2D models imported',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _loadManifest(
    Live2DModelDefinition definition, {
    required bool replaceConfig,
  }) async {
    setState(() {
      _isLoadingModel = true;
      _error = null;
    });
    try {
      final manifest = await _service.loadManifest(definition);
      final missing = await _service.findMissingFiles(definition, manifest);
      if (missing.isNotEmpty) {
        throw FormatException('Missing model file: ${missing.first}');
      }
      if (!mounted) return;
      final previous = _config;
      var config = replaceConfig
          ? Live2DConfig.fromDefinition(definition, manifest)
          : previous!;
      if (replaceConfig && previous != null) {
        config = config.copyWith(
          enabled: previous.enabled,
          scale: previous.scale,
          offsetX: previous.offsetX,
          offsetY: previous.offsetY,
          opacity: previous.opacity,
          motionSpeed: previous.motionSpeed,
        );
      }
      setState(() {
        _config = config;
        _manifest = manifest;
        _selectedMotion = manifest.motions.firstOrNull;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isLoadingModel = false);
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final currentAssets = widget.character.assets;
      final assets = CharacterAssets(
        avatarPath: currentAssets?.avatarPath,
        avatarUrl: currentAssets?.avatarUrl,
        expressionPack: currentAssets?.expressionPack,
        live2d: _config,
      );
      final updated = widget.character.copyWith(
        assets: assets.hasAssets ? assets : null,
        clearAssets: !assets.hasAssets,
        modifiedAt: DateTime.now(),
      );
      await ref.read(characterRepositoryProvider).updateCharacter(updated);
      ref.invalidate(characterDetailProvider(widget.character.id));
      await ref.read(characterListProvider.notifier).refresh();

      final activeChat = ref.read(activeChatProvider);
      if (activeChat.character?.id == widget.character.id &&
          activeChat.chat != null) {
        await ref
            .read(activeChatProvider.notifier)
            .loadChat(activeChat.chat!.id);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _showLicenseNotice() async {
    final openTerms = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Live2D licensing'),
        content: const Text(
          'The renderer includes the Live2D Cubism SDK and Core. Model files '
          'and commercial distribution may have separate terms.\n\n'
          'The bundled Hiyori Momose model is official sample data owned and '
          'copyrighted by Live2D Inc. It is used under the Live2D Free '
          'Material License Agreement and Sample Data Terms of Use. This app '
          'itself is created at the author\'s sole discretion.\n\n'
          'Verify the rights for every imported model before publishing the '
          'app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Review terms'),
          ),
        ],
      ),
    );
    if (openTerms == true) {
      await launchUrl(
        Uri.parse('https://www.live2d.com/en/learn/sample/model-terms/'),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final config = _config;
    final selectedModelId = config == null ? _noneModel : config.modelId;
    final availableIds = _availableModels.map((m) => m.id).toSet();
    final hasCustomModel =
        config != null && !availableIds.contains(config.modelId);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.character.name} Live2D'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Live2D licensing',
            onPressed: _showLicenseNotice,
          ),
          IconButton(
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            tooltip: l10n.save,
            onPressed: _isSaving ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.animation),
            title: const Text('Live2D'),
            value: config?.enabled ?? false,
            onChanged: config == null
                ? null
                : (value) => setState(() {
                      _config = config.copyWith(enabled: value);
                    }),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: DropdownButtonFormField<String>(
              initialValue: selectedModelId,
              decoration: const InputDecoration(
                labelText: 'Model',
                border: OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: _noneModel,
                  child: Text(l10n.none),
                ),
                if (hasCustomModel)
                  DropdownMenuItem(
                    value: config.modelId,
                    child: Text(config.displayName),
                  ),
                ..._availableModels.map(
                  (model) => DropdownMenuItem(
                    value: model.id,
                    child: Text(
                      model.source == Live2DModelSource.asset
                          ? model.displayName
                          : '${model.displayName} (Imported)',
                    ),
                  ),
                ),
              ],
              onChanged: _isLoadingModel || _isImporting
                  ? null
                  : (value) {
                      if (value != null) _selectModel(value);
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                icon: _isImporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.archive_outlined),
                label: const Text('Import ZIP'),
                onPressed: _isImporting ? null : _importZip,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_isLoadingModel)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (config != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: math.min(MediaQuery.sizeOf(context).width, 420),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  border: Border.all(
                    color: Theme.of(context).dividerColor,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Live2DCharacterView(
                  key: ValueKey(
                    '${config.modelDirectory}/${config.modelFileName}',
                  ),
                  config: config.copyWith(enabled: true),
                  controller: _previewController,
                  showStatus: true,
                  interactive: true,
                  onTransformChanged: (transform) => setState(
                    () => _config = config.copyWith(
                      scale: transform.scale,
                      offsetX: transform.offsetX,
                      offsetY: transform.offsetY,
                    ),
                  ),
                ),
              ),
            ),
            if (_manifest?.motions.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<Live2DMotionRef>(
                        initialValue: _selectedMotion,
                        decoration: const InputDecoration(
                          labelText: 'Motion',
                          border: OutlineInputBorder(),
                        ),
                        items: _manifest!.motions
                            .map(
                              (motion) => DropdownMenuItem(
                                value: motion,
                                child: Text(
                                  motion.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (motion) =>
                            setState(() => _selectedMotion = motion),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: const Icon(Icons.play_arrow),
                      tooltip: 'Play motion',
                      onPressed: _selectedMotion == null
                          ? null
                          : () => _previewController.playMotion(
                                _selectedMotion,
                                priority: 3,
                              ),
                    ),
                  ],
                ),
              ),
            ExpansionTile(
              leading: const Icon(Icons.tune),
              title: const Text('Stage adjustment'),
              children: [
                _SliderTile(
                  label: 'Opacity',
                  value: config.opacity,
                  min: 0.3,
                  max: 1,
                  onChanged: (value) => setState(
                    () => _config = config.copyWith(opacity: value),
                  ),
                ),
                _SliderTile(
                  label: 'Motion speed',
                  value: config.motionSpeed,
                  min: 0.5,
                  max: 1.5,
                  onChanged: (value) => setState(
                    () => _config = config.copyWith(motionSpeed: value),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value.toStringAsFixed(2)),
        ],
      ),
      subtitle: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
