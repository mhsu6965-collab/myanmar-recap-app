import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';

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
    required int blurY,
    required int blurHeight,
  }) async {
    final vidDur = await getDuration(videoPath);
    final audDur = await getDuration(audioPath);
    final ptsRatio = (audDur / vidDur).toStringAsFixed(4);

    final fontDir = await _prepareFontDir();
    final outDir = await getApplicationDocumentsDirectory();
    final outputPath = '${outDir.path}/recap_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // CPU သက်သာစေရန် scale=720:-2 နှင့် boxblur=10:2 သုံးထားပါသည်
    final filterComplex =
        "[0:v]scale=720:-2,setpts=$ptsRatio*PTS[v_sync];"
        "[v_sync]split[main][to_blur];"
        "[to_blur]crop=iw:$blurHeight:0:$blurY,boxblur=10:2[blurred];"
        "[main][blurred]overlay=0:$blurY[v_blur];"
        "[v_blur]subtitles=$srtPath:fontsdir=$fontDir:"
        "force_style='FontName=Pyidaungsu,FontSize=20,PrimaryColour=&H00FFFFFF,"
        "OutlineColour=&H00000000,BorderStyle=1,Outline=2,Alignment=2'[v_out]";

    // ဖုန်းမပူစေရန် -threads 2, -preset ultrafast, -crf 28 သုံးထားပါသည်
    final cmd = '-y -i "$videoPath" -i "$audioPath" '
        '-filter_complex "$filterComplex" '
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
