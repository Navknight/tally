import 'dart:math';

import '../models/categories.dart';

/// Persistence the categorizer needs. The app implements this over SQLite;
/// tests use an in-memory version.
abstract class CategoryStore {
  Future<String?> merchantCategory(String merchantKey);
  Future<void> saveMerchantCategory(String merchantKey, String category);

  /// category -> times this token appeared in a labelled example.
  Future<Map<String, int>> tokenCounts(String token);

  /// [tokenCounts] for many tokens in one round trip, keyed by token.
  Future<Map<String, Map<String, int>>> tokenCountsBatch(List<String> tokens);

  /// category -> number of labelled examples.
  Future<Map<String, int>> categoryCounts();
  Future<void> train(List<String> tokens, String category);
}

class CategoryGuess {
  const CategoryGuess(
    this.category,
    this.confidence, {
    this.needsReview = false,
  });
  final String category;
  final double confidence; // 0..1
  final bool needsReview; // true when the app should ask the user
}

/// Substring keyword -> category. Checked lowercase, merchant first then body.
const Map<String, String> _seedLexicon = {
  // Food
  'swiggy': 'Food',
  'zomato': 'Food',
  'dominos': 'Food',
  'kfc': 'Food',
  'mcdonald': 'Food',
  'starbucks': 'Food',
  'cafe': 'Food',
  'restaurant': 'Food',
  // Groceries
  'bigbasket': 'Groceries',
  'blinkit': 'Groceries',
  'zepto': 'Groceries',
  'dmart': 'Groceries',
  'grofers': 'Groceries',
  'instamart': 'Groceries',
  'supermarket': 'Groceries',
  'kirana': 'Groceries',
  // Transport
  'uber': 'Transport',
  'ola': 'Transport',
  'rapido': 'Transport',
  'irctc': 'Transport',
  'metro': 'Transport',
  'petrol': 'Transport',
  'fuel': 'Transport',
  'hpcl': 'Transport',
  'iocl': 'Transport',
  'bpcl': 'Transport',
  'indian oil': 'Transport',
  'toll': 'Transport',
  'fastag': 'Transport',
  // Shopping
  'amazon': 'Shopping',
  'flipkart': 'Shopping',
  'myntra': 'Shopping',
  'ajio': 'Shopping',
  'nykaa': 'Shopping',
  'meesho': 'Shopping',
  'decathlon': 'Shopping',
  // Bills
  'electricity': 'Bills',
  'bescom': 'Bills',
  'recharge': 'Bills',
  'airtel': 'Bills',
  'jio': 'Bills',
  'vodafone': 'Bills',
  'broadband': 'Bills',
  'gas': 'Bills',
  'water bill': 'Bills',
  'insurance': 'Bills',
  'premium': 'Bills',
  'rent': 'Bills',
  'emi': 'Bills',
  'loan': 'Bills',
  // Health
  'pharmacy': 'Health',
  'apollo': 'Health',
  'medplus': 'Health',
  'pharmeasy': 'Health',
  'hospital': 'Health',
  'clinic': 'Health',
  'diagnostic': 'Health',
  'lab': 'Health',
  // Entertainment
  'netflix': 'Entertainment',
  'spotify': 'Entertainment',
  'prime video': 'Entertainment',
  'hotstar': 'Entertainment',
  'jiocinema': 'Entertainment',
  'bookmyshow': 'Entertainment',
  'pvr': 'Entertainment',
  'inox': 'Entertainment',
  'youtube': 'Entertainment',
  'gaming': 'Entertainment',
  // Income
  'salary': 'Income',
  'credited by employer': 'Income',
  'interest': 'Income',
  'dividend': 'Income',
  'refund': 'Income',
  'cashback': 'Income',
  // Transfers
  'atm': 'Transfers',
  'self': 'Transfers',
  'own account': 'Transfers',
  'transfer to self': 'Transfers',
  'imps': 'Transfers',
  'neft': 'Transfers',
  'rtgs': 'Transfers',
};

const Set<String> _stopwords = {
  'the',
  'and',
  'for',
  'you',
  'your',
  'has',
  'have',
  'been',
  'with',
  'from',
  'this',
  'that',
  'was',
  'are',
  'not',
  'via',
  'txn',
  'upi',
  'account',
  'acct',
  'bank',
  'debited',
  'credited',
  'debit',
  'credit',
  'rs',
  'inr',
  'amount',
  'dear',
  'customer',
  'info',
  'ref',
  'avl',
  'bal',
  'balance',
  'on',
  'to',
  'of',
  'in',
  'at',
  'is',
  'it',
  'by',
};

final _nonLetterRegex = RegExp(r'[^a-z\s]');
final _whitespaceRegex = RegExp(r'\s+');
final _nonLettersRegex = RegExp(r'[^a-z]+');

class Categorizer {
  Categorizer(this.store, {this.threshold = 0.62, this.minExamples = 4});
  final CategoryStore store;
  final double threshold;
  final int minExamples;

  /// Normalised merchant identity: lowercase, punctuation and digits stripped,
  /// whitespace collapsed. Used as the merchant-rule key so "ACME MART #12"
  /// and "Acme Mart" are the same merchant.
  static String merchantKey(String merchant) {
    final lower = merchant.toLowerCase();
    final stripped = lower.replaceAll(_nonLetterRegex, ' ');
    return stripped.replaceAll(_whitespaceRegex, ' ').trim();
  }

