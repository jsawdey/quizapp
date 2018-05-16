import 'package:flutter/material.dart';

class QuestionCategoryWidget extends StatelessWidget {
  final String _category;
  QuestionCategoryWidget(this._category);


  @override
  Widget build(BuildContext context) {
    return new Text(
      _category == null ? '' : _category.toUpperCase(),
      style: new TextStyle(
        fontFamily: 'Swiss911',
        fontSize: 36.0,
        color: Colors.white,
      ),
    );
  }
}