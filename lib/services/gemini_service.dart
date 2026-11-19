import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class GeminiService {
  final String apiKey;
  GeminiService(this.apiKey);

  // Hybrid စနစ်အတွက်: Groq ကရလာတဲ့ Transcript ကို Gemini နဲ့ မြန်မာ Recap ပြန်ရေးမယ်
  Future<String> translateToMyanmarRecap(String transcript) async {
    final genUri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
    );
    final genRes = await http.post(
      genUri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
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
      }),
    );

    if (genRes.statusCode != 200) {
      throw Exception('Gemini ဘာသာပြန်မရပါ: ${genRes.body}');
    }

    final jsonRes = jsonDecode(genRes.body);
    return jsonRes['candidates'][0]['content']['parts'][0]['text'].toString().trim();
  }

  // Gemini တစ်ခုတည်းသုံးပြီး ဗီဒီယိုတိုက်ရိုက်ကြည့်မည့်စနစ်
  Future<String> generateRecapScript(String videoPath) async {
    final file = File(videoPath);
    final bytes = await file.readAsBytes();

    final uploadUri = Uri.parse(
      'https://generativelanguage.googleapis.com/upload/v1beta/files?key=$apiKey',
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
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/$fileName?key=$apiKey'),
      );
      final state = jsonDecode(stateRes.body)['state'];
      if (state == 'ACTIVE') break;
      if (state == 'FAILED') throw Exception('Gemini Video Processing မအောင်မြင်ပါ');
    }

    final genUri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
    );
    final genRes = await http.post(
      genUri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
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
      }),
    );

    if (genRes.statusCode != 200) {
      throw Exception('Script ထုတ်မရပါ: ${genRes.body}');
    }

    final jsonRes = jsonDecode(genRes.body);
    return jsonRes['candidates'][0]['content']['parts'][0]['text'].toString().trim();
  }
}
