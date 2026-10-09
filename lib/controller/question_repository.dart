import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/data/token_store.dart';
import 'package:quizapp/model/question.dart';

/// What the UI talks to. Forwards to a [QuestionSource] and handles what is
/// the same for every source: skipping hidden questions and hiding them.
class QuestionRepository {
  /// How many random questions to try before giving up because they were all
  /// hidden.
  static const maxAttempts = 20;

  final QuestionSource source;
  final HiddenQuestionStore hiddenStore;

  /// Where an access token entered in the app is kept, and the credentials the
  /// source sends. Both are set in web builds, which ask for the token
  /// instead of compiling it in.
  final TokenStore? tokenStore;
  final ApiCredentials? credentials;
  Future<void>? _opening;

  QuestionRepository({required this.source, required this.hiddenStore,
    this.tokenStore, this.credentials});

  /// Opens the source and the hidden-question store. Safe to call more than
  /// once; a failed open is retried on the next call.
  Future<void> open() => _opening ??= _open();

  Future<void> _open() async {
    try {
      final tokenStore = this.tokenStore;
      final credentials = this.credentials;
      if (tokenStore != null && credentials != null) {
        credentials.token = await tokenStore.read() ?? credentials.token;
      }
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

  /// Whether the app can ask for an access token when the source needs one.
  bool get canSetToken => tokenStore != null && credentials != null;

  /// Saves [token] and uses it from the next request on. Only allowed when
  /// [canSetToken].
  Future<void> setToken(String token) async {
    final tokenStore = this.tokenStore;
    final credentials = this.credentials;
    if (tokenStore == null || credentials == null) {
      throw StateError('This repository has no token store');
    }
    final trimmed = token.trim();
    await tokenStore.write(trimmed);
    credentials.token = trimmed;
  }

  /// Whether hiding [question] also reports it to the source.
  bool canReport(JeopardyQuestion question) => source.canReport(question);

  /// Where reports go, for the hide dialog.
  String get reportTarget => source.description;

  /// Whether questions are coming from the fallback source because the main
  /// one is unavailable.
  bool get usingFallback {
    final source = this.source;
    return source is FallbackQuestionSource && source.usingFallback;
  }

  /// Hides [question] on this device, then reports it to the source if it can
  /// be. A failed report is only logged: hiding still works offline.
  Future<void> hide(JeopardyQuestion question) async {
    await open();
    await hiddenStore.hide(question);
    if (source.canReport(question)) {
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
