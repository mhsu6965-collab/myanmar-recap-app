import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class GeminiService {
  final List<String> apiKeys;
  GeminiService(this.apiKeys);

  // တစ်ခုမရရင် တစ်ခု အလိုအလျောက် လှည့်သုံးမည့် Model စာရင်း
  static const List<String> _models = [
    'gemini-3.8-flash',
    'gemini-3.5-flash',
    'gemini-3.1-flash',
  ];

  // Key များနှင့် Model များကို Rotate လုပ်ပြီး Limit ထိရင် စောင့်ခေါ်ပေးမည့် Function
  Future<String> _callWithRotation(Map<String, dynamic> Function() bodyBuilder) async {
    String lastError = 'API Key မရှိပါ';

    // အများဆုံး ၃ ကြိမ်အထိ (Limit ထိရင် ၁၀ စက္ကန့်စောင့်ပြီး) ပြန်ကြိုးစားမယ်
    for (int round = 1; round <= 3; round++) {
      bool hitRateLimit = false;

      for (final key in apiKeys) {
        for (final model in _models) {
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
              final jsonRes = jsonDecode(res.body);
              return jsonRes['candidates'][0]['content']['parts'][0]['text'].toString().trim();
            } else if (res.statusCode == 429 || res.statusCode == 503) {
              hitRateLimit = true;
              lastError = 'Limit ထိနေပါသည် ($model): ${res.statusCode}';
              continue; // နောက် Model / Key ပြောင်းမယ်
            } else {
              lastError = '($model) Error ${res.statusCode}: ${res.body}';
              continue; // 404 စသည်ဖြစ်ရင် နောက် Model ပြောင်းမယ်
            }
          } catch (e) {
            lastError = '($model) Connection Error: $e';
            continue;
          }
        }
      }

      // Key နဲ့ Model အကုန် Limit ထိနေရင် ၁၀ စက္ကန့်စောင့်ပြီး ထပ်ခေါ်မယ်
      if (hitRateLimit && round < 3) {
        await Future.delayed(const Duration(seconds: 10));
      } else if (!hitRateLimit) {
        break;
      }
    }

    throw Exception('Gemini Model/Key အားလုံး မအောင်မြင်ပါ: $lastError');
  }

  // Hybrid စနစ်အတွက်: Groq ကရလာတဲ့ Transcript ကို Gemini နဲ့ မြန်မာ Recap ဘာသာပြန်မယ်
  Future<String> translateToMyanmarRecap(String transcript) async {
    return _callWithRotation(() => {
          "contents": [
            {
              "parts": [
                {
                  "text": "အောက်ပါ ဗီဒီယိုစကားပြောစာသားကို ဆွဲဆောင်မှုရှိပြီး သဘာဝကျတဲ့ "
                      "မြန်မာ Movie Recap ပုံစံနဲ့ အတိုချုံးပြန်ပြောပြပေးပါ။ "
                      "စာသားသက်သက် (Plain text) ပဲ ထုတ်ပေးပါ။ Markdown သင်္ကေတတွေ လုံးဝမထည့်ပါနဲ့။\n\n$transcript"
                }
              ]
            }
          ]
        });
  }

  // Gemini တစ်ခုတည်းသုံးပြီး ဗီဒီယိုတိုက်ရိုက်ကြည့်မည့်စနစ်
  Future<String> generateRecapScript(String videoPath) async {
    final primaryKey = apiKeys.first;
    final file = File(videoPath);
    final bytes = await file.readAsBytes();

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

    while (true) {
      await Future.delayed(const Duration(seconds: 3));
      final stateRes = await http.get(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/$fileName?key=$primaryKey'),
      );
      final state = jsonDecode(stateRes.body)['state'];
      if (state == 'ACTIVE') break;
      if (state == 'FAILED') throw Exception('Gemini Video Processing မအောင်မြင်ပါ');
    }

    return _callWithRotation(() => {
          "contents": [
            {
              "parts": [
                {
                  "file_data": {"mime_type": "video/mp4", "file_uri": fileUri}
                },
                {
                  "text": "ဒီဗီဒီယိုထဲက အကြောင်းအရာကို ဆွဲဆောင်မှုရှိတဲ့ မြန်မာ Movie Recap ပုံစံနဲ့ "
                      "အတိုချုံးပြန်ပြောပြပေးပါ။ စာသားသက်သက် (Plain text) ပဲ ထုတ်ပေးပါ။ "
                      "Markdown သင်္ကေတတွေ မထည့်ပါနဲ့။"
                }
              ]
            }
          ]
        });
  }
}
