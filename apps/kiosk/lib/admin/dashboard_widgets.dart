import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Colores de un estado de asistencia: fuerte para el dato, tinte para el fondo.
typedef Tone = ({Color strong, Color tint});
const Tone toneOnTime = (strong: AppColors.onTime, tint: AppColors.onTimeTint);
const Tone toneLate = (strong: AppColors.late, tint: AppColors.lateTint);
const Tone toneAbsent = (strong: AppColors.absent, tint: AppColors.absentTint);
const Tone toneInfo = (strong: AppColors.info, tint: AppColors.infoTint);
const Tone toneNeutral = (strong: AppColors.muted, tint: AppColors.selected);

class RoundIcon extends StatelessWidget {
  const RoundIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: AppColors.surface,
      shape: const CircleBorder(side: BorderSide(color: AppColors.line)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 22,
            color: onTap == null ? AppColors.line : AppColors.ink,
          ),
        ),
      ),
    ),
  );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.line),
      borderRadius: BorderRadius.circular(10),
    ),
    child: child,
  );
}

class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.tone,
    required this.icon,
    required this.label,
    required this.value,
    this.caption,
    this.progress,
    this.onTap,
  });
  final Tone tone;
  final IconData icon;
  final String label;
  final String value;
  final String? caption;
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final zero = value == '0' || value == '—';
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: tone.tint,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 18, color: tone.strong),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: AppColors.muted),
                    ),
                  ),
                  if (onTap != null)
                    const Icon(
                      Icons.arrow_forward,
                      size: 18,
                      color: AppColors.info,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.6, end: 1),
                duration: const Duration(milliseconds: 260),
                key: ValueKey(value),
                builder: (context, t, child) =>
                    Opacity(opacity: t, child: child),
                child: Text(
                  value,
                  style: text.headlineMedium?.copyWith(
                    fontSize: 32,
                    color: zero ? AppColors.ink : tone.strong,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (progress != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: progress!.clamp(0, 1)),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => LinearProgressIndicator(
                      value: v,
                      minHeight: 6,
                      backgroundColor: AppColors.selected,
                      color: v >= 0.9
                          ? AppColors.onTime
                          : v >= 0.7
                          ? AppColors.late
                          : AppColors.absent,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                caption ?? ' ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  color: onTap != null ? AppColors.info : AppColors.muted,
                  fontWeight: onTap != null ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PersonIdentity extends StatelessWidget {
  const PersonIdentity({
    super.key,
    required this.name,
    this.department,
    required this.tone,
  });
  final String name;
  final String? department;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
    return Row(
      children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: tone.tint,
          child: Text(
            initials,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: tone.strong,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (department != null)
                Text(
                  department!,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.text, required this.tone});
  final String text;
  final Tone tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: tone.tint,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: tone.strong,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

/// Barra con la proporción de días a tiempo, tarde y faltas del periodo.
