import 'package:flutter/material.dart';

class CustomAppTheme {

  // Question/Answer theme constants
  static const String _qaFontFamily = 'Korinna';
  static const double _qaFontSize = 28.0;
  static const Color _qaTextColor = Colors.white;

  // Category theme constants
  static const String _categoryFontFamily = 'Swiss911';
  static const double _categoryFontSize = 36.0;
  static const Color _categoryTextColor = Colors.white;

  static TextStyle questionAnswerTextTheme() {
    return const TextStyle(
      fontFamily: _qaFontFamily,
      fontSize: _qaFontSize,
      color: _qaTextColor,
    );
  }

  static TextStyle categoryTextTheme() {
    return const TextStyle(
      fontFamily: _categoryFontFamily,
      fontSize: _categoryFontSize,
      color: _categoryTextColor,
    );
  }

}
