import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class SettingsEntry {
  const SettingsEntry({
    required this.title,
    required this.description,
    required this.icon,
    required this.onOpen,
  });
  final String title;
  final String description;
  final IconData icon;
  final Future<void> Function() onOpen;
}

class SettingsGroup {
  const SettingsGroup(this.title, this.entries);
  final String title;
  final List<SettingsEntry> entries;
}

/// Tareas poco frecuentes del administrador, agrupadas por tema.
class SettingsSection extends StatefulWidget {
  const SettingsSection({super.key, required this.groups});
  final List<SettingsGroup> groups;

  @override
  State<SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<SettingsSection> {
  bool _busy = false;
  String? _error;

  Future<void> _open(SettingsEntry entry) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await entry.onOpen();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'No se pudo abrir "${entry.title}". Vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        for (final group in widget.groups) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Text(
              group.title.toUpperCase(),
              style: text.bodySmall?.copyWith(
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              children: [
                for (var i = 0; i < group.entries.length; i++) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    enabled: !_busy,
                    leading: Icon(group.entries[i].icon),
                    title: Text(group.entries[i].title),
                    subtitle: Text(
                      group.entries[i].description,
                      style: text.bodySmall,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(group.entries[i]),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ],
    );
  }
}
