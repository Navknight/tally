import 'package:flutter/material.dart';

/// A category as stored: a name, a mark and a colour.
///
/// The built-in set is seeded into the database rather than living only in
/// code, so a user-made category is the same kind of thing as a shipped one
/// and every screen can treat them alike.
class CategoryDef {
  const CategoryDef({
    required this.name,
    required this.iconIndex,
    required this.colorValue,
    required this.sort,
    required this.builtin,
  });

  final String name;

  /// Index into [kCategoryIconChoices]. An index, not a code point: Flutter
  /// tree-shakes icons it cannot see used, so a code point read from the
  /// database would render as a blank box in a release build.
  final int iconIndex;

  final int colorValue;
  final int sort;

  /// Shipped with the app. Can be recoloured and renamed but not deleted, so
  /// the learner's seed lexicon always has somewhere to point.
  final bool builtin;

  IconData get icon =>
      kCategoryIconChoices[iconIndex % kCategoryIconChoices.length];
  Color get color => Color(colorValue);

  CategoryDef copyWith({
    String? name,
    int? iconIndex,
    int? colorValue,
    int? sort,
  }) => CategoryDef(
    name: name ?? this.name,
    iconIndex: iconIndex ?? this.iconIndex,
    colorValue: colorValue ?? this.colorValue,
    sort: sort ?? this.sort,
    builtin: builtin,
  );

  Map<String, Object?> toMap() => {
    'name': name,
    'icon_index': iconIndex,
    'color_value': colorValue,
    'sort_order': sort,
    'builtin': builtin ? 1 : 0,
  };

  factory CategoryDef.fromMap(Map<String, Object?> map) => CategoryDef(
    name: map['name'] as String,
    iconIndex: (map['icon_index'] as int?) ?? 0,
    colorValue: (map['color_value'] as int?) ?? 0xFF8C8C8C,
    sort: (map['sort_order'] as int?) ?? 0,
    builtin: ((map['builtin'] as int?) ?? 0) == 1,
  );
}

/// Every icon a category can wear. Referenced by index from the database;
/// appending is safe, reordering is not.
const kCategoryIconChoices = <IconData>[
  Icons.restaurant_rounded,
  Icons.shopping_basket_rounded,
  Icons.directions_car_filled_rounded,
  Icons.shopping_bag_rounded,
  Icons.receipt_long_rounded,
  Icons.favorite_rounded,
  Icons.movie_rounded,
  Icons.trending_up_rounded,
  Icons.swap_horiz_rounded,
  Icons.savings_rounded,
  Icons.category_rounded,
  Icons.home_rounded,
  Icons.flight_rounded,
  Icons.school_rounded,
  Icons.fitness_center_rounded,
  Icons.pets_rounded,
  Icons.child_care_rounded,
  Icons.local_cafe_rounded,
  Icons.local_bar_rounded,
  Icons.local_gas_station_rounded,
  Icons.train_rounded,
  Icons.phone_iphone_rounded,
  Icons.wifi_rounded,
  Icons.bolt_rounded,
  Icons.water_drop_rounded,
  Icons.medical_services_rounded,
  Icons.card_giftcard_rounded,
  Icons.celebration_rounded,
  Icons.sports_esports_rounded,
  Icons.music_note_rounded,
  Icons.book_rounded,
  Icons.brush_rounded,
  Icons.build_rounded,
  Icons.cleaning_services_rounded,
  Icons.content_cut_rounded,
  Icons.spa_rounded,
  Icons.volunteer_activism_rounded,
  Icons.account_balance_rounded,
  Icons.percent_rounded,
  Icons.work_rounded,
];

/// The colours a category can take. Mid-saturation so one palette reads on
/// both a white and a near-black surface.
const kCategoryColorChoices = <int>[
  0xFFE07A3F,
  0xFF5FA850,
  0xFF4C86C6,
  0xFFC15FA0,
  0xFFC6A73F,
  0xFFD9555C,
  0xFF8A6FD1,
  0xFF3F8FA9,
  0xFF4FADA8,
  0xFF4FA97D,
  0xFF8C8C8C,
  0xFFB0714A,
  0xFF6B8E23,
  0xFF5C6BC0,
  0xFFD1737A,
  0xFF00897B,
];
