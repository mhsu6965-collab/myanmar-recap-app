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

  Future<String> _callWithRotation(
    Map<String, dynamic> Function() bodyBuilder,
    Function(String)? onLog,
  ) async {
    String lastError = 'API Key မရှိပါ';

    for (int round = 1; round <= 3; round++) {
      bool hitRateLimit = false;

      for (int k = 0; k < apiKeys.length; k++) {
        final key = apiKeys[k];
        for (final model in _models) {
          onLog?.call('Gemini: Key #${k + 1} | $model ဖြင့် ဘာသာပြန်နေသည်...');
          final uri = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key',
          );
          try {
            final res = await http.post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(bodyBuilder()),
            );

            if (res.statusCode == 200) {
              onLog?.call('Gemini: $model ဖြင့် ဘာသာပြန်ပြီးစီးပါပြီ။');
              final jsonRes = jsonDecode(res.body);
              return jsonRes['candidates'][0]['content']['parts'][0]['text'].toString().trim();
            } else if (res.statusCode == 429 || res.statusCode == 503) {
              hitRateLimit = true;
              lastError = 'Limit ထိနေသည် ($model)';
              onLog?.call('Gemini: $model Limit ထိ၍ နောက်တစ်ခုပြောင်းနေသည်...');
              continue;
            } else {
              lastError = '($model) Error ${res.statusCode}';
              onLog?.call('Gemini: $model မရ၍ နောက်တစ်ခုပြောင်းနေသည်...');
              continue;
            }
          } catch (e) {
            lastError = '($model) Error: $e';
            continue;
          }
        }
      }

      if (hitRateLimit && round < 3) {
        onLog?.call('Gemini: Key အားလုံး Limit ထိနေ၍ ၁၀ စက္ကန့် စောင့်နေသည်...');
        await Future.delayed(const Duration(seconds: 10));
      } else if (!hitRateLimit) {
        break;
      }
    }

    throw Exception('Gemini Model/Key အားလုံး မအောင်မြင်ပါ: $lastError');
  }

  // Script အတိုင်း တိုက်ရိုက်ဘာသာပြန်မည် (အတိုမချုံးပါ)
  Future<String> translateToMyanmarRecap(String transcript, {Function(String)? onLog}) async {
    return _callWithRotation(
      () => {
        "generationConfig": {"temperature": 0.2},
        "contents": [
          {
            "parts": [
              {
                "text": "အောက်ပါ Script ကို အတိုမချုံးဘဲ၊ မူရင်းအဓိပ္ပာယ်အတိုင်း "
                    "သဘာဝကျကျ မြန်မာဘာသာသို့ တိုက်ရိုက်ဘာသာပြန်ပေးပါ။ "
                    "စာသားသက်သက် (Plain text) ပဲ ထုတ်ပေးပါ။ Markdown သင်္ကေတတွေ မထည့်ပါနဲ့။\n\n$transcript"
              }
            ]
          }
        ]
      },
      onLog,
    );
  }

  Future<String> generateRecapScript(String videoPath, {Function(String)? onLog}) async {
    final primaryKey = apiKeys.first;
    final file = File(videoPath);
    final bytes = await file.readAsBytes();

    onLog?.call('Gemini: ဗီဒီယိုကို Upload တင်နေသည်...');
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

    onLog?.call('Gemini: ဗီဒီယို Processing ပြီးအောင် စောင့်နေသည်...');
    while (true) {
      await Future.delayed(const Duration(seconds: 3));
      final stateRes = await http.get(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/$fileName?key=$primaryKey'),
      );
      final state = jsonDecode(stateRes.body)['state'];
      if (state == 'ACTIVE') break;
      if (state == 'FAILED') throw Exception('Gemini Video Processing မအောင်မြင်ပါ');
    }

    return _callWithRotation(
      () => {
        "generationConfig": {"temperature": 0.2},
        "contents": [
          {
            "parts": [
              {
                "file_data": {"mime_type": "video/mp4", "file_uri": fileUri}
              },
              {
                "text": "ဒီဗီဒီယိုထဲက စကားပြောတွေကို မူရင်းအတိုင်း သဘာဝကျကျ "
                    "မြန်မာဘာသာသို့ တိုက်ရိုက်ဘာသာပြန်ပေးပါ။ စာသားသက်သက် (Plain text) ပဲ ထုတ်ပေးပါ။"
              }
            ]
          }
        ]
      },
      onLog,
    );
  }
}
