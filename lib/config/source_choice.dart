import 'dart:convert';

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
  /// `local:trivia`, `opentdb`, `thetriviaapi`, or `server:<name>` for
  /// another database on the configured server.
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

/// Where the databases learned from the configured server are kept, so a
/// saved choice of one of them still works at the next launch.
abstract class ServerDatasetStore {
  /// The databases saved for the server at [url]; null if none were, or
  /// they were saved for another server.
  Future<List<ServerDataset>?> read(Uri url);
  Future<void> write(Uri url, List<ServerDataset> datasets);
}

class InMemoryServerDatasetStore implements ServerDatasetStore {
  Uri? url;
  List<ServerDataset>? datasets;

  @override
  Future<List<ServerDataset>?> read(Uri url) async => url == this.url ? datasets : null;

  @override
  Future<void> write(Uri url, List<ServerDataset> datasets) async {
    this.url = url;
    this.datasets = datasets;
  }
}

class SharedPrefsServerDatasetStore implements ServerDatasetStore {
  static const prefsKey = 'server_datasets';

  final Future<SharedPreferences> Function() _prefs;

  SharedPrefsServerDatasetStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  @override
  Future<List<ServerDataset>?> read(Uri url) async {
    final text = (await _prefs()).getString(prefsKey);
    if (text == null) return null;
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, dynamic> || json['url'] != url.toString()) return null;
    final datasets = json['datasets'];
    if (datasets is! List) return null;
    return [for (final item in datasets) ?ServerDataset.fromJson(item)];
  }

  @override
  Future<void> write(Uri url, List<ServerDataset> datasets) async =>
      (await _prefs()).setString(prefsKey, jsonEncode({
        'url': url.toString(),
        'datasets': [for (final dataset in datasets) dataset.toJson()],
      }));
}

/// The `quizapp` server a build is configured with. Once the app has reached
/// it, its other databases are offered too (docs/combined-server-plan.md).
class ConfiguredServer {
  /// The configured URL, ending in `/`.
  final Uri url;

  /// What the options for its databases say under their names.
  final String detail;

  /// What the configured option says once it's named after its database,
  /// so the label no longer shows the host.
  final String configuredDetail;

  final QuestionSource Function(ServerDataset dataset) create;
  final ServerDatasetStore store;

  ConfiguredServer({required Uri url, required this.detail, required this.configuredDetail,
    required this.create, required this.store})
      : url = withSlash(url);

  /// [url] with a path ending in `/`, as [ServerDataset.url]s have.
  static Uri withSlash(Uri url) =>
      url.path.endsWith('/') ? url : url.replace(path: '${url.path}/');

  /// Whether [url] is on this server, so it may have the token.
  bool hosts(Uri url) => url.scheme == this.url.scheme && url.host == this.url.host &&
      url.port == this.url.port && url.userInfo == this.url.userInfo;
}

/// The sources this build can read from, and which one is in use.
///
/// The one the build was configured with comes first and is the default.
/// When that is a `quizapp` server, the other databases it lists come next,
/// once [learn] has been told them. Then come the bundled databases (not in
/// web builds, which can't open them) and the public trivia APIs, leaving
/// out any that is the configured one again. Only the configured server's
/// sources get the access token.
class SourceChooser {
  static const configuredId = 'configured';

  /// The prefix of the ids of the configured server's other databases.
  static const serverIdPrefix = 'server:';

  /// The options without the server's databases.
  final List<SourceOption> _built;
  final SourceChoiceStore store;
  final ConfiguredServer? server;
  List<ServerDataset> _datasets = const [];
  List<SourceOption> _options;
  String _currentId;

  /// [datasets] are the server's databases as saved at the last launch.
  SourceChooser(List<SourceOption> options, {required this.store, String? currentId,
      this.server, List<ServerDataset> datasets = const []})
      : assert(options.isNotEmpty),
        _built = options,
        _options = options,
        _currentId = options.first.id {
    _setDatasets(datasets);
    if (currentId != null && _options.any((o) => o.id == currentId)) _currentId = currentId;
  }

  /// Every option, in the order to offer them.
  List<SourceOption> get options => _options;

  SourceOption get current => _options.firstWhere((o) => o.id == _currentId);

  /// The configured server's databases, as last learned.
  List<ServerDataset> get datasets => _datasets;

