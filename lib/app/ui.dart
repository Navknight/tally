import 'package:flutter/material.dart';

import '../core/money.dart';
import '../models/categories.dart';
import 'theme.dart';

/// A run of content under a heading, with an optional action on the right.
/// Every screen uses this instead of a bare `Text` so the rhythm between
/// sections is set in one place.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.caption,
    this.action,
    this.onAction,
    this.top = 30,
  });

  final String title;
  final String? caption;
  final String? action;
  final VoidCallback? onAction;
  final double top;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(0, top, 0, caption == null ? 8 : 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleLarge),
                if (caption != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                    child: Text(caption!, style: text.bodySmall),
                  ),
              ],
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(action!),
            ),
        ],
      ),
    );
  }
}

/// The square-cornered category mark used on every ledger row: the category's
/// hue at low alpha behind its icon at full strength. A squircle rather than a
/// circle, so it belongs to the same family as the cards around it.
class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({super.key, required this.category, this.size = 42});

  final String category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(category);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Corners.tile),
      ),
      child: Icon(categoryIcon(category), size: size * 0.48, color: color),
    );
  }
}

/// A slot that has nothing in it yet: dashed outline, faint wash, one icon.
/// Borrowed from the Rituals day strip, where an unfilled day reads as a
/// waiting place rather than an error.
class DashedTile extends StatelessWidget {
  const DashedTile({
    super.key,
    required this.child,
    this.onTap,
    this.color,
    this.radius = Corners.card,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? color;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final line = color ?? Theme.of(context).colorScheme.outline;
    return CustomPaint(
      painter: _DashPainter(line, radius),
      child: Material(
        color: line.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Padding(
            padding: padding,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  const _DashPainter(this.color, this.radius);

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.7),
          Radius.circular(radius),
        ),
      );
    for (final metric in path.computeMetrics())
      for (var d = 0.0; d < metric.length; d += 9)
        canvas.drawPath(metric.extractPath(d, d + 4.5), paint);
  }

  @override
  bool shouldRepaint(_DashPainter old) =>
      old.color != color || old.radius != radius;
}

/// What a screen shows when it has nothing to show: a mark, a line that says
/// why, and the one action that would fix it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(36, 90, 36, 40),
      children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(icon, size: 30, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 20),
        Text(title, textAlign: TextAlign.center, style: text.titleLarge),
        const SizedBox(height: 6),
        Text(message, textAlign: TextAlign.center, style: text.bodySmall),
        if (action != null) ...[
          const SizedBox(height: 22),
          Center(
            child: OutlinedButton(onPressed: onAction, child: Text(action!)),
          ),
        ],
      ],
    );
  }
}

/// A money figure that counts to its new value instead of jumping. Used on
/// the few headline numbers only - a ledger row that animated every refresh
/// would be noise.
class AnimatedMoney extends StatelessWidget {
  const AnimatedMoney({
    super.key,
    required this.minor,
    required this.symbol,
    this.style,
    this.short = false,
  });

  final int minor;
  final String symbol;
  final TextStyle? style;
  final bool short;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: minor.toDouble()),
    duration: const Duration(milliseconds: 520),
    curve: Curves.easeOutCubic,
    builder: (context, value, _) => Text(
      short ? moneyShort(value.round(), symbol) : money(value.round(), symbol),
      maxLines: 1,
      style: style,
    ),
  );
}

/// The budget bar. [pace] draws the marker for an even spend across the
/// period, which is the whole point of the bar: the fill alone says how much
/// is gone, not whether that is early or late.
class PaceBar extends StatelessWidget {
  const PaceBar({
    super.key,
    required this.fraction,
    required this.pace,
    this.over = false,
    this.height = 16,
  });

