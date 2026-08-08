// File selection and exports are user-triggered and intentionally asynchronous.
// ignore_for_file: avoid_slow_async_io

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/domain/services/rpg_scenario_draft_store.dart';
import 'package:native_tavern/domain/services/rpg_scenario_package_service.dart';
import 'package:native_tavern/presentation/controllers/rpg_scenario_editor_controller.dart';

class RpgScenarioFileData {
  final String name;
  final Uint8List bytes;

  const RpgScenarioFileData({required this.name, required this.bytes});
}

abstract class RpgScenarioFileGateway {
  Future<RpgScenarioFileData?> pickScenario();

  Future<String?> saveScenario({
    required String suggestedName,
    required String content,
    required RpgScenarioPackageFormat format,
  });
}

class PlatformRpgScenarioFileGateway implements RpgScenarioFileGateway {
  const PlatformRpgScenarioFileGateway();

  @override
  Future<RpgScenarioFileData?> pickScenario() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: RpgScenarioPackageService.supportedExtensions,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final selected = result.files.single;
    if (selected.size > const RpgScenarioPackageLimits().maxBytes) {
      throw const FileSystemException(
        'The selected scenario exceeds the 2 MiB import limit.',
      );
    }
    final bytes = selected.bytes ??
        (selected.path == null
            ? null
            : await File(selected.path!).readAsBytes());
    if (bytes == null) {
      throw const FileSystemException(
          'The selected scenario could not be read.');
    }
    return RpgScenarioFileData(name: selected.name, bytes: bytes);
  }

  @override
  Future<String?> saveScenario({
    required String suggestedName,
    required String content,
    required RpgScenarioPackageFormat format,
  }) async {
    final extension = format == RpgScenarioPackageFormat.json ? 'json' : 'yaml';
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export RPG Scenario',
      fileName: '$suggestedName.$extension',
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (result == null) return null;
    await File(result).writeAsString(content, flush: true);
    return result;
  }
}

class RpgScenarioEditorScreen extends StatefulWidget {
  final RpgScenarioEditorController? controller;
  final RpgScenarioDraftStore? draftStore;
  final RpgScenarioFileGateway fileGateway;

  const RpgScenarioEditorScreen({
    super.key,
    this.controller,
    this.draftStore,
    this.fileGateway = const PlatformRpgScenarioFileGateway(),
  });

  @override
  State<RpgScenarioEditorScreen> createState() =>
      _RpgScenarioEditorScreenState();
}

