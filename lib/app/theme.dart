import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Same token system as the Rituals app: neutral untinted surfaces, one
/// accent, and surfaces that read as physical - a hairline edge with a lip
/// underneath, which a press drops the face onto. Tally spends the family's
/// boldest weight on money: amounts are the only thing on screen set heavy.
abstract final class Corners {
  static const double card = 16;
  static const double control = 14;
  static const double sheet = 24;
}

/// Money figures: tabular so columns of amounts align digit for digit.
const tabular = [FontFeature.tabularFigures()];

/// A rounded rectangle with a thicker bottom edge, so buttons and cards read
/// as something you can press. The pressed state trades [depth] for [sink]:
/// the face drops by that much and the lip disappears under it.
class LipBorder extends OutlinedBorder {
  const LipBorder({
    this.radius = Corners.control,
    this.depth = 4,
    this.sink = 0,
    this.lip = Colors.transparent,
    super.side,
  });

  final double radius;
  final double depth;
  final double sink;
  final Color lip;

  RRect _rrect(Rect rect) => RRect.fromRectAndRadius(
    Rect.fromLTRB(rect.left, rect.top + sink, rect.right, rect.bottom),
    Radius.circular(radius),
  );

  @override
  EdgeInsetsGeometry get dimensions =>
      EdgeInsets.all(side.width) + EdgeInsets.only(top: sink, bottom: depth);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect).deflate(side.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final outer = _rrect(rect);
    if (depth > 0 && lip.a > 0) {
      final face = RRect.fromRectAndRadius(
        Rect.fromLTRB(outer.left, outer.top, outer.right, outer.bottom - depth),
        Radius.circular(radius),
      );
      canvas.drawPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRRect(outer),
          Path()..addRRect(face),
        ),
        Paint()..color = lip,
      );
    }
    if (side.style != BorderStyle.none && side.width > 0) {
      canvas.drawRRect(outer.deflate(side.width / 2), side.toPaint());
    }
  }

  @override
  LipBorder copyWith({BorderSide? side}) => LipBorder(
    radius: radius,
    depth: depth,
    sink: sink,
    lip: lip,
    side: side ?? this.side,
  );

  @override
  ShapeBorder scale(double t) => LipBorder(
    radius: radius * t,
    depth: depth * t,
    sink: sink * t,
    lip: lip,
    side: side.scale(t),
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is LipBorder
      ? LipBorder(
          radius: lerpDouble(a.radius, radius, t)!,
          depth: lerpDouble(a.depth, depth, t)!,
          sink: lerpDouble(a.sink, sink, t)!,
          lip: Color.lerp(a.lip, lip, t)!,
          side: BorderSide.lerp(a.side, side, t),
        )
      : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) =>
      b is LipBorder ? b.lerpFrom(this, t) : super.lerpTo(b, t);

  @override
  bool operator ==(Object other) =>
      other is LipBorder &&
      other.radius == radius &&
      other.depth == depth &&
      other.sink == sink &&
      other.lip == lip &&
      other.side == side;

  @override
  int get hashCode => Object.hash(radius, depth, sink, lip, side);
}

/// The raised card surface: a hairline outline with a lip underneath.
ShapeDecoration raisedDecoration(
  ColorScheme scheme, {
  Color? edge,
  double radius = Corners.card,
}) {
  final line = edge ?? scheme.outlineVariant;
  return ShapeDecoration(
    color: scheme.surfaceContainerLowest,
    shape: LipBorder(
      radius: radius,
      depth: 3,
      lip: line,
      side: BorderSide(color: line, width: 1.5),
    ),
  );
}

/// A darker shade of [color] for the lip under a filled surface.
Color lipOf(Color color) => Color.lerp(color, Colors.black, 0.22)!;

abstract final class TallyTheme {
  /// Deeper than the Rituals teal so white sits on it at full contrast, which
  /// a screen full of money figures needs.
  static const accent = Color(0xFF0D9488);