  final double fraction;
  final double? pace;
  final bool over;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = over ? scheme.error : scheme.primary;
    final radius = BorderRadius.circular(height / 2);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: radius,
                border: Border.all(color: scheme.outlineVariant, width: 1),
              ),
              child: const SizedBox.expand(),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction.clamp(0, 1).toDouble()),
              duration: const Duration(milliseconds: 620),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => FractionallySizedBox(
                widthFactor: value == 0 ? 0.0001 : value,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: radius,
                    border: Border.all(color: lipOf(fill), width: 1),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            if (pace != null)
              Positioned(
                left: (constraints.maxWidth - 3) * pace!.clamp(0.0, 1.0),
                top: -4,
                bottom: -4,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: scheme.onSurface,
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: scheme.surface, width: 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The last seven days as a row of bars, after the Rituals day strip: it says
/// which days were heavy, which the period total on its own never can. The
/// column for today is the only one in the accent.
class SpendStrip extends StatelessWidget {
  const SpendStrip({
    super.key,
    required this.byDay,
    required this.symbol,
    this.days = 7,
    this.onTap,
  });

  /// Spend per day, keyed by midnight of that day.
  final Map<DateTime, int> byDay;
  final String symbol;
  final int days;
  final VoidCallback? onTap;

  static const _letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final window = [
      for (var i = days - 1; i >= 0; i--)
        DateTime(today.year, today.month, today.day - i),
    ];
    final amounts = [for (final d in window) byDay[d] ?? 0];
    final peak = amounts.fold<int>(0, (m, v) => v > m ? v : m);
    final busiest = peak == 0 ? null : money(peak, symbol);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Corners.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Last $days days', style: text.bodySmall),
                if (busiest != null)
                  Text('busiest day $busiest', style: text.bodySmall),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 88,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < window.length; i++)
                    Expanded(
                      child: _Column(
                        day: window[i],
                        amount: amounts[i],
                        peak: peak,
                        today: window[i] == today,
                        label: _letters[window[i].weekday - 1],
                        scheme: scheme,
                        style: text.labelSmall,
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

class _Column extends StatelessWidget {
  const _Column({
    required this.day,
    required this.amount,
    required this.peak,
    required this.today,
    required this.label,
    required this.scheme,
    required this.style,
  });

  final DateTime day;
  final int amount;
  final int peak;
  final bool today;
  final String label;
  final ColorScheme scheme;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    const track = 54.0;
    // A day with any spend at all keeps a visible stub, so an ordinary day
    // never reads as a day off.
    final height = peak == 0 || amount == 0
        ? 4.0
        : (6 + (track - 6) * (amount / peak)).toDouble();
    // Past days share the accent at low strength so the strip belongs to the
    // same colour family as the budget bar; only today is at full strength.
    final fill = amount == 0
        ? scheme.outlineVariant
        : today
        ? scheme.primary
        : scheme.primary.withValues(alpha: 0.30);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: height),
            duration: const Duration(milliseconds: 540),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => Container(
              height: value,
              // Capped so a bar stays taller than it is wide and reads as a
              // measurement rather than a block.
              constraints: const BoxConstraints(maxWidth: 26),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            style: style?.copyWith(
              height: 1.2,
              color: today ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
          Text(
            '${day.day}',
            style: style?.copyWith(
              height: 1.2,
              fontWeight: today ? FontWeight.w900 : FontWeight.w600,
              color: today ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Every category as a tappable chip. Labelling is the one thing the user
/// does over and over, so it is one tap on a visible target rather than a
/// dropdown that hides ten of the eleven options.
class CategoryPicker extends StatelessWidget {
  const CategoryPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final category in kCategories)
          Builder(
            builder: (context) {
              final color = categoryColor(category);
              final selected = category == value;
              return Material(
                color: selected
                    ? color.withValues(alpha: 0.16)
                    : scheme.surfaceContainerLowest,
                shape: StadiumBorder(
                  side: BorderSide(
                    color: selected ? color : scheme.outlineVariant,
                    width: 1.5,
                  ),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => onChanged(category),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(11, 8, 14, 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(categoryIcon(category), size: 15, color: color),
                        const SizedBox(width: 6),
                        Text(
                          category,
                          style: text.bodyMedium?.copyWith(
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
