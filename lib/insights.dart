import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'app/theme.dart';
import 'app/ui.dart';
import 'core/budget_period.dart';
import 'core/money.dart';
import 'main.dart'
    show
        PageBottomGap,
        PageColumn,
        TallyPage,
        TransactionTile,
        showTransactionSheet;
import 'state/app_state.dart';
import 'models/categories.dart';

/// Where the period's money went: a ring with the total in the middle, the
/// categories under it as share bars, the same period day by day, and finally
/// the rows the budget actually counted.
class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key, required this.onOpenActivity});

  /// Drilling into a slice narrows the ledger and shows it, rather than
  /// building a second, slightly different list here.
  final VoidCallback onOpenActivity;

  Future<void> _drillInto(String category) async {
    await appState.setFilter(
      appState.filter.copyWith(category: category, text: ''),
    );
    onOpenActivity();
  }

  @override
  Widget build(BuildContext context) => TallyPage(
    title: 'Insights',
    slivers: (context, state) {
      final byCategory = state.byCategory;
      final total = byCategory.fold<int>(0, (sum, e) => sum + e.$2);
      if (total == 0)
        return [
          PageColumn(
            children: [
              const _ScopeBar(),
              const SizedBox(height: 40),
              EmptyState(
                icon: Icons.donut_small_outlined,
                title: 'Nothing to chart here',
                message: state.insightsBudgetedOnly
                    ? 'No budgeted spending in this range. Try All time, or '
                          'switch to every account.'
                    : 'No spending in this range yet.',
                embedded: true,
              ),
            ],
          ),
        ];
      final period = state.insightsPeriod;
      final symbol = state.symbol;
      final elapsed = DateTime.now().difference(period.start).inDays + 1;
      final counted = state.budgetRows;
      // A CustomScrollView, not a ListView: the counted rows can run to two
      // hundred, and a plain ListView would build every one of them before it
      // could paint the chart above.
      return [
        PageColumn(
          children: [
            const _ScopeBar(),
            const SizedBox(height: 14),
            RepaintBoundary(
              child: _Panel(
                child: Column(
                  children: [
                    SizedBox(
                      height: 210,
                      child: _CategoryDonut(
                        byCategory: byCategory,
                        total: total,
                        symbol: symbol,
                        onTap: _drillInto,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: _Stat(
                            label: 'A day so far',
                            value: moneyShort(
                              elapsed <= 0 ? total : total ~/ elapsed,
                              symbol,
                            ),
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 30,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        Expanded(
                          child: _Stat(
                            label: 'Biggest slice',
                            value: byCategory.first.$1,
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 30,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        Expanded(
                          child: _Stat(
                            label: 'Came in',
                            value: moneyShort(state.periodIncome, symbol),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SectionHeading(title: 'By category'),
            _Panel(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Column(
                children: [
                  for (final e in byCategory)
                    _CategoryBar(
                      category: e.$1,
                      amountMinor: e.$2,
                      share: e.$2 / total,
                      symbol: symbol,
                      onTap: () => _drillInto(e.$1),
                    ),
                ],
              ),
            ),
            SectionHeading(
              title: 'Day by day',
              caption: state.hasBudget
                  ? '${_dm(period.start)} to '
                        '${_dm(period.end.subtract(const Duration(days: 1)))} · '
                        'dashed line is an even '
                        '${moneyShort(state.budgetMinor ~/ _days(period), symbol)} a day'
                  : '${_dm(period.start)} to '
                        '${_dm(period.end.subtract(const Duration(days: 1)))}',
            ),
            RepaintBoundary(
              child: _Panel(
                child: SizedBox(
                  height: 200,
                  child: _DailyBarChart(
                    period: period,
                    byDay: state.byDay,
                    budgetMinor: state.budgetMinor,
                    symbol: symbol,
                  ),
                ),
              ),
            ),
            SectionHeading(
              title: 'Counted in budget',
              caption: state.budgetRowCount > counted.length
                  ? 'Showing ${counted.length} of ${state.budgetRowCount} transactions'
                  : '${state.budgetRowCount} transactions',
            ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.builder(
            itemCount: counted.length,
            itemBuilder: (context, i) => TransactionTile(
              transaction: counted[i],
              symbol: symbol,
              onTap: () => showTransactionSheet(context, existing: counted[i]),
            ),
          ),
        ),
        const PageBottomGap(),
      ];
    },
  );
}

/// The two questions Insights can answer: how the budget is doing, and where
/// the money actually went. They need different scopes, so the switch is on
/// the screen rather than buried in settings.
class _ScopeBar extends StatelessWidget {
  const _ScopeBar();

  @override
  Widget build(BuildContext context) {
    final state = appState;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            children: [
              for (final range in InsightsRange.values) ...[
                ChoiceChip(
                  selected: state.insightsRange == range,
                  label: Text(range.label),
                  onSelected: (_) =>
                      unawaited(appState.setInsightsScope(range: range)),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Include accounts and rows left out of the budget',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Switch(
              value: !state.insightsBudgetedOnly,
              activeThumbColor: scheme.primary,
              onChanged: (all) =>
                  unawaited(appState.setInsightsScope(budgetedOnly: !all)),
            ),
          ],
        ),
      ],
    );
  }
}

String _dm(DateTime d) => '${d.day}/${d.month}';

int _days(BudgetPeriod p) => p.end.difference(p.start).inDays;

/// A raised surface for a chart or a group of rows, so a figure never floats
/// loose on the page.
class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding});
  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => Container(
    decoration: raisedDecoration(Theme.of(context).colorScheme),
    padding: padding ?? const EdgeInsets.fromLTRB(16, 18, 16, 16),
    child: child,
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.titleLarge?.copyWith(fontFeatures: tabular),
        ),
        const SizedBox(height: 1),
        Text(label, style: text.bodySmall),
      ],
    );
  }
}

/// The ring, with the period total sitting in the hole. Slice labels are left
/// off on purpose: the share bars underneath say the same thing in words.
class _CategoryDonut extends StatelessWidget {
  const _CategoryDonut({
    required this.byCategory,
    required this.total,
    required this.symbol,
    required this.onTap,
  });
  final List<(String, int)> byCategory;
  final int total;
  final String symbol;
  final void Function(String category) onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            centerSpaceRadius: 68,
            sectionsSpace: 3,
            startDegreeOffset: -90,
            // A slice is a way into that category's transactions, so it grows
            // under the finger and opens the filtered ledger on release.
            pieTouchData: PieTouchData(
              touchCallback: (event, response) {
                final index = response?.touchedSection?.touchedSectionIndex;
                if (event is FlTapUpEvent &&
                    index != null &&
                    index >= 0 &&
                    index < byCategory.length)
                  onTap(byCategory[index].$1);
              },
            ),
            sections: [
              for (final e in byCategory)
                PieChartSectionData(
                  value: e.$2.toDouble(),
                  color: categoryColor(e.$1),
                  title: '',
                  radius: 26,
                ),
            ],
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  moneyShort(total, symbol),
                  maxLines: 1,
                  style: text.displaySmall?.copyWith(fontFeatures: tabular),
                ),
              ),
            ),
            Text('this period', style: text.bodySmall),
          ],
        ),
      ],
    );
  }
}

