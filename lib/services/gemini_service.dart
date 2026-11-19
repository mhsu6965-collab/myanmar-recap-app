import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class GeminiService {
  final List<String> apiKeys;
  GeminiService(this.apiKeys);

  // လှည့်သုံးမည့် Model စာရင်း
  static const List<String> _models = [
    'gemini-3.8-flash',
    'gemini-3.5-flash',
    'gemini-3.1-flash',
    'gemini-2.5-flash-lite',
  ];

  // 404 မရှိတဲ့ Model တွေကို မှတ်ထားပြီး နောက်တစ်ခါ မခေါ်တော့ဘူး
  final Set<String> _deadModels = {};

  Future<String> _callWithWaitAndRotate(
    Map<String, dynamic> body,
    int startKeyIndex,
    Function(String)? onLog,
  ) async {
    int round = 1;

    while (round <= 10) {
      bool hitRateLimit = false;
      String lastError = '';

      for (int i = 0; i < apiKeys.length; i++) {
        final kIdx = (i + startKeyIndex) % apiKeys.length;
        final key = apiKeys[kIdx];

        for (final model in _models) {
          if (_deadModels.contains(model)) continue;

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
                .timeout(const Duration(seconds: 30));

            if (res.statusCode == 200) {
              final jsonRes = jsonDecode(res.body);
              return jsonRes['candidates'][0]['content']['parts'][0]['text'].toString().trim();
            } else if (res.statusCode == 404) {
              // 404 ဖြစ်တဲ့ Model ကို ဖယ်ထားမယ် (Error မပြဘဲ နောက်တစ်ခုကူးမယ်)
              _deadModels.add(model);
              continue;
            } else if (res.statusCode == 429 || res.statusCode == 503) {
              hitRateLimit = true;
              lastError = 'Limit ($model)';
              onLog?.call('Gemini: Key #${kIdx + 1} ($model) Limit ထိ၍ နောက်တစ်ခုပြောင်းနေသည်...');
              continue;
            } else {
              lastError = '($model) Error ${res.statusCode}';
              continue;
            }
          } on TimeoutException {
            hitRateLimit = true;
            lastError = '($model) Timeout';
            continue;
          } catch (e) {
            lastError = '($model) $e';
            continue;
          }
        }
      }

      // Limit ထိနေရင် Error မတက်ဘဲ ၁၅ စက္ကန့် စောင့်ပြီး ပြန်ခေါ်မယ်
      if (hitRateLimit) {
        onLog?.call('Gemini: Key/Model အားလုံး Limit ထိနေ၍ ၁၅ စက္ကန့် စောင့်ပြီး ပြန်ခေါ်ပါမည် (အကြိမ် $round/10)...');
        await Future.delayed(const Duration(seconds: 15));
        round++;
      } else {
        throw Exception('Gemini ဘာသာပြန်မရပါ: $lastError');
      }
    }

    throw Exception('Gemini ၁၀ ကြိမ် စောင့်ခေါ်သော်လည်း Limit မပွင့်သေးပါ။ ခဏနေမှ ထပ်စမ်းပါ။');
  }

  // Limit မထိအောင် တစ်ပိုင်းချင်းစီ Key လှည့်ပြီး ဘာသာပြန်မည်
  Future<String> translateToMyanmarRecap(String transcript, {Function(String)? onLog}) async {
    const int chunkSize = 6000;
    final List<String> chunks = [];

    for (int i = 0; i < transcript.length; i += chunkSize) {
      final end = (i + chunkSize < transcript.length) ? i + chunkSize : transcript.length;
      chunks.add(transcript.substring(i, end));
    }

    final List<String> results = [];
    for (int i = 0; i < chunks.length; i++) {
      onLog?.call('Gemini: အပိုင်း (${i + 1}/${chunks.length}) ဘာသာပြန်နေသည်...');
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

      final translated = await _callWithWaitAndRotate(body, i, onLog);
      results.add(translated);

      // နောက်တစ်ပိုင်းမခေါ်ခင် Limit မထိအောင် ၂ စက္ကန့် ခြားပေးမယ်
      if (i + 1 < chunks.length) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    onLog?.call('Gemini: အပိုင်းအားလုံး ဘာသာပြန် ပြီးစီးပါပြီ။');
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

    return _callWithWaitAndRotate(
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
