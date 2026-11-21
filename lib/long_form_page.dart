import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'services/ffmpeg_service.dart';
import 'services/long_form_service.dart';

class LongFormPage extends StatefulWidget {
  const LongFormPage({super.key});

  @override
  State<LongFormPage> createState() => _LongFormPageState();
}

class _LongFormPageState extends State<LongFormPage> {
  final _groqKeyCtrl = TextEditingController();
  final _geminiKeysCtrl = TextEditingController();

  String? _videoPath;
  String? _videoPreviewImg;
  String? _txtPath;
  String _txtContent = '';
  String? _bgmPath;

  String _resolution = '720p';
  int _minutesPerPart = 5;
  String _voice = 'my-MM-NilarNeural';
  double _ttsRate = 10;
  double _ttsPitch = 0;

  // Copyright-Safe Edit Settings
  bool _enableCopyrightSafe = true;
  double _videoSpeed = 0.6;
  double _playSec = 6.0;
  double _freezeSec = 3.0;

  // Optional Blur, Subtitle, BGM
  bool _enableBlur = false;
  bool _enableSubtitles = true;
  double _subScale = 1.0;
  int _selectedColorIdx = 0;
  double _bgmVolume = 0.15;

  static const _subColors = [
    {'name': 'အဖြူ', 'color': Colors.white, 'ass': '&H00FFFFFF'},
    {'name': 'အဝါ', 'color': Color(0xFFFFEB3B), 'ass': '&H003BEBFF'},
    {'name': 'အပြာနု', 'color': Color(0xFF00E5FF), 'ass': '&H00FFE500'},
  ];

