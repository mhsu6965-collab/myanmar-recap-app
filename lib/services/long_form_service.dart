import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';
import 'edge_tts_service.dart';
import 'ffmpeg_service.dart';

class LongFormService {
  // ၁။ 1hr+ ဗီဒီယိုမှ 16kHz Mono MP3 (ဖိုင်သေး ~10-15MB) ခွဲထုတ်ပြီး Groq ဖြင့် Timestamp ယူမည်
  Future<String> extractLongTimestamps({
    required String videoPath,
    required String groqApiKey,
    Function(String)? onLog,
  }) async {
    final tempDir = Directory.systemTemp;
    final audioPath = '${tempDir.path}/long_16k_${DateTime.now().millisecondsSinceEpoch}.mp3';

    onLog?.call('16kHz Mono အသံဖိုင်အသေး ခွဲထုတ်နေသည် (1hr+ ဗီဒီယိုအတွက်)...');
    final session = await FFmpegKit.execute(
      '-y -i "$videoPath" -vn -ar 16000 -ac 1 -b:a 24k "$audioPath"',
    );
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw Exception('ဗီဒီယိုမှ အသံခွဲထုတ်မရပါ');
    }

    final fileSizeMb = (await File(audioPath).length()) / (1024 * 1024);
    onLog?.call('အသံဖိုင်ဆိုဒ်: ${fileSizeMb.toStringAsFixed(1)} MB → Groq Whisper ဆီ ပို့နေသည်...');

