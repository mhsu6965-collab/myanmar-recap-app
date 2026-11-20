import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

class GroqService {
  final String apiKey;
  GroqService(this.apiKey);

  // ဗီဒီယိုမှ အသံခွဲထုတ်ပြီး Timestamp ပါသည့် Script ([0.0-14.5] ...) ထုတ်ပေးမည်
  Future<String> transcribeWithTimestamps(String videoPath) async {
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
      ..fields['response_format'] = 'verbose_json'
      ..files.add(await http.MultipartFile.fromPath('file', audioPath));

    final whisperRes = await http.Response.fromStream(await whisperReq.send());
    if (whisperRes.statusCode != 200) {
      throw Exception('Groq Whisper မအောင်မြင်ပါ: ${whisperRes.body}');
    }

    final data = jsonDecode(whisperRes.body);
    final List rawSegments = data['segments'] ?? [];
    if (rawSegments.isEmpty) {
      return data['text'].toString().trim();
    }

    // ဖုန်း CPU သက်သာပြီး Sync တိကျအောင် ၁၂ စက္ကန့်ဝန်းကျင်စီ စုစည်းပေးမည်
    final buffer = StringBuffer();
    double? groupStart;
    double groupEnd = 0.0;
    final groupText = StringBuffer();

    for (int i = 0; i < rawSegments.length; i++) {
      final seg = rawSegments[i];
      final double start = (seg['start'] as num).toDouble();
      final double end = (seg['end'] as num).toDouble();
      final String text = seg['text'].toString().trim();
      if (text.isEmpty) continue;

      groupStart ??= start;
      groupEnd = end;
      if (groupText.isNotEmpty) groupText.write(' ');
      groupText.write(text);

      final isLast = i == rawSegments.length - 1;
      if ((groupEnd - groupStart) >= 5.0 || isLast) {
        buffer.writeln('[${groupStart.toStringAsFixed(1)}-${groupEnd.toStringAsFixed(1)}] ${groupText.toString().trim()}');
        groupStart = null;
        groupText.clear();
      }
    }

    return buffer.toString().trim();
  }

  // ရိုးရိုး စာသားသက်သက် (Hybrid စနစ်အတွက်)
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
}
