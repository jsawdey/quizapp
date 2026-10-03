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
      );

  /// Throws [SourceConfigError]. Empty strings count as unset.
  factory SourceConfig.parse({String source = '', String apiUrl = '',
      String apiDialect = '', String apiToken = '', bool allowHttp = false}) {
    final name = source.trim();
    final kind = name.isEmpty
        ? SourceKind.local
        : SourceKind.values.where((k) => k.configName == name).firstOrNull;
    if (kind == null) {
      throw SourceConfigError(
          'QUESTION_SOURCE is "$source"; it must be one of: '
          '${SourceKind.values.map((k) => k.configName).join(', ')}.');
    }
    if (!kind.usesApi) return local;

    final url = Uri.tryParse(apiUrl.trim());
    if (apiUrl.trim().isEmpty || url == null || !url.hasAuthority ||
        url.host.isEmpty || !(url.isScheme('https') || url.isScheme('http'))) {
      throw SourceConfigError('QUESTION_SOURCE is "$name", so QUESTION_API_URL must be '
          'an http(s) URL, not "$apiUrl".');
    }
    if (url.isScheme('http') && !allowHttp) {
      throw SourceConfigError('QUESTION_API_URL must use https in release builds: $apiUrl');
    }
    final dialect = apiDialect.trim();
    if (!apiDialects.containsKey(dialect)) {
      throw SourceConfigError('QUESTION_API_DIALECT is "$apiDialect"; it must be one of: '
          '${apiDialects.keys.join(', ')}.');
    }
    final token = apiToken.trim();
    return SourceConfig._(kind, apiUrl: url, apiDialect: dialect,
        apiToken: token.isEmpty ? null : token);
  }
}
