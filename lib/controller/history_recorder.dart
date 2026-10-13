import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:quizapp/data/history_client.dart';
import 'package:quizapp/data/history_store.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/history.dart';

enum HistorySyncStatus { idle, syncing, failed, unauthorized }

/// Keeps every answer in the device's [HistoryStore] and, when the build has
/// a server, syncs it there: sends what's waiting, then fetches what the
/// other devices sent (docs/history-plan.md §3).
///
/// Sync problems never reach the player's game: they show in [status] and
/// the recorder tries again later.
class HistoryRecorder extends ChangeNotifier {
  /// How long to wait before trying again after the 1st, 2nd and later
  /// failures.
  static const retryDelays = [Duration(minutes: 1), Duration(minutes: 5), Duration(minutes: 15)];

  final HistoryStore store;

  /// The build's server; null if it has none.
  final HistoryClient? client;

  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _timer;

  Future<void>? _opening;
  bool? _serverKeepsHistory;
  Future<void>? _syncing;
  bool _syncAgain = false;
  int _failures = 0;
  Timer? _retry;
  HistorySyncStatus _status = HistorySyncStatus.idle;
  String? _error;
  DateTime? _lastSynced;
  int _unsent = 0;
  int _revision = 0;

  HistoryRecorder({required this.store, this.client,
    @visibleForTesting DateTime Function()? now,
    @visibleForTesting Timer Function(Duration, void Function())? timer})
      : _now = now ?? DateTime.now,
        _timer = timer ?? Timer.new;

  /// Whether there is a history to show: the device keeps one, or its server
  /// does (the web build's case, once the server has said so).
  bool get offersHistory => store.keepsHistory || _serverKeepsHistory == true;

  /// The server's name, for messages; null without one.
  String? get serverName => client?.description;

  HistorySyncStatus get status => _status;

  /// Why the last sync failed, while [status] says it did.
  String? get error => _error;

  DateTime? get lastSynced => _lastSynced;

  /// Answers on this device not yet on the server.
  int get unsentCount => _unsent;

  /// Goes up whenever the device's history gains what another device sent,
  /// so a screen showing it knows to read it again.
  int get revision => _revision;

  /// Opens the store, then syncs in the background. Safe to call more than
  /// once; a failed open is tried again on the next call.
  Future<void> open() => _opening ??= _open();

  Future<void> _open() async {
    try {
      await store.open();
      _lastSynced = (await store.syncState()).lastSynced;
      _unsent = await store.unsentCount();
    } catch (_) {
      _opening = null;
      rethrow;
    }
    notifyListeners();
    unawaited(sync());
  }

  /// Keeps [answer] and its game's totals, then syncs. Completes once both
  /// are in the store; the sync carries on in the background.
  Future<void> record(HistoryAnswer answer, HistoryGame game) async {
    await open();
    await store.putAnswer(answer);
    await store.putGame(game);
    _unsent = await store.unsentCount();
    notifyListeners();
    unawaited(sync());
  }

  /// Sends what's waiting and fetches what's new. One sync runs at a time;
  /// asked for during one, another follows it, and the returned future
  /// completes after both. After a failure, the retry timer takes over
  /// instead. Failures are reported in [status], not thrown.
  Future<void> sync() async {
    final client = this.client;
    if (client == null) return;
    final running = _syncing;
    if (running != null) {
      _syncAgain = true;
      return running;
    }
    final done = Completer<void>();
    _syncing = done.future;
    try {
      var synced = false;
      do {
        _syncAgain = false;
        synced = await _syncOnce(client);
      } while (_syncAgain && synced);
    } finally {
      _syncing = null;
      done.complete();
    }
  }

  /// Whether it synced.
  Future<bool> _syncOnce(HistoryClient client) async {
    _retry?.cancel();
    _retry = null;
    _status = HistorySyncStatus.syncing;
    notifyListeners();
    try {
      await open();
      if (_serverKeepsHistory != true) {
        final keeps = await client.keepsHistory();
        _serverKeepsHistory = keeps;
        if (!keeps) {
          // An older server: the device keeps its history to itself.
          _status = HistorySyncStatus.idle;
          return true;
        }
      }
      await _sendAll(client);
      if (store.keepsHistory) await _fetchAll(client);
      _lastSynced = _now();
      final state = await store.syncState();
      await store.saveSyncState(HistorySyncState(
          historyId: state.historyId, cursor: state.cursor, lastSynced: _lastSynced));
      _failures = 0;
      _status = HistorySyncStatus.idle;
      _error = null;
      return true;
    } on Unauthorized catch (e) {
      // Waits for the next sync, after the player has given the token.
      _status = HistorySyncStatus.unauthorized;
      _error = e.message;
    } on SourceUnavailable catch (e) {
      _failed(e.message);
    } catch (e) {
      _failed('$e');
    } finally {
      try {
        _unsent = await store.unsentCount();
      } catch (_) {}
      notifyListeners();
    }
    return false;
  }