  /// Tokens used for the Bayes layer: merchant + optional message body,
  /// lowercased, split on non-letters, stopwords and 1-char tokens dropped,
  /// de-duplicated.
  static List<String> tokenize(String merchant, [String body = '']) {
    final combined = '$merchant $body'.toLowerCase();
    final raw = combined.split(_nonLettersRegex);
    final seen = <String>{};
    for (final token in raw) {
      if (token.length <= 1) continue;
      if (_stopwords.contains(token)) continue;
      seen.add(token);
    }
    return seen.toList();
  }

  Future<CategoryGuess> guess({
    required String merchant,
    String body = '',
  }) async {
    final key = merchantKey(merchant);
    final learned = await store.merchantCategory(key);
    if (learned != null) return CategoryGuess(learned, 1.0);

    final seeded = _seedGuess(merchant, body);
    if (seeded != null) return seeded;

    final categoryCounts = await store.categoryCounts();
    final totalExamples = categoryCounts.values.fold<int>(0, (a, b) => a + b);
    if (totalExamples == 0) {
      return const CategoryGuess(kUncategorized, 0.0, needsReview: true);
    }

    final tokens = tokenize(merchant, body);
    final tokenCountsByToken = <String, Map<String, int>>{};
    for (final t in tokens) {
      tokenCountsByToken[t] = await store.tokenCounts(t);
    }
    return _bayesGuess(tokens, categoryCounts, totalExamples, tokenCountsByToken);
  }

  /// Same guess as [guess], for many transactions at once: the category and
  /// token stats each message needs are fetched once up front instead of per
  /// message, which is what makes a big SMS ingest batch cheap.
  Future<List<CategoryGuess>> guessMany(
    List<({String merchant, String body})> items,
  ) async {
    final categoryCounts = await store.categoryCounts();
    final totalExamples = categoryCounts.values.fold<int>(0, (a, b) => a + b);
    final tokenized = [for (final i in items) tokenize(i.merchant, i.body)];
    final allTokens = <String>{for (final t in tokenized) ...t};
    final tokenCountsByToken = await store.tokenCountsBatch(
      allTokens.toList(),
    );

    final results = <CategoryGuess>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final key = merchantKey(item.merchant);
      final learned = await store.merchantCategory(key);
      if (learned != null) {
        results.add(CategoryGuess(learned, 1.0));
        continue;
      }
      final seeded = _seedGuess(item.merchant, item.body);
      if (seeded != null) {
        results.add(seeded);
        continue;
      }
      results.add(
        totalExamples == 0
            ? const CategoryGuess(kUncategorized, 0.0, needsReview: true)
            : _bayesGuess(
                tokenized[i],
                categoryCounts,
                totalExamples,
                tokenCountsByToken,
              ),
      );
    }
    return results;
  }

  CategoryGuess? _seedGuess(String merchant, String body) {
    final lowerMerchant = merchant.toLowerCase();
    final lowerBody = body.toLowerCase();
    for (final entry in _seedLexicon.entries)
      if (lowerMerchant.contains(entry.key)) return CategoryGuess(entry.value, 0.8);
    for (final entry in _seedLexicon.entries)
      if (lowerBody.contains(entry.key)) return CategoryGuess(entry.value, 0.8);
    return null;
  }

  CategoryGuess _bayesGuess(
    List<String> tokens,
    Map<String, int> categoryCounts,
    int totalExamples,
    Map<String, Map<String, int>> tokenCountsByToken,
  ) {
    final categories = categoryCounts.keys.toList();
    final relevant = {
      for (final t in tokens)
        if (tokenCountsByToken.containsKey(t)) t: tokenCountsByToken[t]!,
    };
    // Approximate vocabulary size: number of distinct tokens observed across
    // categories for the tokens we're scoring (a reasonable, cheap proxy).
    final vocabSize = relevant.isEmpty ? 1 : relevant.length;

    final totalTokensPerCategory = <String, int>{};
    for (final cat in categories) {
      var sum = 0;
      for (final counts in relevant.values) {
        sum += counts[cat] ?? 0;
      }
      totalTokensPerCategory[cat] = sum;
    }

    final logScores = <String, double>{};
    for (final cat in categories) {
      final prior = categoryCounts[cat]! / totalExamples;
      var logScore = log(prior);
      final denom = totalTokensPerCategory[cat]! + vocabSize;
      for (final t in tokens) {
        final count = relevant[t]?[cat] ?? 0;
        logScore += log((count + 1) / denom);
      }
      logScores[cat] = logScore;
    }

    if (logScores.isEmpty) {
      return const CategoryGuess(kUncategorized, 0.0, needsReview: true);
    }

    // log-sum-exp for normalised posterior.
    final maxLog = logScores.values.reduce(max);
    var sumExp = 0.0;
    for (final v in logScores.values) {
      sumExp += exp(v - maxLog);
    }
    final logSumExp = maxLog + log(sumExp);

    String bestCategory = categories.first;
    double bestPosterior = -1;
    for (final entry in logScores.entries) {
      final posterior = exp(entry.value - logSumExp);
      if (posterior > bestPosterior) {
        bestPosterior = posterior;
        bestCategory = entry.key;
      }
    }

    if (!bestPosterior.isFinite) bestPosterior = 0.0;
    bestPosterior = bestPosterior.clamp(0.0, 1.0);

    if (totalExamples >= minExamples && bestPosterior >= threshold) {
      return CategoryGuess(bestCategory, bestPosterior, needsReview: false);
    }
    return CategoryGuess(kUncategorized, bestPosterior, needsReview: true);
  }

  /// Records a user's correction so future guesses improve.
  Future<void> learn({
    required String merchant,
    String body = '',
    required String category,
  }) async {
    final key = merchantKey(merchant);
    await store.saveMerchantCategory(key, category);
    await store.train(tokenize(merchant, body), category);
  }
}
