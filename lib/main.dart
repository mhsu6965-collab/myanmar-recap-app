import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'services/gemini_service.dart';
import 'services/groq_service.dart';
import 'services/edge_tts_service.dart';
import 'services/ffmpeg_service.dart';

void main() => runApp(const RecapApp());

class RecapApp extends StatelessWidget {
  const RecapApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E1016),
        cardColor: const Color(0xFF181B24),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF7C4DFF),
          secondary: Color(0xFF00E5FF),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF11131A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2A2E3D)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2A2E3D)),
          ),
        ),
      ),
      home: const RecapHomePage(),
    );
  }
}

class RecapHomePage extends StatefulWidget {
  const RecapHomePage({super.key});
  @override
  State<RecapHomePage> createState() => _RecapHomePageState();
}

class _RecapHomePageState extends State<RecapHomePage> {
  final _groqKeyCtrl = TextEditingController();
  final _geminiKeysCtrl = TextEditingController();
  final _manualScriptCtrl = TextEditingController();

  String _apiProvider = 'Manual';
  String _resolution = '720p';

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
  bool _isTranscribing = false;
  String _errorMsg = '';
  String _outputPath = '';
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadSavedKeys();
  }

  void _addLog(String msg) {
    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() => _logs.add('[$time] $msg'));
  }

  File _getKeysFile() => File('${Directory.systemTemp.parent.path}/recap_saved_keys.json');

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
      await _getKeysFile().writeAsString(jsonEncode({
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
    _manualScriptCtrl.dispose();
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

  void _openSavedVideoPlayer() {
    if (_outputPath.isEmpty || !File(_outputPath).existsSync()) return;
    _videoCtrl?.pause();
    showDialog(
      context: context,
      builder: (_) => _SavedVideoPlayerDialog(videoPath: _outputPath),
    );
  }

  Future<void> _extractTranscriptOnly() async {
    await _saveKeys();
    if (_videoPath == null) {
      setState(() => _errorMsg = 'ဗီဒီယိုကို အရင်ရွေးပါ');
      return;
    }
    if (_groqKeyCtrl.text.trim().isEmpty) {
      setState(() => _errorMsg = 'Groq API Key ထည့်ပါ');
      return;
    }

    setState(() {
      _isTranscribing = true;
      _errorMsg = '';
      _logs.clear();
      _currentStep = 1;
    });

    try {
      _addLog('Groq: ဗီဒီယိုမှ အသံခွဲထုတ်ပြီး Whisper ဖြင့် နားထောင်နေသည်...');
      final transcript = await GroqService(_groqKeyCtrl.text.trim()).transcribeAudio(_videoPath!);
      _addLog('Groq: Script ထုတ်ပြီးပါပြီ (စာလုံးရေ ${transcript.length})။');
      setState(() {
        _manualScriptCtrl.text = transcript;
        _currentStep = 2;
      });
    } catch (e) {
      _addLog('❌ Error: $e');
      setState(() => _errorMsg = e.toString());
    } finally {
      setState(() => _isTranscribing = false);
    }
  }

  Future<void> _startRecap() async {
    await _saveKeys();
    final geminiKeys = _parseGeminiKeys();

    if (_videoPath == null) {
      setState(() => _errorMsg = 'ဗီဒီယိုကို အရင်ရွေးပါ');
      return;
    }

    if (_apiProvider == 'Manual') {
      if (_manualScriptCtrl.text.trim().isEmpty) {
        setState(() => _errorMsg = 'ဘာသာပြန်ထားတဲ့ မြန်မာစာသားကို အကွက်ထဲ အရင် Paste ထည့်ပါ');
        return;
      }
    } else {
      if (_apiProvider == 'Hybrid' && _groqKeyCtrl.text.trim().isEmpty) {
        setState(() => _errorMsg = 'Groq API Key ထည့်ပါ');
        return;
      }
      if ((_apiProvider == 'Hybrid' || _apiProvider == 'Gemini') && geminiKeys.isEmpty) {
        setState(() => _errorMsg = 'Gemini API Key အနည်းဆုံး ၁ ခု ထည့်ပါ');
        return;
      }
    }

    setState(() {
      _isProcessing = true;
      _errorMsg = '';
      _outputPath = '';
      _logs.clear();
      _currentStep = _apiProvider == 'Manual' ? 3 : 1;
    });

    try {
      final tempDir = Directory.systemTemp;
      final audioPath = '${tempDir.path}/tts.mp3';
      final srtPath = '${tempDir.path}/subs.srt';

      String script;
      if (_apiProvider == 'Manual') {
        script = _manualScriptCtrl.text.trim();
        _addLog('Manual: မြန်မာစာသား (စာလုံးရေ ${script.length}) ဖြင့် TTS စတင်ထုတ်နေသည်...');
      } else if (_apiProvider == 'Hybrid') {
        _addLog('Groq: အသံခွဲထုတ်ပြီး Whisper ဖြင့် နားထောင်နေသည်...');
        final transcript = await GroqService(_groqKeyCtrl.text.trim()).transcribeAudio(_videoPath!);
        _addLog('Groq: အသံဖတ်ပြီးပါပြီ (စာလုံးရေ ${transcript.length})။');

        setState(() => _currentStep = 2);
        script = await GeminiService(geminiKeys).translateToMyanmarRecap(transcript, onLog: _addLog);
      } else {
        script = await GeminiService(geminiKeys).generateRecapScript(_videoPath!, onLog: _addLog);
        setState(() => _currentStep = 2);
      }

      setState(() => _currentStep = 3);

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
      final outPath = await FfmpegService().renderRecapVideo(
        videoPath: _videoPath!,
        audioPath: audioPath,
        srtPath: srtPath,
        blurs: [_blur1, _blur2],
        subY: _subY,
        resolution: _resolution,
        onLog: _addLog,
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

  Widget _sectionCard({required String title, required IconData icon, required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF181B24),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF262A38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF00E5FF)),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _buildDraggableBlur(BlurBox box, String label, Color color, double maxW, double maxH) {
    if (!box.enabled) return const SizedBox.shrink();
    return Positioned(
      left: box.x * maxW,
      top: box.y * maxH,
      width: box.w * maxW,
      height: box.h * maxH,
      child: GestureDetector(
        onPanUpdate: (d) {
          setState(() {
            box.x = (box.x + d.delta.dx / maxW).clamp(0.0, 1.0 - box.w);
            box.y = (box.y + d.delta.dy / maxH).clamp(0.0, 1.0 - box.h);
          });
        },
        child: Container(
          decoration: BoxDecoration(
            color: color.withOpacity(0.32),
            border: Border.all(color: color, width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(
            children: [
              Center(child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      box.w = (box.w + d.delta.dx / maxW).clamp(0.1, 1.0 - box.x);
                      box.h = (box.h + d.delta.dy / maxH).clamp(0.05, 1.0 - box.y);
                    });
                  },
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    child: const Icon(Icons.open_in_full, size: 13, color: Colors.white),
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
        onVerticalDragUpdate: (d) => setState(() => _subY = (_subY + d.delta.dy / maxH).clamp(0.08, 0.95)),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.55),
            border: Border.all(color: Colors.greenAccent, width: 1.5),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: const Text('↕ မြန်မာစာတန်း (၂ ကြောင်း)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
        ),
      ),
    );
  }

  Widget _buildStepTile(int stepNum, String title) {
    Widget icon;
    if (_currentStep > stepNum || _currentStep == 5) {
      icon = const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20);
    } else if (_currentStep == stepNum && (_isProcessing || _isTranscribing)) {
      icon = const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Color(0xFF00E5FF)));
    } else {
      icon = const Icon(Icons.radio_button_unchecked, color: Colors.white30, size: 20);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                color: _currentStep >= stepNum ? Colors.white : Colors.white54,
                fontWeight: _currentStep == stepNum ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF141720),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text('Myanmar Recap Studio', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionCard(
              title: 'API & Script Settings',
              icon: Icons.key_rounded,
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    value: _apiProvider,
                    decoration: const InputDecoration(labelText: 'Script စနစ်ရွေးပါ'),
                    items: const [
                      DropdownMenuItem(value: 'Manual', child: Text('Manual (Groq နားထောင် → ကိုယ်တိုင်ဘာသာပြန်)')),
                      DropdownMenuItem(value: 'Hybrid', child: Text('Hybrid (Groq နားထောင် + Gemini ဘာသာပြန်)')),
                      DropdownMenuItem(value: 'Gemini', child: Text('Google Gemini တစ်ခုတည်း')),
                    ],
                    onChanged: (v) => setState(() => _apiProvider = v!),
                  ),
                  if (_apiProvider == 'Manual' || _apiProvider == 'Hybrid') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _groqKeyCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Groq API Key (gsk_...)'),
                    ),
                  ],
                  if (_apiProvider == 'Hybrid' || _apiProvider == 'Gemini') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _geminiKeysCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Gemini API Keys (၂-၃ ခု တစ်ကြောင်းတစ်ခုစီ)',
                        hintText: 'AIzaSy...\nAIzaSy...',
                      ),
                    ),
                  ],
                ],
              ),
            ),

            _sectionCard(
              title: 'Video & Blur Editor',
              icon: Icons.movie_edit,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: (_isProcessing || _isTranscribing) ? null : _pickVideo,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: Color(0xFF7C4DFF)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.video_library, color: Color(0xFF00E5FF)),
                    label: Text(
                      _videoPath == null ? 'Gallery မှ ဗီဒီယိုရွေးပါ' : 'ရွေးပြီး: ${_videoPath!.split('/').last}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _resolution,
                    decoration: const InputDecoration(labelText: 'Export Resolution (CPU အလိုက်ရွေးပါ)'),
                    items: const [
                      DropdownMenuItem(value: '720p', child: Text('720p HD (CPU သက်သာ / ပိုမြန်)')),
                      DropdownMenuItem(value: '1080p', child: Text('1080p Full HD (ကြည်လင် / CPU ပိုသုံး)')),
                    ],
                    onChanged: (v) => setState(() => _resolution = v!),
                  ),
                  if (_videoCtrl != null && _videoCtrl!.value.isInitialized) ...[
                    const SizedBox(height: 12),
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 350),
                          child: AspectRatio(
                            aspectRatio: _videoCtrl!.value.aspectRatio,
                            child: LayoutBuilder(
                              builder: (context, c) => Stack(
                                children: [
                                  VideoPlayer(_videoCtrl!),
                                  _buildDraggableBlur(_blur1, 'Blur 1', Colors.blueAccent, c.maxWidth, c.maxHeight),
                                  _buildDraggableBlur(_blur2, 'Blur 2', Colors.orangeAccent, c.maxWidth, c.maxHeight),
                                  _buildDraggableSubtitle(c.maxWidth, c.maxHeight),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(_videoCtrl!.value.isPlaying ? Icons.pause_circle : Icons.play_circle, size: 36, color: const Color(0xFF00E5FF)),
                          onPressed: () => setState(() => _videoCtrl!.value.isPlaying ? _videoCtrl!.pause() : _videoCtrl!.play()),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('Blur 1'),
                          selected: _blur1.enabled,
                          selectedColor: Colors.blueAccent.withOpacity(0.4),
                          onSelected: (v) => setState(() => _blur1.enabled = v),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('Blur 2'),
                          selected: _blur2.enabled,
                          selectedColor: Colors.orangeAccent.withOpacity(0.4),
                          onSelected: (v) => setState(() => _blur2.enabled = v),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            if (_apiProvider == 'Manual')
              _sectionCard(
                title: 'Manual Script (Groq → ကိုယ်တိုင်ဘာသာပြန်)',
                icon: Icons.translate_rounded,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ElevatedButton.icon(
                      onPressed: (_isProcessing || _isTranscribing) ? null : _extractTranscriptOnly,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF262A38),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.hearing_rounded, color: Color(0xFF00E5FF)),
                      label: Text(
                        _isTranscribing ? 'Groq ဖြင့် နားထောင်နေသည်...' : '🎧 ၁။ Groq ဖြင့် Script ထုတ်မယ်',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _manualScriptCtrl,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Script / မြန်မာဘာသာပြန်စာသား',
                        hintText: 'Groq မှထွက်လာသော Script ကို Copy ကူးပြီး ဘာသာပြန်ကာ ဒီနေရာမှာ ပြန် Paste ထည့်ပါ...',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _manualScriptCtrl.text));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Script ကို Copy ကူးပြီးပါပြီ'), duration: Duration(seconds: 2)),
                              );
                            },
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Copy ကူးမယ်'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final data = await Clipboard.getData('text/plain');
                              if (data?.text != null) {
                                setState(() => _manualScriptCtrl.text = data!.text!);
                              }
                            },
                            icon: const Icon(Icons.paste, size: 16),
                            label: const Text('Paste ထည့်မယ်'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

            _sectionCard(
              title: 'Edge TTS Voice',
              icon: Icons.record_voice_over_rounded,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    value: _voice,
                    decoration: const InputDecoration(labelText: 'အသံရွေးပါ'),
                    items: const [
                      DropdownMenuItem(value: 'my-MM-NilarNeural', child: Text('Nilar (အမျိုးသမီး)')),
                      DropdownMenuItem(value: 'my-MM-ThihaNeural', child: Text('Thiha (အမျိုးသား)')),
                    ],
                    onChanged: (v) => setState(() => _voice = v!),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [const Text('Speed (Rate)'), Text('${_rate.toInt()}%', style: const TextStyle(color: Color(0xFF00E5FF)))],
                  ),
                  Slider(value: _rate, min: -100, max: 100, divisions: 40, onChanged: (v) => setState(() => _rate = v)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [const Text('Pitch'), Text('${_pitch.toInt()} Hz', style: const TextStyle(color: Color(0xFF00E5FF)))],
                  ),
                  Slider(value: _pitch, min: -100, max: 100, divisions: 40, onChanged: (v) => setState(() => _pitch = v)),
                ],
              ),
            ),

            Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF7C4DFF), Color(0xFF00B0FF)]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ElevatedButton(
                onPressed: (_isProcessing || _isTranscribing) ? null : _startRecap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  _isProcessing
                      ? 'လုပ်ဆောင်နေပါသည်...'
                      : (_apiProvider == 'Manual' ? '🚀 ၂။ TTS နှင့် ဗီဒီယို စတင်ထုတ်မယ်' : '🚀 Recap ဗီဒီယို စတင်ထုတ်မယ်'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ),

            if (_currentStep > 0) ...[
              const SizedBox(height: 14),
              _sectionCard(
                title: 'လုပ်ဆောင်နေသည့် အဆင့်များ',
                icon: Icons.checklist_rounded,
                child: Column(
                  children: [
                    _buildStepTile(1, '၁။ Groq Whisper ဖြင့် အသံနားထောင်ခြင်း'),
                    _buildStepTile(2, '၂။ မြန်မာဘာသာပြန် Script ပြင်ဆင်ခြင်း'),
                    _buildStepTile(3, '၃။ Microsoft Edge TTS ဖြင့် အသံနှင့် ၂ ကြောင်းစာတန်းထုတ်ခြင်း'),
                    _buildStepTile(4, '၄။ $_resolution Blur, မြန်မာ Font နှင့် ရုပ်/အသံ Sync ပေါင်းထုတ်ခြင်း'),
                    _buildStepTile(5, '၅။ ဗီဒီယို အပြီးသတ် သိမ်းဆည်းခြင်း'),
                  ],
                ),
              ),
            ],

            // Save ပြီးသား ဗီဒီယိုကို နှိပ်ပြီး တန်းကြည့်နိုင်သည့် Card
            if (_outputPath.isNotEmpty)
              InkWell(
                onTap: _openSavedVideoPlayer,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.greenAccent, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.play_circle_fill, color: Colors.greenAccent, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('✅ သိမ်းပြီးပါပြီ! နှိပ်ပြီး ဗီဒီယိုကြည့်မယ်', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                            const SizedBox(height: 4),
                            Text(_outputPath, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (_logs.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('📋 Live Log', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 6),
                    ..._logs.map((l) => Text(l, style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'))),
                  ],
                ),
              ),
            ],

            if (_errorMsg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text('❌ Error: $_errorMsg', style: const TextStyle(color: Colors.redAccent)),
              ),
          ],
        ),
      ),
    );
  }
}

class _SavedVideoPlayerDialog extends StatefulWidget {
  final String videoPath;
  const _SavedVideoPlayerDialog({required this.videoPath});

  @override
  State<_SavedVideoPlayerDialog> createState() => _SavedVideoPlayerDialogState();
}

class _SavedVideoPlayerDialogState extends State<_SavedVideoPlayerDialog> {
  late VideoPlayerController _ctrl;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        setState(() => _ready = true);
        _ctrl.play();
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF141720),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Saved Video Preview', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            if (!_ready)
              const Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              )
            else ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: AspectRatio(
                  aspectRatio: _ctrl.value.aspectRatio,
                  child: VideoPlayer(_ctrl),
                ),
              ),
              const SizedBox(height: 8),
              VideoProgressIndicator(_ctrl, allowScrubbing: true, colors: const VideoProgressColors(playedColor: Color(0xFF00E5FF))),
              IconButton(
                icon: Icon(_ctrl.value.isPlaying ? Icons.pause_circle : Icons.play_circle, size: 42, color: const Color(0xFF00E5FF)),
                onPressed: () => setState(() => _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
