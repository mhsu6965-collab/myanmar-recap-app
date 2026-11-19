import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

class EdgeTtsService {
  static const _trustedToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _chromiumVersion = '130.0.2849.68';

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

  Future _synthesizeChunk({
    required String text,
    required String voice,
    required String rateStr,
    required String pitchStr,
  }) async {
    final requestId = const Uuid().v4().replaceAll('-', '');
    final secMsGec = _generateSecMsGec();

    final wsUrl =
        'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
        '?TrustedClientToken=$_trustedToken'
        '&Sec-MS-GEC=$secMsGec'
        '&Sec-MS-GEC-Version=1-$_chromiumVersion'
        '&ConnectionId=$requestId';

    final channel = IOWebSocketChannel.connect(
      Uri.parse(wsUrl),
      headers: {
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0',
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

  Future<void> synthesize({
    required String text,
    required String voice,
    required int ratePercent,
    required int pitchHz,
    required String audioOutPath,
    required String srtOutPath,
    Function(String)? onLog,
  }) async {
    final rateStr = '${ratePercent >= 0 ? '+' : ''}$ratePercent%';
    final pitchStr = '${pitchHz >= 0 ? '+' : ''}${pitchHz}Hz';
    final chunks = _splitText(text, 800);

    onLog?.call('Edge TTS: စာသားကို ${chunks.length} ပိုင်းခွဲပြီး အသံထုတ်နေသည်...');

    final allAudio = BytesBuilder();
    final allTimings = [];
    int timeOffsetTicks = 0;

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
          onLog?.call('Edge TTS: လိုင်းပြတ်၍ ၂ စက္ကန့်စောင့်ပြီး ပြန်ချိတ်နေသည် ($attempt/3)...');
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      allAudio.add(result!['audio'] as Uint8List);
      final List chunkTimings = result['timings'] as List;
      int lastEnd = 0;
      for (final w in chunkTimings) {
        final offset = (w['Offset'] as int) + timeOffsetTicks;
        final dur = w['Duration'] as int;
        allTimings.add({'Offset': offset, 'Duration': dur, 'text': w['text']});
        if ((w['Offset'] as int) + dur > lastEnd) {
          lastEnd = (w['Offset'] as int) + dur;
        }
      }
      timeOffsetTicks += lastEnd + 2000000;
    }

    await File(audioOutPath).writeAsBytes(allAudio.toBytes());
    onLog?.call('Edge TTS: MP3 အသံဖိုင် နှင့် SRT စာတန်းထိုးဖိုင် ပြီးစီးပါပြီ။');

    final srtBuffer = StringBuffer();
    int subIndex = 1;
    for (int i = 0; i < allTimings.length; i += 8) {
      final chunk = allTimings.sublist(
        i,
        (i + 8 > allTimings.length) ? allTimings.length : i + 8,
      );
      final startMs = (chunk.first['Offset'] as int) ~/ 10000;
      final endMs = ((chunk.last['Offset'] as int) + (chunk.last['Duration'] as int)) ~/ 10000;
      final lineText = chunk.map((w) => w['text']['Text']).join(' ');

      srtBuffer.writeln(subIndex++);
      srtBuffer.writeln('${_formatSrtTime(startMs)} --> ${_formatSrtTime(endMs)}');
      srtBuffer.writeln(lineText);
      srtBuffer.writeln();
    }
    await File(srtOutPath).writeAsString(srtBuffer.toString(), encoding: utf8);
  }

  String _formatSrtTime(int ms) {
    final hours = (ms ~/ 3600000).toString().padLeft(2, '0');
    final minutes = ((ms % 3600000) ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
    final millis = (ms % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$millis';
  }
}
