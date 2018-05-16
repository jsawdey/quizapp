import 'package:flutter/material.dart';

class AnswerWidget extends StatelessWidget {
  final String _answer;
  AnswerWidget(this._answer);

  @override
  Widget build(BuildContext context) {
    return new Stack(
      alignment: Alignment.center,
      children: <Widget>[
        new Positioned.fill(
          child: new Padding(
            padding: const EdgeInsets.all(30.0),
            child: new Center(
              child: new Text(
                _answer == null ? '' : _answer.toUpperCase(),
                textAlign: TextAlign.center,
                style: new TextStyle(
                  fontFamily: 'Korinna',
                  fontSize: 28.0,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
        new Positioned(
            top: 0.0,
            right: 0.0,
            child: new IconButton(
                icon: new Icon(Icons.info_outline),
                onPressed: null)
        ),
      ],
    );
  }
}