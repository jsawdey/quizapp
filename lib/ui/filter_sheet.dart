import 'package:flutter/material.dart';
import 'package:quizapp/data/question_source.dart';

/// The first year the filter offers: the syndicated show began in 1984,
/// which is where the clue dataset starts.
const firstFilterYear = 1984;

const _roundNames = {1: 'Jeopardy!', 2: 'Double Jeopardy!', 3: 'Final Jeopardy!'};

/// "Easy" for `easy`.
String _capitalized(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

/// A short description of [filter] for the app bar, such as
/// "Double Jeopardy!, 1990–1999". Empty for [QuestionFilter.any].
String describeFilter(QuestionFilter filter) {
  final parts = <String>[];
  final rounds = filter.rounds;
  if (rounds != null) {
    parts.add([for (final round in rounds.toList()..sort()) _roundNames[round] ?? 'Round $round']
        .join(', '));
  }
  final from = filter.from?.year;
  final to = filter.to?.year;
  if (from != null && to != null) {
    parts.add(from == to ? '$from' : '$from–$to');
  } else if (from != null) {
    parts.add('from $from');
  } else if (to != null) {
    parts.add('to $to');
  }
  final boardRows = filter.boardRows;
  if (boardRows != null && boardRows.isNotEmpty) {
    final rows = boardRows.toList()..sort();
    if (rows.length == 1) {
      parts.add('row ${rows.single}');
    } else if (rows.last - rows.first == rows.length - 1) {
      parts.add('rows ${rows.first}–${rows.last}');
    } else {
      parts.add('rows ${rows.join(', ')}');
    }
  }
  final categories = filter.categories;
  if (categories != null && categories.isNotEmpty) {
    parts.add(categories.length <= 2
        ? (categories.toList()..sort()).join(', ')
        : '${categories.length} categories');
  }
  final difficulties = filter.difficulties;
  if (difficulties != null && difficulties.isNotEmpty) {
    parts.add([
      for (final difficulty in QuestionFilter.allDifficulties)
        if (difficulties.contains(difficulty)) _capitalized(difficulty),
    ].join(', '));
  }
  return parts.join(', ');
}

/// Shows the filter sheet and returns the filter chosen with Apply, or null
/// if it was closed any other way. Offers only the [supported] filters, and
/// the [categories] the source lists.
Future<QuestionFilter?> showFilterSheet(BuildContext context,
    {required QuestionFilter current, required Set<FilterKind> supported,
      List<String> categories = const [], int? lastYear}) =>
    showModalBottomSheet<QuestionFilter>(
      context: context,
      isScrollControlled: true,
      // Lines up with the board in a wide browser window.
      constraints: const BoxConstraints(maxWidth: 900.0),
      builder: (context) => FilterSheet(current: current, supported: supported,
          categories: categories, lastYear: lastYear ?? DateTime.now().year),
    );

/// Round chips, a range of years and board-row chips for Jeopardy clues;
/// category and difficulty chips for general trivia. Apply pops the chosen
/// filter.
class FilterSheet extends StatefulWidget {
  const FilterSheet({super.key, required this.current, required this.supported,
    this.categories = const [], required this.lastYear});

  final QuestionFilter current;
  final Set<FilterKind> supported;

  /// The categories to offer, when [supported] has [FilterKind.category].
  final List<String> categories;

  /// The last year the slider offers, normally the current one.
  final int lastYear;

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late Set<int> _rounds;
  late RangeValues _years;
  late Set<int> _boardRows;
  late Set<String> _categories;
  late Set<String> _difficulties;

  int get _lastYear => widget.lastYear;

  @override
  void initState() {
    super.initState();
    _show(widget.current);
  }

  void _show(QuestionFilter filter) {
    _rounds = {...filter.rounds ?? QuestionFilter.allRounds};
    _boardRows = {...filter.boardRows ?? QuestionFilter.allBoardRows};
    _categories = {...filter.categories ?? const <String>{}};
    _difficulties = {...filter.difficulties ?? QuestionFilter.allDifficulties};
    double year(DateTime? date, int otherwise) =>
        (date?.year ?? otherwise).clamp(firstFilterYear, _lastYear).toDouble();
    _years = RangeValues(year(filter.from, firstFilterYear), year(filter.to, _lastYear));
  }

  /// Whether only Final Jeopardy is chosen, which has no board row.
  bool get _onlyFinal => _rounds.length == 1 && _rounds.contains(3);

  /// The filter shown, with the slider's ends meaning "no limit".
  QuestionFilter get _chosen {
    final from = _years.start.round();
    final to = _years.end.round();
    return QuestionFilter(
      rounds: _rounds,
      from: from == firstFilterYear ? null : DateTime(from),
      to: to == _lastYear ? null : DateTime(to, 12, 31),
      boardRows: _onlyFinal ? null : _boardRows,
      categories: _categories,
      difficulties: _difficulties,
    ).normalized().limitedTo(widget.supported);
  }

  void _toggle<T>(Set<T> chosen, T value, bool selected) => setState(() {
    if (selected) {
      chosen.add(value);
    } else {
      chosen.remove(value);
    }
  });

  /// A chip for [value] in [chosen]. Unless [noneMeansAll], the last chosen
  /// one can't be turned off, since choosing none would match nothing.
  Widget _chip<T>(String label, Set<T> chosen, T value,
      {bool enabled = true, bool noneMeansAll = false}) =>
      FilterChip(
        label: Text(label),
        selected: chosen.contains(value),
        onSelected: !enabled ||
                (!noneMeansAll && chosen.length == 1 && chosen.contains(value))
            ? null
            : (selected) => _toggle(chosen, value, selected),
      );

  String get _yearsText {
    final from = _years.start.round();
    final to = _years.end.round();
    if (from == firstFilterYear && to == _lastYear) return 'Any year';
    return from == to ? '$from' : '$from–$to';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = theme.textTheme.titleMedium;
    final showRounds = widget.supported.contains(FilterKind.round);
    final showYears = widget.supported.contains(FilterKind.airDate);
    final showRows = widget.supported.contains(FilterKind.boardRow);
    final showCategories = widget.supported.contains(FilterKind.category);
    final showDifficulties = widget.supported.contains(FilterKind.difficulty);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24.0, 16.0, 24.0, 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(showRounds ? 'Filter clues' : 'Filter questions',
                style: theme.textTheme.titleLarge),
            if (showRounds) ...[
              const SizedBox(height: 16.0),
              Text('Rounds', style: heading),
              const SizedBox(height: 8.0),
              Wrap(
                spacing: 8.0,
                runSpacing: 4.0,
                children: <Widget>[
                  for (final MapEntry(key: round, value: name) in _roundNames.entries)
                    _chip(name, _rounds, round),
                ],
              ),
            ],
            if (showYears) ...[
              const SizedBox(height: 16.0),
              Row(
                children: <Widget>[
                  Expanded(child: Text('Years', style: heading)),
                  Text(_yearsText, key: const Key('filter-years')),
                ],
              ),
              RangeSlider(
                values: _years,
                min: firstFilterYear.toDouble(),
                max: _lastYear.toDouble(),
                divisions: _lastYear - firstFilterYear,
                labels: RangeLabels('${_years.start.round()}', '${_years.end.round()}'),
                onChanged: (values) => setState(() => _years = values),
              ),
            ],
            if (showRows) ...[
              const SizedBox(height: 8.0),
              Text('Difficulty', style: heading),
              const SizedBox(height: 8.0),
              Wrap(
                spacing: 8.0,
                runSpacing: 4.0,
                children: <Widget>[
                  for (final row in QuestionFilter.allBoardRows)
                    _chip('$row', _boardRows, row, enabled: !_onlyFinal),
                ],
              ),
              const SizedBox(height: 4.0),
              Text(_onlyFinal
                  ? 'Final Jeopardy has no board row.'
                  : 'Row on the board: 1 is the top row, 5 the bottom.',
                  style: theme.textTheme.bodySmall),
            ],
            if (showCategories) ...[
              const SizedBox(height: 16.0),
              Text('Categories', style: heading),
              const SizedBox(height: 8.0),
              if (widget.categories.isEmpty)
                Text("The categories couldn't be loaded.", style: theme.textTheme.bodySmall)
              else ...[
                Wrap(
                  spacing: 8.0,
                  runSpacing: 4.0,
                  children: <Widget>[
                    for (final category in widget.categories)
                      _chip(category, _categories, category, noneMeansAll: true),
                  ],
                ),
                const SizedBox(height: 4.0),
                Text(_categories.isEmpty
                    ? 'Every category. Choose some to play only those.'
                    : '${_categories.length} chosen.',
                    style: theme.textTheme.bodySmall),
              ],
            ],
            if (showDifficulties) ...[
              const SizedBox(height: 16.0),
              Text('Difficulty', style: heading),
              const SizedBox(height: 8.0),
              Wrap(
                spacing: 8.0,
                runSpacing: 4.0,
                children: <Widget>[
                  for (final difficulty in QuestionFilter.allDifficulties)
                    _chip(_capitalized(difficulty), _difficulties, difficulty),
                ],
              ),
            ],
            const SizedBox(height: 8.0),
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: () => setState(() => _show(QuestionFilter.any)),
                  child: const Text('Reset'),
                ),
                const Spacer(),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, _chosen),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
