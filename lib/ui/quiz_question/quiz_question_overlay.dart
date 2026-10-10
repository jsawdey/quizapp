import 'package:flutter/material.dart';

/// The raw record behind a question, and the source's [attribution] if it
/// has one.
class QuestionOverlay extends StatelessWidget {
  final Map<String, dynamic> _json;
  final String? attribution;
  const QuestionOverlay(this._json, {super.key, this.attribution});

  @override
  Widget build(BuildContext context) {
    final attribution = this.attribution;
    final keys = _json.keys.toList();
    return Container(
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0x9F000000),
      ),
      child: ListView.builder(
        itemCount: keys.length + (attribution == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index == keys.length) {
            return Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: Text(attribution!, style: const TextStyle(color: Colors.white70)),
            );
          }
          final key = keys[index];
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
