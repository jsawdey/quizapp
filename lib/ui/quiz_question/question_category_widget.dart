import 'package:flutter/material.dart';
import 'package:quizapp/ui/theme.dart';

/// The category panel: the category, then an optional line such as the clue's
/// value or "FINAL JEOPARDY", then the host's comment about the category.
class QuestionCategoryWidget extends StatelessWidget {
  final String _category;
  final String? detail;
  final String? comment;
  const QuestionCategoryWidget(this._category, {super.key, this.detail, this.comment});

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    final comment = this.comment;
    // Lay the text out at the panel's width, then scale it down only if it is
    // taller than the panel, so long categories and comments stay readable.
    return LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: constraints.maxWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _category.toUpperCase(),
                textAlign: TextAlign.center,
                style: CustomAppTheme.categoryTextTheme(),
              ),
              if (detail != null)
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: CustomAppTheme.detailTextTheme(),
                ),
              if (comment != null)
                Text(
                  comment,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 4,
                  style: CustomAppTheme.commentTextTheme(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
