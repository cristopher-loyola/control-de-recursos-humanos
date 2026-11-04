import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AdminSection {
  const AdminSection({
    required this.label,
    required this.icon,
    required this.builder,
  });
  final String label;
  final IconData icon;
  final WidgetBuilder builder;
}

/// Las páginas que también se abren solas ocultan su barra superior cuando
/// se muestran dentro del contenedor administrativo.
class EmbeddedInShell extends InheritedWidget {
  const EmbeddedInShell({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EmbeddedInShell>() != null;

  @override
  bool updateShouldNotify(EmbeddedInShell oldWidget) => false;
}

/// Menú lateral fijo con las secciones, la cuenta activa y el regreso al
/// checador. En pantallas angostas el menú muestra solo íconos.
class AdminShell extends StatefulWidget {
  const AdminShell({
    super.key,
    required this.sections,
    required this.onExit,
    this.organizationName,
    this.accountName,
    this.roleLabel,
    this.initialIndex = 0,
  });
  final List<AdminSection> sections;
  final VoidCallback onExit;
  final String? organizationName;
  final String? accountName;
  final String? roleLabel;
  final int initialIndex;

  static AdminShellState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<AdminShellState>();

  @override
  State<AdminShell> createState() => AdminShellState();
}

class AdminShellState extends State<AdminShell> {
  late int _index = widget.initialIndex.clamp(0, widget.sections.length - 1);

  /// Cambia de sección; lo usan los accesos directos de Inicio.
  void show(String label) {
    final index = widget.sections.indexWhere((s) => s.label == label);
    if (index >= 0) setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 840;
    final section = widget.sections[_index];
    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Rail(
              compact: compact,
              sections: widget.sections,
              index: _index,
              onSelect: (index) => setState(() => _index = index),
              organizationName: widget.organizationName,
              accountName: widget.accountName,
              roleLabel: widget.roleLabel,
              onExit: widget.onExit,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 64,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: const BoxDecoration(
                      color: AppColors.surface,
                      border: Border(bottom: BorderSide(color: AppColors.line)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            section.label,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: widget.onExit,
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: const Text('Volver al checador'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: EmbeddedInShell(
                      child: KeyedSubtree(
                        key: ValueKey(section.label),
                        child: Builder(builder: section.builder),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.compact,
    required this.sections,
    required this.index,
    required this.onSelect,
    required this.onExit,
    this.organizationName,
    this.accountName,
    this.roleLabel,
  });
  final bool compact;
  final List<AdminSection> sections;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onExit;
  final String? organizationName;
  final String? accountName;
  final String? roleLabel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      width: compact ? 76 : 232,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 64,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 20),
              child: Align(
                alignment: compact ? Alignment.center : Alignment.centerLeft,
                child: compact
                    ? const Icon(Icons.apartment_outlined)
                    : Text(
                        organizationName ?? 'Control de RH',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium,
                      ),
              ),
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),
          for (var i = 0; i < sections.length; i++)
            _RailItem(
              compact: compact,
              section: sections[i],
              selected: i == index,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          const Divider(),
          Padding(
            padding: EdgeInsets.all(compact ? 8 : 16),
            child: Column(
              crossAxisAlignment: compact
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                if (!compact && accountName != null) ...[
                  Text(
                    accountName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (roleLabel != null)
                    Text(roleLabel!, style: text.bodySmall),
                  const SizedBox(height: 8),
                ],
                compact
                    ? IconButton(
                        tooltip: 'Salir',
                        onPressed: onExit,
                        icon: const Icon(Icons.logout),
                      )
                    : TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.muted,
                          padding: EdgeInsets.zero,
                          alignment: Alignment.centerLeft,
                        ),
                        onPressed: onExit,
                        icon: const Icon(Icons.logout, size: 18),
                        label: const Text('Salir'),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.compact,
    required this.section,
    required this.selected,
    required this.onTap,
  });
  final bool compact;
  final AdminSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.ink : AppColors.muted;
    final item = Material(
      color: selected ? AppColors.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: compact
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              if (!compact) const SizedBox(width: 12),
              Icon(section.icon, size: 20, color: color),
              if (!compact) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    section.label,
                    style: TextStyle(
                      color: color,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Semantics(
        selected: selected,
        button: true,
        child: compact ? Tooltip(message: section.label, child: item) : item,
      ),
    );
  }
}
