import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'services/gemini_service.dart';
import 'services/edge_tts_service.dart';
import 'services/ffmpeg_service.dart';

void main() => runApp(const MaterialApp(home: RecapHomePage(), debugShowCheckedModeBanner: false));

class RecapHomePage extends StatefulWidget {
  const RecapHomePage({super.key});
  @override
  State<RecapHomePage> createState() => _RecapHomePageState();
}

class _RecapHomePageState extends State<RecapHomePage> {
  final _apiKeyCtrl = TextEditingController();
  final _blurYCtrl = TextEditingController(text: '550');
  final _blurHCtrl = TextEditingController(text: '100');

  String? _videoPath;
  String _voice = 'my-MM-NilarNeural';
  double _rate = 10;
  double _pitch = 0;
  String _status = 'အသင့်ဖြစ်ပါပြီ';
  String _script = '';
  bool _isProcessing = false;

  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null && result.files.single.path != null) {
      setState(() => _videoPath = result.files.single.path);
    }
  }

  Future<void> _startRecap() async {
    if (_videoPath == null || _apiKeyCtrl.text.isEmpty) {
      setState(() => _status = 'API Key နဲ့ ဗီဒီယိုကို အရင်ရွေးပါ');
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = '၁။ Gemini API နဲ့ မြန်မာ Script ထုတ်နေပါတယ်...';
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final audioPath = '${tempDir.path}/tts.mp3';
      final srtPath = '${tempDir.path}/subs.srt';

      final script = await GeminiService(_apiKeyCtrl.text.trim())
          .generateRecapScript(_videoPath!);
      setState(() {
        _script = script;
        _status = '၂။ Microsoft Edge TTS နဲ့ အသံထုတ်နေပါတယ်...';
      });

      await EdgeTtsService().synthesize(
        text: script,
        voice: _voice,
        ratePercent: _rate.toInt(),
        pitchHz: _pitch.toInt(),
        audioOutPath: audioPath,
        srtOutPath: srtPath,
      );

      setState(() => _status = '၃။ ဖုန်း CPU နဲ့ ဗီဒီယိုပေါင်းထုတ်နေပါတယ်...');
      final outPath = await FfmpegService().renderRecapVideo(
        videoPath: _videoPath!,
        audioPath: audioPath,
        srtPath: srtPath,
        blurY: int.tryParse(_blurYCtrl.text) ?? 550,
        blurHeight: int.tryParse(_blurHCtrl.text) ?? 100,
      );

      setState(() => _status = '✅ ပြီးပါပြီ! သိမ်းထားတဲ့နေရာ:\n$outPath');
    } catch (e) {
      setState(() => _status = '❌ Error: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Myanmar Recap Tool')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _apiKeyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Google Gemini API Key',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _pickVideo,
              icon: const Icon(Icons.video_library),
              label: Text(_videoPath == null ? 'Gallery မှ ဗီဒီယိုရွေးပါ' : 'ရွေးပြီး: ${_videoPath!.split('/').last}'),
            ),
            const Divider(height: 28),
            DropdownButtonFormField<String>(
              value: _voice,
              decoration: const InputDecoration(labelText: 'Edge TTS အသံ'),
              items: const [
                DropdownMenuItem(value: 'my-MM-NilarNeural', child: Text('Nilar (အမျိုးသမီး)')),
                DropdownMenuItem(value: 'my-MM-ThihaNeural', child: Text('Thiha (အမျိုးသား)')),
              ],
              onChanged: (v) => setState(() => _voice = v!),
            ),
            const SizedBox(height: 12),
            Text('Speed (Rate): ${_rate.toInt()}%'),
            Slider(value: _rate, min: -100, max: 100, divisions: 40, onChanged: (v) => setState(() => _rate = v)),
            Text('Pitch: ${_pitch.toInt()} Hz'),
            Slider(value: _pitch, min: -100, max: 100, divisions: 40, onChanged: (v) => setState(() => _pitch = v)),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _blurYCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Blur Y (px)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _blurHCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Blur Height (px)'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isProcessing ? null : _startRecap,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _isProcessing
                  ? const CircularProgressIndicator()
                  : const Text('🚀 Recap ဗီဒီယို စတင်ထုတ်မယ်'),
            ),
            const SizedBox(height: 16),
            Text(_status, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (_script.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.grey.shade200,
                child: Text(_script),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
