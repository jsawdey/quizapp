import 'package:flutter/material.dart';

class QuestionAnswerWrapper extends StatelessWidget {
  final double _height;
  final Widget _widget;
  QuestionAnswerWrapper(this._height, this._widget);
  @override
  Widget build(BuildContext context) {
    return new Container(
        constraints: new BoxConstraints.expand(
            height: _height
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
