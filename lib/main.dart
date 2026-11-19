import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'services/gemini_service.dart';
import 'services/groq_service.dart';
import 'services/edge_tts_service.dart';
import 'services/ffmpeg_service.dart';

void main() => runApp(const MaterialApp(home: RecapHomePage(), debugShowCheckedModeBanner: false));

class RecapHomePage extends StatefulWidget {
  const RecapHomePage({super.key});
  @override
  State<RecapHomePage> createState() => _RecapHomePageState();
}

class _RecapHomePageState extends State<RecapHomePage> {
  final _groqKeyCtrl = TextEditingController();
  final _geminiKeysCtrl = TextEditingController();
  String _apiProvider = 'Hybrid';

  String? _videoPath;
  VideoPlayerController? _videoCtrl;

  String _voice = 'my-MM-NilarNeural';
  double _rate = 10;
  double _pitch = 0;

  final BlurBox _blur1 = BlurBox(enabled: true, x: 0.05, y: 0.72, w: 0.90, h: 0.12);
  final BlurBox _blur2 = BlurBox(enabled: false, x: 0.05, y: 0.10, w: 0.90, h: 0.10);
  double _subY = 0.85;

  int _currentStep = 0;
  bool _isProcessing = false;
  String _errorMsg = '';
  String _outputPath = '';
  String _script = '';
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadSavedKeys();
  }

  void _addLog(String msg) {
    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logs.add('[$time] $msg');
    });
  }

  File _getKeysFile() {
    final parentDir = Directory.systemTemp.parent;
    return File('${parentDir.path}/recap_saved_keys.json');
  }

  Future<void> _loadSavedKeys() async {
    try {
      final file = _getKeysFile();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        setState(() {
          _groqKeyCtrl.text = data['groq'] ?? '';
          _geminiKeysCtrl.text = data['gemini'] ?? '';
        });
      }
    } catch (_) {}
  }

  Future<void> _saveKeys() async {
    try {
      final file = _getKeysFile();
      await file.writeAsString(jsonEncode({
        'groq': _groqKeyCtrl.text.trim(),
        'gemini': _geminiKeysCtrl.text.trim(),
      }));
    } catch (_) {}
  }

  List<String> _parseGeminiKeys() {
    return _geminiKeysCtrl.text
        .split(RegExp(r'[\n,]+'))
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
  }

  @override
  void dispose() {
    _videoCtrl?.dispose();
    _groqKeyCtrl.dispose();
    _geminiKeysCtrl.dispose();
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
        _logs.clear();
      });
    }
  }

  Future<void> _startRecap() async {
    await _saveKeys();
    final geminiKeys = _parseGeminiKeys();

    if (_videoPath == null) {
      setState(() => _errorMsg = 'ဗီဒီယိုကို အရင်ရွေးပါ');
      return;
    }
    if ((_apiProvider == 'Hybrid' || _apiProvider == 'Groq') && _groqKeyCtrl.text.trim().isEmpty) {
      setState(() => _errorMsg = 'Groq API Key ထည့်ပါ');
      return;
    }
    if ((_apiProvider == 'Hybrid' || _apiProvider == 'Gemini') && geminiKeys.isEmpty) {
      setState(() => _errorMsg = 'Gemini API Key အနည်းဆုံး ၁ ခု ထည့်ပါ');
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMsg = '';
      _outputPath = '';
      _logs.clear();
      _currentStep = 1;
    });

    try {
      final tempDir = Directory.systemTemp;
      final audioPath = '${tempDir.path}/tts.mp3';
      final srtPath = '${tempDir.path}/subs.srt';

      String script;
      if (_apiProvider == 'Hybrid') {
        _addLog('Groq: ဗီဒီယိုမှ အသံခွဲထုတ်ပြီး Whisper ဖြင့် နားထောင်နေသည်...');
        final transcript = await GroqService(_groqKeyCtrl.text.trim())
            .transcribeAudio(_videoPath!);
        _addLog('Groq: အသံဖတ်ပြီးပါပြီ (စာလုံးရေ ${transcript.length})။');

        setState(() => _currentStep = 2);
        script = await GeminiService(geminiKeys)
            .translateToMyanmarRecap(transcript, onLog: _addLog);
      } else if (_apiProvider == 'Gemini') {
        script = await GeminiService(geminiKeys)
            .generateRecapScript(_videoPath!, onLog: _addLog);
        setState(() => _currentStep = 2);
      } else {
        _addLog('Groq: အသံနားထောင်ပြီး ဘာသာပြန်နေသည်...');
        script = await GroqService(_groqKeyCtrl.text.trim())
            .generateRecapScript(_videoPath!);
        setState(() => _currentStep = 2);
      }

      setState(() {
        _script = script;
        _currentStep = 3;
      });

      await EdgeTtsService().synthesize(
        text: script,
        voice: _voice,
        ratePercent: _rate.toInt(),
        pitchHz: _pitch.toInt(),
        audioOutPath: audioPath,
        srtOutPath: srtPath,
        onLog: _addLog,
      );

      setState(() => _currentStep = 4);
      _addLog('FFmpeg: ဖုန်း CPU ဖြင့် Blur, မြန်မာစာတန်း နှင့် ရုပ်/အသံ ချိန်ညှိပေါင်းထုတ်နေသည်...');
      final outPath = await FfmpegService().renderRecapVideo(
        videoPath: _videoPath!,
        audioPath: audioPath,
        srtPath: srtPath,
        blurs: [_blur1, _blur2],
        subY: _subY,
      );

      _addLog('ပြီးစီးပါပြီ! ဖိုင်သိမ်းပြီး: $outPath');
      setState(() {
        _outputPath = outPath;
        _currentStep = 5;
      });
    } catch (e) {
      _addLog('❌ Error: $e');
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
                child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
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

  Widget _buildDraggableSubtitle(double maxW, double maxH) {
    return Positioned(
      left: maxW * 0.05,
      top: (_subY * maxH) - 16,
      width: maxW * 0.90,
      height: 32,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          setState(() {
            _subY = (_subY + details.delta.dy / maxH).clamp(0.08, 0.95);
          });
        },
        child: Container(
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.5),
            border: Border.all(color: Colors.greenAccent, width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: const Text(
            '↕ မြန်မာစာတန်းထိုးနေရာ',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildStepTile(int stepNum, String title) {
    Widget icon;
    if (_currentStep > stepNum || _currentStep == 5) {
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
            DropdownButtonFormField<String>(
              value: _apiProvider,
              decoration: const InputDecoration(
                labelText: 'Script ယူမည့် စနစ်ရွေးပါ',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'Hybrid', child: Text('Hybrid (Groq နားထောင် + Gemini ဘာသာပြန်)')),
                DropdownMenuItem(value: 'Gemini', child: Text('Google Gemini တစ်ခုတည်း')),
                DropdownMenuItem(value: 'Groq', child: Text('Groq API တစ်ခုတည်း')),
              ],
              onChanged: (v) => setState(() => _apiProvider = v!),
            ),
            if (_apiProvider == 'Hybrid' || _apiProvider == 'Groq') ...[
              const SizedBox(height: 10),
              TextField(
                controller: _groqKeyCtrl,
                onChanged: (_) => _saveKeys(),
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Groq API Key (အလိုအလျောက်သိမ်းမည်)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            if (_apiProvider == 'Hybrid' || _apiProvider == 'Gemini') ...[
              const SizedBox(height: 10),
              TextField(
                controller: _geminiKeysCtrl,
                onChanged: (_) => _saveKeys(),
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Gemini API Keys (၂-၃ ခု တစ်ကြောင်းတစ်ခုစီထည့်ပါ)',
                  hintText: 'AIzaSy...\nAIzaSy...\nAIzaSy...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _pickVideo,
              icon: const Icon(Icons.video_library),
              label: Text(_videoPath == null ? 'Gallery မှ ဗီဒီယိုရွေးပါ' : 'ရွေးပြီး: ${_videoPath!.split('/').last}'),
            ),

            if (_videoCtrl != null && _videoCtrl!.value.isInitialized) ...[
              const SizedBox(height: 14),
              const Text('Blur (အပြာ/လိမ္မော်) နဲ့ မြန်မာစာတန်း (အစိမ်း) ကို လက်နဲ့ဆွဲရွှေ့ပါ', style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                            _buildDraggableSubtitle(constraints.maxWidth, constraints.maxHeight),
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
                      _buildStepTile(1, '၁။ Groq Whisper ဖြင့် အသံနားထောင်ခြင်း'),
                      _buildStepTile(2, '၂။ Gemini ဖြင့် မြန်မာတိုက်ရိုက်ဘာသာပြန်ခြင်း'),
                      _buildStepTile(3, '၃။ Microsoft Edge TTS ဖြင့် အသံနှင့် စာတန်းထိုး ထုတ်ခြင်း'),
                      _buildStepTile(4, '၄။ Blur, စာတန်း နှင့် ရုပ်/အသံ ချိန်ညှိပေါင်းထုတ်ခြင်း (CPU)'),
                      _buildStepTile(5, '၅။ ဗီဒီယို အပြီးသတ် သိမ်းဆည်းခြင်း'),
                    ],
                  ),
                ),
              ),
            ],

            // Live Task Log Box
            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('📋 Live Log (လုပ်ဆောင်နေပုံ)', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 6),
                    ..._logs.map((l) => Text(l, style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'))),
                  ],
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
