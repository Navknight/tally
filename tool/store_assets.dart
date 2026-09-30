// Regenerates the store listing images from seeded demo data:
//
//   flutter test tool/store_assets.dart --update-goldens
//
// Demo data on purpose. Screenshots of a real ledger would publish the
// owner's balances and the names of people they paid. Lives outside test/ so
// `flutter test` never treats these images as a suite to verify.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tally/app/theme.dart';
import 'package:tally/core/budget_period.dart';
import 'package:tally/insights.dart';
import 'package:tally/main.dart';
import 'package:tally/models/account.dart';
import 'package:tally/models/transaction.dart';
import 'package:tally/state/app_state.dart';

const _out = '../fastlane/metadata/android/en-US/images';

TallyTransaction _tx(
  int id,
  String merchant,
  int minor,
  String category,
  DateTime at, {
  bool review = false,
  TransactionKind kind = TransactionKind.expense,
}) => TallyTransaction(
  id: id,
  amountMinor: minor,
  kind: kind,
  occurredAt: at,
  merchant: merchant,
  category: category,
  accountId: 1,
  needsReview: review,
);

void _seed() {
  // Anchored on the real clock: the strip and the pace marker read
  // DateTime.now() themselves, so a fixed date would leave the screenshot
  // disagreeing with its own chart.
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final s = appState;
  s.loaded = true;
  s.symbol = '₹';
  s.budgetMinor = 3000000;
  s.startDay = 1;
  s.period = budgetPeriod(now, 1);
  // Two thirds through the period, comfortably under the limit.
  s.spent = (30000 * 0.62 * 100).round();
  s.accounts = const [
    Account(
      id: 1,
      name: 'HDFC Savings',
      last4: '4417',
      openingBalanceMinor: 0,
    ),
    Account(id: 2, name: 'SBI Deposit', last4: '9082', openingBalanceMinor: 0),
    Account(
      id: 3,
      name: 'Amazon Pay ICICI',
      last4: '3301',
      openingBalanceMinor: 0,
      kind: AccountKind.card,
    ),
  ];
  s.balances = const {1: 5284160, 2: 12840000, 3: -1839900};
  // No detection card: on Home it lands exactly under the floating button.
  s.detections = const [];
  final rows = [
    _tx(
      1,
      'Corner Cafe',
      41800,
      'Food',
      now.subtract(const Duration(hours: 3)),
    ),
    _tx(
      2,
      'City Metro',
      6000,
      'Transport',
      now.subtract(const Duration(hours: 6)),
    ),
    _tx(
      3,
      'UPI/9845012345',
      120000,
      'Other',
      now.subtract(const Duration(hours: 8)),
      review: true,
    ),
    _tx(
      4,
      'Green Grocer',
      237450,
      'Groceries',
      now.subtract(const Duration(days: 1, hours: 2)),
    ),
    _tx(
      5,
      'Streaming plan',
      64900,
      'Entertainment',
      now.subtract(const Duration(days: 1, hours: 7)),
    ),
    _tx(
      6,
      'Salary',
      12500000,
      'Income',
      now.subtract(const Duration(days: 2, hours: 1)),
      kind: TransactionKind.income,
    ),
    _tx(
      7,
      'NACH debit',
      500000,
      'Investments',
      now.subtract(const Duration(days: 2, hours: 5)),
    ),
    _tx(
      8,
      'Fuel stop',
      300000,
      'Transport',
      now.subtract(const Duration(days: 3, hours: 4)),
    ),
    _tx(
      9,
      'Pharmacy',
      87600,
      'Health',
      now.subtract(const Duration(days: 4, hours: 2)),
    ),
    _tx(
      10,
      'Bookshop',
      129900,
      'Shopping',
      now.subtract(const Duration(days: 5, hours: 6)),
    ),
    _tx(
      11,
      'Electricity bill',
      214300,
      'Bills',
      now.subtract(const Duration(days: 6, hours: 3)),
    ),
  ];
  s.ledger = rows;
  s.recent = rows.take(6).toList();
  s.ledgerDays = groupByDay(rows);
  s.hasMore = true;
  s.review = [rows[2]];
  s.oldest = DateTime(2025, 4, 1);
  s.byCategory = const [
    ('Groceries', 537450),
    ('Food', 418000),
    ('Transport', 360000),
    ('Bills', 214300),
    ('Shopping', 129900),
    ('Health', 87600),
    ('Entertainment', 64900),
  ];
  s.byDay = {
    for (var i = 0; i < 30; i++)
      DateTime(2026, 9, i + 1): [
        0,
        41800,
        119000,
        0,
        64900,
        302000,
        214300,
      ][i % 7],
  };
  s.lastWeek = {
    for (var i = 0; i < 7; i++)
      today.subtract(Duration(days: i)): [
        47800,
        302350,
        64900,
        500000,
        300000,
        87600,
        129900,
      ][i],
  };
  s.budgetRows = rows.where((r) => r.kind == TransactionKind.expense).toList();
  s.budgetRowCount = 64;
}

