import 'package:flutter/material.dart';

class CustomAppTheme {

  // Question/Answer theme constants
  static final String _qaFontFamily = 'Korinna';
  static final double _qaFontSize = 28.0;
  static final Color _qaTextColor = Colors.white;

  // Category theme constants
  static final String _categoryFontFamily = 'Swiss911';
  static final double _categoryFontSize = 36.0;
  static final Color _categoryTextColor = Colors.white;

  static TextStyle questionAnswerTextTheme() {
    return new TextStyle(
      fontFamily: _qaFontFamily,
      fontSize: _qaFontSize,
      color: _qaTextColor,
    );
  }

  static TextStyle categoryTextTheme() {
    return new TextStyle(
      fontFamily: _categoryFontFamily,
      fontSize: _categoryFontSize,
      color: _categoryTextColor,
    );
  }

}