  List _parts = [];
  final Map<int, String> _completedParts = {};
  bool _isBusy = false;
  String _errorMsg = '';
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadSavedKeys();
  }

  void _addLog(String msg) {
    final now = DateTime.now();
    final t = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() => _logs.add('[$t] $msg'));
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

  List<String> _parseGeminiKeys() {
    return _geminiKeysCtrl.text
        .split(RegExp(r'[\n,]+'))
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
  }

  Future<void> _pickVideo() async {
    setState(() => _errorMsg = '');
    final file = await FilePicker.pickFile(type: FileType.video);
    if (file != null && file.path != null) {
      setState(() {
        _videoPath = file.path;
        _videoPreviewImg = null;
      });
      try {
        final previewPath = await FfmpegService().extractThumbnail(
          videoPath: file.path!,
          atSeconds: 5.0,
          enableMirror: false,
        );
        if (mounted) setState(() => _videoPreviewImg = previewPath);
      } catch (_) {}
    }
  }

  Future<void> _pickTxt() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (file != null && file.path != null) {
      final content = await File(file.path!).readAsString(encoding: utf8);
      setState(() {
        _txtPath = file.path;
        _txtContent = content.trim();
        _errorMsg = '';
      });
    }
  }

  Future<void> _pickBgm() async {
    final file = await FilePicker.pickFile(type: FileType.audio);
    if (file != null && file.path != null) {
      setState(() => _bgmPath = file.path);
    }
  }

  Future<void> _prepareParts() async {
    await _loadSavedKeys(); // <--- ဒီ ၁ ကြောင်း ထည့်ပါ
    final geminiKeys = _parseGeminiKeys();
    if (_videoPath == null) {
      setState(() => _errorMsg = '၁ နာရီစာ ဗီဒီယိုကို အရင်ရွေးပါ');
      return;
    }
    if (_txtContent.isEmpty) {
      setState(() => _errorMsg = 'မြန်မာ Script (.txt) ဖိုင်ကို အရင်ရွေးပါ');
      return;
    }
    if (_groqKeyCtrl.text.trim().isEmpty || geminiKeys.isEmpty) {
      setState(() => _errorMsg = 'Groq Key နှင့် Gemini Key ထည့်ပါ');
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMsg = '';
      _logs.clear();
      _parts = [];
      _completedParts.clear();
    });

    try {
      final svc = LongFormService();
      final groqTs = await svc.extractLongTimestamps(
        videoPath: _videoPath!,
        groqApiKey: _groqKeyCtrl.text.trim(),
        onLog: _addLog,
      );

      final aligned = await svc.alignScriptWithGemini(
        groqTimestamps: groqTs,
        myanmarTxtScript: _txtContent,
        geminiKeys: geminiKeys,
        onLog: _addLog,
      );

      final split = svc.splitIntoParts(aligned, _minutesPerPart);
      if (split.isEmpty) throw Exception('Script အပိုင်းခွဲ၍ မရပါ');

      setState(() => _parts = split);
      _addLog('✅ စုစုပေါင်း Part ${split.length} ခု ခွဲပြီးပါပြီ။ အောက်မှ တစ်ပိုင်းချင်း (သို့) အကုန် Render လုပ်နိုင်ပါပြီ။');
    } catch (e) {
      _addLog('❌ Error: $e');
      setState(() => _errorMsg = e.toString());
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<void> _renderSinglePart(int idx) async {
    if (_videoPath == null || idx >= _parts.length) return;
    setState(() {
      _isBusy = true;
      _errorMsg = '';
    });

    try {
      final outPath = await LongFormService().renderPart(
        partNumber: idx + 1,
        partSegments: _parts[idx] as List,
        videoPath: _videoPath!,
        voice: _voice,
        ratePercent: _ttsRate.toInt(),
        pitchHz: _ttsPitch.toInt(),
        resolution: _resolution,
        enableCopyrightSafe: _enableCopyrightSafe,
        videoSpeed: _videoSpeed,
        playSec: _playSec,
        freezeSec: _freezeSec,
        enableSubtitles: _enableSubtitles,
        subY: 0.85,
        subScale: _subScale,
        subColorAss: _subColors[_selectedColorIdx]['ass'] as String,
        enableBlur: _enableBlur,
        blurBox: BlurBox(enabled: _enableBlur, x: 0.05, y: 0.72, w: 0.90, h: 0.12),
        bgmPath: _bgmPath,
        bgmVolume: _bgmVolume,
        saveToGallery: true,
        onLog: _addLog,
      );

      setState(() => _completedParts[idx] = outPath);
    } catch (e) {
      _addLog('❌ Part ${idx + 1} Error: $e');
      setState(() => _errorMsg = e.toString());
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<void> _mergeAllForYouTube() async {
    if (_completedParts.length < 2) {
      setState(() => _errorMsg = 'ပေါင်းရန် အနည်းဆုံး Part ၂ ခု Render ပြီးထားရပါမည်');
      return;
    }
    setState(() {
      _isBusy = true;
      _errorMsg = '';
    });
    try {
      final orderedPaths = <String>[];
      for (int i = 0; i < _parts.length; i++) {
        if (_completedParts.containsKey(i)) {
          orderedPaths.add(_completedParts[i]!);
        }
      }
      final merged = await LongFormService().mergeAllParts(
        partPaths: orderedPaths,
        onLog: _addLog,
      );
      _addLog('🎉 YouTube ဗီဒီယိုအရှည် သိမ်းပြီး: $merged');
    } catch (e) {
      _addLog('❌ Merge Error: $e');
      setState(() => _errorMsg = e.toString());
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Widget _card(String title, IconData icon, Widget child) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF141720),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.movie_filter_rounded, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text('Long-Form YouTube Studio (1hr+)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _card(
              '၁။ ဗီဒီယို နှင့် မြန်မာ Script (.txt) ရွေးပါ',
              Icons.folder_open_rounded,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isBusy ? null : _pickVideo,
                    icon: const Icon(Icons.video_library, color: Color(0xFF00E5FF)),
                    label: Text(_videoPath == null ? '၁ နာရီစာ ဗီဒီယိုရွေးပါ' : 'ဗီဒီယို: ${_videoPath!.split('/').last}'),
                  ),
                  if (_videoPath != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF11131A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.greenAccent.withOpacity(0.5)),
                      ),
                      child: Row(
                        children: [
                          if (_videoPreviewImg != null && File(_videoPreviewImg!).existsSync())
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.file(
                                File(_videoPreviewImg!),
                                width: 64,
                                height: 42,
                                fit: BoxFit.cover,
                              ),
                            )
                          else
                            const Icon(Icons.video_file, color: Colors.greenAccent, size: 36),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '✅ ရွေးပြီး: ${_videoPath!.split('/').last}',
                              style: const TextStyle(fontSize: 12, color: Colors.greenAccent),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _isBusy ? null : _pickTxt,
                    icon: const Icon(Icons.description, color: Color(0xFF00E5FF)),
                    label: Text(_txtPath == null ? 'မြန်မာ Script (.txt) ရွေးပါ' : 'Script: ${_txtPath!.split('/').last} (${_txtContent.length} လုံး)'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _isBusy ? null : _pickBgm,
                    icon: const Icon(Icons.music_note, color: Colors.amberAccent),
                    label: Text(_bgmPath == null ? 'BGM သီချင်းရွေးပါ (မထည့်လည်းရ)' : 'BGM: ${_bgmPath!.split('/').last}'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int>(
                    value: _minutesPerPart,
                    decoration: const InputDecoration(labelText: 'အပိုင်းအရှည် (Part Length)'),
                    items: const [
                      DropdownMenuItem(value: 3, child: Text('၃ မိနစ်စီ ခွဲထုတ်မယ် (ဖုန်းအပေါ့ဆုံး)')),
                      DropdownMenuItem(value: 5, child: Text('၅ မိနစ်စီ ခွဲထုတ်မယ်')),
                      DropdownMenuItem(value: 8, child: Text('၈ မိနစ်စီ ခွဲထုတ်မယ်')),
                      DropdownMenuItem(value: 10, child: Text('၁၀ မိနစ်စီ ခွဲထုတ်မယ်')),
                    ],
                    onChanged: (v) => setState(() => _minutesPerPart = v!),
                  ),
                ],
              ),
            ),

            _card(
              '၂။ Copyright-Safe Edit (Speed + Freeze/Zoom)',
              Icons.shield_rounded,
              Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('6s Play + 3s Freeze & Zoom In/Out ဖွင့်မယ်', style: TextStyle(fontSize: 13)),
                    value: _enableCopyrightSafe,
                    onChanged: (v) => setState(() => _enableCopyrightSafe = v),
                  ),
                  if (_enableCopyrightSafe) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('မူရင်းဗီဒီယို Speed', style: TextStyle(fontSize: 13)),
                        Text('${_videoSpeed.toStringAsFixed(2)}x', style: const TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: _videoSpeed,
                      min: 0.5,
                      max: 1.0,
                      divisions: 10,
                      onChanged: (v) => setState(() => _videoSpeed = v),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Play: ${_playSec.toInt()}s / Freeze+Zoom: ${_freezeSec.toInt()}s', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      ],
                    ),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('မြန်မာစာတန်းထိုး ထည့်မယ်', style: TextStyle(fontSize: 13)),
                    value: _enableSubtitles,
                    onChanged: (v) => setState(() => _enableSubtitles = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('အောက်ခြေ Blur Box ဖွင့်မယ်', style: TextStyle(fontSize: 13)),
                    value: _enableBlur,
                    onChanged: (v) => setState(() => _enableBlur = v),
                  ),
                ],
              ),
            ),

            _card(
              '၃။ Edge TTS နှင့် Resolution',
              Icons.record_voice_over_rounded,
              Column(
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
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [const Text('TTS Speed'), Text('${_ttsRate.toInt()}%', style: const TextStyle(color: Color(0xFF00E5FF)))],
                  ),
                  Slider(value: _ttsRate, min: -100, max: 100, divisions: 40, onChanged: (v) => setState(() => _ttsRate = v)),
                  DropdownButtonFormField<String>(
                    value: _resolution,
                    decoration: const InputDecoration(labelText: 'Resolution'),
                    items: const [
                      DropdownMenuItem(value: '720p', child: Text('720p HD (မြန် / CPU သက်သာ)')),
                      DropdownMenuItem(value: '1080p', child: Text('1080p Full HD')),
                    ],
                    onChanged: (v) => setState(() => _resolution = v!),
                  ),
                ],
              ),
            ),

            ElevatedButton.icon(
              onPressed: _isBusy ? null : _prepareParts,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7C4DFF),
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Icon(Icons.auto_awesome, color: Colors.white),
              label: Text(
                _isBusy ? 'လုပ်ဆောင်နေပါသည်...' : '⚡ ၁။ AI ဖြင့် အချိန်တွဲပြီး Part များ ခွဲမယ်',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),

            if (_parts.isNotEmpty) ...[
              const SizedBox(height: 14),
              _card(
                '၄။ အပိုင်းလိုက် Render ထုတ်မယ် (CapCut / YouTube)',
                Icons.playlist_play_rounded,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...List.generate(_parts.length, (idx) {
                      final done = _completedParts.containsKey(idx);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(done ? Icons.check_circle : Icons.movie_creation_outlined, color: done ? Colors.greenAccent : Colors.white54),
                        title: Text('Part ${idx + 1} (${(_parts[idx] as List).length} ခန်း)', style: const TextStyle(fontSize: 13)),
                        subtitle: Text(done ? 'Gallery ထဲ သိမ်းပြီး' : 'Render မလုပ်ရသေးပါ', style: const TextStyle(fontSize: 11, color: Colors.white54)),
                        trailing: ElevatedButton(
                          onPressed: _isBusy ? null : () => _renderSinglePart(idx),
                          style: ElevatedButton.styleFrom(backgroundColor: done ? Colors.green.shade700 : const Color(0xFF00B0FF)),
                          child: Text(done ? 'ပြန်ထုတ်' : 'Render', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                      );
                    }),
                    const Divider(color: Colors.white24),
                    ElevatedButton.icon(
                      onPressed: (_isBusy || _completedParts.length < 2) ? null : _mergeAllForYouTube,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      icon: const Icon(Icons.merge_type, color: Colors.white),
                      label: const Text('🎬 ပြီးပြီးသား Part အားလုံးကို YouTube တစ်ပုဒ်တည်း ပေါင်းမယ်', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],

            if (_logs.isNotEmpty)
              Container(
                height: 160,
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(top: 12),
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
                    Expanded(
                      child: ListView.builder(
                        reverse: true,
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final log = _logs[_logs.length - 1 - index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(log, style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace')),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

            if (_errorMsg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('❌ $_errorMsg', style: const TextStyle(color: Colors.redAccent)),
              ),
          ],
        ),
      ),
    );
  }
}
