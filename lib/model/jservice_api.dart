import 'dart:async';
import 'dart:convert' show json, utf8;
import 'dart:io';

class JServiceAPI {
  static final _httpClient = HttpClient();
  static final _url = 'jservice.io';

  static Future<List<dynamic>> getRandomJServiceAPIQuestions(int count) async {
    final uri = Uri.http(_url, '/api/random', {"count": count.toString()});

    final httpRequest = await _httpClient.getUrl(uri);
    final httpResponse = await httpRequest.close();
    if (httpResponse.statusCode != HttpStatus.OK) {
      return null;
    }

    final responseBody = await httpResponse.transform(utf8.decoder).join();
    final jsonResponse = json.decode(responseBody);
    return jsonResponse;
  }

  static Future<dynamic> markJServiceQuestionInvalid(int id) async {

    if (id < 0) return null;

    final uri = Uri.http(_url, '/api/invalid', {"id": id.toString()});

    final httpRequest = await _httpClient.postUrl(uri);
    final httpResponse = await httpRequest.close();
    if (httpResponse.statusCode != HttpStatus.OK) {
      return null;
    }

    final responseBody = await httpResponse.transform(utf8.decoder).join();
    final jsonResponse = json.decode(responseBody);
    return jsonResponse;
  }

}