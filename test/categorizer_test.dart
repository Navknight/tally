import 'package:flutter_test/flutter_test.dart';
import 'package:tally/models/categories.dart';
import 'package:tally/services/categorizer.dart';

class InMemoryCategoryStore implements CategoryStore {
  final Map<String, String> merchantRules = {};
  final Map<String, Map<String, int>> _tokenCounts = {};
  final Map<String, int> _categoryCounts = {};

  @override
  Future<String?> merchantCategory(String merchantKey) async =>
      merchantRules[merchantKey];

  @override
  Future<void> saveMerchantCategory(String merchantKey, String category) async {
    merchantRules[merchantKey] = category;
  }

  @override
  Future<Map<String, int>> tokenCounts(String token) async =>
      Map.of(_tokenCounts[token] ?? {});

  @override
  Future<Map<String, int>> categoryCounts() async => Map.of(_categoryCounts);

  @override
  Future<void> train(List<String> tokens, String category) async {
    _categoryCounts[category] = (_categoryCounts[category] ?? 0) + 1;
    for (final t in tokens) {
      final counts = _tokenCounts.putIfAbsent(t, () => {});
      counts[category] = (counts[category] ?? 0) + 1;
    }
  }
}

void main() {
  group('merchantKey', () {
    test('normalises case, digits and punctuation', () {
      expect(
        Categorizer.merchantKey('ACME MART #12'),
        Categorizer.merchantKey('Acme Mart'),
      );
      expect(Categorizer.merchantKey('ACME MART #12'), 'acme mart');
    });
  });

  group('seed lexicon', () {
    test('unseen SWIGGY merchant guesses Food without training', () async {
      final store = InMemoryCategoryStore();
      final categorizer = Categorizer(store);
      final guess = await categorizer.guess(merchant: 'SWIGGY');
      expect(guess.category, 'Food');
      expect(guess.confidence, 0.8);
      expect(guess.needsReview, false);
    });
  });

  group('learned merchant rule', () {
    test('wins over seed lexicon', () async {
      final store = InMemoryCategoryStore();
      final categorizer = Categorizer(store);

      var guess = await categorizer.guess(merchant: 'Swiggy');
      expect(guess.category, 'Food');

      await categorizer.learn(merchant: 'Swiggy', category: 'Transport');

      guess = await categorizer.guess(merchant: 'Swiggy');
      expect(guess.category, 'Transport');
      expect(guess.confidence, 1.0);
    });
  });

  group('Bayes generalisation', () {
    test(
      'new merchant with shared body token guessed by learned category',
      () async {
        final store = InMemoryCategoryStore();
        final categorizer = Categorizer(store, minExamples: 4);

        // Train several distinct Food merchants (not in the seed lexicon)
        // sharing a body token "tastybites".
        final foodMerchants = [
          'Corner Diner',
          'Spice Hub',
          'Grill House',
          'Curry Point',
        ];
        for (final m in foodMerchants) {
          await categorizer.learn(
            merchant: m,
            body: 'order from tastybites app',
            category: 'Food',
          );
        }

        final guess = await categorizer.guess(
          merchant: 'New Eatery',
          body: 'order from tastybites app',
        );
        expect(guess.category, 'Food');
      },
    );
  });

  group('below minExamples', () {
    test('unknown merchant returns Other with needsReview true', () async {
      final store = InMemoryCategoryStore();
      final categorizer = Categorizer(store, minExamples: 4);

      // Train fewer than minExamples total labelled examples.
      await categorizer.learn(
        merchant: 'Corner Diner',
        body: 'random words here',
        category: 'Food',
      );
      await categorizer.learn(
        merchant: 'Spice Hub',
        body: 'random words here',
        category: 'Food',
      );

      final guess = await categorizer.guess(
        merchant: 'Totally Unknown Shop',
        body: 'nothing matches',
      );
      expect(guess.category, kUncategorized);
      expect(guess.needsReview, true);
    });
  });

  group('confidence bounds', () {
    test(
      'confidence stays within [0,1] and is never NaN across paths',
      () async {
        final store = InMemoryCategoryStore();
        final categorizer = Categorizer(store, minExamples: 2);

        // Path: no training at all, no lexicon match.
        var guess = await categorizer.guess(
          merchant: 'Xyzzy Unknown',
          body: 'plugh',
        );
        expect(guess.confidence.isNaN, false);
        expect(guess.confidence, inRange(0.0, 1.0));

        // Path: seed lexicon.
        guess = await categorizer.guess(merchant: 'Amazon Pay');
        expect(guess.confidence.isNaN, false);
        expect(guess.confidence, inRange(0.0, 1.0));

        // Path: learned merchant rule.
        await categorizer.learn(merchant: 'Local Store', category: 'Groceries');
        guess = await categorizer.guess(merchant: 'Local Store');
        expect(guess.confidence.isNaN, false);
        expect(guess.confidence, inRange(0.0, 1.0));

        // Path: Bayes with enough examples.
        await categorizer.learn(
          merchant: 'Store One',
          body: 'buy veggies daily',
          category: 'Groceries',
        );
        await categorizer.learn(
          merchant: 'Store Two',
          body: 'buy veggies daily',
          category: 'Groceries',
        );
        guess = await categorizer.guess(
          merchant: 'Store Three',
          body: 'buy veggies daily',
        );
        expect(guess.confidence.isNaN, false);
        expect(guess.confidence, inRange(0.0, 1.0));
      },
    );
  });
}

Matcher inRange(double min, double max) =>
    allOf(greaterThanOrEqualTo(min), lessThanOrEqualTo(max));
