import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// Reads from [primary] and switches to [fallback] while [primary] is
/// unavailable, trying [primary] again once [retryAfter] has passed.
///
/// Only [SourceUnavailable] switches over: a [NoQuestionFound] from [primary]
/// means it works but has nothing matching, and is passed on.
class FallbackQuestionSource extends QuestionSource {
  final QuestionSource primary;
  final QuestionSource fallback;
  final Duration retryAfter;
  final DateTime Function() _now;

  DateTime? _primaryFailedAt;
  SourceUnavailable? _primaryError;
  bool _primaryOpen = false;
  bool _fallbackOpen = false;
  bool _usingFallback = false;
  final Expando<bool> _fromFallback = Expando();

  FallbackQuestionSource({required this.primary, required this.fallback,
    this.retryAfter = const Duration(seconds: 60), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  /// Whether the last question came from [fallback]. The UI shows this as
  /// being offline.
  bool get usingFallback => _usingFallback;

  @override
  String get description => primary.description;

  @override
  bool get supportsRemoteReport =>
      primary.supportsRemoteReport || fallback.supportsRemoteReport;

  /// Only filters both sources apply: one that worked on the primary and
  /// then failed on the fallback would look like a bug.
  @override
  Set<FilterKind> get supportedFilters =>
      primary.supportedFilters.intersection(fallback.supportedFilters);

  /// Opens nothing up front: each source is opened the first time it's
  /// needed, so a build without a fallback database works while the primary
  /// does, and a primary that's down at launch doesn't stop the fallback.
  @override
  Future<void> open() async {}

  @override
  Future<JeopardyQuestion> randomQuestion({QuestionFilter filter = QuestionFilter.any}) async {
    final SourceUnavailable primaryError;
    try {
      if (_primaryFailedAt != null &&
          _now().difference(_primaryFailedAt!) < retryAfter) {
        throw _primaryError!;
      }
      if (!_primaryOpen) {
        await primary.open();
        _primaryOpen = true;
      }
      final question = await primary.randomQuestion(filter: filter);
      _primaryFailedAt = null;
      _usingFallback = false;
      return question;
    } on SourceUnavailable catch (e) {
      primaryError = e;
      // Keep the time of the first failure, so the cooldown isn't extended
      // by every question served while it runs.
      if (_primaryFailedAt == null ||
          _now().difference(_primaryFailedAt!) >= retryAfter) {
        _primaryFailedAt = _now();
        _primaryError = e;
        debugPrint('${primary.description} unavailable, using ${fallback.description}: $e');
      }
    }

    try {
      if (!_fallbackOpen) {
        await fallback.open();
        _fallbackOpen = true;
      }
      final question = await fallback.randomQuestion(filter: filter);
      _fromFallback[question] = true;
      _usingFallback = true;
      return question;
    } on SourceUnavailable catch (e) {
      throw SourceUnavailable('${primaryError.message} (fallback: ${e.message})');
    }
  }

  QuestionSource _servedBy(JeopardyQuestion question) =>
      _fromFallback[question] == true ? fallback : primary;

  /// Whether the source that served [question] can report it.
  @override
  bool canReport(JeopardyQuestion question) => _servedBy(question).canReport(question);

  /// Reports to whichever source served [question], if it can.
  @override
  Future<void> reportRemote(JeopardyQuestion question) async {
    final source = _servedBy(question);
    if (source.canReport(question)) await source.reportRemote(question);
  }

  @override
  Future<void> close() async {
    await Future.wait([primary.close(), fallback.close()]);
    _primaryOpen = false;
    _fallbackOpen = false;
  }
}
