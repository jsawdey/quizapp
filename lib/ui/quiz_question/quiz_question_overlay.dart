import 'package:flutter/material.dart';

class QuestionOverlay extends StatelessWidget {
  final Map<String, dynamic> _json;
  QuestionOverlay(this._json);

  @override
  Widget build(BuildContext context) {
    return new Container(
      alignment: Alignment.center,
      decoration: new BoxDecoration(
        color: const Color(0x9F000000),
      ),
      child: new ListView.builder(
        itemCount: _json.length,
        itemBuilder: (context, index) {
          final key = _json.keys.toList()[index];
          final item = _json[key];
          return new Text(
              key.toString() + ': ' + item.toString(),
            style: new TextStyle(color: Colors.white),
          );
        }
      ),
    );
  }
}
