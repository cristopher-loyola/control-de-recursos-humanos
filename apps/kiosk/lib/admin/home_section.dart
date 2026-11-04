import 'package:flutter/material.dart';

import '../attendance/attendance_store.dart';
import '../employees/employee_store.dart';
import '../theme/app_theme.dart';
import 'admin_shell.dart';

/// Resumen del día: lo que hay que atender, con un acceso directo a cada cosa.
class HomeSection extends StatefulWidget {
  const HomeSection({
    super.key,
    required this.employees,
    required this.attendance,
    required this.pendingReviews,
  });
  final EmployeeStore employees;
  final AttendanceStore attendance;
  final Future<int> Function() pendingReviews;

  @override
  State<HomeSection> createState() => _HomeSectionState();
}

class _Summary {
  const _Summary(this.checkedToday, this.pending, this.withoutFace, this.total);
  final int? checkedToday;
  final int? pending;
  final int? withoutFace;
  final int? total;
}

class _HomeSectionState extends State<HomeSection> {
  late Future<_Summary> _summary = _load();

  Future<_Summary> _load() async {
    Future<T?> safe<T>(Future<T> Function() read) async {
      try {
        return await read();
      } catch (_) {
        return null;
      }
    }

    final employees = await safe(widget.employees.list);
    final today = await safe(() => widget.attendance.forDay(DateTime.now()));
    final pending = await safe(widget.pendingReviews);
    return _Summary(
      today?.map((event) => event.employeeNumber).toSet().length,
      pending,
      employees?.where((employee) => !employee.hasFace).length,
      employees?.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = AdminShell.maybeOf(context);
    final now = DateTime.now();
    const months = [
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre',
    ];
    return RefreshIndicator(
      onRefresh: () async {
        final next = _load();
        setState(() => _summary = next);
        await next;
      },
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Hoy, ${now.day} de ${months[now.month - 1]}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 20),
          FutureBuilder<_Summary>(
            future: _summary,
            builder: (context, snapshot) {
              final data = snapshot.data;
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  children: [
                    _Row(
                      value: data?.pending,
                      label: 'Checadas por revisar',
                      action: 'Revisar',
                      onAction: () => shell?.show('Asistencia'),
                    ),
                    const Divider(),
                    _Row(
                      value: data?.checkedToday,
                      label: 'Personas que checaron hoy',
                      action: 'Ver registro',
                      onAction: () => shell?.show('Asistencia'),
                    ),
                    const Divider(),
                    _Row(
                      value: data?.withoutFace,
                      label: data?.total == null
                          ? 'Empleados sin rostro registrado'
                          : 'Empleados sin rostro registrado, de ${data!.total}',
                      action: 'Ir a empleados',
                      onAction: () => shell?.show('Empleados'),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => shell?.show('Empleados'),
              icon: const Icon(Icons.person_add_alt, size: 20),
              label: const Text('Dar de alta un empleado'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.value,
    required this.label,
    required this.action,
    required this.onAction,
  });
  final int? value;
  final String label;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    child: Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            value?.toString() ?? '—',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        Expanded(child: Text(label)),
        TextButton(onPressed: onAction, child: Text(action)),
      ],
    ),
  );
}