/// One category as a row plus the share of the period it took. A bar reads
/// faster than a colour key against a ring.
class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.category,
    required this.amountMinor,
    required this.share,
    required this.symbol,
    required this.onTap,
  });
  final String category;
  final int amountMinor;
  final double share;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = categoryColor(category);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Corners.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Column(
          children: [
            Row(
              children: [
                Icon(categoryIcon(category), size: 16, color: color),
                const SizedBox(width: 9),
                Expanded(child: Text(category, style: text.bodyMedium)),
                Text(
                  '${(share * 100).round()}%',
                  style: text.bodySmall?.copyWith(fontFeatures: tabular),
                ),
                const SizedBox(width: 12),
                Text(
                  money(amountMinor, symbol),
                  style: text.titleMedium?.copyWith(fontFeatures: tabular),
                ),
              ],
            ),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: share.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 560),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 5,
                  backgroundColor: scheme.surfaceContainerHigh,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DailyBarChart extends StatelessWidget {
  const _DailyBarChart({
    required this.period,
    required this.byDay,
    required this.budgetMinor,
    required this.symbol,
  });
  final BudgetPeriod period;
  final Map<DateTime, int> byDay;
  final int budgetMinor;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final days = period.end.difference(period.start).inDays;
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    final bars = <BarChartGroupData>[];
    var maxY = 0.0;
    for (var i = 0; i < days; i++) {
      final day = period.start.add(Duration(days: i));
      final amount = (byDay[day] ?? 0) / 100.0;
      if (amount > maxY) maxY = amount;
      final future = day.isAfter(today);
      bars.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: amount,
              // Days still to come are drawn flat, so the chart doesn't read
              // as a run of zero-spend days that have already happened.
              color: future
                  ? scheme.outlineVariant
                  : amount == 0
                  ? scheme.surfaceContainerHigh
                  : scheme.primary,
              width: days > 28 ? 7 : 9,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(3),
              ),
            ),
          ],
        ),
      );
    }
    final dailyPace = budgetMinor > 0 ? (budgetMinor / days) / 100.0 : null;
    if (dailyPace != null && dailyPace > maxY) maxY = dailyPace;
    final labelStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    return BarChart(
      BarChartData(
        maxY: maxY == 0 ? 1 : maxY * 1.18,
        barGroups: bars,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: scheme.outlineVariant, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => scheme.inverseSurface,
            getTooltipItem: (group, _, rod, _) => BarTooltipItem(
              '${_dm(period.start.add(Duration(days: group.x)))}\n'
              '${money((rod.toY * 100).round(), symbol)}',
              TextStyle(
                fontFamily: 'Nunito',
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: scheme.onInverseSurface,
              ),
            ),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final day = period.start.add(Duration(days: value.toInt()));
                // Every fifth day plus the first, or the axis turns to mush.
                if (day.day != 1 && day.day % 5 != 0)
                  return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('${day.day}', style: labelStyle),
                );
              },
            ),
          ),
        ),
        extraLinesData: dailyPace == null
            ? const ExtraLinesData()
            : ExtraLinesData(
                horizontalLines: [
                  HorizontalLine(
                    y: dailyPace,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                    strokeWidth: 1.5,
                    dashArray: [5, 5],
                    // No inline label: at 30 bars it lands on top of one.
                    // The section caption carries the figure instead.
                  ),
                ],
              ),
      ),
    );
  }
}
