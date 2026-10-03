import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/question.dart';

/// What the UI talks to. Forwards to a [QuestionSource] and handles what is
/// the same for every source: skipping hidden questions and hiding them.
class QuestionRepository {
  /// How many random questions to try before giving up because they were all
  /// hidden.
  static const maxAttempts = 20;

  final QuestionSource source;
  final HiddenQuestionStore hiddenStore;
  Future<void>? _opening;

  QuestionRepository({required this.source, required this.hiddenStore});

  /// Opens the source and the hidden-question store. Safe to call more than
  /// once; a failed open is retried on the next call.
  Future<void> open() => _opening ??= _open();

  Future<void> _open() async {
    try {
      await Future.wait([source.open(), hiddenStore.open()]);
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  /// Throws [SourceUnavailable] or [NoQuestionFound].
  Future<JeopardyQuestion> next({QuestionFilter filter = QuestionFilter.any}) async {
    await open();
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final question = await source.randomQuestion(filter: filter);
      if (!hiddenStore.isHidden(question)) return question;
    }
    throw const NoQuestionFound('Every question tried has been hidden.');
  }

  bool get supportsRemoteReport => source.supportsRemoteReport;

  /// Hides [question] on this device, then reports it to the source if the
  /// source supports that. A failed report is only logged: hiding still works
  /// offline.
  Future<void> hide(JeopardyQuestion question) async {
    await open();
    await hiddenStore.hide(question);
    if (source.supportsRemoteReport) {
      unawaited(source.reportRemote(question).catchError((Object error) {
        debugPrint('Could not report question ${question.key}: $error');
      }));
    }
  }

  Future<void> close() async {
    await Future.wait([source.close(), hiddenStore.close()]);
    _opening = null;
  }
}
