import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

class BlurBox {
  bool enabled;
  double x;
  double y;
  double w;
  double h;

  BlurBox({
    required this.enabled,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}

class FfmpegService {
  Future getVideoInfo(String filePath) async {
    final session = await FFprobeKit.getMediaInformation(filePath);
    final info = session.getMediaInformation();
    final durStr = info?.getDuration();
    if (durStr == null) throw Exception('Media duration ဖတ်မရပါ');

    int width = 720;
    int height = 1280;
    for (final stream in info?.getStreams() ?? []) {
      if (stream.getType() == 'video') {
        width = stream.getWidth() ?? 720;
        height = stream.getHeight() ?? 1280;
        break;
      }
    }
    return {'duration': double.parse(durStr), 'width': width, 'height': height};
  }

  Future<double> getDuration(String filePath) async {
    final session = await FFprobeKit.getMediaInformation(filePath);
    final durStr = session.getMediaInformation()?.getDuration();
    if (durStr == null) throw Exception('Audio duration ဖတ်မရပါ');
    return double.parse(durStr);
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
    final assPath = '${Directory.systemTemp.path}/subs_styled.ass';

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

  Future<String> renderRecapVideo({
    required String videoPath,
    required String audioPath,
    required String srtPath,
    required List<BlurBox> blurs,
    required double subY,
    double subScale = 1.0,
    String subColorAss = '&H00FFFFFF',
    String resolution = '720p',
    List? syncSegments,
    Function(String)? onLog,
  }) async {
    final vidInfo = await getVideoInfo(videoPath);
    final double vidDur = vidInfo['duration'] as double;
    final int srcW = vidInfo['width'] as int;
    final int srcH = vidInfo['height'] as int;
    final double audDur = await getDuration(audioPath);

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

    final fontDir = await _prepareFontDir();
    final assPath = await _convertSrtToAss(
      srtPath: srtPath,
      outW: outW,
      outH: outH,
      subY: subY,
      subScale: subScale,
      subColorAss: subColorAss,
    );

    final outDir = Directory('/storage/emulated/0/Download');
    final saveFolder = await outDir.exists() ? outDir.path : Directory.systemTemp.path;
    final outputPath = '$saveFolder/recap_${resolution}_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final buffer = StringBuffer();

    // အပိုင်းလိုက် Sync Data ပါလာရင် အခန်းတိုင်းကို TTS အသံအချိန်အတိုင်း ရုပ်မြန်/နှေး ချိန်ပြီး ပြန်ဆက်မည်
    if (syncSegments != null && syncSegments.isNotEmpty) {
      final int n = syncSegments.length;
      onLog?.call('FFmpeg ($resolution): အပိုင်း $n ခုလုံးကို TTS အသံအတိုင်း အပိုင်းလိုက် ရုပ်မြန်/နှေး ချိန်ညှိနေသည်...');

      final splitLabels = List.generate(n, (i) => '[in$i]').join();
      buffer.writeln('[0:v]split=$n$splitLabels;');

      final concatInputs = StringBuffer();
      for (int i = 0; i < n; i++) {
        final double rawStart = (syncSegments[i]['vStart'] as num).toDouble();
        final double vStart = (i == 0) ? 0.0 : rawStart.clamp(0.0, vidDur - 0.1);
        final double vEnd = (i == n - 1)
            ? vidDur
            : (syncSegments[i + 1]['vStart'] as num).toDouble().clamp(vStart + 0.1, vidDur);
        final double segVidDur = (vEnd - vStart) > 0.1 ? (vEnd - vStart) : 0.1;
        final double segAudDur = (syncSegments[i]['audDur'] as num).toDouble();
        final double ratio = (segAudDur / segVidDur).clamp(0.25, 4.0);

        buffer.writeln(
          '[in$i]trim=start=${vStart.toStringAsFixed(3)}:end=${vEnd.toStringAsFixed(3)},'
          'setpts=(PTS-STARTPTS)*${ratio.toStringAsFixed(6)}[seg$i];',
        );
        concatInputs.write('[seg$i]');
      }

      buffer.writeln('${concatInputs.toString()}concat=n=$n:v=1:a=0,scale=$outW:$outH,fps=30[v0];');
    } else {
      final double ptsRatio = audDur / vidDur;
      onLog?.call('FFmpeg ($resolution): ${outW}x$outH | မူရင်း ${vidDur.toStringAsFixed(1)}s → အသံ ${audDur.toStringAsFixed(1)}s');
      buffer.writeln('[0:v]scale=$outW:$outH,setpts=(PTS-STARTPTS)*${ptsRatio.toStringAsFixed(6)},fps=30[v0];');
    }

    String currentLabel = 'v0';
    int idx = 1;
    for (final b in blurs) {
      if (!b.enabled) continue;
      final bx = b.x.clamp(0.0, 0.95).toStringAsFixed(4);
      final by = b.y.clamp(0.0, 0.95).toStringAsFixed(4);
      final bw = b.w.clamp(0.05, 1.0 - b.x).toStringAsFixed(4);
      final bh = b.h.clamp(0.05, 1.0 - b.y).toStringAsFixed(4);

      final nextLabel = 'v$idx';
      buffer.writeln(
        '[$currentLabel]split[m$idx][b$idx];'
        '[b$idx]crop=iw*$bw:ih*$bh:iw*$bx:ih*$by,boxblur=10:2[bl$idx];'
        '[m$idx][bl$idx]overlay=W*$bx:H*$by[$nextLabel];',
      );
      currentLabel = nextLabel;
      idx++;
    }

    buffer.writeln('[$currentLabel]ass=$assPath:fontsdir=$fontDir:shaping=complex[v_out];');
    buffer.write('[1:a]aresample=async=1:first_pts=0[a_out]');

    // Filter ရှည်ရင် Command Error မတက်အောင် ဖိုင်ထဲရေးပြီး -filter_complex_script နဲ့ ခေါ်မည်
    final filterScriptPath = '${Directory.systemTemp.path}/ffmpeg_filter.txt';
    await File(filterScriptPath).writeAsString(buffer.toString(), encoding: utf8);

    final presetArgs = resolution == '1080p'
        ? '-preset veryfast -crf 23 -threads 4'
        : '-preset ultrafast -crf 26 -threads 2';

    final cmd = '-y -i "$videoPath" -i "$audioPath" '
        '-filter_complex_script "$filterScriptPath" '
        '-map "[v_out]" -map "[a_out]" '
        '-c:v libx264 $presetArgs -pix_fmt yuv420p '
        '-c:a aac -b:a 128k -movflags +faststart -t ${audDur.toStringAsFixed(3)} "$outputPath"';

    final session = await FFmpegKit.execute(cmd);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      throw Exception('FFmpeg Render မအောင်မြင်ပါ:\n$logs');
    }

    return outputPath;
  }
}
