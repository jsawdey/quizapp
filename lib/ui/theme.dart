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

  // Value / round line under the category, in the board's dollar-value gold
  static const double _detailFontSize = 24.0;
  static const Color _detailTextColor = Color(0xFFD69F4C);

  // Host's comment about the category
  static const double _commentFontSize = 14.0;
  static const Color _commentTextColor = Colors.white70;

  // Loading and error messages in the clue panel
  static const double _messageFontSize = 20.0;

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

  static TextStyle detailTextTheme() {
    return const TextStyle(
      fontFamily: _categoryFontFamily,
      fontSize: _detailFontSize,
      color: _detailTextColor,
    );
  }

  static TextStyle commentTextTheme() {
    return const TextStyle(
      fontFamily: _qaFontFamily,
      fontSize: _commentFontSize,
      color: _commentTextColor,
    );
  }

  static TextStyle messageTextTheme() {
    return const TextStyle(
      fontFamily: _qaFontFamily,
      fontSize: _messageFontSize,
      color: _qaTextColor,
    );
  }

}