  void _failed(String message) {
    debugPrint('History sync failed: $message');
    _status = HistorySyncStatus.failed;
    _error = message;
    final delay = retryDelays[_failures < retryDelays.length ? _failures : retryDelays.length - 1];
    _failures++;
    _retry = _timer(delay, () => unawaited(sync()));
  }

  Future<void> _sendAll(HistoryClient client) async {
    HistoryBatch? previous;
    while (true) {
      final batch = await store.unsent();
      if (batch.isEmpty) return;
      // A batch the store won't mark as sent would otherwise go round forever.
      if (previous != null && listEquals(batch.answers, previous.answers) &&
          listEquals(batch.games, previous.games)) {
        throw StateError('The history store kept ${batch.length} rows waiting after '
            'they were sent');
      }
      previous = batch;
      try {
        await client.send(batch);
      } on HistoryRejected catch (e) {
        // One bad row mustn't hold up the rest: send them one at a time,
        // and drop only those the server refuses.
        if (batch.length == 1) {
          debugPrint('History: the server refused ${batch.answers.firstOrNull ?? batch.games.first}'
              ' ($e); dropping it');
        } else {
          for (final single in [
            for (final a in batch.answers) HistoryBatch(answers: [a]),
            for (final g in batch.games) HistoryBatch(games: [g]),
          ]) {
            try {
              await client.send(single);
            } on HistoryRejected catch (e) {
              debugPrint('History: the server refused '
                  '${single.answers.firstOrNull ?? single.games.first} ($e); dropping it');
            }
          }
        }
      }
      await store.markSent(batch);
    }
  }

  Future<void> _fetchAll(HistoryClient client) async {
    var state = await store.syncState();
    var merged = false;
    while (true) {
      final page = await client.fetch(after: state.cursor);
      final knownId = state.historyId;
      if (knownId != null && knownId != page.historyId) {
        // The server's history was replaced: give it everything this device
        // has, then fetch the new one from the start.
        debugPrint('History: the server has a new history; sending it this device\'s');
        await store.resendAll();
        await store.saveSyncState(
            HistorySyncState(historyId: page.historyId, lastSynced: state.lastSynced));
        _syncAgain = true;
        return;
      }
      if (page.answers.isNotEmpty || page.games.isNotEmpty) {
        await store.merge(page.answers, page.games);
        merged = true;
      }
      state = HistorySyncState(
          historyId: page.historyId, cursor: page.next, lastSynced: state.lastSynced);
      await store.saveSyncState(state);
      if (!page.more) break;
    }
    if (merged) _revision++;
  }

  /// The whole history to show. Phones and desktop read their own store;
  /// the web fetches it from the server, adding what's still waiting here.
  /// Throws [SourceUnavailable] or [Unauthorized] when the web build can't
  /// reach its server.
  Future<HistorySnapshot> history() async {
    await open();
    if (store.keepsHistory) return store.all();
    final client = this.client;
    if (client == null) return HistorySnapshot.empty;
    final answers = <String, HistoryAnswer>{};
    final games = <String, HistoryGame>{};
    var after = 0;
    while (true) {
      final page = await client.fetch(after: after);
      for (final a in page.answers) {
        answers[a.id] = a;
      }
      for (final g in page.games) {
        games[g.id] = g;
      }
      after = page.next;
      if (!page.more) break;
    }
    final waiting = await store.unsent(answers: 1 << 30, games: 1 << 30);
    for (final a in waiting.answers) {
      answers[a.id] = a;
    }
    for (final g in waiting.games) {
      final old = games[g.id];
      if (old == null || !old.updatedAt.isAfter(g.updatedAt)) games[g.id] = g;
    }
    return HistorySnapshot(answers: answers.values.toList(), games: games.values.toList());
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }
}
