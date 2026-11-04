import 'package:flutter/material.dart';

/// Una sola sección de asistencia: revisión de RH y registro manual.
class AttendanceSection extends StatelessWidget {
  const AttendanceSection({
    super.key,
    required this.review,
    required this.manual,
  });
  final WidgetBuilder review;
  final WidgetBuilder manual;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Material(
          color: Colors.white,
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            padding: EdgeInsets.symmetric(horizontal: 12),
            tabs: [
              Tab(text: 'Por revisar'),
              Tab(text: 'Registro manual'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            children: [
              Builder(builder: review),
              Builder(builder: manual),
            ],
          ),
        ),
      ],
    ),
  );
}
