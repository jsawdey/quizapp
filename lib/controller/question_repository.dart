import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:quizapp/data/fallback_question_source.dart';
import 'package:quizapp/data/filter_store.dart';
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

  /// Where the filter chosen in the app is kept between launches.
  final FilterStore? filterStore;
  QuestionFilter _filter = QuestionFilter.any;
  bool _filterChosen = false;
  Future<void>? _opening;

  QuestionRepository({required this.source, required this.hiddenStore,
    this.tokenStore, this.credentials, this.filterStore});

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
      await _readFilter();
      await Future.wait([source.open(), hiddenStore.open()]);
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  /// Loads the saved filter, unless one was chosen while opening. A filter
  /// that can't be read is only logged: questions still load, unfiltered.
  Future<void> _readFilter() async {
    final filterStore = this.filterStore;
    if (filterStore == null || _filterChosen) return;
    try {
      final saved = await filterStore.read();
      // Kept whole: [filter] drops what the source can't apply each time.
      if (!_filterChosen) _filter = saved.normalized();
    } catch (error) {
      debugPrint('Could not read the saved filter: $error');
    }
  }

  QuestionFilter _usable(QuestionFilter filter) =>
      filter.normalized().limitedTo(source.supportedFilters);

  /// The filters the source can apply; the app offers only these. A
  /// `quizapp` API only says which it supports once it's open.
  Set<FilterKind> get supportedFilters => source.supportedFilters;

  /// The category names the source offers for [QuestionFilter.categories].
  Future<List<String>> filterCategories() async {
    await open();
    return source.filterCategories();
  }

  /// The filter [next] applies: the one last chosen, or the saved one once
  /// the repository is open, without anything the source can't apply now.
  QuestionFilter get filter => _usable(_filter);

  /// Uses [filter] from the next question on, and saves it. A failed save is
  /// thrown, but the filter still applies until the app closes.
  Future<void> setFilter(QuestionFilter filter) async {
    _filter = _usable(filter);
    _filterChosen = true;
    await filterStore?.write(_filter);
  }

  /// Throws [SourceUnavailable] or [NoQuestionFound]. Uses [filter] if
  /// given, else [QuestionRepository.filter].
  Future<Question> next({QuestionFilter? filter}) async {
    await open();
    final using = filter ?? this.filter;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final question = await source.randomQuestion(filter: using);
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
  bool canReport(Question question) => source.canReport(question);

  /// Where reports go, for the hide dialog.
  String get reportTarget => source.description;

  /// The credit the current questions' license asks for; see
  /// [QuestionSource.attribution].
  String? get attribution => source.attribution;

  /// Whether questions are coming from the fallback source because the main
  /// one is unavailable.
  bool get usingFallback {
    final source = this.source;
    return source is FallbackQuestionSource && source.usingFallback;
  }

  /// Hides [question] on this device, then reports it to the source if it can
  /// be. A failed report is only logged: hiding still works offline.
  Future<void> hide(Question question) async {
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
