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

    final isPortrait = outH >= outW;
    final baseFontSize = isPortrait ? (outW * 0.044) : (outH * 0.050);
    final fontSize = (baseFontSize * subScale).round().clamp(16, 140);
    final marginLR = (outW * 0.06).round();
    final marginV = ((1.0 - subY).clamp(0.04, 0.90) * outH).round();
    final outline = (outW * 0.0035 * subScale).round().clamp(2, 6);

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
    ass.writeln('Style: Default,Pyidaungsu,$fontSize,$subColorAss,&H000000FF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,$outline,1,2,$marginLR,$marginLR,$marginV,1');
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
      ass.writeln('Dialogue: 0,${_formatAssTime(startMs)},${_formatAssTime(endMs)},Default,,0,0,0,,$text');
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

    // အသံကို မူရင်းအတိုင်း (1.0x) ထားပြီး ဗီဒီယိုရုပ်ကို အသံအချိန်အတိအကျနဲ့ ကိုက်အောင် မြန်/နှေး ချိန်မည်
    final double ptsRatio = audDur / vidDur;
    final double videoSpeed = vidDur / audDur;

    onLog?.call(
      'FFmpeg ($resolution): ${outW}x$outH | ဗီဒီယိုအမြန်နှုန်း ${videoSpeed.toStringAsFixed(2)}x (မူရင်း ${vidDur.toStringAsFixed(1)}s → အသံ ${audDur.toStringAsFixed(1)}s)',
    );

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

    // setpts ကို fps=30 ရှေ့ထားမှ Frame Rate မလွဲဘဲ ရုပ်နဲ့အသံ အတိအကျ ကိုက်မည်
    final buffer = StringBuffer();
    buffer.write('[0:v]scale=$outW:$outH,setpts=${ptsRatio.toStringAsFixed(6)}*PTS,fps=30[v0];');
    String currentLabel = 'v0';
    int idx = 1;

    for (final b in blurs) {
      if (!b.enabled) continue;
      final bx = b.x.clamp(0.0, 0.95).toStringAsFixed(4);
      final by = b.y.clamp(0.0, 0.95).toStringAsFixed(4);
      final bw = b.w.clamp(0.05, 1.0 - b.x).toStringAsFixed(4);
      final bh = b.h.clamp(0.05, 1.0 - b.y).toStringAsFixed(4);

      final nextLabel = 'v$idx';
      buffer.write(
        '[$currentLabel]split[m$idx][b$idx];'
        '[b$idx]crop=iw*$bw:ih*$bh:iw*$bx:ih*$by,boxblur=10:2[bl$idx];'
        '[m$idx][bl$idx]overlay=W*$bx:H*$by[$nextLabel];',
      );
      currentLabel = nextLabel;
      idx++;
    }

    buffer.write('[$currentLabel]ass=$assPath:fontsdir=$fontDir:shaping=complex[v_out];');
    buffer.write('[1:a]aresample=async=1:first_pts=0[a_out]');

    final presetArgs = resolution == '1080p'
        ? '-preset veryfast -crf 23 -threads 4'
        : '-preset ultrafast -crf 26 -threads 2';

    final cmd = '-y -i "$videoPath" -i "$audioPath" '
        '-filter_complex "${buffer.toString()}" '
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
