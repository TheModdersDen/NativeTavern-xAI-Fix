import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Uses a modal action sheet on iOS so transient parent rebuilds do not close
/// an open menu. Other platforms retain the standard anchored popup.
class AdaptivePopupMenuButton<T> extends StatelessWidget {
  const AdaptivePopupMenuButton({
    super.key,
    required this.itemBuilder,
    required this.onSelected,
    this.icon,
    this.tooltip,
    this.padding = const EdgeInsets.all(8),
    this.iconSize,
    this.enabled = true,
    this.useBottomSheet,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;
  final Widget? icon;
  final String? tooltip;
  final EdgeInsetsGeometry padding;
  final double? iconSize;
  final bool enabled;

  /// Primarily exposed for widget tests. Defaults to true on iOS/iPadOS.
  final bool? useBottomSheet;

  bool get _shouldUseBottomSheet =>
      useBottomSheet ?? defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    if (!_shouldUseBottomSheet) {
      return PopupMenuButton<T>(
        itemBuilder: itemBuilder,
        onSelected: onSelected,
        icon: icon,
        tooltip: tooltip,
        padding: padding,
        iconSize: iconSize,
        enabled: enabled,
      );
    }

    return IconButton(
      icon: icon ?? const Icon(Icons.more_vert),
      tooltip: tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
      padding: padding,
      iconSize: iconSize,
      onPressed: enabled ? () => _showActionSheet(context) : null,
    );
  }

  Future<void> _showActionSheet(BuildContext context) async {
    final value = await showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final entries = itemBuilder(sheetContext);
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: entries
                .map((entry) => _buildBottomSheetEntry(sheetContext, entry))
                .toList(),
          ),
        );
      },
    );
    if (value != null) onSelected(value);
  }

  Widget _buildBottomSheetEntry(
    BuildContext context,
    PopupMenuEntry<T> entry,
  ) {
    if (entry is PopupMenuDivider) {
      return Divider(height: entry.height);
    }
    if (entry is! PopupMenuItem<T>) return const SizedBox.shrink();

    final isChecked = entry is CheckedPopupMenuItem<T> && entry.checked;
    return InkWell(
      onTap: entry.enabled
          ? () {
              Navigator.pop(context, entry.value);
              entry.onTap?.call();
            }
          : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: entry.height),
        child: Padding(
          padding: entry.padding ??
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              if (entry is CheckedPopupMenuItem<T>) ...[
                SizedBox(
                  width: 32,
                  child: isChecked ? const Icon(Icons.check, size: 20) : null,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color:
                        entry.enabled ? null : Theme.of(context).disabledColor,
                  ),
                  child: entry.child ?? const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