  static ThemeData build(Brightness brightness) {
    final light = brightness == Brightness.light;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ).copyWith(
          primary: accent,
          onPrimary: Colors.white,
          surface: light ? Colors.white : Colors.black,
          onSurface: light ? Colors.black : Colors.white,
          onSurfaceVariant: Color(light ? 0xFF6B6B6B : 0xFFA8A8A8),
          surfaceContainerLowest: light ? Colors.white : Colors.black,
          surfaceContainerLow: Color(light ? 0xFFF7F7F7 : 0xFF141414),
          surfaceContainer: Color(light ? 0xFFF2F2F2 : 0xFF1B1B1B),
          surfaceContainerHigh: Color(light ? 0xFFEBEBEB : 0xFF232323),
          surfaceContainerHighest: Color(light ? 0xFFE3E3E3 : 0xFF2C2C2C),
          outline: Color(light ? 0xFF9E9E9E : 0xFF6E6E6E),
          outlineVariant: Color(light ? 0xFFE6E6E6 : 0xFF262626),
          surfaceTint: Colors.transparent,
        );
    final control = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Corners.control),
    );
    // Pressed buttons drop onto their lip, and the label drops with them.
    bool down(Set<WidgetState> states) => states.contains(WidgetState.pressed);
    final pressable = WidgetStateProperty.resolveWith<OutlinedBorder>(
      (states) => states.contains(WidgetState.disabled)
          ? const LipBorder(depth: 0)
          : down(states)
          ? const LipBorder(depth: 0, sink: 4)
          : LipBorder(lip: lipOf(scheme.primary)),
    );
    final pressablePadding =
        WidgetStateProperty.resolveWith<EdgeInsetsGeometry>(
          (states) => down(states)
              ? const EdgeInsets.fromLTRB(20, 4, 20, 0)
              : const EdgeInsets.fromLTRB(20, 0, 20, 4),
        );
    final outlinedPressable = WidgetStateProperty.resolveWith<OutlinedBorder>(
      (states) => down(states)
          ? const LipBorder(depth: 0, sink: 3)
          : LipBorder(depth: 3, lip: scheme.outlineVariant),
    );
    final outlinedPadding = WidgetStateProperty.resolveWith<EdgeInsetsGeometry>(
      (states) => down(states)
          ? const EdgeInsets.fromLTRB(20, 3, 20, 0)
          : const EdgeInsets.fromLTRB(20, 0, 20, 3),
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Nunito',
    );
    final text = base.textTheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text.copyWith(
        displayMedium: text.displayMedium?.copyWith(
          fontWeight: FontWeight.w900,
          letterSpacing: -2,
          height: 1.05,
          fontFeatures: tabular,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        labelLarge: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
          fontSize: 15,
        ),
        bodyLarge: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        bodyMedium: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        bodySmall: text.bodySmall
            ?.merge(muted)
            .copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: text.headlineSmall?.copyWith(
          fontFamily: 'Nunito',
          fontSize: 25,
          color: scheme.onSurface,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.5,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: raisedDecoration(scheme).shape,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      listTileTheme: ListTileThemeData(
        shape: control,
        subtitleTextStyle: text.bodyMedium?.merge(muted),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearMinHeight: 6,
        borderRadius: BorderRadius.circular(3),
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 50))
            .copyWith(shape: pressable, padding: pressablePadding),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              minimumSize: const Size(0, 50),
              foregroundColor: scheme.onSurface,
            ).copyWith(
              shape: outlinedPressable,
              padding: outlinedPadding,
              side: WidgetStatePropertyAll(
                BorderSide(color: scheme.outlineVariant, width: 1.5),
              ),
            ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: control),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: control,
          side: BorderSide(color: scheme.outlineVariant),
          selectedBackgroundColor: scheme.primary,
          selectedForegroundColor: scheme.onPrimary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Corners.control),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Corners.control),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        elevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        highlightElevation: 0,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: LipBorder(radius: 18, lip: lipOf(scheme.primary)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Corners.card),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Corners.sheet),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: control,
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}