  /// Offers [datasets], the databases a source's server listed, if that is
  /// the configured server and they differ from what was offered. Returns
  /// whether the options changed. An empty list changes nothing: it comes
  /// from a source that lists no databases. The list is saved in the
  /// background; a failed save is only logged.
  bool learn(List<ServerDataset> datasets) {
    final server = this.server;
    if (server == null) return false;
    final onServer = [for (final dataset in datasets) if (server.hosts(dataset.url)) dataset];
    if (onServer.isEmpty || listEquals(onServer, _datasets)) return false;
    _setDatasets(onServer);
    server.store.write(server.url, onServer).catchError(
        (Object e) => debugPrint('Could not save the server\'s databases: $e'));
    return true;
  }

  void _setDatasets(List<ServerDataset> datasets) {
    final server = this.server;
    if (server == null || _built.first.id != configuredId) {
      _options = _built;
      return;
    }
    _datasets = [for (final dataset in datasets) if (server.hosts(dataset.url)) dataset];
    final previous = {for (final option in _options) option.id: option};
    final configured = _built.first;
    final own = _datasets.where((d) => d.url == server.url).firstOrNull;
    final others = [for (final dataset in _datasets) if (dataset.url != server.url) dataset];
    String label(ServerDataset dataset) {
      final shared = _datasets.where((d) => d.kind == dataset.kind).length > 1;
      final byKind = switch (dataset.kind) {
        'clues' => 'Jeopardy! clues',
        'trivia' => 'Trivia',
        _ => dataset.name,
      };
      return shared && byKind != dataset.name ? '$byKind (${dataset.name})' : byKind;
    }

    final serverOptions = [
      for (final dataset in others)
        SourceOption(id: '$serverIdPrefix${dataset.name}', label: label(dataset),
            detail: server.detail, create: () => server.create(dataset)),
    ];
    // The option in use stays until the next launch, even if the server
    // stopped listing it.
    final inUse = previous[_currentId];
    if (inUse != null && _currentId.startsWith(serverIdPrefix) &&
        !serverOptions.any((o) => o.id == _currentId)) {
      serverOptions.insert(0, inUse);
    }
    _options = [
      own == null ? configured : SourceOption(id: configured.id, label: label(own),
          detail: server.configuredDetail, create: configured.create),
      ...serverOptions,
      ..._built.skip(1),
    ];
  }

  /// Whether there is anything to choose between.
  bool get hasChoice => options.length > 1;

  /// Makes [id] the current option and saves it. Returns its new source, or
  /// null if [id] is already current or unknown. A failed save is only
  /// logged: the choice still applies until the app closes.
  Future<QuestionSource?> choose(String id) async {
    if (id == _currentId || !_options.any((o) => o.id == id)) return null;
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
      SourceChoiceStore? store, ServerDatasetStore? datasetStore, AssetBundle? bundle}) async {
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
    final pageHost = kIsWeb ? Uri.base.host : null;
    final server = config == null ? null : configuredServer(config,
        credentials: credentials, pageHost: pageHost,
        store: datasetStore ?? SharedPrefsServerDatasetStore());
    List<ServerDataset>? datasets;
    if (server != null) {
      try {
        datasets = await server.store.read(server.url);
      } catch (e) {
        debugPrint('Could not read the server\'s databases: $e');
      }
    }
    return SourceChooser(
        buildOptions(config: config, configError: configError, credentials: credentials,
            bundledDatasets: {
              for (final dataset in LocalDataset.values)
                if (assets.contains(dataset.versionAssetPath)) dataset,
            },
            pageHost: pageHost),
        store: choiceStore,
        currentId: saved,
        server: server,
        datasets: datasets ?? const []);
  }

  /// The `quizapp` server [config] reads from, whose other databases the app
  /// can offer; null for any other source.
  static ConfiguredServer? configuredServer(SourceConfig config,
      {ApiCredentials? credentials, String? pageHost, required ServerDatasetStore store}) {
    final url = config.apiUrl;
    if (!config.kind.usesApi || config.apiDialect != 'quizapp' || url == null) return null;
    return ConfiguredServer(url: url,
        detail: _detail(config, pageHost, offline: false, named: true),
        configuredDetail: _detail(config, pageHost, named: true),
        store: store,
        create: (dataset) =>
            createServerDatasetSource(config, dataset, credentials: credentials));
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

  /// With [offline], it mentions the fallback to the database on this
  /// device, if the build has one. With [named], it names the host, as it
  /// always does in a browser, where the label says "This server".
  static String _detail(SourceConfig config, String? pageHost,
      {bool offline = true, bool named = false}) {
    final what = config.apiDialect == 'quizapp' ? 'Your question server' : 'Questions online';
    final fallback = offline && config.kind == SourceKind.apiWithLocalFallback
        ? ', or the ${config.localDataset.description} on this device while it is down'
        : '';
    final host = config.apiUrl?.host;
    final where = host != null && (named || host == pageHost) ? ' ($host)' : '';
    return '$what$where$fallback';
  }
}
