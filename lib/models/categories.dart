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
  'Transfers',
  'Income',
  'Other',
];

const kUncategorized = 'Other';

/// Icon shown for a category, in tiles, pickers and charts.
const Map<String, IconData> kCategoryIcons = {
  'Food': Icons.restaurant_rounded,
  'Groceries': Icons.shopping_basket_rounded,
  'Transport': Icons.directions_car_filled_rounded,
  'Shopping': Icons.shopping_bag_rounded,
  'Bills': Icons.receipt_long_rounded,
  'Health': Icons.favorite_rounded,
  'Entertainment': Icons.movie_rounded,
  'Transfers': Icons.swap_horiz_rounded,
  'Income': Icons.savings_rounded,
  'Other': Icons.category_rounded,
};

IconData categoryIcon(String category) =>
    kCategoryIcons[category] ?? Icons.category_rounded;

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
  'Transfers': Color(0xFF4FADA8),
  'Income': Color(0xFF4FA97D),
  'Other': Color(0xFF8C8C8C),
};

Color categoryColor(String category) =>
    kCategoryColors[category] ?? kCategoryColors[kUncategorized]!;
