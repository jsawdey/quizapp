import 'package:flutter/foundation.dart';
import 'package:quizapp/data/api_dialect.dart';

/// Which backend a build reads questions from.
enum SourceKind {
  local('local'),
  api('api'),
  /// The API, switching to the local database while the API is unavailable.
  apiWithLocalFallback('api_with_local_fallback');

  /// The value `QUESTION_SOURCE` uses for this kind.
  final String configName;
  const SourceKind(this.configName);

  bool get usesApi => this != local;
}

/// A build-time setting that isn't valid. The app shows [message] instead of
/// questions.
class SourceConfigError implements Exception {
  final String message;
  const SourceConfigError(this.message);

  @override
  String toString() => message;
}

/// The question backend, chosen at build time with `--dart-define` or
/// `--dart-define-from-file` (see `config/question_source.example.json`):
///
/// - `QUESTION_SOURCE`: `local` (the default), `api` or `api_with_local_fallback`
/// - `QUESTION_API_URL`: base URL of the API; https, or http in debug and
///   profile builds
/// - `QUESTION_API_DIALECT`: which API it is; one of [apiDialects]
/// - `QUESTION_API_TOKEN`: optional bearer token. It is compiled into the app,
///   so it is not a secret.
///
/// Web builds read from the server that served the page: the source defaults
/// to `api`, the URL to the page's origin and the dialect to `quizapp`. The
/// clue database isn't available there, and the token is entered in the page
/// instead, because a compiled-in token would be readable by every visitor.
class SourceConfig {
  final SourceKind kind;
  final Uri? apiUrl;
  final String? apiDialect;
  final String? apiToken;

  const SourceConfig._(this.kind, {this.apiUrl, this.apiDialect, this.apiToken});

  static const local = SourceConfig._(SourceKind.local);

  /// Reads the values compiled into this build. Throws [SourceConfigError].
  factory SourceConfig.fromEnvironment() => SourceConfig.parse(
        source: const String.fromEnvironment('QUESTION_SOURCE'),
        apiUrl: const String.fromEnvironment('QUESTION_API_URL'),
        apiDialect: const String.fromEnvironment('QUESTION_API_DIALECT'),
        apiToken: const String.fromEnvironment('QUESTION_API_TOKEN'),
        allowHttp: !kReleaseMode,
        isWeb: kIsWeb,
        pageUrl: kIsWeb ? Uri.base : null,
      );

  /// Throws [SourceConfigError]. Empty strings count as unset.
  ///
  /// With [isWeb], the defaults and checks for web builds apply (see the
  /// class comment); [pageUrl] is the page's address, whose origin is the
  /// default API URL.
  factory SourceConfig.parse({String source = '', String apiUrl = '',
      String apiDialect = '', String apiToken = '', bool allowHttp = false,
      bool isWeb = false, Uri? pageUrl}) {
    final name = source.trim();
    final kind = name.isEmpty
        ? (isWeb ? SourceKind.api : SourceKind.local)
        : SourceKind.values.where((k) => k.configName == name).firstOrNull;
    if (kind == null) {
      throw SourceConfigError(
          'QUESTION_SOURCE is "$source"; it must be one of: '
          '${SourceKind.values.map((k) => k.configName).join(', ')}.');
    }
    if (isWeb && kind != SourceKind.api) {
      throw SourceConfigError('QUESTION_SOURCE is "${kind.configName}", but the clue '
          'database isn\'t available in the browser. Serve it with '
          'tool/serve_clues.py and use "api".');
    }
    if (!kind.usesApi) return local;

    final urlText = apiUrl.trim().isEmpty && isWeb && pageUrl != null
        ? Uri(scheme: pageUrl.scheme, host: pageUrl.host,
              port: pageUrl.hasPort ? pageUrl.port : null, path: '/').toString()
        : apiUrl.trim();
    final url = Uri.tryParse(urlText);
    if (urlText.isEmpty || url == null || !url.hasAuthority ||
        url.host.isEmpty || !(url.isScheme('https') || url.isScheme('http'))) {
      throw SourceConfigError('QUESTION_SOURCE is "${kind.configName}", so QUESTION_API_URL '
          'must be an http(s) URL, not "$apiUrl".');
    }
    // In a browser, mixed-content rules decide whether http is allowed.
    if (url.isScheme('http') && !allowHttp && !isWeb) {
      throw SourceConfigError('QUESTION_API_URL must use https in release builds: $apiUrl');
    }
    final dialectText = apiDialect.trim();
    final dialect = dialectText.isEmpty && isWeb ? 'quizapp' : dialectText;
    if (!apiDialects.containsKey(dialect)) {
      throw SourceConfigError('QUESTION_API_DIALECT is "$apiDialect"; it must be one of: '
          '${apiDialects.keys.join(', ')}.');
    }
    final token = apiToken.trim();
    if (isWeb && token.isNotEmpty) {
      throw const SourceConfigError('QUESTION_API_TOKEN would be readable by anyone who '
          'loads the page. Leave it out of web builds; the page asks for the token.');
    }
    return SourceConfig._(kind, apiUrl: url, apiDialect: dialect,
        apiToken: token.isEmpty ? null : token);
  }
}
