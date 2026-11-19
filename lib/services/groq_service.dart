import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

class GroqService {
  final String apiKey;
  GroqService(this.apiKey);

  // ဗီဒီယိုမှ အသံခွဲထုတ်ပြီး Groq Whisper ဖြင့် စာသား (Transcript) ပြန်ဖတ်မယ်
  Future<String> transcribeAudio(String videoPath) async {
    final tempDir = Directory.systemTemp;
    final audioPath = '${tempDir.path}/groq_audio_${DateTime.now().millisecondsSinceEpoch}.mp3';

    final session = await FFmpegKit.execute(
      '-y -i "$videoPath" -vn -acodec libmp3lame -q:a 5 "$audioPath"',
    );
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw Exception('ဗီဒီယိုမှ အသံခွဲထုတ်မရပါ');
    }

    final whisperReq = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'),
    )
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['model'] = 'whisper-large-v3-turbo'
      ..files.add(await http.MultipartFile.fromPath('file', audioPath));

    final whisperRes = await http.Response.fromStream(await whisperReq.send());
    if (whisperRes.statusCode != 200) {
      throw Exception('Groq Whisper မအောင်မြင်ပါ: ${whisperRes.body}');
    }
    return jsonDecode(whisperRes.body)['text'].toString().trim();
  }

  // Groq တစ်ခုတည်းသုံးချင်သူများအတွက်
  Future<String> generateRecapScript(String videoPath) async {
    final transcript = await transcribeAudio(videoPath);

    final chatRes = await http.post(
      Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        "model": "llama-3.3-70b-versatile",
        "messages": [
          {
            "role": "system",
            "content": "သင်သည် မြန်မာ Movie Recap Script ရေးသားသူဖြစ်သည်။ စာသားသက်သက် (Plain text) ပဲ ထုတ်ပေးပါ။ Markdown သင်္ကေတတွေ မထည့်ပါနဲ့။"
          },
          {
            "role": "user",
            "content": "အောက်ပါ ဗီဒီယိုစာသားကို ဆွဲဆောင်မှုရှိတဲ့ မြန်မာ Movie Recap ပုံစံနဲ့ အတိုချုံးပြန်ပြောပြပေးပါ:\n\n$transcript"
          }
        ]
      }),
    );

    if (chatRes.statusCode != 200) {
      throw Exception('Groq Script ထုတ်မရပါ: ${chatRes.body}');
    }
    return jsonDecode(chatRes.body)['choices'][0]['message']['content'].toString().trim();
  }
}