    final req = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'),
    )
      ..headers['Authorization'] = 'Bearer $groqApiKey'
      ..fields['model'] = 'whisper-large-v3-turbo'
      ..fields['response_format'] = 'verbose_json'
      ..files.add(await http.MultipartFile.fromPath('file', audioPath));

    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 200) {
      throw Exception('Groq Whisper မအောင်မြင်ပါ: ${res.body}');
    }

    final data = jsonDecode(res.body);
    final List rawSegments = data['segments'] ?? [];
    if (rawSegments.isEmpty) {
      throw Exception('ဗီဒီယိုထဲတွင် စကားပြောအသံ မတွေ့ပါ');
    }

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
      if ((groupEnd - groupStart) >= 15.0 || isLast) {
        buffer.writeln('[${groupStart.toStringAsFixed(1)}-${groupEnd.toStringAsFixed(1)}] ${groupText.toString().trim()}');
        groupStart = null;
        groupText.clear();
      }
    }

    onLog?.call('Groq Timestamp အားလုံး ဖတ်ပြီးပါပြီ။');
    return buffer.toString().trim();
  }

  // ၂။ မြန်မာ .txt Script ကို Groq Timestamp နှင့် Gemini (3.8 / 3.5) သုံးပြီး [start-end] တွဲပေးမည်
  Future<String> alignScriptWithGemini({
    required String groqTimestamps,
    required String myanmarTxtScript,
    required List<String> geminiKeys,
    Function(String)? onLog,
  }) async {
    final prompt = '''
You are a professional movie recap editor.
Below is the timestamped transcript of a long video in [start-end] format (in seconds), followed by a user's Myanmar recap script.
Match EVERY paragraph or sentence of the Myanmar recap script to the most accurate [start-end] time range from the video transcript in chronological order.

STRICT RULES:
1. Output ONLY lines in this exact format: [start-end] Myanmar text
2. Example: [12.5-35.0] မင်းသားက မြို့ထဲကို ရောက်လာပြီး...
3. Do NOT change, shorten, or omit the user's Myanmar text. Keep all of it.
4. Ensure start < end and timestamps progress forward chronologically.
5. No explanations, no markdown, no extra headers.

=== VIDEO TRANSCRIPT ===
$groqTimestamps

=== USER MYANMAR SCRIPT ===
$myanmarTxtScript
''';

    final models = [
      'gemini-3.8-flash',
      'gemini-3.5-flash',
    ];

    String? lastError;
    for (final model in models) {
      for (int i = 0; i < geminiKeys.length; i++) {
        final key = geminiKeys[i];
        onLog?.call('$model | Key (${i + 1}/${geminiKeys.length}) ဖြင့် စမ်းနေသည်...');
        try {
          final uri = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key',
          );
          final res = await http.post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ],
              'generationConfig': {'temperature': 0.2},
            }),
          );

          if (res.statusCode == 200) {
            final json = jsonDecode(res.body);
            final out = json['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString().trim();
            if (out != null && out.isNotEmpty) {
              onLog?.call('✅ $model ဖြင့် Script နှင့် အချိန်တွဲပြီးပါပြီ။');
              return out;
            }
          }
          lastError = '[$model] HTTP ${res.statusCode}: ${res.body}';
          if (res.statusCode == 404) break;
        } catch (e) {
          lastError = e.toString();
        }
      }
    }
    throw Exception('Gemini 3.8 / 3.5 အားလုံး မအောင်မြင်ပါ: $lastError');
  }

  // ၃။ [start-end] Script ကို Part 1, Part 2, Part 3... အပိုင်းခွဲပေးမည်
  List splitIntoParts(String alignedScript, int minutesPerPart) {
    final regex = RegExp(r'^\[(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\]\s*(.+)$');
    final lines = alignedScript.split(RegExp(r'\r?\n'));
    final allSegments = [];

    for (final line in lines) {
      final m = regex.firstMatch(line.trim());
      if (m != null) {
        allSegments.add({
          'vStart': double.parse(m.group(1)!),
          'vEnd': double.parse(m.group(2)!),
          'text': m.group(3)!.trim(),
        });
      }
    }

    if (allSegments.isEmpty) return [];

    final int targetChars = minutesPerPart * 650;
    final parts = [];
    final currentPart = [];
    int charCount = 0;

    for (final seg in allSegments) {
      currentPart.add(seg);
      charCount += (seg['text'] as String).length;
      if (charCount >= targetChars) {
        parts.add(List.from(currentPart));
        currentPart.clear();
        charCount = 0;
      }
    }
    if (currentPart.isNotEmpty) {
      parts.add(currentPart);
    }
    return parts;
  }

  Future<String> _prepareFontDir() async {
    final fontDir = Directory('${Directory.systemTemp.path}/fonts');
    if (!await fontDir.exists()) await fontDir.create(recursive: true);

    final fontFile = File('${fontDir.path}/Pyidaungsu.ttf');
    if (!await fontFile.exists()) {
      final data = await rootBundle.load('assets/fonts/Pyidaungsu.ttf');
      await fontFile.writeAsBytes(data.buffer.asUint8List());
    }
    await FFmpegKitConfig.setFontDirectoryList([fontDir.path, '/system/fonts']);
    return fontDir.path;
  }

  int _parseSrtTimeMs(String t) {
    final parts = t.trim().split(RegExp(r'[:,.]'));
    if (parts.length < 4) return 0;
    return int.parse(parts[0]) * 3600000 +
        int.parse(parts[1]) * 60000 +
        int.parse(parts[2]) * 1000 +
        int.parse(parts[3]);
  }

  String _formatAssTime(int ms) {
    final safeMs = ms < 0 ? 0 : ms;
    final h = safeMs ~/ 3600000;
    final m = ((safeMs % 3600000) ~/ 60000).toString().padLeft(2, '0');
    final s = ((safeMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final cs = ((safeMs % 1000) ~/ 10).toString().padLeft(2, '0');
    return '$h:$m:$s.$cs';
  }

  Future<String> _convertSrtToAss({
    required String srtPath,
    required int outW,
    required int outH,
    required double subY,
    required double subScale,
    required String subColorAss,
  }) async {
    final srtContent = await File(srtPath).readAsString(encoding: utf8);
    final assPath = '${Directory.systemTemp.path}/long_subs.ass';

    final baseFontSize = outH * 0.052;
    final fontSize = (baseFontSize * subScale).round().clamp(20, 180);
    final outline = (fontSize * 0.07).round().clamp(2, 8);
    final marginLR = (outW * 0.05).round();
    final posX = outW ~/ 2;
    final posY = (subY.clamp(0.05, 0.95) * outH).round();

    final ass = StringBuffer();
    ass.writeln('[Script Info]');
    ass.writeln('ScriptType: v4.00+');
    ass.writeln('PlayResX: $outW');
    ass.writeln('PlayResY: $outH');
    ass.writeln('WrapStyle: 2');
    ass.writeln('ScaledBorderAndShadow: yes');
    ass.writeln();
    ass.writeln('[V4+ Styles]');
    ass.writeln('Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding');
    ass.writeln('Style: Default,Pyidaungsu,$fontSize,$subColorAss,&H000000FF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,$outline,1,5,$marginLR,$marginLR,0,1');
    ass.writeln();
    ass.writeln('[Events]');
    ass.writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text');

    final blocks = srtContent.trim().split(RegExp(r'\r?\n\r?\n'));
    for (final block in blocks) {
      final lines = block.split(RegExp(r'\r?\n'));
      if (lines.length < 3) continue;
      final timeLine = lines[1];
      if (!timeLine.contains('-->')) continue;
      final times = timeLine.split('-->');
      final startMs = _parseSrtTimeMs(times[0]);
      final endMs = _parseSrtTimeMs(times[1]);
      final text = lines.sublist(2).join(r'\N').trim();
      if (text.isEmpty) continue;
      ass.writeln('Dialogue: 0,${_formatAssTime(startMs)},${_formatAssTime(endMs)},Default,,0,0,0,,{\\an5\\pos($posX,$posY)}$text');
    }

    await File(assPath).writeAsString(ass.toString(), encoding: utf8);
    return assPath;
  }

  // ၄။ Part တစ်ခုချင်းစီကို Speed (0.6x) + 6s Play / 3s Freeze & Zoom In/Out ဖြင့် Render ထုတ်မည်
  Future<String> renderPart({
    required int partNumber,
    required List partSegments,
    required String videoPath,
    required String voice,
    required int ratePercent,
    required int pitchHz,
    required String resolution,
    required bool enableCopyrightSafe,
    required double videoSpeed,
    required double playSec,
    required double freezeSec,
    required bool enableSubtitles,
    required double subY,
    required double subScale,
    required String subColorAss,
    required bool enableBlur,
    required BlurBox blurBox,
    String? bgmPath,
    double bgmVolume = 0.15,
    bool saveToGallery = true,
    Function(String)? onLog,
  }) async {
    final tempDir = Directory.systemTemp;
    final partScriptBuf = StringBuffer();
    for (final seg in partSegments) {
      partScriptBuf.writeln('[${seg['vStart']}-${seg['vEnd']}] ${seg['text']}');
    }

    final audioPath = '${tempDir.path}/part_${partNumber}_tts.mp3';
    final srtPath = '${tempDir.path}/part_${partNumber}_subs.srt';

    onLog?.call('Part $partNumber: Edge TTS အသံထုတ်နေသည်...');
    final syncSegments = await EdgeTtsService().synthesizeAuto(
      text: partScriptBuf.toString().trim(),
      voice: voice,
      ratePercent: ratePercent,
      pitchHz: pitchHz,
      audioOutPath: audioPath,
      srtOutPath: srtPath,
      onLog: onLog,
    );

    final vidInfo = await FfmpegService().getVideoInfo(videoPath);
    final int srcW = vidInfo['width'] as int;
    final int srcH = vidInfo['height'] as int;
    final double audDur = await FfmpegService().getDuration(audioPath);

    final int targetShort = resolution == '1080p' ? 1080 : 720;
    int outW;
    int outH;
    if (srcH >= srcW) {
      outW = targetShort;
      outH = (((srcH * targetShort) / srcW).round() ~/ 2) * 2;
    } else {
      outH = targetShort;
      outW = (((srcW * targetShort) / srcH).round() ~/ 2) * 2;
    }

    final clipListBuf = StringBuffer();
    final presetFast = '-preset ultrafast -crf 25 -threads 2';
    int clipCounter = 0;
    bool zoomInToggle = true;

    for (int i = 0; i < syncSegments.length; i++) {
      final double vStart = (syncSegments[i]['vStart'] as num).toDouble();
      final double vEnd = (syncSegments[i]['vEnd'] as num).toDouble();
      final double segVidDur = (vEnd - vStart) > 0.5 ? (vEnd - vStart) : 4.0;
      final double segAudDur = (syncSegments[i]['audDur'] as num).toDouble();

      if (!enableCopyrightSafe) {
        final double ratio = (segAudDur / segVidDur).clamp(0.25, 4.0);
        final clipPath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';
        onLog?.call('Part $partNumber: အခန်း (${i + 1}/${syncSegments.length}) ဖြတ်ညှိနေသည်...');
        final cmd = '-y -ss ${vStart.toStringAsFixed(3)} -t ${segVidDur.toStringAsFixed(3)} -i "$videoPath" '
            '-vf "scale=$outW:$outH,setpts=(PTS-STARTPTS)*${ratio.toStringAsFixed(6)},fps=30" '
            '-an -c:v libx264 $presetFast -pix_fmt yuv420p "$clipPath"';
        final s = await FFmpegKit.execute(cmd);
        if (!ReturnCode.isSuccess(await s.getReturnCode())) {
          throw Exception('Part $partNumber Clip $i ဖြတ်မရပါ');
        }
        clipListBuf.writeln("file '$clipPath'");
      } else {
        onLog?.call('Part $partNumber: အခန်း (${i + 1}/${syncSegments.length}) [Speed ${videoSpeed}x + Freeze/Zoom]...');
        double remaining = segAudDur;
        double curSrcPos = vStart;
        final double ptsMult = 1.0 / videoSpeed.clamp(0.4, 1.0);

        while (remaining > 0.15) {
          final double playDur = remaining >= playSec ? playSec : remaining;
          final double srcNeeded = playDur * videoSpeed;
          if (curSrcPos + srcNeeded > vEnd) {
            curSrcPos = vStart;
          }

          final playPath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';
          final playCmd = '-y -ss ${curSrcPos.toStringAsFixed(3)} -t ${(srcNeeded + 0.2).toStringAsFixed(3)} -i "$videoPath" '
              '-vf "scale=$outW:$outH,setpts=(PTS-STARTPTS)*${ptsMult.toStringAsFixed(6)},fps=30" '
              '-t ${playDur.toStringAsFixed(3)} -an -c:v libx264 $presetFast -pix_fmt yuv420p "$playPath"';

          final sPlay = await FFmpegKit.execute(playCmd);
          if (!ReturnCode.isSuccess(await sPlay.getReturnCode())) {
            throw Exception('Part $partNumber Play Clip မအောင်မြင်ပါ');
          }
          clipListBuf.writeln("file '$playPath'");

          curSrcPos += srcNeeded;
          remaining -= playDur;

          if (remaining > 0.4) {
            final double fDur = remaining >= freezeSec ? freezeSec : remaining;
            final int totalFrames = (fDur * 30).round().clamp(15, 300);
            final frameImg = '${tempDir.path}/p${partNumber}_f_$clipCounter.jpg';
            final freezePath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';

            await FFmpegKit.execute(
              '-y -ss ${curSrcPos.toStringAsFixed(3)} -i "$videoPath" -frames:v 1 -q:v 2 "$frameImg"',
            );

            final zoomExpr = zoomInToggle
                ? "min(zoom+0.0022,1.22)"
                : "if(lte(on,1),1.22,max(1.0,zoom-0.0022))";
            zoomInToggle = !zoomInToggle;

            final freezeCmd = '-y -i "$frameImg" '
                '-vf "scale=$outW:$outH,zoompan=z=\'$zoomExpr\':x=\'iw/2-(iw/zoom/2)\':y=\'ih/2-(ih/zoom/2)\':d=$totalFrames:s=${outW}x$outH:fps=30" '
                '-t ${fDur.toStringAsFixed(3)} -an -c:v libx264 $presetFast -pix_fmt yuv420p "$freezePath"';

            final sFreeze = await FFmpegKit.execute(freezeCmd);
            if (ReturnCode.isSuccess(await sFreeze.getReturnCode())) {
              clipListBuf.writeln("file '$freezePath'");
              remaining -= fDur;
            }
          }
        }
      }
    }

    final listFile = File('${tempDir.path}/p${partNumber}_list.txt');
    await listFile.writeAsString(clipListBuf.toString());

    final rawConcatPath = '${tempDir.path}/p${partNumber}_raw.mp4';
    final concatSession = await FFmpegKit.execute(
      '-y -f concat -safe 0 -i "${listFile.path}" -c copy "$rawConcatPath"',
    );
    if (!ReturnCode.isSuccess(await concatSession.getReturnCode())) {
      throw Exception('Part $partNumber Clip များ ပြန်ဆက်မရပါ');
    }

    final outDir = Directory('/storage/emulated/0/Download');
    final saveFolder = await outDir.exists() ? outDir.path : tempDir.path;
    final outputPath = '$saveFolder/Recap_Part_${partNumber}_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final filterBuf = StringBuffer();
    String currentV = '0:v';

    if (enableBlur && blurBox.enabled) {
      final bx = blurBox.x.clamp(0.0, 0.95).toStringAsFixed(4);
      final by = blurBox.y.clamp(0.0, 0.95).toStringAsFixed(4);
      final bw = blurBox.w.clamp(0.05, 1.0 - blurBox.x).toStringAsFixed(4);
      final bh = blurBox.h.clamp(0.05, 1.0 - blurBox.y).toStringAsFixed(4);
      filterBuf.writeln(
        '[$currentV]split[m1][b1];'
        '[b1]crop=iw*$bw:ih*$bh:iw*$bx:ih*$by,boxblur=10:2[bl1];'
        '[m1][bl1]overlay=W*$bx:H*$by[v_blur];',
      );
      currentV = 'v_blur';
    }

    if (enableSubtitles) {
      final fontDir = await _prepareFontDir();
      final assPath = await _convertSrtToAss(
        srtPath: srtPath,
        outW: outW,
        outH: outH,
        subY: subY,
        subScale: subScale,
        subColorAss: subColorAss,
      );
      filterBuf.writeln('[$currentV]ass=$assPath:fontsdir=$fontDir:shaping=complex[v_out];');
      currentV = 'v_out';
    } else if (currentV == '0:v') {
      filterBuf.writeln('[0:v]null[v_out];');
      currentV = 'v_out';
    }

    String audioInputArgs = '-i "$audioPath"';
    if (bgmPath != null && bgmPath.isNotEmpty && File(bgmPath).existsSync()) {
      audioInputArgs += ' -stream_loop -1 -i "$bgmPath"';
      filterBuf.write(
        '[1:a]aresample=async=1:first_pts=0[tts_a];'
        '[2:a]volume=${bgmVolume.toStringAsFixed(2)}[bgm_a];'
        '[tts_a][bgm_a]amix=inputs=2:duration=first:dropout_transition=2[a_out]',
      );
    } else {
      filterBuf.write('[1:a]aresample=async=1:first_pts=0[a_out]');
    }

    final filterScriptPath = '${tempDir.path}/p${partNumber}_filter.txt';
    await File(filterScriptPath).writeAsString(filterBuf.toString(), encoding: utf8);

    onLog?.call('Part $partNumber: အသံ၊ စာတန်း နှင့် BGM ပေါင်းထုတ်နေသည်...');
    final finalCmd = '-y -i "$rawConcatPath" $audioInputArgs '
        '-filter_complex_script "$filterScriptPath" '
        '-map "[$currentV]" -map "[a_out]" '
        '-c:v libx264 $presetFast -pix_fmt yuv420p '
        '-c:a aac -b:a 128k -movflags +faststart -t ${audDur.toStringAsFixed(3)} "$outputPath"';

    final finalSession = await FFmpegKit.execute(finalCmd);
    if (!ReturnCode.isSuccess(await finalSession.getReturnCode())) {
      final logs = await finalSession.getAllLogsAsString();
      throw Exception('Part $partNumber Render မအောင်မြင်ပါ:\n$logs');
    }

    if (saveToGallery) {
      try {
        await Gal.putVideo(outputPath, album: 'Myanmar Recap');
        onLog?.call('✅ Part $partNumber ကို Gallery ထဲ သိမ်းပြီးပါပြီ။');
      } catch (_) {}
    }

    return outputPath;
  }

  // ၅။ Part တွေအားလုံးကို YouTube ဗီဒီယိုတစ်ပုဒ်တည်း ပေါင်းမည် (-c copy)
  Future<String> mergeAllParts({
    required List<String> partPaths,
    Function(String)? onLog,
  }) async {
    final tempDir = Directory.systemTemp;
    final listBuf = StringBuffer();
    for (final p in partPaths) {
      listBuf.writeln("file '$p'");
    }
    final listFile = File('${tempDir.path}/merge_all_parts.txt');
    await listFile.writeAsString(listBuf.toString());

    final outDir = Directory('/storage/emulated/0/Download');
    final saveFolder = await outDir.exists() ? outDir.path : tempDir.path;
    final mergedPath = '$saveFolder/YouTube_LongRecap_${DateTime.now().millisecondsSinceEpoch}.mp4';

    onLog?.call('Part ${partPaths.length} ခုလုံးကို YouTube ဗီဒီယိုတစ်ပုဒ်တည်း ပေါင်းနေသည်...');
    final session = await FFmpegKit.execute(
      '-y -f concat -safe 0 -i "${listFile.path}" -c copy -movflags +faststart "$mergedPath"',
    );
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw Exception('Part များ ပေါင်း၍မရပါ');
    }

    try {
      await Gal.putVideo(mergedPath, album: 'Myanmar Recap');
      onLog?.call('✅ YouTube Long Recap ကို Gallery ထဲ သိမ်းပြီးပါပြီ!');
    } catch (_) {}

    return mergedPath;
  }
}
