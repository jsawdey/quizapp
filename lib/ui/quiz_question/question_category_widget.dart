import 'package:flutter/material.dart';
import 'package:quizapp/ui/theme.dart';

class QuestionCategoryWidget extends StatelessWidget {
  final String _category;
  const QuestionCategoryWidget(this._category, {super.key});


  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        _category.toUpperCase(),
        textAlign: TextAlign.center,
        style: CustomAppTheme.categoryTextTheme(),
      ),
    );
  }
}
