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
  // ၁။ 240p 1fps ဖြတ်ထုတ်ပြီး Gemini ကို Scene အတိအကျနဲ့ Script ရေးခိုင်းမည်
  Future generateScriptForVideoPart({
    required String videoPath,
    required int partNumber,
    required int totalParts,
    required double chunkStartSec,
    required double chunkDurSec,
    required String previousSummary,
    String previousTailLines = '',
    required List<String> geminiKeys,
    Function(String)? onLog,
  }) async {
    final tempDir = Directory.systemTemp;
    final smallClipPath = '${tempDir.path}/gemini_p${partNumber}_${DateTime.now().millisecondsSinceEpoch}.mp4';

    onLog?.call('Part $partNumber/$totalParts: ဖိုင်အသေး (240p/1fps) ဖြတ်ထုတ်နေသည်...');
    final cutCmd = '-y -ss ${chunkStartSec.toStringAsFixed(2)} -t ${chunkDurSec.toStringAsFixed(2)} -i "$videoPath" '
        '-vf "scale=-2:240,fps=1" -c:v libx264 -preset ultrafast -crf 35 '
        '-c:a aac -ar 16000 -ac 1 -b:a 16k -movflags +faststart "$smallClipPath"';

    final cutSession = await FFmpegKit.execute(cutCmd);
    if (!ReturnCode.isSuccess(await cutSession.getReturnCode())) {
      throw Exception('Part $partNumber ဗီဒီယိုဖြတ်ထုတ်မရပါ');
    }

    final clipFile = File(smallClipPath);
    final sizeMb = (await clipFile.length()) / (1024 * 1024);
    onLog?.call('Part $partNumber: ဖိုင်ဆိုဒ် ${sizeMb.toStringAsFixed(2)} MB → Gemini ဆီ ပို့နေသည်...');

    final base64Video = base64Encode(await clipFile.readAsBytes());

    final int targetMinLines = (chunkDurSec / 8).round().clamp(10, 45);
    final int targetMaxLines = (chunkDurSec / 5).round().clamp(15, 60);

    final contextBuf = StringBuffer();
    if (previousSummary.trim().isEmpty) {
      contextBuf.writeln('This is PART 1 (the beginning of the movie). Introduce the characters and setting clearly.');
    } else {
      contextBuf.writeln('PREVIOUS STORY SUMMARY (keep character names & plot 100% consistent):');
      contextBuf.writeln(previousSummary.trim());
      if (previousTailLines.trim().isNotEmpty) {
        contextBuf.writeln('\nLAST NARRATION LINES FROM PREVIOUS PART (continue smoothly right after this, do NOT repeat):');
        contextBuf.writeln(previousTailLines.trim());
      }
    }

    final prompt = '''
You are a professional Burmese movie recap narrator.
Watch this entire video clip (PART $partNumber of $totalParts, exact duration: ${chunkDurSec.toStringAsFixed(0)} seconds) very carefully.

${contextBuf.toString()}

STRICT REQUIREMENTS:
1. First line MUST be: SUMMARY: <2-3 short sentences in Burmese summarizing key events & character names so far>
2. Write detailed, natural Burmese movie recap narration covering the FULL ${chunkDurSec.toStringAsFixed(0)} seconds ($targetMinLines to $targetMaxLines lines).
3. CRITICAL SYNC RULE: Every [start-end] timestamp MUST match the EXACT second when that visual action/scene happens on screen. Do NOT use evenly spaced dummy timestamps.
4. Format EVERY narration line strictly as: [start-end] Burmese text
   (start and end in seconds relative to THIS clip, from 0.0 to ${chunkDurSec.toStringAsFixed(1)})
5. Example:
SUMMARY: မင်းသားက ရွာထဲရောက်လာပြီး ရန်သူတွေနဲ့ စတင်တွေ့ဆုံခဲ့သည်။
[0.0-6.5] မင်းသားက မှောင်မိုက်နေတဲ့ လမ်းကြားထဲကို ဘေးဘီဝဲယာကြည့်ရင်း ဝင်လာခဲ့ပါတယ်။
[6.5-14.0] အဲဒီအချိန်မှာပဲ နောက်ကျောကနေ ရန်သူတစ်ယောက်က ဓားရှည်ကြီးနဲ့ ရုတ်တရက် ဝင်ခုတ်လိုက်ပါတယ်။
6. No markdown, no bold text, no extra explanations.
''';

    final models = ['gemini-3.5-flash', 'gemini-3.8-flash'];
    final int startKeyIdx = (partNumber - 1) % geminiKeys.length;
    String? lastError;

    try {
      for (final model in models) {
        for (int k = 0; k < geminiKeys.length; k++) {
          final keyIdx = (startKeyIdx + k) % geminiKeys.length;
          final key = geminiKeys[keyIdx];
          for (int attempt = 1; attempt <= 2; attempt++) {
            onLog?.call('Part $partNumber/$totalParts → $model | Key ${keyIdx + 1}/${geminiKeys.length} (အကြိမ် $attempt)...');
            try {
              final uri = Uri.parse(
                'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key',
              );
              final res = await http
                  .post(
                    uri,
                    headers: {'Content-Type': 'application/json'},
                    body: jsonEncode({
                      'contents': [
                        {
                          'parts': [
                            {
                              'inline_data': {
                                'mime_type': 'video/mp4',
                                'data': base64Video,
                              }
                            },
                            {'text': prompt}
                          ]
                        }
                      ],
                      'generationConfig': {'temperature': 0.3},
                    }),
                  )
                  .timeout(const Duration(seconds: 120));

              if (res.statusCode == 200) {
                final json = jsonDecode(res.body);
                final out = json['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString().trim();
                if (out != null && out.isNotEmpty) {
                  String newSummary = previousSummary;
                  final summaryMatch = RegExp(r'^SUMMARY:\s*(.+)$', multiLine: true).firstMatch(out);
                  if (summaryMatch != null) {
                    newSummary = summaryMatch.group(1)!.trim();
                  }

                  final segments = parseAlignedSegments(out, offsetSec: chunkStartSec);
                  if (segments.isNotEmpty) {
                    final tailList = segments.length >= 2
                        ? segments.sublist(segments.length - 2)
                        : segments;
                    final tailLines = tailList.map((e) => e['text'].toString()).join('\n');

                    onLog?.call('✅ Part $partNumber/$totalParts ($model) Script ထုတ်ပြီး (${segments.length} ကြောင်း)။');
                    return {
                      'segments': segments,
                      'summary': newSummary,
                      'tailLines': tailLines,
                    };
                  }
                }
              }

              lastError = '[$model] HTTP ${res.statusCode}: ${res.body}';
              if (res.statusCode == 404) break;
              if ((res.statusCode == 503 || res.statusCode == 429) && attempt == 1) {
                onLog?.call('⏳ Limit/Server ကျပ်နေသည် (${res.statusCode}) → ၁၂ စက္ကန့်စောင့်နေသည်...');
                await Future.delayed(const Duration(seconds: 12));
                continue;
              }
              break;
            } catch (e) {
              lastError = e.toString();
              if (attempt == 1) {
                onLog?.call('⚠️ ချိတ်ဆက်မှုနှေးနေသည် → ၅ စက္ကန့်စောင့်ပြီး ပြန်စမ်းနေသည်...');
                await Future.delayed(const Duration(seconds: 5));
                continue;
              }
            }
          }
          if (lastError != null && lastError.contains('HTTP 404')) break;
        }
      }
      throw Exception('Part $partNumber မအောင်မြင်ပါ: $lastError');
    } finally {
      try {
        if (await clipFile.exists()) await clipFile.delete();
      } catch (_) {}
    }
  }

  List parseAlignedSegments(String alignedScript, {double offsetSec = 0.0}) {
    final regex = RegExp(r'^\[(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\]\s*(.+)$');
    final lines = alignedScript.split(RegExp(r'\r?\n'));
    final List segments = [];

    for (final line in lines) {
      final m = regex.firstMatch(line.trim());
      if (m != null) {
        final s = double.parse(m.group(1)!) + offsetSec;
        final e = double.parse(m.group(2)!) + offsetSec;
        segments.add({
          'vStart': s,
          'vEnd': e > s ? e : s + 3.0,
          'text': m.group(3)!.trim(),
        });
      }
    }
    return segments;
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

  // ၂။ Zero-Drift Scene Sync + Continuous 6s Play / 3s Freeze & Zoom In/Out ဖြင့် Render ထုတ်မည်
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
    bool enableMirror = false,
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

    // Continuous 6s Play / 3s Freeze Timer + Zero-Drift Timeline Tracker
    double playAcc = 0.0;
    double freezeRem = 0.0;
    double targetTotalVid = 0.0;
    double actualTotalVid = 0.0;

    for (int i = 0; i < syncSegments.length; i++) {
      final double vStart = (syncSegments[i]['vStart'] as num).toDouble();
      final double vEnd = (syncSegments[i]['vEnd'] as num).toDouble();
      final double segVidDur = (vEnd - vStart) > 0.3 ? (vEnd - vStart) : 3.0;
      final double segAudDur = (syncSegments[i]['audDur'] as num).toDouble();

      targetTotalVid += segAudDur;
      double remaining = (targetTotalVid - actualTotalVid).clamp(0.2, 60.0);

      if (!enableCopyrightSafe) {
        final double ratio = (remaining / segVidDur).clamp(0.25, 4.0);
        final clipPath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';
        onLog?.call('Part $partNumber: အခန်း (${i + 1}/${syncSegments.length}) ဖြတ်ညှိနေသည်...');
        final cmd = '-y -ss ${vStart.toStringAsFixed(3)} -t ${segVidDur.toStringAsFixed(3)} -i "$videoPath" '
            '-vf "scale=$outW:$outH,setpts=(PTS-STARTPTS)*${ratio.toStringAsFixed(6)},fps=30" '
            '-t ${remaining.toStringAsFixed(3)} -an -c:v libx264 $presetFast -pix_fmt yuv420p "$clipPath"';
        final s = await FFmpegKit.execute(cmd);
        if (!ReturnCode.isSuccess(await s.getReturnCode())) {
          throw Exception('Part $partNumber Clip $i ဖြတ်မရပါ');
        }
        clipListBuf.writeln("file '$clipPath'");
        actualTotalVid += remaining;
      } else {
        onLog?.call('Part $partNumber: အခန်း (${i + 1}/${syncSegments.length}) [Sync + 6s/3s Freeze]...');
        final double safeSpeed = videoSpeed.clamp(0.4, 1.0);
        final double ptsMult = 1.0 / safeSpeed;
        double curSrcPos = vStart;

        while (remaining > 0.08) {
          // (က) Freeze လုပ်ရမယ့်အလှည့် (သို့) လက်ရှိအခန်း vEnd ကုန်သွားရင် Freeze + Zoom In/Out လုပ်မည်
          if (freezeRem > 0.08 || curSrcPos >= vEnd - 0.1) {
            final double fDur = (freezeRem > 0.08)
                ? (remaining < freezeRem ? remaining : freezeRem)
                : remaining;
            final int totalFrames = (fDur * 30).round().clamp(5, 600);
            final double freezeAt = curSrcPos.clamp(vStart, vEnd);
            final frameImg = '${tempDir.path}/p${partNumber}_f_$clipCounter.jpg';
            final freezePath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';

            await FFmpegKit.execute(
              '-y -ss ${freezeAt.toStringAsFixed(3)} -i "$videoPath" -frames:v 1 -q:v 2 "$frameImg"',
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
              actualTotalVid += fDur;
            }
            remaining -= fDur;
            if (freezeRem > 0.08) {
              freezeRem = (freezeRem - fDur).clamp(0.0, freezeSec);
            }
            if (freezeRem <= 0.08) {
              playAcc = 0.0;
            }
          } else {
            // (ခ) Play လုပ်မယ့်အလှည့် (0.65x Speed ဖြင့် 6s ပြည့်သည်အထိ သို့မဟုတ် vEnd အထိ ပြမည်)
            final double needPlay = (playSec - playAcc).clamp(0.15, playSec);
            final double maxSrcLeft = (vEnd - curSrcPos).clamp(0.05, 60.0);
            final double maxPlayFromScene = maxSrcLeft * ptsMult;

            double playDur = remaining < needPlay ? remaining : needPlay;
            if (playDur > maxPlayFromScene) playDur = maxPlayFromScene;

            final double srcNeeded = (playDur * safeSpeed).clamp(0.05, maxSrcLeft);
            final playPath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';
            final playCmd = '-y -ss ${curSrcPos.toStringAsFixed(3)} -t ${(srcNeeded + 0.15).toStringAsFixed(3)} -i "$videoPath" '
                '-vf "scale=$outW:$outH,setpts=(PTS-STARTPTS)*${ptsMult.toStringAsFixed(6)},fps=30" '
                '-t ${playDur.toStringAsFixed(3)} -an -c:v libx264 $presetFast -pix_fmt yuv420p "$playPath"';

            final sPlay = await FFmpegKit.execute(playCmd);
            if (!ReturnCode.isSuccess(await sPlay.getReturnCode())) {
              throw Exception('Part $partNumber Play Clip မအောင်မြင်ပါ');
            }
            clipListBuf.writeln("file '$playPath'");
            actualTotalVid += playDur;
            curSrcPos += srcNeeded;
            remaining -= playDur;
            playAcc += playDur;

            if (playAcc >= playSec - 0.05) {
              freezeRem = freezeSec;
              playAcc = 0.0;
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

    final outputPath = '${tempDir.path}/Recap_Part_${partNumber}_${DateTime.now().millisecondsSinceEpoch}.mp4';

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

    if (enableMirror) {
      filterBuf.writeln('[$currentV]hflip[v_flip];');
      currentV = 'v_flip';
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

  // ၃။ Part တွေအားလုံးကို YouTube ဗီဒီယိုတစ်ပုဒ်တည်း ပေါင်းမည် (-c copy)
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

    final mergedPath = '${tempDir.path}/YouTube_LongRecap_${DateTime.now().millisecondsSinceEpoch}.mp4';

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
