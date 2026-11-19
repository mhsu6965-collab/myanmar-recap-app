import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

class BlurBox {
  bool enabled;
  double x; // 0.0 to 1.0
  double y; // 0.0 to 1.0
  double w; // 0.0 to 1.0
  double h; // 0.0 to 1.0

  BlurBox({
    required this.enabled,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}

class FfmpegService {
  Future<double> getDuration(String filePath) async {
    final session = await FFprobeKit.getMediaInformation(filePath);
    final info = session.getMediaInformation();
    final durStr = info?.getDuration();
    if (durStr == null) throw Exception('Media duration ဖတ်မရပါ');
    return double.parse(durStr);
  }

  Future<String> _prepareFontDir() async {
    final docDir = await getApplicationDocumentsDirectory();
    final fontDir = Directory('${docDir.path}/fonts');
    if (!await fontDir.exists()) await fontDir.create(recursive: true);

    final fontFile = File('${fontDir.path}/Pyidaungsu.ttf');
    if (!await fontFile.exists()) {
      final data = await rootBundle.load('assets/fonts/Pyidaungsu.ttf');
      await fontFile.writeAsBytes(data.buffer.asUint8List());
    }
    return fontDir.path;
  }

  Future<String> renderRecapVideo({
    required String videoPath,
    required String audioPath,
    required String srtPath,
    required List<BlurBox> blurs,
  }) async {
    final vidDur = await getDuration(videoPath);
    final audDur = await getDuration(audioPath);
    final ptsRatio = (audDur / vidDur).toStringAsFixed(4);

    final fontDir = await _prepareFontDir();
    final outDir = await getApplicationDocumentsDirectory();
    final outputPath = '${outDir.path}/recap_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // 1. Scale 720p + Audio/Video Sync
    final buffer = StringBuffer();
    buffer.write("[0:v]scale=720:-2,setpts=$ptsRatio*PTS[v0];");
    String currentLabel = "v0";
    int idx = 1;

    // 2. Blur 1 & Blur 2 ကို နေရာအတိအကျထည့်မယ်
    for (final b in blurs) {
      if (!b.enabled) continue;
      final bx = b.x.clamp(0.0, 0.95).toStringAsFixed(4);
      final by = b.y.clamp(0.0, 0.95).toStringAsFixed(4);
      final bw = b.w.clamp(0.05, 1.0 - b.x).toStringAsFixed(4);
      final bh = b.h.clamp(0.05, 1.0 - b.y).toStringAsFixed(4);

      final nextLabel = "v$idx";
      buffer.write(
        "[$currentLabel]split[m$idx][b$idx];"
        "[b$idx]crop=iw*$bw:ih*$bh:iw*$bx:ih*$by,boxblur=10:2[bl$idx];"
        "[m$idx][bl$idx]overlay=W*$bx:H*$by[$nextLabel];",
      );
      currentLabel = nextLabel;
      idx++;
    }

    // 3. မြန်မာစာတန်းထိုးထည့်မယ်
    buffer.write(
      "[$currentLabel]subtitles=$srtPath:fontsdir=$fontDir:"
      "force_style='FontName=Pyidaungsu,FontSize=20,PrimaryColour=&H00FFFFFF,"
      "OutlineColour=&H00000000,BorderStyle=1,Outline=2,Alignment=2'[v_out]",
    );

    final cmd = '-y -i "$videoPath" -i "$audioPath" '
        '-filter_complex "${buffer.toString()}" '
        '-map "[v_out]" -map 1:a '
        '-c:v libx264 -preset ultrafast -crf 28 -threads 2 '
        '-c:a aac -b:a 128k -shortest "$outputPath"';

    final session = await FFmpegKit.execute(cmd);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      throw Exception('FFmpeg Render မအောင်မြင်ပါ:\n$logs');
    }

    return outputPath;
  }
}
