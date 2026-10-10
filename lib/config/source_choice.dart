import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quizapp/config/source_config.dart';
import 'package:quizapp/config/source_factory.dart';
import 'package:quizapp/data/api_dialect.dart';
import 'package:quizapp/data/clue_database.dart';
import 'package:quizapp/data/http_question_source.dart';
import 'package:quizapp/data/local_question_source.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A question source the app can switch to.
class SourceOption {
  /// Saved to remember the choice: `configured`, `local:clues`,
  /// `local:trivia`, `opentdb` or `thetriviaapi`.
  final String id;
  final String label;
  final String detail;
  final QuestionSource Function() create;

  const SourceOption({required this.id, required this.label, required this.detail,
    required this.create});
}

/// Where the source chosen in the app is kept between launches.
abstract class SourceChoiceStore {
  /// The saved [SourceOption.id], or null.
  Future<String?> read();
  Future<void> write(String id);
}

class InMemorySourceChoiceStore implements SourceChoiceStore {
  String? id;
  InMemorySourceChoiceStore([this.id]);

  @override
  Future<String?> read() async => id;

  @override
  Future<void> write(String id) async => this.id = id;
}

class SharedPrefsSourceChoiceStore implements SourceChoiceStore {
  static const prefsKey = 'question_source';

  final Future<SharedPreferences> Function() _prefs;

  SharedPrefsSourceChoiceStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  @override
  Future<String?> read() async => (await _prefs()).getString(prefsKey);

  @override
  Future<void> write(String id) async => (await _prefs()).setString(prefsKey, id);
}

/// The sources this build can read from, and which one is in use.
///
/// The one the build was configured with comes first and is the default.
/// Then come the bundled databases (not in web builds, which can't open
/// them) and the public trivia APIs, leaving out any that is the configured
/// one again. Only the configured source gets the access token.
class SourceChooser {
  static const configuredId = 'configured';

  final List<SourceOption> options;
  final SourceChoiceStore store;
  String _currentId;

  SourceChooser(this.options, {required this.store, String? currentId})
      : assert(options.isNotEmpty),
        _currentId = currentId != null && options.any((o) => o.id == currentId)
            ? currentId
            : options.first.id;

  SourceOption get current => options.firstWhere((o) => o.id == _currentId);

  /// Whether there is anything to choose between.
  bool get hasChoice => options.length > 1;

  /// Makes [id] the current option and saves it. Returns its new source, or
  /// null if [id] is already current or unknown. A failed save is only
  /// logged: the choice still applies until the app closes.
  Future<QuestionSource?> choose(String id) async {
    if (id == _currentId || !options.any((o) => o.id == id)) return null;
    _currentId = id;
    try {
      await store.write(id);
    } catch (e) {
      debugPrint('Could not save the question source: $e');
    }
    return current.create();
  }

  /// Reads this build's settings, which databases it bundles and the saved
  /// choice. Problems only narrow the choice: a bad configuration becomes an
  /// option that explains itself, and the other sources still work.
  static Future<SourceChooser> load({ApiCredentials? credentials,
      SourceChoiceStore? store, AssetBundle? bundle}) async {
    final choiceStore = store ?? SharedPrefsSourceChoiceStore();
    SourceConfig? config;
    String? configError;
    try {
      config = SourceConfig.fromEnvironment();
    } on SourceConfigError catch (e) {
      configError = e.message;
    }
    final assets = kIsWeb ? const <String>{} : await _bundledAssets(bundle ?? rootBundle);
    String? saved;
    try {
      saved = await choiceStore.read();
    } catch (e) {
      debugPrint('Could not read the question source: $e');
    }
    return SourceChooser(
        buildOptions(config: config, configError: configError, credentials: credentials,
            bundledDatasets: {
              for (final dataset in LocalDataset.values)
                if (assets.contains(dataset.versionAssetPath)) dataset,
            },
            pageHost: kIsWeb ? Uri.base.host : null),
        store: choiceStore,
        currentId: saved);
  }

