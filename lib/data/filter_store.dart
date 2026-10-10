import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the filter chosen in the app is kept between launches.
abstract class FilterStore {
  /// The saved filter, or [QuestionFilter.any] if there is none.
  Future<QuestionFilter> read();
  Future<void> write(QuestionFilter filter);
}

/// Keeps the filter in memory only. Used by tests.
class InMemoryFilterStore implements FilterStore {
  QuestionFilter filter;
  InMemoryFilterStore([this.filter = QuestionFilter.any]);

  @override
  Future<QuestionFilter> read() async => filter;

  @override
  Future<void> write(QuestionFilter filter) async => this.filter = filter;
}

/// Keeps the filter with shared_preferences, as JSON such as
/// `{"rounds":[1,2],"from":"1990-01-01","to":"1999-12-31","rows":[4,5]}`.
/// A missing key means that part isn't filtered.
class SharedPrefsFilterStore implements FilterStore {
  static const prefsKey = 'question_filter';

  final Future<SharedPreferences> Function() _prefs;

  SharedPrefsFilterStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  @override
  Future<QuestionFilter> read() async {
    final saved = (await _prefs()).getString(prefsKey);
    return saved == null ? QuestionFilter.any : decodeFilter(saved);
  }

  @override
  Future<void> write(QuestionFilter filter) async {
    final prefs = await _prefs();
    if (filter.isAny) {
      await prefs.remove(prefsKey);
    } else {
      await prefs.setString(prefsKey, encodeFilter(filter));
    }
  }
}

@visibleForTesting
String encodeFilter(QuestionFilter filter) {
  final rounds = filter.rounds;
  final boardRows = filter.boardRows;
  return json.encode({
    if (rounds != null) 'rounds': rounds.toList()..sort(),
    if (filter.from != null) 'from': isoDate(filter.from!),
    if (filter.to != null) 'to': isoDate(filter.to!),
    if (boardRows != null) 'rows': boardRows.toList()..sort(),
  });
}

/// Reads what [encodeFilter] wrote. A part that doesn't parse is left out,
/// and anything unreadable is [QuestionFilter.any], so a bad saved value
/// can't stop the app from showing questions.
@visibleForTesting
QuestionFilter decodeFilter(String saved) {
  final Object? decoded;
  try {
    decoded = json.decode(saved);
  } on FormatException {
    return QuestionFilter.any;
  }
  if (decoded is! Map<String, dynamic>) return QuestionFilter.any;
  DateTime? date(Object? value) => value is String ? DateTime.tryParse(value) : null;
  Set<int>? ints(Object? value) =>
      value is List && value.isNotEmpty && value.every((v) => v is int)
          ? value.cast<int>().toSet()
          : null;
  return QuestionFilter(
    rounds: ints(decoded['rounds']),
    from: date(decoded['from']),
    to: date(decoded['to']),
    boardRows: ints(decoded['rows']),
  );
}
