import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/tally_database.dart';
import '../models/transaction.dart';

/// Batch editing, shared by every screen that lists transactions.
///
/// Activity and the review queue are the same job on different slices of the
/// ledger, so the selection, the app-bar actions and the batch writes live
/// here once rather than being written twice and drifting apart.
mixin LedgerSelection<T extends StatefulWidget> on State<T> {
  final Set<int> selected = {};

  bool get selecting => selected.isNotEmpty;

  /// Every row the screen is currently showing, so "select all" knows what
  /// "all" means there. Activity overrides it to mean everything the filter
  /// matches, not just the page that has been loaded.
  List<TallyTransaction> get selectableRows;

  /// What to do after a batch write lands.
  void onSelectionApplied();

  /// Asks for one category; supplied by the screen so this file needs no
  /// knowledge of the sheets.
  Future<String?> pickCategory(BuildContext context);

  /// All ids the current view covers. Overridden where the view is paged and
  /// "all" has to come from the database instead of the loaded page.
  Future<List<int>> allSelectableIds() async => [
    for (final row in selectableRows)
      if (row.id != null) row.id!,
  ];

  void toggleSelected(int id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!selected.remove(id)) selected.add(id);
    });
  }

  void clearSelection() => setState(selected.clear);

  Future<void> selectAll() async {
    final ids = await allSelectableIds();
    HapticFeedback.selectionClick();
    setState(() => selected.addAll(ids));
  }

  Future<void> _apply(Future<void> Function(List<int> ids) write) async {
    final ids = selected.toList();
    if (ids.isEmpty) return;
    await write(ids);
    HapticFeedback.mediumImpact();
    clearSelection();
    onSelectionApplied();
  }

  Future<void> categoriseSelection(BuildContext context) async {
    final picked = await pickCategory(context);
    if (picked == null) return;
    await _apply(
      (ids) => TallyDatabase.instance.setCategoryForIds(ids, picked),
    );
  }

  Future<void> excludeSelection({required bool excluded}) =>
      _apply((ids) => TallyDatabase.instance.setExcludedForIds(ids, excluded));

  Future<void> deleteSelection(BuildContext context) async {
    final count = selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $count ${count == 1 ? 'row' : 'rows'}?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _apply(TallyDatabase.instance.deleteByIds);
  }

  /// The app bar while rows are picked: label them, drop them out of the
  /// budget, delete them, or take everything in view.
  List<Widget> selectionActions(BuildContext context) => [
    IconButton(
      icon: const Icon(Icons.select_all_rounded),
      tooltip: 'Select all',
      onPressed: () => unawaited(selectAll()),
    ),
    IconButton(
      icon: const Icon(Icons.label_outline_rounded),
      tooltip: 'Set category',
      onPressed: () => unawaited(categoriseSelection(context)),
    ),
    IconButton(
      icon: const Icon(Icons.savings_outlined),
      tooltip: 'Leave out of the budget',
      onPressed: () => unawaited(excludeSelection(excluded: true)),
    ),
    IconButton(
      icon: const Icon(Icons.delete_outline_rounded),
      tooltip: 'Delete',
      onPressed: () => unawaited(deleteSelection(context)),
    ),
    IconButton(
      icon: const Icon(Icons.close_rounded),
      tooltip: 'Cancel',
      onPressed: clearSelection,
    ),
    const SizedBox(width: 4),
  ];
}
