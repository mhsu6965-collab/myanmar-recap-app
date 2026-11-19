import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

class EdgeTtsService {
  static const _trustedToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  Future<void> synthesize({
    required String text,
    required String voice,
    required int ratePercent,
    required int pitchHz,
    required String audioOutPath,
    required String srtOutPath,
  }) async {
    final requestId = const Uuid().v4().replaceAll('-', '');
    final rateStr = '${ratePercent >= 0 ? '+' : ''}$ratePercent%';
    final pitchStr = '${pitchHz >= 0 ? '+' : ''}${pitchHz}Hz';

    final wsUrl =
        'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=$_trustedToken&ConnectionId=$requestId';

    final channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
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

    await completer.future;

    await File(audioOutPath).writeAsBytes(audioBytes.toBytes());

    final srtBuffer = StringBuffer();
    int subIndex = 1;
    for (int i = 0; i < wordTimings.length; i += 8) {
      final chunk = wordTimings.sublist(
        i,
        (i + 8 > wordTimings.length) ? wordTimings.length : i + 8,
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
