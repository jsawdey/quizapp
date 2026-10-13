import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:quizapp/config/source_choice.dart';
import 'package:quizapp/config/source_config.dart';
import 'package:quizapp/controller/history_recorder.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/controller/score_keeper.dart';
import 'package:quizapp/data/filter_store.dart';
import 'package:quizapp/data/hidden_question_store.dart';
import 'package:quizapp/data/history_client.dart';
import 'package:quizapp/data/history_store.dart';
import 'package:quizapp/data/score_store.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/token_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'quiz_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // sqflite only runs on Android, iOS and macOS; desktop builds use SQLite
  // through FFI instead.
  if (!kIsWeb && const {TargetPlatform.linux, TargetPlatform.windows}
      .contains(defaultTargetPlatform)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // Web builds ask for the API's access token rather than compiling it in.
  final credentials = kIsWeb ? ApiCredentials() : null;
  // The build's own source, or the one last chosen in the app.
  final sources = await SourceChooser.load(credentials: credentials);
  final repository = QuestionRepository(
    source: sources.current.create(),
    // sqflite has no web implementation.
    hiddenStore: kIsWeb ? SharedPrefsHiddenQuestionStore() : SqfliteHiddenQuestionStore(),
    tokenStore: kIsWeb ? SharedPrefsTokenStore() : null,
    credentials: credentials,
    filterStore: SharedPrefsFilterStore(),
  );
  // Every answer is kept on the device and, with a server, synced there.
  // The web keeps only what waits to be sent: its server holds the rest.
  final recorder = HistoryRecorder(
    store: kIsWeb ? SharedPrefsHistoryStore() : SqfliteHistoryStore(),
    client: _historyServer(credentials),
  );
  unawaited(recorder.open().catchError((Object error) {
    debugPrint('Could not open the score history: $error');
  }));
  // Read before the first question can be scored.
  final scoreKeeper = await ScoreKeeper.load(SharedPrefsScoreStore(), recorder: recorder);
  runApp(QuizApp(repository: repository, sources: sources, scoreKeeper: scoreKeeper));
}

/// The build's own `quizapp` server, which keeps the score history whichever
/// source is chosen in the app; null if the build has none. Sends the token
/// in [credentials] if given (the web's, entered in the page), else the
/// configured one.
HistoryClient? _historyServer(ApiCredentials? credentials) {
  final SourceConfig config;
  try {
    config = SourceConfig.fromEnvironment();
  } on SourceConfigError {
    return null;
  }
  final url = config.apiUrl;
  if (url == null || config.apiDialect != 'quizapp') return null;
  return HistoryClient(baseUrl: url, credentials: credentials ?? ApiCredentials(config.apiToken));
}

class QuizApp extends StatelessWidget {
  const QuizApp({super.key, required this.repository, this.sources, this.scoreKeeper});

  final QuestionRepository repository;

  /// The sources to offer in the app; none if null.
  final SourceChooser? sources;

  /// Keeps score; no scoring if null.
  final ScoreKeeper? scoreKeeper;

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trivia',
      theme: ThemeData(
        // This is the theme of your application.
        primarySwatch: Colors.blue,
        useMaterial3: false,
      ),
      home: QuizPage(title: 'Trivia', repository: repository,
          sources: sources, scoreKeeper: scoreKeeper),
    );
  }
}
