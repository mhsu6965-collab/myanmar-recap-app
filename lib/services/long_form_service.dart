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
  // Temp ဖိုင်အသေးများကို ဘေးကင်းစွာ ပြန်ဖျက်ပေးမည့် Helper
  Future<void> _cleanupTempFiles(List<String> paths) async {
    for (final p in paths) {
      try {
        final f = File(p);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
  }

  // =========================================================================
  // MODE A: GROQ (အသံထုတ်) + GEMINI (သဘာဝပြောစကား ဘာသာပြန်) + SMART SYNC DUBBING
  // =========================================================================

  Future<List> transcribePartWithGroq({
    required String videoPath,
    required int partNumber,
    required int totalParts,
    required double chunkStartSec,
    required double chunkDurSec,
    required String groqApiKey,
    Function(String)? onLog,
  }) async {
    final tempDir = Directory.systemTemp;
    final audioClipPath = '${tempDir.path}/groq_p${partNumber}_${DateTime.now().millisecondsSinceEpoch}.mp3';

    onLog?.call('Part $partNumber/$totalParts: Groq အတွက် အသံဖိုင် ဖြတ်ထုတ်နေသည်...');
    final cutCmd = '-y -ss ${chunkStartSec.toStringAsFixed(2)} -t ${chunkDurSec.toStringAsFixed(2)} -i "$videoPath" '
        '-vn -ac 1 -ar 16000 -b:a 32k "$audioClipPath"';

    final cutSession = await FFmpegKit.execute(cutCmd);
    if (!ReturnCode.isSuccess(await cutSession.getReturnCode())) {
      throw Exception('Part $partNumber အသံဖြတ်ထုတ်မရပါ');
    }

    try {
      onLog?.call('Part $partNumber/$totalParts: Groq Whisper ဖြင့် စကားပြော Script ထုတ်နေသည်...');
      final uri = Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${groqApiKey.trim()}'
        ..fields['model'] = 'whisper-large-v3-turbo'
        ..fields['response_format'] = 'verbose_json'
        ..files.add(await http.MultipartFile.fromPath('file', audioClipPath));

      final streamedRes = await request.send().timeout(const Duration(seconds: 90));
      final resBody = await streamedRes.stream.bytesToString();

      if (streamedRes.statusCode != 200) {
        throw Exception('Groq HTTP ${streamedRes.statusCode}: $resBody');
      }

      final json = jsonDecode(resBody);
      final rawSegments = (json['segments'] as List?) ?? [];
      final List result = [];

      for (final seg in rawSegments) {
        final text = (seg['text'] ?? '').toString().trim();
        if (text.isEmpty) continue;
        final start = (seg['start'] as num).toDouble();
        final end = (seg['end'] as num).toDouble();
        result.add({
          'start': start,
          'end': end > start ? end : start + 1.5,
          'text': text,
        });
      }

      onLog?.call('✅ Part $partNumber: Groq Script ထုတ်ပြီး (${result.length} ကြောင်း)။');
      return result;
    } finally {
      await _cleanupTempFiles([audioClipPath]);
    }
  }

  Future generateDubbingScriptForPart({
    required String videoPath,
    required int partNumber,
    required int totalParts,
    required double chunkStartSec,
    required double chunkDurSec,
    required String previousSummary,
    String previousTailLines = '',
    required String groqApiKey,
    required List<String> geminiKeys,
    Function(String)? onLog,
  }) async {
    final groqSegments = await transcribePartWithGroq(
      videoPath: videoPath,
      partNumber: partNumber,
      totalParts: totalParts,
      chunkStartSec: chunkStartSec,
      chunkDurSec: chunkDurSec,
      groqApiKey: groqApiKey,
      onLog: onLog,
    );

    if (groqSegments.isEmpty) {
      return {
        'segments': [],
        'summary': previousSummary,
        'tailLines': previousTailLines,
      };
    }

    final transcriptBuf = StringBuffer();
    for (final s in groqSegments) {
      transcriptBuf.writeln('[${(s['start'] as double).toStringAsFixed(2)}-${(s['end'] as double).toStringAsFixed(2)}] ${s['text']}');
    }

    final tempDir = Directory.systemTemp;
    final smallClipPath = '${tempDir.path}/gemini_dub_p${partNumber}_${DateTime.now().millisecondsSinceEpoch}.mp4';

    onLog?.call('Part $partNumber/$totalParts: Gemini ကြည့်ဖို့ 240p ဖိုင်အသေး ဖြတ်ထုတ်နေသည်...');
    final cutCmd = '-y -ss ${chunkStartSec.toStringAsFixed(2)} -t ${chunkDurSec.toStringAsFixed(2)} -i "$videoPath" '
        '-vf "scale=-2:240,fps=0.5" -c:v libx264 -preset ultrafast -crf 35 -an -movflags +faststart "$smallClipPath"';

    final cutSession = await FFmpegKit.execute(cutCmd);
    if (!ReturnCode.isSuccess(await cutSession.getReturnCode())) {
      throw Exception('Part $partNumber ဗီဒီယိုဖြတ်ထုတ်မရပါ');
    }

    final clipFile = File(smallClipPath);
    final base64Video = base64Encode(await clipFile.readAsBytes());

    final contextBuf = StringBuffer();
    if (previousSummary.trim().isNotEmpty) {
      contextBuf.writeln('PREVIOUS STORY SUMMARY (keep character names & pronouns consistent):');
      contextBuf.writeln(previousSummary.trim());
    }

    final prompt = '''
You are a professional Burmese drama dubbing translator.
Watch this video clip (PART $partNumber of $totalParts) to understand the exact scene, speaker gender, age, relationship (e.g., မေမေ/သား/အစ်ကို/ညီမ/မင်း/ငါ), and emotion.
Translate EVERY SINGLE LINE of the provided original transcript into NATURAL, SHORT, SPOKEN BURMESE (ပြောစကား — NOT formal/literary Burmese).

${contextBuf.toString()}

ORIGINAL TRANSCRIPT (with exact timestamps):
${transcriptBuf.toString()}

STRICT RULES:
1. First line MUST be: SUMMARY: <2 short sentences in Burmese summarizing key events & character names so far>
2. Translate EVERY line faithfully—do NOT skip lines, do NOT merge lines, do NOT invent extra lines.
3. KEEP THE EXACT [start-end] TIMESTAMPS UNCHANGED from the original transcript.
4. Keep every Burmese line SHORT, punchy, and conversational so spoken TTS matches the lip movement duration naturally.
5. Output format strictly:
SUMMARY: ...
[0.00-3.20] မေမေ ဒါဆို သားတို့ စိုက်ထားတဲ့ ဆေးပင်တွေနဲ့တင် မလောက်တော့ဘူးနော်။
6. No markdown, no extra commentary.
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
            onLog?.call('Part $partNumber/$totalParts → $model | Key ${keyIdx + 1}/${geminiKeys.length} ဘာသာပြန်နေသည်...');
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
                      'generationConfig': {'temperature': 0.25},
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

                  final segments = parseAlignedSegments(out, offsetSec: 0.0);
                  if (segments.isNotEmpty) {
                    final tailList = segments.length >= 2 ? segments.sublist(segments.length - 2) : segments;
                    final tailLines = tailList.map((e) => e['text'].toString()).join('\n');
                    onLog?.call('✅ Part $partNumber/$totalParts ဘာသာပြန်ပြီး (${segments.length} ကြောင်း)။');
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
      throw Exception('Part $partNumber ဘာသာပြန်မရပါ: $lastError');
    } finally {
      await _cleanupTempFiles([smallClipPath]);
    }
  }

  // Smart Sync Dubbing Render: အသံကို အများဆုံး 1.15x ပဲမြန်ပြီး ဗီဒီယိုကို အလိုက်သင့်ညှိပေးမည် (0.00s Drift)
  Future<String> renderDubbingPart({
    required int partNumber,
    required double chunkStartSec,
    required double chunkDurSec,
    required List partSegments,
    required String videoPath,
    required String voice,
    required int ratePercent,
    required int pitchHz,
    required String resolution,
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
    final ffmpeg = FfmpegService();
    final tts = EdgeTtsService();
    final List<String> tempFilesToClean = [];

    try {
      final vidInfo = await ffmpeg.getVideoInfo(videoPath);
      final int srcW = vidInfo['width'] as int;
      final int srcH = vidInfo['height'] as int;

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

      final presetFast = '-preset ultrafast -crf 25 -threads 2';
      final vidConcatBuf = StringBuffer();
      final audConcatBuf = StringBuffer();
      final srtBuf = StringBuffer();

      double curSrcPos = 0.0;
      double curOutTime = 0.0;
      int clipIdx = 0;
      int srtIdx = 1;

      for (int i = 0; i < partSegments.length; i++) {
        final double relStart = (partSegments[i]['vStart'] as num).toDouble().clamp(curSrcPos, chunkDurSec);
        final double relEnd = (partSegments[i]['vEnd'] as num).toDouble().clamp(relStart + 0.3, chunkDurSec);
        final String text = (partSegments[i]['text'] ?? '').toString().trim();
        if (text.isEmpty) continue;

        final double nextStart = (i + 1 < partSegments.length)
            ? (partSegments[i + 1]['vStart'] as num).toDouble().clamp(relEnd, chunkDurSec)
            : chunkDurSec;

        onLog?.call('Part $partNumber: Smart Sync (${i + 1}/${partSegments.length}) ထုတ်ညှိနေသည်...');

        // (က) စကားမပြောခင် ကြားကွက်လပ် (1.0x ဗီဒီယို + Silence)
        if (relStart > curSrcPos + 0.05) {
          final double gapDur = relStart - curSrcPos;
          final vGapPath = '${tempDir.path}/dub_p${partNumber}_vg_${clipIdx}.mp4';
          final aGapPath = '${tempDir.path}/dub_p${partNumber}_ag_${clipIdx}.m4a';
          clipIdx++;
          tempFilesToClean.addAll([vGapPath, aGapPath]);

          final sVG = await FFmpegKit.execute(
            '-y -ss ${(chunkStartSec + curSrcPos).toStringAsFixed(3)} -t ${gapDur.toStringAsFixed(3)} -i "$videoPath" '
            '-vf "scale=$outW:$outH,fps=30" -an -c:v libx264 $presetFast -pix_fmt yuv420p "$vGapPath"',
          );
          if (ReturnCode.isSuccess(await sVG.getReturnCode())) {
            final realVG = await ffmpeg.getDuration(vGapPath);
            final usedVG = realVG > 0.03 ? realVG : gapDur;
            await FFmpegKit.execute(
              '-y -f lavfi -i anullsrc=r=24000:cl=mono -t ${usedVG.toStringAsFixed(3)} -c:a aac -b:a 64k "$aGapPath"',
            );
            vidConcatBuf.writeln("file '$vGapPath'");
            audConcatBuf.writeln("file '$aGapPath'");
            curOutTime += usedVG;
          }
          curSrcPos = relStart;
        }

        // (ခ) ဒီစာကြောင်းအတွက် TTS ထုတ်မည်
        final double segSrcEnd = relEnd.clamp(curSrcPos + 0.3, nextStart);
        final double srcDur = (segSrcEnd - curSrcPos).clamp(0.3, 30.0);

        final rawLinePath = '${tempDir.path}/dub_p${partNumber}_raw_$i.mp3';
        final dummySrtPath = '${tempDir.path}/dub_p${partNumber}_tmp_$i.srt';
        tempFilesToClean.addAll([rawLinePath, dummySrtPath]);

        await tts.synthesizeAuto(
          text: text,
          voice: voice,
          ratePercent: ratePercent,
          pitchHz: pitchHz,
          audioOutPath: rawLinePath,
          srtOutPath: dummySrtPath,
        );

        final double rawAudDur = await ffmpeg.getDuration(rawLinePath);
        final fitAudPath = '${tempDir.path}/dub_p${partNumber}_af_${clipIdx}.m4a';
        final fitVidPath = '${tempDir.path}/dub_p${partNumber}_vf_${clipIdx}.mp4';
        clipIdx++;
        tempFilesToClean.addAll([fitAudPath, fitVidPath]);

        // Smart Sync: အသံကို အများဆုံး 1.15x ပဲ မြန်ပေးမည် (အသံသဘာဝမပျက်စေရန်)
        double tempo = 1.0;
        if (rawAudDur > srcDur) {
          tempo = (rawAudDur / srcDur).clamp(1.0, 1.15);
        }

        final aFilter = tempo > 1.01
            ? 'atempo=${tempo.toStringAsFixed(4)},aresample=24000'
            : 'aresample=24000';

        await FFmpegKit.execute(
          '-y -i "$rawLinePath" -af "$aFilter" -ac 1 -ar 24000 -c:a aac -b:a 96k "$fitAudPath"',
        );

        final double fitAudDur = await ffmpeg.getDuration(fitAudPath);
        final double safeAudDur = fitAudDur > 0.1 ? fitAudDur : rawAudDur;

        // ဗီဒီယိုကို အသံအရှည်နဲ့ ကွက်တိကိုက်အောင် ညှိမည်
        if (safeAudDur >= srcDur) {
          // အသံပိုရှည်နေရင် ဗီဒီယိုကို နည်းနည်းနှေးပေးမည် (0.65x - 0.99x)
          final double vPtsMult = (safeAudDur / srcDur).clamp(1.0, 1.55);
          await FFmpegKit.execute(
            '-y -ss ${(chunkStartSec + curSrcPos).toStringAsFixed(3)} -t ${srcDur.toStringAsFixed(3)} -i "$videoPath" '
            '-vf "scale=$outW:$outH,setpts=(PTS-STARTPTS)*${vPtsMult.toStringAsFixed(6)},fps=30" '
            '-t ${safeAudDur.toStringAsFixed(3)} -an -c:v libx264 $presetFast -pix_fmt yuv420p "$fitVidPath"',
          );
          vidConcatBuf.writeln("file '$fitVidPath'");
          audConcatBuf.writeln("file '$fitAudPath'");

          final startMs = (curOutTime * 1000).round();
          final endMs = ((curOutTime + safeAudDur) * 1000).round();
          srtBuf.writeln('${srtIdx++}');
          srtBuf.writeln('${_formatSrtTime(startMs)} --> ${_formatSrtTime(endMs)}');
          srtBuf.writeln(text);
          srtBuf.writeln();
          curOutTime += safeAudDur;
        } else {
          // အသံပိုတိုနေရင် ဗီဒီယို 1.0x ပြပြီး အသံနောက်မှာ Silence နည်းနည်းဖြည့်မည်
          await FFmpegKit.execute(
            '-y -ss ${(chunkStartSec + curSrcPos).toStringAsFixed(3)} -t ${srcDur.toStringAsFixed(3)} -i "$videoPath" '
            '-vf "scale=$outW:$outH,fps=30" -an -c:v libx264 $presetFast -pix_fmt yuv420p "$fitVidPath"',
          );
          final realVDur = await ffmpeg.getDuration(fitVidPath);
          final usedVDur = realVDur > 0.1 ? realVDur : srcDur;

          vidConcatBuf.writeln("file '$fitVidPath'");
          audConcatBuf.writeln("file '$fitAudPath'");

          final startMs = (curOutTime * 1000).round();
          final endMs = ((curOutTime + safeAudDur) * 1000).round();
          srtBuf.writeln('${srtIdx++}');
          srtBuf.writeln('${_formatSrtTime(startMs)} --> ${_formatSrtTime(endMs)}');
          srtBuf.writeln(text);
          srtBuf.writeln();

          final double padSil = usedVDur - safeAudDur;
          if (padSil > 0.03) {
            final padPath = '${tempDir.path}/dub_p${partNumber}_pad_${clipIdx++}.m4a';
            tempFilesToClean.add(padPath);
            await FFmpegKit.execute(
              '-y -f lavfi -i anullsrc=r=24000:cl=mono -t ${padSil.toStringAsFixed(3)} -c:a aac -b:a 64k "$padPath"',
            );
            audConcatBuf.writeln("file '$padPath'");
          }
          curOutTime += usedVDur;
        }

        curSrcPos = segSrcEnd;
      }

      // အဆုံးပိုင်း ကျန်နေသေးရင် 1.0x ဗီဒီယို + Silence ဖြည့်မည်
      if (chunkDurSec > curSrcPos + 0.08) {
        final tailDur = chunkDurSec - curSrcPos;
        final vTailPath = '${tempDir.path}/dub_p${partNumber}_vt.mp4';
        final aTailPath = '${tempDir.path}/dub_p${partNumber}_at.m4a';
        tempFilesToClean.addAll([vTailPath, aTailPath]);

        final sVT = await FFmpegKit.execute(
          '-y -ss ${(chunkStartSec + curSrcPos).toStringAsFixed(3)} -t ${tailDur.toStringAsFixed(3)} -i "$videoPath" '
          '-vf "scale=$outW:$outH,fps=30" -an -c:v libx264 $presetFast -pix_fmt yuv420p "$vTailPath"',
        );
        if (ReturnCode.isSuccess(await sVT.getReturnCode())) {
          final realVT = await ffmpeg.getDuration(vTailPath);
          final usedVT = realVT > 0.03 ? realVT : tailDur;
          await FFmpegKit.execute(
            '-y -f lavfi -i anullsrc=r=24000:cl=mono -t ${usedVT.toStringAsFixed(3)} -c:a aac -b:a 64k "$aTailPath"',
          );
          vidConcatBuf.writeln("file '$vTailPath'");
          audConcatBuf.writeln("file '$aTailPath'");
        }
      }

      final vListFile = File('${tempDir.path}/dub_p${partNumber}_vlist.txt');
      final aListFile = File('${tempDir.path}/dub_p${partNumber}_alist.txt');
      final rawVidPath = '${tempDir.path}/dub_p${partNumber}_rawv.mp4';
      final rawAudPath = '${tempDir.path}/dub_p${partNumber}_rawa.m4a';
      final srtPath = '${tempDir.path}/dub_p${partNumber}_subs.srt';
      tempFilesToClean.addAll([vListFile.path, aListFile.path, rawVidPath, rawAudPath, srtPath]);

      await vListFile.writeAsString(vidConcatBuf.toString());
      await aListFile.writeAsString(audConcatBuf.toString());
      await File(srtPath).writeAsString(srtBuf.toString(), encoding: utf8);

      final sCV = await FFmpegKit.execute('-y -f concat -safe 0 -i "${vListFile.path}" -c copy "$rawVidPath"');
      if (!ReturnCode.isSuccess(await sCV.getReturnCode())) {
        throw Exception('Part $partNumber ဗီဒီယိုအပိုင်းများ ပေါင်းမရပါ');
      }

      final sCA = await FFmpegKit.execute('-y -f concat -safe 0 -i "${aListFile.path}" -c copy "$rawAudPath"');
      if (!ReturnCode.isSuccess(await sCA.getReturnCode())) {
        throw Exception('Part $partNumber Dubbing အသံများ ပေါင်းမရပါ');
      }

      final outputPath = '${tempDir.path}/Dubbing_Part_${partNumber}_${DateTime.now().millisecondsSinceEpoch}.mp4';
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

      if (enableSubtitles && srtBuf.isNotEmpty) {
        final fontDir = await _prepareFontDir();
        final assPath = await _convertSrtToAss(
          srtPath: srtPath,
          outW: outW,
          outH: outH,
          subY: subY,
          subScale: subScale,
          subColorAss: subColorAss,
        );
        tempFilesToClean.add(assPath);
        filterBuf.writeln('[$currentV]ass=$assPath:fontsdir=$fontDir:shaping=complex[v_out];');
        currentV = 'v_out';
      } else if (currentV == '0:v') {
        filterBuf.writeln('[0:v]null[v_out];');
        currentV = 'v_out';
      }

      String audioInputArgs = '-i "$rawAudPath"';
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

      final filterScriptPath = '${tempDir.path}/dub_p${partNumber}_filter.txt';
      tempFilesToClean.add(filterScriptPath);
      await File(filterScriptPath).writeAsString(filterBuf.toString(), encoding: utf8);

      onLog?.call('Part $partNumber: Dubbing ဗီဒီယို + မြန်မာစာတန်း ပေါင်းထုတ်နေသည်...');
      final finalCmd = '-y -i "$rawVidPath" $audioInputArgs '
          '-filter_complex_script "$filterScriptPath" '
          '-map "[$currentV]" -map "[a_out]" '
          '-c:v libx264 $presetFast -pix_fmt yuv420p '
          '-c:a aac -b:a 128k -movflags +faststart -shortest "$outputPath"';

      final finalSession = await FFmpegKit.execute(finalCmd);
      if (!ReturnCode.isSuccess(await finalSession.getReturnCode())) {
        final logs = await finalSession.getAllLogsAsString();
        throw Exception('Part $partNumber Dubbing Render မအောင်မြင်ပါ:\n$logs');
      }

      if (saveToGallery) {
        try {
          await Gal.putVideo(outputPath, album: 'Myanmar Recap');
          onLog?.call('✅ Part $partNumber (Dubbing) ကို Gallery ထဲ သိမ်းပြီးပါပြီ။');
        } catch (_) {}
      }

      return outputPath;
    } finally {
      await _cleanupTempFiles(tempFilesToClean);
      onLog?.call('🧹 Part $partNumber Temp ဖိုင်များ အလိုအလျောက် ရှင်းလင်းပြီးပါပြီ။');
    }
  }

  String _formatSrtTime(int ms) {
    final safeMs = ms < 0 ? 0 : ms;
    final h = (safeMs ~/ 3600000).toString().padLeft(2, '0');
    final m = ((safeMs % 3600000) ~/ 60000).toString().padLeft(2, '0');
    final s = ((safeMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final rem = (safeMs % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$rem';
  }

  // =========================================================================
  // MODE B: GEMINI RECAP MODE (အရင် Recap စနစ်)
  // =========================================================================

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

    final int targetMinLines = (chunkDurSec / 11).round().clamp(12, 35);
    final int targetMaxLines = (chunkDurSec / 9).round().clamp(16, 40);

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
2. Write VERY DETAILED, engaging Burmese movie recap narration covering the FULL ${chunkDurSec.toStringAsFixed(0)} seconds with $targetMinLines to $targetMaxLines scenes.
3. COPYRIGHT-SAFE SCENE SPACING: Pick the key 4-second visual moments spaced roughly 6 seconds apart (e.g., [0.0-4.0], [10.0-14.0], [20.0-24.0]) while still narrating every important plot detail smoothly.
4. CRITICAL SYNC RULE: Every [start-end] timestamp MUST match the EXACT second when that visual action/scene happens on screen.
5. Format EVERY narration line strictly as: [start-end] Burmese text
   (start and end in seconds relative to THIS clip, from 0.0 to ${chunkDurSec.toStringAsFixed(1)})
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
                    final tailList = segments.length >= 2 ? segments.sublist(segments.length - 2) : segments;
                    final tailLines = tailList.map((e) => e['text'].toString()).join('\n');

                    onLog?.call('✅ Part $partNumber/$totalParts ($model) Script ထုတ်ပြီး (${segments.length} ခန်း)။');
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
      await _cleanupTempFiles([smallClipPath]);
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
          'vEnd': e > s ? e : s + 4.0,
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
    final assPath = '${Directory.systemTemp.path}/long_subs_${DateTime.now().millisecondsSinceEpoch}.ass';

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
    final List<String> tempFilesToClean = [];

    try {
      final partScriptBuf = StringBuffer();
      for (final seg in partSegments) {
        partScriptBuf.writeln('[${seg['vStart']}-${seg['vEnd']}] ${seg['text']}');
      }

      final audioPath = '${tempDir.path}/part_${partNumber}_tts.mp3';
      final srtPath = '${tempDir.path}/part_${partNumber}_subs.srt';
      tempFilesToClean.addAll([audioPath, srtPath]);

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

      final ffmpeg = FfmpegService();
      final vidInfo = await ffmpeg.getVideoInfo(videoPath);
      final int srcW = vidInfo['width'] as int;
      final int srcH = vidInfo['height'] as int;
      final double audDur = await ffmpeg.getDuration(audioPath);

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

      double targetTotalVid = 0.0;
      double actualTotalVid = 0.0;
      double playAcc = 0.0;
      double freezeRem = 0.0;

      for (int i = 0; i < syncSegments.length; i++) {
        final double vStart = (syncSegments[i]['vStart'] as num).toDouble();
        final double vEnd = (syncSegments[i]['vEnd'] as num).toDouble();
        final double segVidDur = (vEnd - vStart) > 0.3 ? (vEnd - vStart) : 4.0;
        final double segAudDur = (syncSegments[i]['audDur'] as num).toDouble();

        targetTotalVid += segAudDur;
        double remaining = (targetTotalVid - actualTotalVid).clamp(0.15, 60.0);

        if (!enableCopyrightSafe) {
          final double ratio = (remaining / segVidDur).clamp(0.25, 4.0);
          final clipPath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';
          tempFilesToClean.add(clipPath);
          onLog?.call('Part $partNumber: အခန်း (${i + 1}/${syncSegments.length}) ဖြတ်ညှိနေသည်...');
          final cmd = '-y -ss ${vStart.toStringAsFixed(3)} -t ${segVidDur.toStringAsFixed(3)} -i "$videoPath" '
              '-vf "scale=$outW:$outH,setpts=(PTS-STARTPTS)*${ratio.toStringAsFixed(6)},fps=30" '
              '-t ${remaining.toStringAsFixed(3)} -an -c:v libx264 $presetFast -pix_fmt yuv420p "$clipPath"';
          final s = await FFmpegKit.execute(cmd);
          if (!ReturnCode.isSuccess(await s.getReturnCode())) {
            throw Exception('Part $partNumber Clip $i ဖြတ်မရပါ');
          }
          clipListBuf.writeln("file '$clipPath'");
          final realDur = await ffmpeg.getDuration(clipPath);
          actualTotalVid += (realDur > 0.05 ? realDur : remaining);
        } else {
          onLog?.call('Part $partNumber: အခန်း (${i + 1}/${syncSegments.length}) [Zero-Drift + Max 6s/3s Freeze]...');
          final double safeSpeed = videoSpeed.clamp(0.4, 1.0);
          final double ptsMult = 1.0 / safeSpeed;
          double curSrcPos = vStart;

          while (remaining > 0.08) {
            if (freezeRem > 0.08 || curSrcPos >= vEnd - 0.1) {
              final double fDur = (freezeRem > 0.08)
                  ? (remaining < freezeRem ? remaining : freezeRem)
                  : remaining;
              final int totalFrames = (fDur * 30).round().clamp(5, 600);
              final double freezeAt = curSrcPos.clamp(vStart, vEnd);
              final frameImg = '${tempDir.path}/p${partNumber}_f_$clipCounter.jpg';
              final freezePath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';
              tempFilesToClean.addAll([frameImg, freezePath]);

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
                final realDur = await ffmpeg.getDuration(freezePath);
                final used = realDur > 0.05 ? realDur : fDur;
                actualTotalVid += used;
                remaining -= used;
                if (freezeRem > 0.08) {
                  freezeRem = (freezeRem - used).clamp(0.0, freezeSec);
                }
              } else {
                remaining -= fDur;
                freezeRem = 0.0;
              }
              if (freezeRem <= 0.08) {
                playAcc = 0.0;
              }
            } else {
              final double needPlay = (playSec - playAcc).clamp(0.15, playSec);
              final double maxSrcLeft = (vEnd - curSrcPos).clamp(0.05, 60.0);
              final double maxPlayFromScene = maxSrcLeft * ptsMult;

              double playDur = remaining < needPlay ? remaining : needPlay;
              if (playDur > maxPlayFromScene) playDur = maxPlayFromScene;

              final double srcNeeded = (playDur * safeSpeed).clamp(0.05, maxSrcLeft);
              final playPath = '${tempDir.path}/p${partNumber}_c${clipCounter++}.mp4';
              tempFilesToClean.add(playPath);

              final playCmd = '-y -ss ${curSrcPos.toStringAsFixed(3)} -t ${(srcNeeded + 0.15).toStringAsFixed(3)} -i "$videoPath" '
                  '-vf "scale=$outW:$outH,setpts=(PTS-STARTPTS)*${ptsMult.toStringAsFixed(6)},fps=30" '
                  '-t ${playDur.toStringAsFixed(3)} -an -c:v libx264 $presetFast -pix_fmt yuv420p "$playPath"';

              final sPlay = await FFmpegKit.execute(playCmd);
              if (!ReturnCode.isSuccess(await sPlay.getReturnCode())) {
                throw Exception('Part $partNumber Play Clip မအောင်မြင်ပါ');
              }
              clipListBuf.writeln("file '$playPath'");

              final realDur = await ffmpeg.getDuration(playPath);
              final used = realDur > 0.05 ? realDur : playDur;
              actualTotalVid += used;
              curSrcPos += srcNeeded;
              remaining -= used;
              playAcc += used;

              if (playAcc >= playSec - 0.05) {
                freezeRem = freezeSec;
                playAcc = 0.0;
              }
            }
          }
        }
      }

      final listFile = File('${tempDir.path}/p${partNumber}_list.txt');
      tempFilesToClean.add(listFile.path);
      await listFile.writeAsString(clipListBuf.toString());

      final rawConcatPath = '${tempDir.path}/p${partNumber}_raw.mp4';
      tempFilesToClean.add(rawConcatPath);
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
        tempFilesToClean.add(assPath);
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
      tempFilesToClean.add(filterScriptPath);
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
    } finally {
      await _cleanupTempFiles(tempFilesToClean);
      onLog?.call('🧹 Part $partNumber Temp ဖိုင်များ အလိုအလျောက် ရှင်းလင်းပြီးပါပြီ။');
    }
  }

  // Part တွေအားလုံးကို YouTube ဗီဒီယိုတစ်ပုဒ်တည်း ပေါင်းမည် (-c copy)
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

    try {
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
    } finally {
      await _cleanupTempFiles([listFile.path]);
    }
  }
}
