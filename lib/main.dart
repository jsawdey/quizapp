import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:quizapp/config/source_choice.dart';
import 'package:quizapp/controller/question_repository.dart';
import 'package:quizapp/data/filter_store.dart';
import 'package:quizapp/data/hidden_question_store.dart';
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
  runApp(QuizApp(repository: repository, sources: sources));
}

class QuizApp extends StatelessWidget {
  const QuizApp({super.key, required this.repository, this.sources});

  final QuestionRepository repository;

  /// The sources to offer in the app; none if null.
  final SourceChooser? sources;

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
          sources: sources),
    );
  }
}
