import 'package:flutter/material.dart';

class QuestionOverlay extends StatelessWidget {
  final Map<String, dynamic> _json;
  const QuestionOverlay(this._json, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0x9F000000),
      ),
      child: ListView.builder(
        itemCount: _json.length,
        itemBuilder: (context, index) {
          final key = _json.keys.toList()[index];
          final item = _json[key];
          return Text(
            '$key: $item',
            style: const TextStyle(color: Colors.white),
          );
        }
      ),
    );
  }
}
