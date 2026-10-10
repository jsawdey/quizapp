import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:quizapp/model/question.dart';

/// The kinds of filter a source can apply; see [QuestionSource.supportedFilters].
enum FilterKind {
  /// [QuestionFilter.rounds].
  round,

  /// [QuestionFilter.from] and [QuestionFilter.to].
  airDate,

  /// [QuestionFilter.boardRows].
  boardRow,
}

/// Narrows which clues a source may return. Sources that can't filter on the
/// server leave it to [QuestionFilter.matches].
class QuestionFilter {
  final Set<int>? rounds;
  final DateTime? from;
  final DateTime? to;

  /// Rows on the board, 1 (top) to 5 (bottom); see [JeopardyQuestion.boardRow].
  /// Only narrows Jeopardy! and Double Jeopardy! clues: Final Jeopardy! has
  /// no row, and passes whenever its round does.
  final Set<int>? boardRows;

  const QuestionFilter({this.rounds, this.from, this.to, this.boardRows});

  static const any = QuestionFilter();

  /// Jeopardy!, Double Jeopardy! and Final Jeopardy!.
  static const allRounds = {1, 2, 3};

  /// Every row on the board, top to bottom.
  static const allBoardRows = {1, 2, 3, 4, 5};

  /// This filter with "every round" and "every row" written as no filter, so
  /// a filter that lets everything through equals [any].
  QuestionFilter normalized() => QuestionFilter(
      rounds: rounds != null && rounds!.containsAll(allRounds) ? null : rounds,
      from: from, to: to,
      boardRows: boardRows != null && boardRows!.containsAll(allBoardRows)
          ? null : boardRows);

  /// Whether this filter narrows anything.
  bool get isAny => this == any;

  /// This filter without the parts a source supporting only [kinds] can't
  /// apply, so a filter saved under one source can't empty another.
  QuestionFilter limitedTo(Set<FilterKind> kinds) => QuestionFilter(
      rounds: kinds.contains(FilterKind.round) ? rounds : null,
      from: kinds.contains(FilterKind.airDate) ? from : null,
      to: kinds.contains(FilterKind.airDate) ? to : null,
      boardRows: kinds.contains(FilterKind.boardRow) ? boardRows : null);

  bool matches(JeopardyQuestion q) {
    final rounds = this.rounds;
    if (rounds != null && !rounds.contains(q.round)) return false;
    final airDate = q.airDate;
    if (from != null && (airDate == null || airDate.isBefore(from!))) return false;
    if (to != null && (airDate == null || airDate.isAfter(to!))) return false;
    final boardRows = this.boardRows;
    if (boardRows != null && !q.isFinalJeopardy && !boardRows.contains(q.boardRow)) {
      return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is QuestionFilter && setEquals(rounds, other.rounds) &&
      from == other.from && to == other.to && setEquals(boardRows, other.boardRows);

  @override
  int get hashCode => Object.hash(
      rounds == null ? null : Object.hashAllUnordered(rounds!), from, to,
      boardRows == null ? null : Object.hashAllUnordered(boardRows!));
}

/// [date] as `YYYY-MM-DD`, the format air dates use in filters and the
/// clue database.
String isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// The backend is unreachable or broken: network down, missing database,
/// server error. A fallback source may take over.
class SourceUnavailable implements Exception {
  final String message;
  const SourceUnavailable(this.message);

  @override
  String toString() => message;
}

/// The backend refused the request because its access token is missing or
/// wrong. Still [SourceUnavailable], so a fallback source can take over.
class Unauthorized extends SourceUnavailable {
  const Unauthorized(super.message);
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

  /// The filters this source applies reliably. The app offers only these.
  Set<FilterKind> get supportedFilters => const {};

  /// Whether hiding [question] reports it to the backend too.
  bool canReport(JeopardyQuestion question) => supportsRemoteReport;

  /// Prepares the source. May throw [SourceUnavailable].
  Future<void> open() async {}

  /// Throws [SourceUnavailable] or [NoQuestionFound].
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any});

  /// Tells the backend a question is bad. Only called when [canReport] is
  /// true for it.
  Future<void> reportRemote(JeopardyQuestion question) async {}

  Future<void> close() async {}
}
