import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/domain/models/tool_generation.dart';
import 'package:native_tavern/presentation/providers/tool_calling_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';

class ToolCallingSettingsScreen extends ConsumerWidget {
  const ToolCallingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(toolCallingSettingsProvider);
    final controller = ref.read(toolCallingSettingsProvider.notifier);
    final descriptors = ref.watch(builtInToolRegistryProvider).descriptors;
    return Scaffold(
      appBar: AppBar(title: const Text('Tool calling')),
      body: ListView(
        children: [
          SwitchListTile(
            key: const Key('tool-calling-master-toggle'),
            secondary: const Icon(Icons.build_outlined),
            title: const Text('Allow tool calling'),
            subtitle: const Text(
              'Providers may request only the tools enabled below',
            ),
            value: settings.enabled,
            onChanged: controller.setEnabled,
          ),
          const Divider(height: 24),
          const _SectionTitle('Built-in tools'),
          for (final descriptor in descriptors)
            CheckboxListTile(
              key: Key('built-in-tool-${descriptor.definition.name}'),
              secondary: Icon(_toolIcon(descriptor.definition.name)),
              title: Text(descriptor.definition.name),
              subtitle: Text(descriptor.definition.description),
              value: settings.enabledBuiltInTools.contains(
                descriptor.definition.name,
              ),
              onChanged: settings.enabled
                  ? (value) => controller.setBuiltInEnabled(
                        descriptor.definition.name,
                        value ?? false,
                      )
                  : null,
            ),
          ListTile(
            key: const Key('tool-calling-mcp-link'),
            leading: const Icon(Icons.extension_outlined),
            title: const Text('MCP tools'),
            subtitle: const Text(
              'Connected MCP servers use their individual permissions',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.mcpSettings),
          ),
          const Divider(height: 24),
          const _SectionTitle('Safety limits'),
          _LimitStepper(
            key: const Key('tool-round-limit'),
            icon: Icons.repeat,
            title: 'Tool rounds',
            value: settings.limits.maxToolRounds,
            minimum: 1,
            maximum: 16,
            onChanged: (value) => controller.setLimits(
              _limits(settings.limits, maxToolRounds: value),
            ),
          ),
          _LimitStepper(
            key: const Key('tool-call-limit'),
            icon: Icons.numbers,
            title: 'Calls per response',
            value: settings.limits.maxCalls,
            minimum: 1,
            maximum: 64,
            onChanged: (value) => controller.setLimits(
              _limits(settings.limits, maxCalls: value),
            ),
          ),
          _LimitStepper(
            key: const Key('tool-time-limit'),
            icon: Icons.timer_outlined,
            title: 'Time limit',
            suffix: 'seconds',
            value: settings.limits.maxElapsed.inSeconds,
            minimum: 5,
            maximum: 600,
            step: 5,
            onChanged: (value) => controller.setLimits(
              _limits(settings.limits, maxElapsedSeconds: value),
            ),
          ),
          _LimitStepper(
            key: const Key('tool-token-limit'),
            icon: Icons.token_outlined,
            title: 'Tool token budget',
            suffix: 'tokens',
            value: settings.limits.maxTokenBudget,
            minimum: 256,
            maximum: 65536,
            step: 256,
            onChanged: (value) => controller.setLimits(
              _limits(settings.limits, maxTokenBudget: value),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _LimitStepper extends StatelessWidget {
  const _LimitStepper({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.onChanged,
    this.step = 1,
    this.suffix,
  });

  final IconData icon;
  final String title;
  final int value;
  final int minimum;
  final int maximum;
  final int step;
  final String? suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(suffix == null ? '$value' : '$value $suffix'),
      trailing: SizedBox(
        width: 96,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              onPressed: value <= minimum
                  ? null
                  : () => onChanged((value - step).clamp(minimum, maximum)),
              icon: const Icon(Icons.remove),
              tooltip: 'Decrease $title',
            ),
            IconButton(
              onPressed: value >= maximum
                  ? null
                  : () => onChanged((value + step).clamp(minimum, maximum)),
              icon: const Icon(Icons.add),
              tooltip: 'Increase $title',
            ),
          ],
        ),
      ),
    );
  }
}

ToolLoopLimits _limits(
  ToolLoopLimits current, {
  int? maxToolRounds,
  int? maxCalls,
  int? maxElapsedSeconds,
  int? maxTokenBudget,
}) {
  return ToolLoopLimits(
    maxToolRounds: maxToolRounds ?? current.maxToolRounds,
    maxCalls: maxCalls ?? current.maxCalls,
    maxElapsed: Duration(
      seconds: maxElapsedSeconds ?? current.maxElapsed.inSeconds,
    ),
    maxTokenBudget: maxTokenBudget ?? current.maxTokenBudget,
  );
}

IconData _toolIcon(String name) => switch (name) {
      'generate_image' => Icons.image_outlined,
      'roll_dice' => Icons.casino_outlined,
      'read_variable' => Icons.data_object,
      'search_world_info' => Icons.manage_search,
      _ => Icons.build_outlined,
    };
