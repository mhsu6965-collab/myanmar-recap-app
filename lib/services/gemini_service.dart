import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class GeminiService {
  final List<String> apiKeys;
  GeminiService(this.apiKeys);

  static const List<String> _models = [
    'gemini-3.8-flash',
    'gemini-3.5-flash',
    'gemini-3.1-flash',
  ];

  // Key နှင့် Model Rotate + 25s Timeout (လုံးဝမဟန်းအောင်)
  Future<String> _callSingle(
    Map<String, dynamic> body,
    int keyOffset,
    Function(String)? onLog,
  ) async {
    String lastError = 'API Key မရှိပါ';

    for (int round = 1; round <= 2; round++) {
      bool hitRateLimit = false;

      for (int i = 0; i < apiKeys.length; i++) {
        final kIndex = (i + keyOffset) % apiKeys.length;
        final key = apiKeys[kIndex];

        for (final model in _models) {
          final uri = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key',
          );
          try {
            final res = await http
                .post(
                  uri,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode(body),
                )
                .timeout(const Duration(seconds: 25));

            if (res.statusCode == 200) {
              final jsonRes = jsonDecode(res.body);
              return jsonRes['candidates'][0]['content']['parts'][0]['text'].toString().trim();
            } else if (res.statusCode == 429 || res.statusCode == 503) {
              hitRateLimit = true;
              lastError = 'Limit ($model)';
              continue;
            } else {
              lastError = '($model) Error ${res.statusCode}';
              continue;
            }
          } on TimeoutException {
            lastError = '($model) Timeout 25s';
            continue;
          } catch (e) {
            lastError = '($model) $e';
            continue;
          }
        }
      }

      if (hitRateLimit && round < 2) {
        onLog?.call('Gemini: Limit ထိနေ၍ ၅ စက္ကန့် စောင့်နေသည်...');
        await Future.delayed(const Duration(seconds: 5));
      } else if (!hitRateLimit) {
        break;
      }
    }

    throw Exception('Gemini ဘာသာပြန်မရပါ: $lastError');
  }

  // စာရှည်နေရင် အပိုင်းခွဲပြီး ပြိုင်တူ (Parallel) အမြန်ဆုံး ဘာသာပြန်မည်
  Future<String> translateToMyanmarRecap(String transcript, {Function(String)? onLog}) async {
    const int chunkSize = 1200;
    final List<String> chunks = [];

    for (int i = 0; i < transcript.length; i += chunkSize) {
      final end = (i + chunkSize < transcript.length) ? i + chunkSize : transcript.length;
      chunks.add(transcript.substring(i, end));
    }

    onLog?.call('Gemini: စာသားကို ${chunks.length} ပိုင်းခွဲပြီး ပြိုင်တူ အမြန်ဘာသာပြန်နေသည်...');

    // အပိုင်းအားလုံးကို တစ်ပြိုင်နက်တည်း (Parallel) ဘာသာပြန်မယ်
    final futures = <Future<String>>[];
    for (int i = 0; i < chunks.length; i++) {
      final body = {
        "generationConfig": {"temperature": 0.1},
        "contents": [
          {
            "parts": [
              {
                "text": "အောက်ပါစာသားကို အတိုမချုံးဘဲ မူရင်းအတိုင်း သဘာဝကျကျ "
                    "မြန်မာဘာသာသို့ တိုက်ရိုက်ဘာသာပြန်ပါ။ စာသားသက်သက် (Plain text) ပဲထုတ်ပါ။\n\n${chunks[i]}"
              }
            ]
          }
        ]
      };
      futures.add(_callSingle(body, i, onLog));
    }

    final results = await Future.wait(futures);
    onLog?.call('Gemini: ${chunks.length} ပိုင်းလုံး အမြန်ဘာသာပြန် ပြီးစီးပါပြီ။');
    return results.join('\n');
  }

  Future<String> generateRecapScript(String videoPath, {Function(String)? onLog}) async {
    final primaryKey = apiKeys.first;
    final file = File(videoPath);
    final bytes = await file.readAsBytes();

    onLog?.call('Gemini: ဗီဒီယို Upload တင်နေသည်...');
    final uploadUri = Uri.parse(
      'https://generativelanguage.googleapis.com/upload/v1beta/files?key=$primaryKey',
    );
    final uploadReq = http.Request('POST', uploadUri)
      ..headers['Content-Type'] = 'video/mp4'
      ..headers['X-Goog-Upload-Protocol'] = 'raw'
      ..bodyBytes = bytes;

    final uploadRes = await http.Response.fromStream(await uploadReq.send());
    if (uploadRes.statusCode != 200) {
      throw Exception('Video Upload မအောင်မြင်ပါ: ${uploadRes.body}');
    }

    final fileData = jsonDecode(uploadRes.body)['file'];
    final fileUri = fileData['uri'];
    final fileName = fileData['name'];

    onLog?.call('Gemini: ဗီဒီယို Processing စောင့်နေသည်...');
    while (true) {
      await Future.delayed(const Duration(seconds: 2));
      final stateRes = await http.get(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/$fileName?key=$primaryKey'),
      );
      final state = jsonDecode(stateRes.body)['state'];
      if (state == 'ACTIVE') break;
      if (state == 'FAILED') throw Exception('Gemini Video Processing မအောင်မြင်ပါ');
    }

    return _callSingle(
      {
        "generationConfig": {"temperature": 0.1},
        "contents": [
          {
            "parts": [
              {
                "file_data": {"mime_type": "video/mp4", "file_uri": fileUri}
              },
              {
                "text": "ဒီဗီဒီယိုထဲက စကားပြောတွေကို မူရင်းအတိုင်း မြန်မာဘာသာသို့ တိုက်ရိုက်ဘာသာပြန်ပါ။ Plain text ပဲထုတ်ပါ။"
              }
            ]
          }
        ]
      },
      0,
      onLog,
    );
  }
}
