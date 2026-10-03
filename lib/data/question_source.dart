import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:quizapp/model/question.dart';

/// Narrows which clues a source may return. Sources that can't filter on the
/// server leave it to [QuestionFilter.matches].
class QuestionFilter {
  final Set<int>? rounds;
  final DateTime? from;
  final DateTime? to;

  const QuestionFilter({this.rounds, this.from, this.to});

  static const any = QuestionFilter();

  bool matches(JeopardyQuestion q) {
    final rounds = this.rounds;
    if (rounds != null && !rounds.contains(q.round)) return false;
    final airDate = q.airDate;
    if (from != null && (airDate == null || airDate.isBefore(from!))) return false;
    if (to != null && (airDate == null || airDate.isAfter(to!))) return false;
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is QuestionFilter && setEquals(rounds, other.rounds) &&
      from == other.from && to == other.to;

  @override
  int get hashCode => Object.hash(
      rounds == null ? null : Object.hashAllUnordered(rounds!), from, to);
}

/// The backend is unreachable or broken: network down, missing database,
/// server error. A fallback source may take over.
class SourceUnavailable implements Exception {
  final String message;
  const SourceUnavailable(this.message);

  @override
  String toString() => message;
}

/// The backend works, but nothing matches the filter or everything matching
/// has been hidden.
class NoQuestionFound implements Exception {
  final String message;
  const NoQuestionFound([this.message = 'No question matches.']);

  @override
  String toString() => message;
}

/// Where questions come from: a local database, an HTTP API, and so on.
abstract class QuestionSource {
  /// Human-readable name, used in error messages and the hide dialog.
  String get description;

  bool get supportsRemoteReport => false;

  /// Prepares the source. May throw [SourceUnavailable].
  Future<void> open() async {}

  /// Throws [SourceUnavailable] or [NoQuestionFound].
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any});

  /// Tells the backend a question is bad. Only called when
  /// [supportsRemoteReport] is true.
  Future<void> reportRemote(JeopardyQuestion question) async {}

  Future<void> close() async {}
}
