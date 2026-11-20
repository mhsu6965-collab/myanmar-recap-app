import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

class EdgeTtsService {
  static const _trustedToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _chromiumVersion = '143.0.3650.75';

  String _generateSecMsGec() {
    int ticks = (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000) + 11644473600;
    ticks -= ticks % 300;
    ticks *= 10000000;
    final strToHash = '$ticks$_trustedToken';
    return sha256.convert(utf8.encode(strToHash)).toString().toUpperCase();
  }

  List<String> _splitText(String text, int maxLen) {
    final List<String> chunks = [];
    String remaining = text.trim();
    while (remaining.isNotEmpty) {
      if (remaining.length <= maxLen) {
        chunks.add(remaining);
        break;
      }
      int splitAt = remaining.lastIndexOf('။', maxLen);
      if (splitAt == -1) splitAt = remaining.lastIndexOf('\n', maxLen);
      if (splitAt == -1) splitAt = remaining.lastIndexOf(' ', maxLen);
      if (splitAt <= 0) splitAt = maxLen;
      chunks.add(remaining.substring(0, splitAt + 1).trim());
      remaining = remaining.substring(splitAt + 1).trim();
    }
    return chunks.where((c) => c.isNotEmpty).toList();
  }

  String _formatTwoLines(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= 24) return clean;
    final mid = clean.length ~/ 2;
    int splitIdx = clean.indexOf(' ', mid);
    if (splitIdx == -1 || splitIdx > clean.length - 4) {
      splitIdx = clean.lastIndexOf(' ', mid);
    }
    if (splitIdx > 4 && splitIdx < clean.length - 4) {
      return '${clean.substring(0, splitIdx).trim()}\n${clean.substring(splitIdx + 1).trim()}';
    }
    return clean;
  }

  Future _synthesizeChunk({
    required String text,
    required String voice,
    required String rateStr,
    required String pitchStr,
  }) async {
    final requestId = const Uuid().v4().replaceAll('-', '');
    final secMsGec = _generateSecMsGec();
    final muid = const Uuid().v4().replaceAll('-', '').toUpperCase();

    final wsUrl =
        'wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1'
        '?Ocp-Apim-Subscription-Key=$_trustedToken'
        '&Sec-MS-GEC=$secMsGec'
        '&Sec-MS-GEC-Version=1-$_chromiumVersion'
        '&ConnectionId=$requestId';

    final channel = IOWebSocketChannel.connect(
      Uri.parse(wsUrl),
      headers: {
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'Accept-Language': 'en-US,en;q=0.9',
        'Cookie': 'muid=$muid;',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
      },
    );

    await channel.ready;

    final audioBytes = BytesBuilder();
    final wordTimings = [];
    final completer = Completer<void>();

    channel.stream.listen((message) {
      if (message is String) {
        if (message.contains('Path:turn.end')) {
          channel.sink.close();
          if (!completer.isCompleted) completer.complete();
        } else if (message.contains('Path:audio.metadata')) {
          final jsonStart = message.indexOf('{');
          if (jsonStart != -1) {
            final meta = jsonDecode(message.substring(jsonStart));
            for (final item in meta['Metadata'] ?? []) {
              if (item['Type'] == 'WordBoundary') {
                wordTimings.add(item['Data']);
              }
            }
          }
        }
      } else if (message is List<int>) {
        final bytes = Uint8List.fromList(message);
        final headerLen = (bytes[0] << 8) | bytes[1];
        final dataStart = headerLen + 2;
        if (dataStart < bytes.length) {
          audioBytes.add(bytes.sublist(dataStart));
        }
      }
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    }, onDone: () {
      if (!completer.isCompleted) completer.complete();
    });

    final configMsg = 'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}';
    channel.sink.add(configMsg);

    final escapedText = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='my-MM'>"
        "<voice name='$voice'>"
        "<prosody rate='$rateStr' pitch='$pitchStr'>$escapedText</prosody>"
        "</voice></speak>";

    final ssmlMsg = 'X-RequestId:$requestId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'Path:ssml\r\n\r\n$ssml';
    channel.sink.add(ssmlMsg);

    await completer.future.timeout(const Duration(seconds: 40));
    return {'audio': audioBytes.toBytes(), 'timings': wordTimings};
  }

  Future<int> _getExactAudioMs(String filePath, int fallbackMs) async {
    try {
      final session = await FFprobeKit.getMediaInformation(filePath);
      final durStr = session.getMediaInformation()?.getDuration();
      if (durStr != null) {
        return (double.parse(durStr) * 1000).round();
      }
    } catch (_) {}
    return fallbackMs;
  }

  void _writeTwoLineSrt(List allTimings, String srtOutPath) {
    final srtBuffer = StringBuffer();
    int subIndex = 1;
    int i = 0;
    while (i < allTimings.length) {
      final int cueStart = allTimings[i]['startMs'] as int;
      int cueEnd = allTimings[i]['endMs'] as int;
      final lineBuf = StringBuffer();
      int count = 0;

      while (i < allTimings.length) {
        final word = allTimings[i]['text'] as String;
        if (count > 0 && (lineBuf.length + word.length > 44 || count >= 5)) {
          break;
        }
        if (lineBuf.isNotEmpty) lineBuf.write(' ');
        lineBuf.write(word);
        cueEnd = allTimings[i]['endMs'] as int;
        count++;
        i++;
        if (word.endsWith('။')) break;
      }

      if (cueEnd <= cueStart) cueEnd = cueStart + 600;
      srtBuffer.writeln(subIndex++);
      srtBuffer.writeln('${_formatSrtTime(cueStart)} --> ${_formatSrtTime(cueEnd)}');
      srtBuffer.writeln(_formatTwoLines(lineBuf.toString()));
      srtBuffer.writeln();
    }

    File(srtOutPath).writeAsStringSync(srtBuffer.toString(), encoding: utf8);
  }

  // [0.0-14.5] အချိန်ပါတဲ့ Script ဆိုရင် အပိုင်းလိုက် TTS ထုတ်ပြီး Sync Data ပြန်ပေးမည်
  Future<List> synthesizeAuto({
    required String text,
    required String voice,
    required int ratePercent,
    required int pitchHz,
    required String audioOutPath,
    required String srtOutPath,
    Function(String)? onLog,
  }) async {
    final regex = RegExp(r'^\[(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\]\s*(.+)$');
    final parsed = [];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final m = regex.firstMatch(line.trim());
      if (m != null) {
        parsed.add({
          'vStart': double.parse(m.group(1)!),
          'vEnd': double.parse(m.group(2)!),
          'text': m.group(3)!.trim(),
        });
      }
    }

    final rateStr = '${ratePercent >= 0 ? '+' : ''}$ratePercent%';
    final pitchStr = '${pitchHz >= 0 ? '+' : ''}${pitchHz}Hz';
    final tempDir = Directory.systemTemp;
    final allAudio = BytesBuilder();
    final allTimings = [];
    final syncSegments = [];
    int currentOffsetMs = 0;

    if (parsed.isNotEmpty) {
      onLog?.call('Edge TTS (Sync Mode): အပိုင်း ${parsed.length} ခုကို အပိုင်းလိုက် အသံထုတ်နေသည်...');

      for (int i = 0; i < parsed.length; i++) {
        onLog?.call('Edge TTS: အပိုင်း (${i + 1}/${parsed.length}) ထုတ်နေသည်...');
        final segText = parsed[i]['text'] as String;
        Map? result;

        for (int attempt = 1; attempt <= 3; attempt++) {
          try {
            result = await _synthesizeChunk(
              text: segText,
              voice: voice,
              rateStr: rateStr,
              pitchStr: pitchStr,
            );
            break;
          } catch (e) {
            if (attempt == 3) rethrow;
            onLog?.call('Edge TTS: လိုင်းပြတ်၍ ပြန်ချိတ်နေသည် ($attempt/3)...');
            await Future.delayed(const Duration(seconds: 2));
          }
        }

        final Uint8List chunkBytes = result!['audio'] as Uint8List;
        allAudio.add(chunkBytes);

        final chunkFile = File('${tempDir.path}/tts_sync_$i.mp3');
        await chunkFile.writeAsBytes(chunkBytes);

        final List chunkTimings = result['timings'] as List;
        int lastEndMs = 0;
        for (final w in chunkTimings) {
          final startMs = ((w['Offset'] as int) ~/ 10000) + currentOffsetMs;
          final durMs = (w['Duration'] as int) ~/ 10000;
          allTimings.add({
            'startMs': startMs,
            'endMs': startMs + durMs,
            'text': w['text']['Text'].toString(),
          });
          final relEnd = ((w['Offset'] as int) + (w['Duration'] as int)) ~/ 10000;
          if (relEnd > lastEndMs) lastEndMs = relEnd;
        }

        final exactMs = await _getExactAudioMs(chunkFile.path, lastEndMs + 150);
        currentOffsetMs += exactMs;

        syncSegments.add({
          'vStart': parsed[i]['vStart'],
          'vEnd': parsed[i]['vEnd'],
          'audDur': exactMs / 1000.0,
        });
      }

      await File(audioOutPath).writeAsBytes(allAudio.toBytes());
      _writeTwoLineSrt(allTimings, srtOutPath);
      onLog?.call('Edge TTS: အပိုင်း ${parsed.length} ခုလုံး အသံနှင့် စာတန်းထိုး ပြီးစီးပါပြီ။');
      return syncSegments;
    }

    // အချိန်မပါတဲ့ ရိုးရိုးစာသားဆိုရင် ပုံမှန်အတိုင်း ထုတ်ပေးမည်
    final chunks = _splitText(text, 800);
    onLog?.call('Edge TTS: စာသားကို ${chunks.length} ပိုင်းခွဲပြီး အသံထုတ်နေသည်...');

    for (int i = 0; i < chunks.length; i++) {
      onLog?.call('Edge TTS: အပိုင်း (${i + 1}/${chunks.length}) ထုတ်နေသည်...');
      Map? result;

      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          result = await _synthesizeChunk(
            text: chunks[i],
            voice: voice,
            rateStr: rateStr,
            pitchStr: pitchStr,
          );
          break;
        } catch (e) {
          if (attempt == 3) rethrow;
          onLog?.call('Edge TTS: လိုင်းပြတ်၍ ပြန်ချိတ်နေသည် ($attempt/3)...');
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      final Uint8List chunkBytes = result!['audio'] as Uint8List;
      allAudio.add(chunkBytes);

      final chunkFile = File('${tempDir.path}/tts_chunk_$i.mp3');
      await chunkFile.writeAsBytes(chunkBytes);

      final List chunkTimings = result['timings'] as List;
      int lastEndMs = 0;
      for (final w in chunkTimings) {
        final startMs = ((w['Offset'] as int) ~/ 10000) + currentOffsetMs;
        final durMs = (w['Duration'] as int) ~/ 10000;
        allTimings.add({
          'startMs': startMs,
          'endMs': startMs + durMs,
          'text': w['text']['Text'].toString(),
        });
        final relEnd = ((w['Offset'] as int) + (w['Duration'] as int)) ~/ 10000;
        if (relEnd > lastEndMs) lastEndMs = relEnd;
      }

      final exactMs = await _getExactAudioMs(chunkFile.path, lastEndMs + 150);
      currentOffsetMs += exactMs;
    }

    await File(audioOutPath).writeAsBytes(allAudio.toBytes());
    _writeTwoLineSrt(allTimings, srtOutPath);
    onLog?.call('Edge TTS: MP3 အသံဖိုင် နှင့် ၂ ကြောင်းစာတန်းထိုး ပြီးစီးပါပြီ။');
    return [];
  }

  String _formatSrtTime(int ms) {
    final hours = (ms ~/ 3600000).toString().padLeft(2, '0');
    final minutes = ((ms % 3600000) ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
    final millis = (ms % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$millis';
  }
}
