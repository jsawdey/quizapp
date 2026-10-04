import 'package:shared_preferences/shared_preferences.dart';

/// Where the web UI keeps the API's access token between visits.
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
}

/// Keeps the token in memory only. Used by tests.
class InMemoryTokenStore implements TokenStore {
  String? token;
  InMemoryTokenStore([this.token]);

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String token) async => this.token = token;
}

/// Keeps the token with shared_preferences: the browser's localStorage on the
/// web, readable by scripts on the page's origin.
class SharedPrefsTokenStore implements TokenStore {
  static const prefsKey = 'api_token';

  final Future<SharedPreferences> Function() _prefs;

  SharedPrefsTokenStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  @override
  Future<String?> read() async => (await _prefs()).getString(prefsKey);

  @override
  Future<void> write(String token) async => (await _prefs()).setString(prefsKey, token);
}
