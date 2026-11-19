import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
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

  String? _videoPath;
  VideoPlayerController? _videoCtrl;

  String _voice = 'my-MM-NilarNeural';
  double _rate = 10;
  double _pitch = 0;

  // Blur 1 & Blur 2 (0.0 မှ 1.0 အတွင်း နေရာ)
  final BlurBox _blur1 = BlurBox(enabled: true, x: 0.05, y: 0.72, w: 0.90, h: 0.12);
  final BlurBox _blur2 = BlurBox(enabled: false, x: 0.05, y: 0.10, w: 0.90, h: 0.10);

  // Step Progress: 0 = မစသေး, 1 = Script, 2 = TTS, 3 = Render, 4 = ပြီးပြီ
  int _currentStep = 0;
  bool _isProcessing = false;
  String _errorMsg = '';
  String _outputPath = '';
  String _script = '';

  @override
  void dispose() {
    _videoCtrl?.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    final file = await FilePicker.pickFile(type: FileType.video);
    if (file != null && file.path != null) {
      await _videoCtrl?.dispose();
      final ctrl = VideoPlayerController.file(File(file.path!));
      await ctrl.initialize();
      setState(() {
        _videoPath = file.path;
        _videoCtrl = ctrl;
        _errorMsg = '';
        _outputPath = '';
        _currentStep = 0;
      });
    }
  }

  Future<void> _startRecap() async {
    if (_videoPath == null || _apiKeyCtrl.text.trim().isEmpty) {
      setState(() => _errorMsg = 'API Key နဲ့ ဗီဒီယိုကို အရင်ရွေးပါ');
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMsg = '';
      _outputPath = '';
      _currentStep = 1;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final audioPath = '${tempDir.path}/tts.mp3';
      final srtPath = '${tempDir.path}/subs.srt';

      // Step 1: Gemini Script
      final script = await GeminiService(_apiKeyCtrl.text.trim())
          .generateRecapScript(_videoPath!);
      setState(() {
        _script = script;
        _currentStep = 2;
      });

      // Step 2: Edge TTS
      await EdgeTtsService().synthesize(
        text: script,
        voice: _voice,
        ratePercent: _rate.toInt(),
        pitchHz: _pitch.toInt(),
        audioOutPath: audioPath,
        srtOutPath: srtPath,
      );

      // Step 3: FFmpeg Render
      setState(() => _currentStep = 3);
      final outPath = await FfmpegService().renderRecapVideo(
        videoPath: _videoPath!,
        audioPath: audioPath,
        srtPath: srtPath,
        blurs: [_blur1, _blur2],
      );

      setState(() {
        _outputPath = outPath;
        _currentStep = 4;
      });
    } catch (e) {
      setState(() => _errorMsg = e.toString());
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Widget _buildDraggableBlur(BlurBox box, String label, Color color, double maxW, double maxH) {
    if (!box.enabled) return const SizedBox.shrink();
    return Positioned(
      left: box.x * maxW,
      top: box.y * maxH,
      width: box.w * maxW,
      height: box.h * maxH,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            box.x = (box.x + details.delta.dx / maxW).clamp(0.0, 1.0 - box.w);
            box.y = (box.y + details.delta.dy / maxH).clamp(0.0, 1.0 - box.h);
          });
        },
        child: Container(
          decoration: BoxDecoration(
            color: color.withOpacity(0.35),
            border: Border.all(color: color, width: 2),
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              // ညာဘက်အောက်ထောင့် အကြီး/အသေး ဆွဲချဲ့ရန်
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      box.w = (box.w + details.delta.dx / maxW).clamp(0.1, 1.0 - box.x);
                      box.h = (box.h + details.delta.dy / maxH).clamp(0.05, 1.0 - box.y);
                    });
                  },
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    child: const Icon(Icons.open_in_full, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepTile(int stepNum, String title) {
    Widget icon;
    if (_currentStep > stepNum || _currentStep == 4) {
      icon = const Icon(Icons.check_circle, color: Colors.green);
    } else if (_currentStep == stepNum && _isProcessing) {
      icon = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5));
    } else {
      icon = const Icon(Icons.radio_button_unchecked, color: Colors.grey);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: TextStyle(fontWeight: _currentStep == stepNum ? FontWeight.bold : FontWeight.normal))),
        ],
      ),
    );
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

            // Video Preview + Draggable Blur 1 & Blur 2
            if (_videoCtrl != null && _videoCtrl!.value.isInitialized) ...[
              const SizedBox(height: 14),
              const Text('Blur အကွက်ကို လက်နဲ့ဆွဲရွှေ့ပါ (ထောင့်စက်ဝိုင်းကိုဆွဲပြီး ချဲ့ပါ)', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 6),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: AspectRatio(
                    aspectRatio: _videoCtrl!.value.aspectRatio,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return Stack(
                          children: [
                            VideoPlayer(_videoCtrl!),
                            _buildDraggableBlur(_blur1, 'Blur 1', Colors.blue, constraints.maxWidth, constraints.maxHeight),
                            _buildDraggableBlur(_blur2, 'Blur 2', Colors.orange, constraints.maxWidth, constraints.maxHeight),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(_videoCtrl!.value.isPlaying ? Icons.pause_circle : Icons.play_circle, size: 36),
                    onPressed: () {
                      setState(() {
                        _videoCtrl!.value.isPlaying ? _videoCtrl!.pause() : _videoCtrl!.play();
                      });
                    },
                  ),
                  FilterChip(
                    label: const Text('Blur 1'),
                    selected: _blur1.enabled,
                    selectedColor: Colors.blue.shade100,
                    onSelected: (v) => setState(() => _blur1.enabled = v),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Blur 2'),
                    selected: _blur2.enabled,
                    selectedColor: Colors.orange.shade100,
                    onSelected: (v) => setState(() => _blur2.enabled = v),
                  ),
                ],
              ),
            ],

            const Divider(height: 24),
            DropdownButtonFormField<String>(
              value: _voice,
              decoration: const InputDecoration(labelText: 'Edge TTS အသံ'),
              items: const [
                DropdownMenuItem(value: 'my-MM-NilarNeural', child: Text('Nilar (အမျိုးသမီး)')),
                DropdownMenuItem(value: 'my-MM-ThihaNeural', child: Text('Thiha (အမျိုးသား)')),
              ],
              onChanged: (v) => setState(() => _voice = v!),
            ),
            const SizedBox(height: 10),
            Text('Speed (Rate): ${_rate.toInt()}%'),
            Slider(value: _rate, min: -100, max: 100, divisions: 40, onChanged: (v) => setState(() => _rate = v)),
            Text('Pitch: ${_pitch.toInt()} Hz'),
            Slider(value: _pitch, min: -100, max: 100, divisions: 40, onChanged: (v) => setState(() => _pitch = v)),

            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _isProcessing ? null : _startRecap,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text(_isProcessing ? 'လုပ်ဆောင်နေပါသည်...' : '🚀 Recap ဗီဒီယို စတင်ထုတ်မယ်'),
            ),

            // Step-by-Step Progress Card
            if (_currentStep > 0) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('လုပ်ဆောင်နေသည့် အဆင့်များ', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      _buildStepTile(1, '၁။ Gemini API ဖြင့် မြန်မာ Script ထုတ်ခြင်း'),
                      _buildStepTile(2, '၂။ Microsoft Edge TTS ဖြင့် အသံနှင့် စာတန်းထိုး ထုတ်ခြင်း'),
                      _buildStepTile(3, '၃။ Blur နှင့် မြန်မာစာတန်း ပေါင်းထုတ်ခြင်း (CPU)'),
                      _buildStepTile(4, '၄။ ဗီဒီယို အပြီးသတ် သိမ်းဆည်းခြင်း'),
                    ],
                  ),
                ),
              ),
            ],

            if (_outputPath.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('✅ ပြီးပါပြီ! သိမ်းထားတဲ့နေရာ:\n$_outputPath', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
            ],
            if (_errorMsg.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('❌ Error: $_errorMsg', style: const TextStyle(color: Colors.red)),
            ],
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
