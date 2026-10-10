import 'package:flutter/material.dart';
import 'package:quizapp/data/question_source.dart';

/// The first year the filter offers: the syndicated show began in 1984,
/// which is where the clue dataset starts.
const firstFilterYear = 1984;

const _roundNames = {1: 'Jeopardy!', 2: 'Double Jeopardy!', 3: 'Final Jeopardy!'};

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
  return parts.join(', ');
}

/// Shows the filter sheet and returns the filter chosen with Apply, or null
/// if it was closed any other way. Offers only the [supported] filters.
Future<QuestionFilter?> showFilterSheet(BuildContext context,
    {required QuestionFilter current, required Set<FilterKind> supported, int? lastYear}) =>
    showModalBottomSheet<QuestionFilter>(
      context: context,
      isScrollControlled: true,
      // Lines up with the board in a wide browser window.
      constraints: const BoxConstraints(maxWidth: 900.0),
      builder: (context) => FilterSheet(current: current, supported: supported,
          lastYear: lastYear ?? DateTime.now().year),
    );

/// Round chips and a range of years. Apply pops the chosen filter.
class FilterSheet extends StatefulWidget {
  const FilterSheet({super.key, required this.current, required this.supported,
    required this.lastYear});

  final QuestionFilter current;
  final Set<FilterKind> supported;

  /// The last year the slider offers, normally the current one.
  final int lastYear;

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late Set<int> _rounds;
  late RangeValues _years;

  int get _lastYear => widget.lastYear;

  @override
  void initState() {
    super.initState();
    _show(widget.current);
  }

  void _show(QuestionFilter filter) {
    _rounds = {...filter.rounds ?? QuestionFilter.allRounds};
    double year(DateTime? date, int otherwise) =>
        (date?.year ?? otherwise).clamp(firstFilterYear, _lastYear).toDouble();
    _years = RangeValues(year(filter.from, firstFilterYear), year(filter.to, _lastYear));
  }

  /// The filter shown, with the slider's ends meaning "no limit".
  QuestionFilter get _chosen {
    final from = _years.start.round();
    final to = _years.end.round();
    return QuestionFilter(
      rounds: _rounds,
      from: from == firstFilterYear ? null : DateTime(from),
      to: to == _lastYear ? null : DateTime(to, 12, 31),
    ).normalized().limitedTo(widget.supported);
  }

  void _toggleRound(int round, bool selected) => setState(() {
    if (selected) {
      _rounds.add(round);
    } else {
      _rounds.remove(round);
    }
  });

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
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24.0, 16.0, 24.0, 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Filter clues', style: theme.textTheme.titleLarge),
            if (showRounds) ...[
              const SizedBox(height: 16.0),
              Text('Rounds', style: heading),
              const SizedBox(height: 8.0),
              Wrap(
                spacing: 8.0,
                runSpacing: 4.0,
                children: <Widget>[
                  for (final MapEntry(key: round, value: name) in _roundNames.entries)
                    FilterChip(
                      label: Text(name),
                      selected: _rounds.contains(round),
                      // No rounds can't match anything, so the last one stays on.
                      onSelected: _rounds.length == 1 && _rounds.contains(round)
                          ? null
                          : (selected) => _toggleRound(round, selected),
                    ),
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
