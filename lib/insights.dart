import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'app/theme.dart';
import 'core/budget_period.dart';
import 'core/money.dart';
import 'data/tally_database.dart';
import 'main.dart' show TransactionTile;
import 'models/transaction.dart';
import 'models/categories.dart';

/// Spending charts for the current budget period: category breakdown and a
/// daily bar chart, with the budget's daily pace overlaid when one is set.
class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Object?>>(
    future: () async {
      final db = TallyDatabase.instance;
      final startDay = await db.budgetStartDay();
      final period = budgetPeriod(DateTime.now(), startDay);
      return Future.wait([
        Future.value(period),
        db.spendByCategory(period),
        db.dailySpend(period),
        db.currency(),
        db.setting('monthly_budget'),
        db.budgetRowsPage(period),
      ]);
    }(),
    builder: (context, snapshot) {
      if (!snapshot.hasData)
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      final values = snapshot.data!;
      final period = values[0] as BudgetPeriod;
      final byCategory = values[1] as List<(String, int)>;
      final byDay = values[2] as Map<DateTime, int>;
      final symbol = values[3] as String;
      final budget = int.tryParse(values[4] as String? ?? '0') ?? 0;
      final total = byCategory.fold<int>(0, (sum, e) => sum + e.$2);
      final (counted, countedTotal) =
          values[5] as (List<TallyTransaction>, int);

      return Scaffold(
        appBar: AppBar(title: const Text('Insights')),
        body: total == 0
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No spending in this budget period yet. Add a transaction '
                    'or import a statement to see charts here.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
                children: [
                  Text(
                    'By category',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  _CategoryDonut(
                    byCategory: byCategory,
                    total: total,
                    symbol: symbol,
                  ),
                  const SizedBox(height: 12),
                  ...byCategory.map(
                    (e) => _CategoryLegendRow(
                      category: e.$1,
                      amountMinor: e.$2,
                      symbol: symbol,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Daily spend',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${period.start.day}/${period.start.month} - '
                    '${period.end.subtract(const Duration(days: 1)).day}/'
                    '${period.end.subtract(const Duration(days: 1)).month}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 220,
                    child: _DailyBarChart(
                      period: period,
                      byDay: byDay,
                      budgetMinor: budget,
                      symbol: symbol,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Counted in budget',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    countedTotal > counted.length
                        ? 'Showing ${counted.length} of $countedTotal transactions'
                        : '$countedTotal transactions',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: counted.length,
                    itemBuilder: (_, i) =>
                        TransactionTile(transaction: counted[i], symbol: symbol),
                  ),
                ],
              ),
      );
    },
  );
}

class _CategoryDonut extends StatelessWidget {
  const _CategoryDonut({
    required this.byCategory,
    required this.total,
    required this.symbol,
  });
  final List<(String, int)> byCategory;
  final int total;
  final String symbol;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 180,
    child: PieChart(
      PieChartData(
        centerSpaceRadius: 50,
        sectionsSpace: 2,
        sections: byCategory
            .map(
              (e) => PieChartSectionData(
                value: e.$2.toDouble(),
                color: categoryColor(e.$1),
                title: total == 0 ? '' : '${(e.$2 * 100 / total).round()}%',
                radius: 40,
                titleStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            )
            .toList(),
      ),
    ),
  );
}

class _CategoryLegendRow extends StatelessWidget {
  const _CategoryLegendRow({
    required this.category,
    required this.amountMinor,
    required this.symbol,
  });
  final String category;
  final int amountMinor;
  final String symbol;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: categoryColor(category),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Icon(categoryIcon(category), size: 16, color: categoryColor(category)),
        const SizedBox(width: 8),
        Expanded(child: Text(category)),
        Text(
          money(amountMinor, symbol),
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontFeatures: tabular,
          ),
        ),
      ],
    ),
  );
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
    final bars = <BarChartGroupData>[];
    var maxY = 0.0;
    for (var i = 0; i < days; i++) {
      final day = period.start.add(Duration(days: i));
      final amount = (byDay[day] ?? 0) / 100.0;
      if (amount > maxY) maxY = amount;
      bars.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(toY: amount, color: scheme.primary, width: 6),
          ],
        ),
      );
    }
    final dailyPace = budgetMinor > 0 ? (budgetMinor / days) / 100.0 : null;
    if (dailyPace != null && dailyPace > maxY) maxY = dailyPace;
    return BarChart(
      BarChartData(
        maxY: maxY == 0 ? 1 : maxY * 1.15,
        barGroups: bars,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 40),
          ),
        ),
        extraLinesData: dailyPace == null
            ? const ExtraLinesData()
            : ExtraLinesData(
                horizontalLines: [
                  HorizontalLine(
                    y: dailyPace,
                    color: scheme.error,
                    strokeWidth: 1.5,
                    dashArray: [6, 4],
                    label: HorizontalLineLabel(
                      show: true,
                      alignment: Alignment.topRight,
                      style: TextStyle(color: scheme.error, fontSize: 10),
                      labelResolver: (_) => 'Daily pace',
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
