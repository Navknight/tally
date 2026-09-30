import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Same token system as the Rituals app: neutral untinted surfaces, one
/// accent, and surfaces that read as physical - a hairline edge with a lip
/// underneath, which a press drops the face onto. Tally spends the family's
/// boldest weight on money: amounts are the only thing on screen set heavy.
abstract final class Corners {
  static const double card = 16;
  static const double control = 14;
  static const double sheet = 26;

  /// The period card and anything else that carries a headline figure.
  static const double hero = 20;

  /// Category avatars and other small square tiles: a squircle, not a circle,
  /// so they belong to the same family as the cards.
  static const double tile = 12;
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
      // The lip is the strip of the outer shape below where the face ends.
      // Clipping to that band and refilling the rounded rect gets there
      // without a path boolean, which every card in a list would otherwise
      // pay for: Path.combine allocates and intersects two paths per paint.
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(
          outer.left,
          outer.bottom - depth,
          outer.right,
          outer.bottom,
        ),
      );
      canvas.drawRRect(outer, Paint()..color = lip);
      canvas.restore();
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

  /// Paper, not glare. A card is pure white on it, which is what makes the
  /// raised edge and the lip underneath visible at all - when the two were
  /// both white every card on Home dissolved into the background.
  static const _paper = Color(0xFFFAF9F7);
  static const _paperCard = Color(0xFFFFFFFF);
  static const _ink = Color(0xFF0B0B0C);
  static const _inkCard = Color(0xFF17171A);

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
          surface: light ? _paper : _ink,
          onSurface: Color(light ? 0xFF121212 : 0xFFF4F4F2),
          onSurfaceVariant: Color(light ? 0xFF74716B : 0xFF9B9A96),
          surfaceContainerLowest: light ? _paperCard : _inkCard,
          surfaceContainerLow: Color(light ? 0xFFF4F2EE : 0xFF1C1C20),
          surfaceContainer: Color(light ? 0xFFEFEDE8 : 0xFF212127),
          surfaceContainerHigh: Color(light ? 0xFFE7E4DE : 0xFF29292F),
          surfaceContainerHighest: Color(light ? 0xFFDEDAD3 : 0xFF33333A),
          outline: Color(light ? 0xFF9C9891 : 0xFF6E6D72),
          outlineVariant: Color(light ? 0xFFE3DFD8 : 0xFF2C2C32),
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
        // The headline figure. Nunito's w900 needs the tracking pulled in
        // hard at this size or the digits drift apart.
        displayMedium: text.displayMedium?.copyWith(
          fontSize: 50,
          fontWeight: FontWeight.w900,
          letterSpacing: -2.4,
          height: 1.0,
          fontFeatures: tabular,
        ),
        displaySmall: text.displaySmall?.copyWith(
          fontSize: 34,
          fontWeight: FontWeight.w900,
          letterSpacing: -1.2,
          height: 1.05,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontSize: 23,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.15,
        ),
        titleSmall: text.titleSmall?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
        labelLarge: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
          fontSize: 15,
        ),
        labelSmall: text.labelSmall?.copyWith(
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 0.2,
        ),
        bodyLarge: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        bodyMedium: text.bodyMedium?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        bodySmall: text.bodySmall
            ?.merge(muted)
            .copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
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
          fontSize: 26,
          color: scheme.onSurface,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.7,
        ),
        titleSpacing: 20,
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
          side: BorderSide(color: scheme.outlineVariant, width: 1.5),
          foregroundColor: scheme.onSurfaceVariant,
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
        height: 66,
        elevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.15),
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 23,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: 'Nunito',
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.1,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
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
        backgroundColor: scheme.surfaceContainerLowest,
        showDragHandle: true,
        dragHandleColor: scheme.outlineVariant,
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
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w700,
          color: scheme.onInverseSurface,
        ),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant, width: 1.5),
        shape: const StadiumBorder(),
        backgroundColor: scheme.surfaceContainerLowest,
        labelStyle: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}