/// The five tally marks from `ic_launcher_foreground.xml`, on the icon teal.
class _Mark extends StatelessWidget {
  const _Mark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MarkPainter());
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 108;
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 6 * k
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final x in [38.0, 48.0, 58.0, 68.0])
      canvas.drawLine(Offset(x * k, 36 * k), Offset(x * k, 72 * k), paint);
    canvas.drawLine(Offset(30 * k, 66 * k), Offset(76 * k, 42 * k), paint);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}

const _iconTeal = Color(0xFF14B8A6);

/// Where Flutter lives, when the environment hasn't said.
String _flutterRoot() {
  final which = Process.runSync('which', ['flutter']).stdout as String;
  if (which.trim().isEmpty) fail('flutter not on PATH; set FLUTTER_ROOT.');
  return File(which.trim()).resolveSymbolicLinksSync().split('/bin/flutter')[0];
}

Future<void> _shot(
  WidgetTester tester,
  Widget screen,
  String name, {
  Brightness mode = Brightness.light,
  double drag = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: TallyTheme.build(mode),
      home: screen,
    ),
  );
  await tester.pumpAndSettle();
  if (drag != 0) {
    await tester.drag(find.byType(Scrollable).first, Offset(0, -drag));
    await tester.pumpAndSettle();
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('$_out/phoneScreenshots/$name.png'),
  );
}

void main() {
  setUpAll(() async {
    for (final weight in ['400', '600', '700', '800', '900']) {
      final loader = FontLoader('Nunito')
        ..addFont(
          File('assets/fonts/Nunito-$weight.ttf')
              .readAsBytes()
              .then((b) => ByteData.sublistView(b)),
        );
      await loader.load();
    }
    // Without this every icon renders as an empty box: the test renderer
    // registers the app's own fonts but not the engine's icon font.
    final icons = File(
      '${Platform.environment['FLUTTER_ROOT'] ?? _flutterRoot()}'
      '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (!icons.existsSync())
      fail('Material icon font not found at ${icons.path}; set FLUTTER_ROOT.');
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(icons.readAsBytes().then((b) => ByteData.sublistView(b)));
    await iconLoader.load();
    _seed();
  });

  group('phone screenshots', () {
    setUp(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1080, 2340);
      view.devicePixelRatio = 3;
    });

    testWidgets('1 home', (t) async {
      await _shot(t, TallyShell(key: UniqueKey()), '1-home');
    });
    testWidgets('2 activity', (t) async {
      await _shot(t, const TransactionsScreen(), '2-activity');
    });
    testWidgets('3 insights', (t) async {
      await _shot(t, InsightsScreen(onOpenActivity: () {}), '3-insights');
    });
    testWidgets('4 insights dark', (t) async {
      await _shot(
        t,
        InsightsScreen(onOpenActivity: () {}),
        '4-categories',
        mode: Brightness.dark,
        drag: 620,
      );
    });
    testWidgets('5 settings', (t) async {
      await _shot(t, const SettingsScreen(), '5-settings');
    });
  });

  testWidgets('icon', (t) async {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(512, 512);
    view.devicePixelRatio = 1;
    await t.pumpWidget(
      const ColoredBox(
        color: _iconTeal,
        child: Center(child: _Mark(size: 512)),
      ),
    );
    await t.pumpAndSettle();
    await expectLater(
      find.byType(ColoredBox),
      matchesGoldenFile('$_out/icon.png'),
    );
  });

  testWidgets('feature graphic', (t) async {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1024, 500);
    view.devicePixelRatio = 1;
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: _iconTeal,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _Mark(size: 290),
              const SizedBox(width: 4),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Tally',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 96,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -4,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Your bank texts, already counted.',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await expectLater(
      find.byType(ColoredBox),
      matchesGoldenFile('$_out/featureGraphic.png'),
    );
  });
}
