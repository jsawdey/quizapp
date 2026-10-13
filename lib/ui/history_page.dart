import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:quizapp/controller/history_recorder.dart';
import 'package:quizapp/data/question_source.dart';
import 'package:quizapp/model/history.dart';
import 'package:quizapp/model/history_stats.dart';
import 'package:quizapp/ui/score_line_widget.dart';

/// All-time statistics from the score history (docs/history-plan.md §5).
///
/// Phones and desktop show the device's history at once and sync in the
/// background, updating when the sync brings anything new. The web fetches
/// the history from its server.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.recorder, this.now});

  final HistoryRecorder recorder;

  /// The clock, for tests; the last 7 and 30 days end today.
  final DateTime Function()? now;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  HistoryStats? _stats;
  String? _error;
  int _revision = -1;

  HistoryRecorder get _recorder => widget.recorder;
  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_recorderChanged);
    unawaited(_load());
    if (_recorder.store.keepsHistory) unawaited(_recorder.sync());
  }

  @override
  void dispose() {
    _recorder.removeListener(_recorderChanged);
    super.dispose();
  }

  void _recorderChanged() {
    // A sync that brought answers from other devices, or a status to show.
    if (_recorder.revision != _revision && _recorder.store.keepsHistory) {
      unawaited(_load());
    } else {
      setState(() {});
    }
  }

  Future<void> _load() async {
    _revision = _recorder.revision;
    try {
      final history = await _recorder.history();
      if (!mounted) return;
      setState(() {
        _stats = HistoryStats.compute(history.answers, history.games, now: _now());
        _error = null;
      });
    } on Unauthorized {
      if (!mounted) return;
      setState(() => _error = '${_recorder.serverName} needs the access token. '
          'Enter it on the main screen, then try again.');
    } on SourceUnavailable {
      if (!mounted) return;
      setState(() => _error = 'The history is on ${_recorder.serverName}, '
          'which can\'t be reached right now.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not read the history: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: stats == null
          ? Center(child: error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                    Text(error, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton(onPressed: _load, child: const Text('Try again')),
                  ]),
                ))
          : Align(
              alignment: Alignment.topCenter,
              // Rows wider than this are hard to read across on a desktop.
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: <Widget>[
                    if (stats.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('No answers yet. Each question you answer shows up here.'),
                      )
                    else
                      ..._sections(context, stats),
                    ..._footer(context),
                  ],
                ),
              ),
            ),
    );
  }

  List<Widget> _sections(BuildContext context, HistoryStats stats) => <Widget>[
        _Heading('Overall'),
        _TallyRow('All time', stats.total),
        _TallyRow('Last 30 days', stats.last30Days),
        _TallyRow('Last 7 days', stats.last7Days),
        if (stats.byRound.isNotEmpty || stats.byRow.isNotEmpty) ...[
          _Heading('Jeopardy! clues'),
          for (final MapEntry(key: round, value: tally) in stats.byRound.entries)
            _TallyRow(_roundNames[round] ?? 'Round $round', tally),
          for (final MapEntry(key: row, value: tally) in stats.byRow.entries)
            _TallyRow(_rowName(row), tally),
        ],
        if (stats.byDifficulty.isNotEmpty) ...[
          _Heading('Trivia'),
          for (final MapEntry(key: difficulty, value: tally) in stats.byDifficulty.entries)
            _TallyRow(_capitalized(difficulty), tally),
        ],
        if (stats.strongest.isNotEmpty) ...[
          _Heading('Strongest categories'),
          for (final c in stats.strongest) _CategoryRow(c),
        ],
        if (stats.weakest.isNotEmpty) ...[
          _Heading('Weakest categories'),
          for (final c in stats.weakest) _CategoryRow(c),
        ],
        if (stats.recentGames.isNotEmpty) ...[
          _Heading('Games'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('Best streak ${formatCount(stats.bestStreak)}'),
          ),
          for (final game in stats.recentGames) _GameRow(game),
        ],
      ];

  List<Widget> _footer(BuildContext context) {
    final server = _recorder.serverName;
    if (server == null) return const <Widget>[];
    final lastSynced = _recorder.lastSynced;
    final lines = <String>[
      switch (_recorder.status) {
        HistorySyncStatus.syncing => 'Syncing with $server…',
        HistorySyncStatus.unauthorized => '$server needs the access token.',
        HistorySyncStatus.failed => 'Could not sync with $server; trying again soon.',
        HistorySyncStatus.idle => lastSynced == null
            ? 'Not synced with $server yet.'
            : 'Synced with $server ${_ago(lastSynced)}.',
      },
      if (_recorder.unsentCount > 0)
        '${formatCount(_recorder.unsentCount)} '
            '${_recorder.unsentCount == 1 ? 'answer' : 'answers'} from this device '
            '${_recorder.unsentCount == 1 ? 'hasn\'t' : 'haven\'t'} been sent yet.',
    ];
    final style = Theme.of(context).textTheme.bodySmall;
    return <Widget>[
      const SizedBox(height: 24),
      for (final line in lines) Text(line, style: style),
      const SizedBox(height: 16),
    ];
  }

  String _ago(DateTime time) {
    final since = _now().difference(time);
    if (since.inMinutes < 1) return 'just now';
    if (since.inMinutes == 1) return 'a minute ago';
    if (since.inHours < 1) return '${since.inMinutes} minutes ago';
    if (since.inHours == 1) return 'an hour ago';
    if (since.inDays < 1) return '${since.inHours} hours ago';
    return 'on ${DateFormat.yMMMd('en_US').format(time.toLocal())}';
  }
}

const _roundNames = {1: 'Jeopardy!', 2: 'Double Jeopardy!', 3: 'Final Jeopardy!'};

String _rowName(int row) => switch (row) {
      1 => 'Row 1 (top)',
      5 => 'Row 5 (bottom)',
      _ => 'Row $row',
    };

String _capitalized(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

/// What the namespaces of the sources the app reads are called.
const _sourceNames = {
  'jwolle1': 'Jeopardy!',
  'opentdb': 'Open Trivia Database',
  'the-trivia-api': 'The Trivia API',
};

String describeTally(Tally tally) => '${formatCount(tally.right)}/${formatCount(tally.answered)} '
    'right (${(tally.fraction * 100).round()}%)';

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium,
            semanticsLabel: text),
      );
}

/// A label, the tally, and a thin bar for its percentage.
class _TallyRow extends StatelessWidget {
  const _TallyRow(this.label, this.tally, {this.detail});
  final String label;
  final Tally tally;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MergeSemantics(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(label),
                if (detail != null)
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            const SizedBox(width: 12),
            Text(describeTally(tally)),
          ]),
          const SizedBox(height: 4),
          ExcludeSemantics(
            child: LinearProgressIndicator(value: tally.fraction, minHeight: 4),
          ),
        ]),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow(this.category);
  final CategoryTally category;

  @override
  Widget build(BuildContext context) => _TallyRow(category.category, category.tally,
      detail: _sourceNames[category.namespace] ?? category.namespace);
}

class _GameRow extends StatelessWidget {
  const _GameRow(this.game);
  final HistoryGame game;

  @override
  Widget build(BuildContext context) {
    final day = game.started ?? game.updatedAt.toLocal();
    final parts = <String>[
      '${formatCount(game.right)}/${formatCount(game.answered)} right',
      'best streak ${formatCount(game.best)}',
      if (game.valued > 0) formatDollars(game.dollars),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        SizedBox(width: 104, child: Text(DateFormat.yMMMd('en_US').format(day))),
        Expanded(child: Text(parts.join(' · '))),
      ]),
    );
  }
}
