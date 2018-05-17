import 'package:flutter/material.dart';

class QuizDecorationWrapper extends StatelessWidget {
  final Widget _widget;
  QuizDecorationWrapper(this._widget);
  @override
  Widget build(BuildContext context) {
    return new Container(
        constraints: new BoxConstraints.expand(
        ),
        decoration: new BoxDecoration(
          border: new Border.all(width: 8.0, color: Colors.black),
          borderRadius: new BorderRadius.all(const Radius.circular(8.0)),
          color: const Color(0xFFFF060CE9),
        ),
        padding: const EdgeInsets.all(4.0),
        alignment: Alignment.center,
        child: _widget
    );
  }
}
