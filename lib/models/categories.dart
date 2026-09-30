import 'package:flutter/material.dart';

/// The fixed category set. Deliberately short: the learner needs enough
/// examples per label to be useful, and a long list starves it.
const kCategories = <String>[
  'Food',
  'Groceries',
  'Transport',
  'Shopping',
  'Bills',
  'Health',
  'Entertainment',
  'Investments',
  'Transfers',
  'Income',
  'Other',
];

const kUncategorized = 'Other';

/// Money moved into savings (SIPs and the like) leaves the account but is
/// not spending, so rows in this category stay out of the budget.
const kInvestments = 'Investments';

/// Icon shown for a category, in tiles, pickers and charts.
const Map<String, IconData> kCategoryIcons = {
  'Food': Icons.restaurant_rounded,
  'Groceries': Icons.shopping_basket_rounded,
  'Transport': Icons.directions_car_filled_rounded,
  'Shopping': Icons.shopping_bag_rounded,
  'Bills': Icons.receipt_long_rounded,
  'Health': Icons.favorite_rounded,
  'Entertainment': Icons.movie_rounded,
  'Investments': Icons.trending_up_rounded,
  'Transfers': Icons.swap_horiz_rounded,
  'Income': Icons.savings_rounded,
  'Other': Icons.category_rounded,
};

/// What the user's own category table says, filled once per [AppState] load.
/// Empty until then, so the built-in tables below stay the answer during
/// startup and in tests that never touch the database.
Map<String, (IconData, Color)> _live = const {};

/// Replaces the live set after categories are read or edited.
void setLiveCategories(Map<String, (IconData, Color)> categories) =>
    _live = categories;

IconData categoryIcon(String category) =>
    _live[category]?.$1 ?? kCategoryIcons[category] ?? Icons.category_rounded;

/// Mid-saturation hues chosen to read on both a black and a white surface, so
/// one palette serves light and dark mode without separate tables.
const Map<String, Color> kCategoryColors = {
  'Food': Color(0xFFE07A3F),
  'Groceries': Color(0xFF5FA850),
  'Transport': Color(0xFF4C86C6),
  'Shopping': Color(0xFFC15FA0),
  'Bills': Color(0xFFC6A73F),
  'Health': Color(0xFFD9555C),
  'Entertainment': Color(0xFF8A6FD1),
  'Investments': Color(0xFF3F8FA9),
  'Transfers': Color(0xFF4FADA8),
  'Income': Color(0xFF4FA97D),
  'Other': Color(0xFF8C8C8C),
};

Color categoryColor(String category) =>
    _live[category]?.$2 ??
    kCategoryColors[category] ??
    kCategoryColors[kUncategorized]!;