  static Future<Set<String>> _bundledAssets(AssetBundle bundle) async {
    try {
      return (await AssetManifest.loadFromAssetBundle(bundle)).listAssets().toSet();
    } catch (e) {
      debugPrint('Could not list the bundled assets: $e');
      return const {};
    }
  }

  /// The options for a build configured with [config] (or failing with
  /// [configError]) that bundles [bundledDatasets]. [pageHost] is set in web
  /// builds.
  @visibleForTesting
  static List<SourceOption> buildOptions({SourceConfig? config, String? configError,
      ApiCredentials? credentials, Set<LocalDataset> bundledDatasets = const {},
      String? pageHost}) {
    final standard = [
      for (final dataset in LocalDataset.values)
        if (bundledDatasets.contains(dataset)) _local(dataset),
      SourceOption(
        id: 'opentdb',
        label: 'Open Trivia Database',
        detail: 'Online trivia from opentdb.com',
        create: () => HttpQuestionSource(
            baseUrl: Uri.parse('https://opentdb.com'), dialect: OpenTdbDialect()),
      ),
      SourceOption(
        id: 'thetriviaapi',
        label: 'The Trivia API',
        detail: 'Online trivia from the-trivia-api.com; non-commercial use',
        create: () => HttpQuestionSource(
            baseUrl: Uri.parse('https://the-trivia-api.com'), dialect: TheTriviaApiDialect()),
      ),
    ];

    final SourceOption configured;
    if (config == null) {
      final reason = 'Invalid question source settings: ${configError ?? 'unknown'}';
      configured = SourceOption(id: configuredId, label: 'As built',
          detail: "This build's settings don't work", create: () =>
              UnavailableQuestionSource(reason));
    } else {
      final sameAs = _standardIdFor(config);
      final match = standard.where((o) => o.id == sameAs).firstOrNull;
      if (match != null) {
        // The configured source is one of the standard ones: list it once,
        // first, under the standard id.
        return [match, ...standard.where((o) => o != match)];
      }
      if (config.kind == SourceKind.local) {
        // Not bundled, so choosing it explains how to build it.
        return [_local(config.localDataset), ...standard];
      }
      configured = SourceOption(id: configuredId, label: _label(config, pageHost),
          detail: _detail(config, pageHost),
          create: () => createQuestionSource(config, credentials: credentials));
    }
    return [configured, ...standard];
  }

  static SourceOption _local(LocalDataset dataset) => SourceOption(
        id: 'local:${dataset.name}',
        label: dataset == LocalDataset.clues ? 'Jeopardy! clues' : 'Trivia',
        detail: dataset == LocalDataset.clues
            ? 'On this device'
            : 'Open Trivia Database questions on this device',
        create: () => LocalQuestionSource(dataset: dataset),
      );

  /// The standard option [config] is the same as, if any.
  static String? _standardIdFor(SourceConfig config) {
    switch (config.kind) {
      case SourceKind.local:
        return 'local:${config.localDataset.name}';
      case SourceKind.api:
        final host = config.apiUrl?.host;
        if (config.apiDialect == 'opentdb' && host == 'opentdb.com') return 'opentdb';
        if (config.apiDialect == 'thetriviaapi' && host == 'the-trivia-api.com') {
          return 'thetriviaapi';
        }
        return null;
      case SourceKind.apiWithLocalFallback:
        return null;
    }
  }

  static String _label(SourceConfig config, String? pageHost) {
    final host = config.apiUrl?.host ?? '';
    if (pageHost != null && host == pageHost) return 'This server';
    return host;
  }

  static String _detail(SourceConfig config, String? pageHost) {
    final what = config.apiDialect == 'quizapp' ? 'Your question server' : 'Questions online';
    final offline = config.kind == SourceKind.apiWithLocalFallback
        ? ', or the ${config.localDataset.description} on this device while it is down'
        : '';
    final where = pageHost != null && config.apiUrl?.host == pageHost
        ? ' ($pageHost)' : '';
    return '$what$where$offline';
  }
}
