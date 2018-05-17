import 'package:flutter/material.dart';
import 'package:quizapp/ui/theme.dart';

class QuestionCategoryWidget extends StatelessWidget {
  final String _category;
  QuestionCategoryWidget(this._category);


  @override
  Widget build(BuildContext context) {
    return new Center(
      child: new Text(
        _category == null ? '' : _category.toUpperCase(),
        textAlign: TextAlign.center,
        style: CustomAppTheme.categoryTextTheme(),
      ),
    );
  }
}