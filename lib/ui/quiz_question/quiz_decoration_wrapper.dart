import 'package:flutter/material.dart';

class QuizDecorationWrapper extends StatelessWidget {
  final Widget _widget;
  const QuizDecorationWrapper(this._widget, {super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
        constraints: const BoxConstraints.expand(),
        decoration: BoxDecoration(
          border: Border.all(width: 8.0, color: Colors.black),
          borderRadius: const BorderRadius.all(Radius.circular(8.0)),
          color: const Color(0xFF060CE9),
        ),
        padding: const EdgeInsets.all(4.0),
        alignment: Alignment.center,
        child: _widget
    );
  }
}