class _RpgScenarioEditorScreenState extends State<RpgScenarioEditorScreen>
    with SingleTickerProviderStateMixin {
  late final RpgScenarioEditorController _controller;
  late final TabController _tabs;
  late final bool _ownsController;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ??
        RpgScenarioEditorController(draftStore: widget.draftStore);
    if (widget.draftStore != null) {
      _controller.configureDraftStore(widget.draftStore!);
    }
    _controller.addListener(_refresh);
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _controller.removeListener(_refresh);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_controller.isDirty ? 'RPG Scenario *' : 'RPG Scenario'),
        actions: [
          IconButton(
            key: const Key('rpg-import'),
            tooltip: 'Import scenario',
            onPressed: _working ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
          ),
          IconButton(
            key: const Key('rpg-save-draft'),
            tooltip: 'Save draft',
            onPressed: _working ? null : _saveDraft,
            icon: const Icon(Icons.save_outlined),
          ),
          IconButton(
            key: const Key('rpg-load-draft'),
            tooltip: 'Restore draft',
            onPressed: _working ? null : _loadDraft,
            icon: const Icon(Icons.history),
          ),
          PopupMenuButton<RpgScenarioPackageFormat>(
            tooltip: 'Export scenario',
            icon: const Icon(Icons.file_upload_outlined),
            enabled: !_working && _controller.isValid,
            onSelected: _export,
            itemBuilder: (context) => const [
              PopupMenuItem(
                key: Key('rpg-export-json'),
                value: RpgScenarioPackageFormat.json,
                child: Text('JSON'),
              ),
              PopupMenuItem(
                key: Key('rpg-export-yaml'),
                value: RpgScenarioPackageFormat.yaml,
                child: Text('YAML'),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            const Tab(key: Key('rpg-tab-edit'), text: 'Edit'),
            const Tab(key: Key('rpg-tab-preview'), text: 'Preview'),
            Tab(
              key: const Key('rpg-tab-issues'),
              text: _controller.issues.isEmpty
                  ? 'Issues'
                  : 'Issues (${_controller.issues.length})',
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabs,
            children: [
              _DocumentEditor(controller: _controller),
              _PreviewPane(source: _controller.preview()),
              _IssuesPane(issues: _controller.issues),
            ],
          ),
          if (_working)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _import() async {
    await _run(() async {
      final selected = await widget.fileGateway.pickScenario();
      if (selected == null) return;
      final result = await _controller.importBytesAsync(
        selected.bytes,
        fileName: selected.name,
      );
      if (!result.isValid) {
        _tabs.animateTo(2);
        _showMessage('Scenario import failed');
      } else {
        _tabs.animateTo(0);
        _showMessage('Imported ${result.scenario!.metadata.name}');
      }
    });
  }

  Future<void> _saveDraft() async {
    await _run(() async {
      await _ensureDraftStore();
      await _controller.saveDraft();
      _showMessage('Draft saved');
    });
  }

  Future<void> _loadDraft() async {
    await _run(() async {
      await _ensureDraftStore();
      final restored = await _controller.loadDraft();
      _showMessage(restored ? 'Draft restored' : 'No saved draft');
      if (restored) _tabs.animateTo(0);
    });
  }

  Future<void> _export(RpgScenarioPackageFormat format) async {
    await _run(() async {
      final scenario = _controller.scenario!;
      final result = await widget.fileGateway.saveScenario(
        suggestedName: scenario.metadata.id,
        content: _controller.export(format: format),
        format: format,
      );
      if (result != null) _showMessage('Scenario exported');
    });
  }

  Future<void> _ensureDraftStore() async {
    if (_controller.draftStore != null) return;
    _controller.configureDraftStore(
      await FileRpgScenarioDraftStore.forApplicationSupport(),
    );
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await operation();
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DocumentEditor extends StatelessWidget {
  final RpgScenarioEditorController controller;

  const _DocumentEditor({required this.controller});

  @override
  Widget build(BuildContext context) {
    final entries = controller.document.entries.toList();
    return ListView.separated(
      key: const PageStorageKey('rpg-document-editor'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final path = RpgEditorPath([entry.key]);
        return _NodeEditor(
          key: ValueKey(path.key),
          controller: controller,
          path: path,
          label: _labelFor(entry.key),
          value: entry.value,
          initiallyExpanded: entry.key == 'metadata',
        );
      },
    );
  }
}

class _NodeEditor extends StatelessWidget {
  final RpgScenarioEditorController controller;
  final RpgEditorPath path;
  final String label;
  final Object? value;
  final bool initiallyExpanded;
  final Widget? trailing;

  const _NodeEditor({
    super.key,
    required this.controller,
    required this.path,
    required this.label,
    required this.value,
    this.initiallyExpanded = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    if (value is Map<String, dynamic>) {
      if (_isOpenMap(path)) {
        return _OpenMapEditor(
          controller: controller,
          path: path,
          label: label,
          value: value! as Map<String, dynamic>,
          initiallyExpanded: initiallyExpanded,
          trailing: trailing,
        );
      }
      final map = value! as Map<String, dynamic>;
      return ExpansionTile(
        key: PageStorageKey(path.key),
        initiallyExpanded: initiallyExpanded,
        title: Text(label),
        subtitle: _objectSubtitle(map),
        trailing: trailing,
        children: map.entries.map((entry) {
          final childPath = path.child(entry.key);
          return Padding(
            padding: const EdgeInsets.only(left: 16),
            child: _NodeEditor(
              key: ValueKey(childPath.key),
              controller: controller,
              path: childPath,
              label: _labelFor(entry.key),
              value: entry.value,
            ),
          );
        }).toList(),
      );
    }
    if (value is List<dynamic>) {
      return _ListEditor(
        controller: controller,
        path: path,
        label: label,
        value: value! as List<dynamic>,
        initiallyExpanded: initiallyExpanded,
        trailing: trailing,
      );
    }
    if (value == null) {
      return ListTile(
        title: Text(label),
        subtitle: _issueText(controller, path),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: Key('rpg-set-${path.key}'),
              tooltip: 'Set value',
              onPressed: () => controller.initializeOptional(path),
              icon: const Icon(Icons.add_circle_outline),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
    }
    return _ScalarEditor(
      controller: controller,
      path: path,
      label: label,
      value: value!,
      trailing: trailing,
    );
  }
}

class _ListEditor extends StatelessWidget {
  final RpgScenarioEditorController controller;
  final RpgEditorPath path;
  final String label;
  final List<dynamic> value;
  final bool initiallyExpanded;
  final Widget? trailing;

  const _ListEditor({
    required this.controller,
    required this.path,
    required this.label,
    required this.value,
    required this.initiallyExpanded,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      key: PageStorageKey(path.key),
      initiallyExpanded: initiallyExpanded,
      title: Text(label),
      subtitle: Text('${value.length}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('rpg-add-${path.key}'),
            tooltip: 'Add ${label.toLowerCase()}',
            onPressed: () => controller.addListItem(path),
            icon: const Icon(Icons.add),
          ),
          if (trailing != null) trailing!,
        ],
      ),
      children: [
        for (var index = 0; index < value.length; index++)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: _NodeEditor(
              key: ValueKey('${path.key}/$index'),
              controller: controller,
              path: path.child(index),
              label: _itemLabel(value[index], index),
              value: value[index],
              trailing: _ListItemActions(
                onMoveUp: index == 0
                    ? null
                    : () => controller.moveListItem(path, index, index - 1),
                onMoveDown: index == value.length - 1
                    ? null
                    : () => controller.moveListItem(path, index, index + 1),
                onDelete: () => controller.removeListItem(path, index),
              ),
            ),
          ),
      ],
    );
  }
}

class _ListItemActions extends StatelessWidget {
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onDelete;

  const _ListItemActions({
    this.onMoveUp,
    this.onMoveDown,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Item actions',
      onSelected: (value) {
        if (value == 'up') onMoveUp?.call();
        if (value == 'down') onMoveDown?.call();
        if (value == 'delete') onDelete();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
            value: 'up',
            enabled: onMoveUp != null,
            child: const Text('Move up')),
        PopupMenuItem(
            value: 'down',
            enabled: onMoveDown != null,
            child: const Text('Move down')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }
}

class _OpenMapEditor extends StatelessWidget {
  final RpgScenarioEditorController controller;
  final RpgEditorPath path;
  final String label;
  final Map<String, dynamic> value;
  final bool initiallyExpanded;
  final Widget? trailing;

  const _OpenMapEditor({
    required this.controller,
    required this.path,
    required this.label,
    required this.value,
    required this.initiallyExpanded,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      key: PageStorageKey(path.key),
      initiallyExpanded: initiallyExpanded,
      title: Text(label),
      subtitle: Text('${value.length}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('rpg-add-map-${path.key}'),
            tooltip: 'Add entry',
            onPressed: () => _addEntry(context),
            icon: const Icon(Icons.add),
          ),
          if (trailing != null) trailing!,
        ],
      ),
      children: value.entries.map((entry) {
        final childPath = path.child(entry.key);
        return Padding(
          padding: const EdgeInsets.only(left: 16),
          child: _NodeEditor(
            key: ValueKey(childPath.key),
            controller: controller,
            path: childPath,
            label: entry.key,
            value: entry.value,
            trailing: IconButton(
              tooltip: 'Delete entry',
              onPressed: () => controller.removeMapEntry(path, entry.key),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _addEntry(BuildContext context) async {
    final keyController = TextEditingController();
    final valueController = TextEditingController();
    final result = await showDialog<(String, Object?)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add $label entry'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('rpg-map-entry-key'),
              controller: keyController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              key: const Key('rpg-map-entry-value'),
              controller: valueController,
              decoration: const InputDecoration(labelText: 'Value'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final key = keyController.text.trim();
              if (key.isEmpty) return;
              Navigator.pop(
                context,
                (key, _parseLooseValue(valueController.text)),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    keyController.dispose();
    valueController.dispose();
    if (result != null) controller.setMapEntry(path, result.$1, result.$2);
  }
}

class _ScalarEditor extends StatefulWidget {
  final RpgScenarioEditorController controller;
  final RpgEditorPath path;
  final String label;
  final Object value;
  final Widget? trailing;

  const _ScalarEditor({
    required this.controller,
    required this.path,
    required this.label,
    required this.value,
    this.trailing,
  });

  @override
  State<_ScalarEditor> createState() => _ScalarEditorState();
}

class _ScalarEditorState extends State<_ScalarEditor> {
  late final TextEditingController _text;
  late final FocusNode _focus;
  String? _localError;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: '${widget.value}');
    _focus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _ScalarEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = '${widget.value}';
    if (!_focus.hasFocus && _text.text != next) _text.text = next;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enumValues = _enumValues(widget.path);
    if (enumValues != null) {
      return ListTile(
        title: DropdownButtonFormField<String>(
          key: Key('rpg-field-${widget.path.key}'),
          initialValue: widget.value as String,
          decoration: InputDecoration(
            labelText: widget.label,
            errorText: _issueMessage(widget.controller, widget.path),
          ),
          items: enumValues
              .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)))
              .toList(),
          onChanged: (value) {
            if (value != null) widget.controller.update(widget.path, value);
          },
        ),
        trailing: widget.trailing,
      );
    }
    if (widget.value is bool) {
      return SwitchListTile(
        key: Key('rpg-field-${widget.path.key}'),
        title: Text(widget.label),
        subtitle: _issueText(widget.controller, widget.path),
        value: widget.value as bool,
        onChanged: (value) => widget.controller.update(widget.path, value),
        secondary: widget.trailing,
      );
    }
    return ListTile(
      title: TextField(
        key: Key('rpg-field-${widget.path.key}'),
        controller: _text,
        focusNode: _focus,
        maxLines: _isLongText(widget.path) ? 3 : 1,
        keyboardType: widget.value is num
            ? const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              )
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: widget.label,
          errorText:
              _localError ?? _issueMessage(widget.controller, widget.path),
        ),
        onChanged: _updateText,
      ),
      trailing: widget.trailing,
    );
  }

  void _updateText(String value) {
    if (widget.value is int) {
      final parsed = int.tryParse(value);
      setState(() => _localError = parsed == null ? 'Enter an integer' : null);
      if (parsed != null) widget.controller.update(widget.path, parsed);
    } else if (widget.value is num) {
      final parsed = num.tryParse(value);
      setState(() => _localError = parsed == null ? 'Enter a number' : null);
      if (parsed != null) widget.controller.update(widget.path, parsed);
    } else {
      widget.controller.update(widget.path, value);
    }
  }
}

class _PreviewPane extends StatelessWidget {
  final String source;

  const _PreviewPane({required this.source});

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          source,
          key: const Key('rpg-preview-source'),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ),
    );
  }
}

class _IssuesPane extends StatelessWidget {
  final List<RpgScenarioPackageIssue> issues;

  const _IssuesPane({required this.issues});

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) {
      return const Center(
        child: Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: issues.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final issue = issues[index];
        return ListTile(
          leading: const Icon(Icons.error_outline, color: Colors.red),
          title: Text(issue.path),
          subtitle: Text('${issue.message}\n${issue.code}'),
          isThreeLine: true,
        );
      },
    );
  }
}

bool _isOpenMap(RpgEditorPath path) {
  const paths = {
    '/initialState/attributes',
    '/initialState/variables',
    '/initialState/cooldowns',
  };
  return paths.contains(path.normalized) ||
      path.normalized.endsWith('/metadata') ||
      path.normalized.endsWith('/data') ||
      path.normalized.endsWith('/objectiveProgress');
}

List<String>? _enumValues(RpgEditorPath path) {
  final normalized = path.normalized;
  if (normalized.endsWith('/operator')) {
    return RpgConditionOperator.values.map((value) => value.name).toList();
  }
  if (normalized.contains('Effects/*/type') ||
      normalized.endsWith('/effects/*/type')) {
    return RpgEffectType.values.map((value) => value.name).toList();
  }
  if (normalized == '/initialState/quests/*/status') {
    return RpgQuestStatus.values.map((value) => value.name).toList();
  }
  return null;
}

bool _isLongText(RpgEditorPath path) {
  final field = path.segments.lastOrNull;
  return field == 'description' || field == 'summary';
}

Widget? _objectSubtitle(Map<String, dynamic> value) {
  final text = value['label'] ?? value['name'] ?? value['id'];
  return text is String && text.isNotEmpty ? Text(text) : null;
}

String _itemLabel(Object? value, int index) {
  if (value is Map<String, dynamic>) {
    final text = value['label'] ?? value['name'] ?? value['id'];
    if (text is String && text.isNotEmpty) return text;
  }
  return 'Item ${index + 1}';
}

String _labelFor(String key) {
  const overrides = {
    'metadata': 'Metadata',
    'compatibility': 'Compatibility',
    'initialState': 'Initial State',
    'initialSeed': 'Initial Seed',
    'schemaVersion': 'Schema Version',
    'protectedFields': 'Protected Fields',
  };
  if (overrides[key] case final value?) return value;
  final spaced = key.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match.group(1)} ${match.group(2)}',
  );
  return spaced[0].toUpperCase() + spaced.substring(1);
}

Object? _parseLooseValue(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return '';
  try {
    return jsonDecode(trimmed);
  } on FormatException {
    return input;
  }
}

Widget? _issueText(
  RpgScenarioEditorController controller,
  RpgEditorPath path,
) {
  final message = _issueMessage(controller, path);
  return message == null ? null : Text(message);
}

String? _issueMessage(
  RpgScenarioEditorController controller,
  RpgEditorPath path,
) {
  for (final issue in controller.issues) {
    final issuePath = issue.path.startsWith(r'$package')
        ? issue.path
        : r'$package.' + issue.path;
    if (issuePath == path.display) return issue.message;
  }
  return null;
}

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
