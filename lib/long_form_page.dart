import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'services/long_form_service.dart';
import 'services/ffmpeg_service.dart';

class _PartItem {
  final int partNumber;
  final String rawText;
  List? alignedSegments;
  String alignStatus; // pending, aligning, ready, error
  String? alignError;
  bool isRendering;
  String? outputPath;

  _PartItem({
    required this.partNumber,
    required this.rawText,
    this.alignedSegments,
    this.alignStatus = 'pending',
    this.alignError,
    this.isRendering = false,
    this.outputPath,
  });
}

class LongFormPage extends StatefulWidget {
  const LongFormPage({super.key});

  @override
  State<LongFormPage> createState() => _LongFormPageState();
}

class _LongFormPageState extends State<LongFormPage> {
  String _groqKey = '';
  String _geminiKeysRaw = '';
  final _groqCtrl = TextEditingController();
  final _geminiCtrl = TextEditingController();

  String? _videoPath;
  VideoPlayerController? _videoController;
  double _videoAspect = 16 / 9;

  String? _txtPath;
  String? _bgmPath;

  // Groq Cache
  String? _cachedGroqTimestamps;
  String? _cachedVideoPath;

  // Settings
  int _minutesPerPart = 8;
  bool _enableCopyrightSafe = true;
  double _videoSpeed = 0.65;
  final double _playSec = 6.0;
  final double _freezeSec = 3.0;
  bool _enableMirror = false;

  bool _enableSubtitles = true;
  double _subY = 0.82;
  double _subScale = 1.0;
  final String _subColorAss = '&H00FFFFFF';

  bool _enableBlur = true;
  final BlurBox _blurBox = BlurBox(
    enabled: true,
    x: 0.05,
    y: 0.78,
    w: 0.90,
    h: 0.14,
  );

  String _voice = 'my-MM-ThihaNeural';
  double _ttsRate = 35.0;
  final int _ttsPitch = 0;
  String _resolution = '720p';

  bool _isAligningAll = false;
  bool _isMerging = false;
  String _errorMsg = '';
  final List<String> _logs = [];
  final List<_PartItem> _parts = [];

  @override
  void initState() {
    super.initState();
    _loadSavedKeys();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _groqCtrl.dispose();
    _geminiCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final g = (prefs.getString('groq_key') ?? prefs.getString('groq_api_key') ?? '').trim();
    final gem = (prefs.getString('gemini_keys') ?? prefs.getString('gemini_api_keys') ?? '').trim();
    setState(() {
      _groqKey = g;
      _geminiKeysRaw = gem;
      _groqCtrl.text = g;
      _geminiCtrl.text = gem;
    });
  }

  Future<void> _saveKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final g = _groqCtrl.text.trim();
    final gem = _geminiCtrl.text.trim();
    await prefs.setString('groq_key', g);
    await prefs.setString('gemini_keys', gem);
    setState(() {
      _groqKey = g;
      _geminiKeysRaw = gem;
      _errorMsg = '';
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ API Keys များ သိမ်းဆည်းပြီးပါပြီ!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  List<String> _parseGeminiKeys() {
    return _geminiKeysRaw
        .split(RegExp(r'[\n,]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  void _addLog(String msg) {
    final now = DateTime.now();
    final t = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _logs.add('[$t] $msg');
      if (_logs.length > 80) _logs.removeAt(0);
    });
  }

  Future<void> _pickVideo() async {
    setState(() => _errorMsg = '');
    final file = await FilePicker.pickFile(type: FileType.video);
    if (file != null && file.path != null) {
      final path = file.path!;
      await _videoController?.dispose();
      _videoController = null;

      setState(() {
        _videoPath = path;
        if (_cachedVideoPath != path) {
          _cachedGroqTimestamps = null;
          _cachedVideoPath = null;
        }
      });

      try {
        final ctrl = VideoPlayerController.file(File(path));
        await ctrl.initialize();
        ctrl.addListener(() {
          if (mounted) setState(() {});
        });
        if (mounted) {
          setState(() {
            _videoController = ctrl;
            _videoAspect = ctrl.value.aspectRatio > 0 ? ctrl.value.aspectRatio : (16 / 9);
          });
        }
      } catch (e) {
        _addLog('⚠️ Preview ဖွင့်မရပါ: $e');
      }
    }
  }

  Future<void> _pickTxt() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (file != null && file.path != null) {
      setState(() => _txtPath = file.path);
    }
  }

  Future<void> _pickBgm() async {
    final file = await FilePicker.pickFile(type: FileType.audio);
    if (file != null && file.path != null) {
      setState(() => _bgmPath = file.path);
    }
  }

  Future<void> _prepareParts() async {
    await _loadSavedKeys();
    final geminiKeys = _parseGeminiKeys();

    if (_groqKey.isEmpty || geminiKeys.isEmpty) {
      setState(() => _errorMsg = 'အပေါ်က API Keys အကွက်မှာ Groq Key နှင့် Gemini Key ထည့်ပြီး Save နှိပ်ပါ');
      return;
    }
    if (_videoPath == null || _txtPath == null) {
      setState(() => _errorMsg = 'ဗီဒီယိုဖိုင် နှင့် မြန်မာ Script (.txt) ကို ရွေးပေးပါ');
      return;
    }

    setState(() {
      _isAligningAll = true;
      _errorMsg = '';
      _logs.clear();
      _parts.clear();
    });

    try {
      final svc = LongFormService();
      final txtContent = await File(_txtPath!).readAsString();
      final rawChunks = svc.splitScriptIntoRawChunks(txtContent, _minutesPerPart);

      if (rawChunks.isEmpty) {
        throw Exception('Script ဖိုင်ထဲတွင် စာသားမရှိပါ');
      }

      setState(() {
        for (int i = 0; i < rawChunks.length; i++) {
          _parts.add(_PartItem(partNumber: i + 1, rawText: rawChunks[i]));
        }
      });
      _addLog('Script ကို စုစုပေါင်း ${rawChunks.length} ပိုင်း ခွဲပြီးပါပြီ။');

      if (_cachedGroqTimestamps == null || _cachedVideoPath != _videoPath) {
        final ts = await svc.extractLongTimestamps(
          videoPath: _videoPath!,
          groqApiKey: _groqKey,
          onLog: _addLog,
        );
        _cachedGroqTimestamps = ts;
        _cachedVideoPath = _videoPath;
      } else {
        _addLog('⚡ သိမ်းထားပြီးသား Groq Timestamp ကို ပြန်သုံးပါမည်။');
      }

      for (int i = 0; i < _parts.length; i++) {
        await _alignSinglePart(i, geminiKeys);
      }
    } catch (e) {
      setState(() => _errorMsg = e.toString());
      _addLog('❌ $e');
    } finally {
      if (mounted) setState(() => _isAligningAll = false);
    }
  }

  Future<void> _alignSinglePart(int index, List<String> geminiKeys) async {
    final item = _parts[index];
    setState(() {
      item.alignStatus = 'aligning';
      item.alignError = null;
    });

    try {
      final segments = await LongFormService().alignSingleChunkWithGemini(
        groqTimestamps: _cachedGroqTimestamps!,
        chunkText: item.rawText,
        partNumber: item.partNumber,
        totalParts: _parts.length,
        geminiKeys: geminiKeys,
        onLog: _addLog,
      );
      if (mounted) {
        setState(() {
          item.alignedSegments = segments;
          item.alignStatus = 'ready';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          item.alignStatus = 'error';
          item.alignError = e.toString();
        });
      }
      _addLog('❌ Part ${item.partNumber} မအောင်မြင်ပါ (Retry ပြန်နှိပ်နိုင်သည်)');
    }
  }

  Future<void> _retryPart(int index) async {
    await _loadSavedKeys();
    final geminiKeys = _parseGeminiKeys();
    if (_cachedGroqTimestamps == null || geminiKeys.isEmpty) {
      setState(() => _errorMsg = 'Key သို့မဟုတ် Groq Timestamp မရှိပါ');
      return;
    }
    await _alignSinglePart(index, geminiKeys);
  }

  Future<void> _renderSinglePart(int index) async {
    final item = _parts[index];
    if (item.alignedSegments == null || item.isRendering) return;

    setState(() {
      item.isRendering = true;
      _errorMsg = '';
    });

    try {
      _blurBox.enabled = _enableBlur;
      final outPath = await LongFormService().renderPart(
        partNumber: item.partNumber,
        partSegments: item.alignedSegments!,
        videoPath: _videoPath!,
        voice: _voice,
        ratePercent: _ttsRate.round(),
        pitchHz: _ttsPitch,
        resolution: _resolution,
        enableCopyrightSafe: _enableCopyrightSafe,
        videoSpeed: _videoSpeed,
        playSec: _playSec,
        freezeSec: _freezeSec,
        enableSubtitles: _enableSubtitles,
        subY: _subY,
        subScale: _subScale,
        subColorAss: _subColorAss,
        enableBlur: _enableBlur,
        blurBox: _blurBox,
        enableMirror: _enableMirror,
        bgmPath: _bgmPath,
        onLog: _addLog,
      );
      if (mounted) {
        setState(() => item.outputPath = outPath);
      }
    } catch (e) {
      if (mounted) setState(() => _errorMsg = 'Part ${item.partNumber} Render Error: $e');
      _addLog('❌ Part ${item.partNumber} Render Error: $e');
    } finally {
      if (mounted) setState(() => item.isRendering = false);
    }
  }

  Future<void> _mergeCompletedParts() async {
    final paths = _parts.where((p) => p.outputPath != null).map((p) => p.outputPath!).toList();
    if (paths.length < 2) return;

    setState(() {
      _isMerging = true;
      _errorMsg = '';
    });

    try {
      await LongFormService().mergeAllParts(partPaths: paths, onLog: _addLog);
    } catch (e) {
      setState(() => _errorMsg = 'Merge Error: $e');
      _addLog('❌ Merge Error: $e');
    } finally {
      if (mounted) setState(() => _isMerging = false);
    }
  }

  String _formatDur(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return '${d.inHours}:$m:$s';
    return '$m:$s';
  }

  Widget _buildInteractivePreview() {
    final ctrl = _videoController;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final durMs = ctrl.value.duration.inMilliseconds.toDouble();
    final posMs = ctrl.value.position.inMilliseconds.toDouble().clamp(0.0, durMs > 0 ? durMs : 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        const Text(
          '🎯 Blur ကို အလယ်ကဆွဲရွှေ့ / ညာအောက်ထောင့်က ဆွဲချဲ့ပါ • စာတန်းကို အပေါ်/အောက် ဆွဲပါ',
          style: TextStyle(fontSize: 11, color: Colors.amberAccent),
        ),
        const SizedBox(height: 6),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: AspectRatio(
              aspectRatio: _videoAspect.clamp(0.45, 2.2),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final boxW = constraints.maxWidth;
                  final boxH = constraints.maxHeight;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.identity()..scale(_enableMirror ? -1.0 : 1.0, 1.0),
                            child: VideoPlayer(ctrl),
                          ),
                        ),
                        if (_enableBlur)
                          Positioned(
                            left: _blurBox.x * boxW,
                            top: _blurBox.y * boxH,
                            width: _blurBox.w * boxW,
                            height: _blurBox.h * boxH,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: GestureDetector(
                                    onPanUpdate: (details) {
                                      setState(() {
                                        _blurBox.x = (_blurBox.x + details.delta.dx / boxW).clamp(0.0, 1.0 - _blurBox.w);
                                        _blurBox.y = (_blurBox.y + details.delta.dy / boxH).clamp(0.0, 1.0 - _blurBox.h);
                                      });
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.blueAccent.withOpacity(0.35),
                                        border: Border.all(color: Colors.lightBlueAccent, width: 2),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      alignment: Alignment.center,
                                      child: const Text(
                                        'Blur နေရာ',
                                        style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: GestureDetector(
                                    onPanUpdate: (details) {
                                      setState(() {
                                        _blurBox.w = (_blurBox.w + details.delta.dx / boxW).clamp(0.10, 1.0 - _blurBox.x);
                                        _blurBox.h = (_blurBox.h + details.delta.dy / boxH).clamp(0.06, 1.0 - _blurBox.y);
                                      });
                                    },
                                    child: Container(
                                      width: 24,
                                      height: 24,
                                      decoration: const BoxDecoration(
                                        color: Colors.lightBlueAccent,
                                        borderRadius: BorderRadius.only(topLeft: Radius.circular(6)),
                                      ),
                                      child: const Icon(Icons.open_in_full, size: 14, color: Colors.black),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (_enableSubtitles)
                          Positioned(
                            left: 8,
                            right: 8,
                            top: (_subY * boxH - 18).clamp(0.0, boxH - 36),
                            child: GestureDetector(
                              onVerticalDragUpdate: (details) {
                                setState(() {
                                  _subY = (_subY + details.delta.dy / boxH).clamp(0.08, 0.94);
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.65),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: Colors.amberAccent, width: 1.2),
                                ),
                                child: Text(
                                  'မြန်မာစာတန်းထိုးနေရာ',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: (13 * _subScale).clamp(9.0, 26.0),
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            IconButton(
              icon: Icon(
                ctrl.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                color: Colors.lightBlueAccent,
                size: 32,
              ),
              onPressed: () {
                setState(() {
                  ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
                });
              },
            ),
            Text(_formatDur(ctrl.value.position), style: const TextStyle(fontSize: 11, color: Colors.white70)),
            Expanded(
              child: Slider(
                value: posMs,
                min: 0.0,
                max: durMs > 0 ? durMs : 1.0,
                onChanged: (v) => ctrl.seekTo(Duration(milliseconds: v.round())),
              ),
            ),
            Text(_formatDur(ctrl.value.duration), style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        if (_enableSubtitles)
          Row(
            children: [
              const Text('စာတန်းအရွယ်:', style: TextStyle(fontSize: 11, color: Colors.white70)),
              Expanded(
                child: Slider(
                  value: _subScale,
                  min: 0.6,
                  max: 1.8,
                  divisions: 12,
                  onChanged: (v) => setState(() => _subScale = v),
                ),
              ),
              Text('${(_subScale * 100).round()}%', style: const TextStyle(fontSize: 11, color: Colors.amberAccent)),
            ],
          ),
      ],
    );
  }

  Widget _buildCard({required String title, required IconData icon, required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF181B24),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF262A38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: Colors.lightBlueAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final completedCount = _parts.where((p) => p.outputPath != null).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Long-Form YouTube Studio (1hr+)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF12141C),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildCard(
              title: '🔑 API Keys (Groq နှင့် Gemini)',
              icon: Icons.vpn_key_rounded,
              children: [
                TextField(
                  controller: _groqCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Groq API Key (gsk_...)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _geminiCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Gemini API Keys (တစ်ခုထက်ပိုရင် Enter ခေါက်ထည့်ပါ)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _saveKeys,
                  icon: const Icon(Icons.save_rounded, size: 18),
                  label: const Text('💾 API Keys သိမ်းမယ် (Save)'),
                ),
              ],
            ),

            _buildCard(
              title: '၁။ ဗီဒီယို နှင့် မြန်မာ Script (.txt) ရွေးပါ',
              icon: Icons.video_library_rounded,
              children: [
                OutlinedButton.icon(
                  onPressed: _isAligningAll ? null : _pickVideo,
                  icon: const Icon(Icons.movie_creation_outlined, color: Colors.lightBlueAccent),
                  label: Text(
                    _videoPath == null ? '၁ နာရီစာ ဗီဒီယို ရွေးမယ်' : '✅ ${_videoPath!.split('/').last}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _buildInteractivePreview(),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _isAligningAll ? null : _pickTxt,
                  icon: const Icon(Icons.description, color: Colors.amberAccent),
                  label: Text(
                    _txtPath == null ? 'မြန်မာ Script (.txt) ရွေးမယ်' : '✅ ${_txtPath!.split('/').last}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _isAligningAll ? null : _pickBgm,
                  icon: const Icon(Icons.music_note, color: Colors.pinkAccent),
                  label: Text(
                    _bgmPath == null ? 'BGM သီချင်း (မထည့်လည်းရသည်)' : '🎵 ${_bgmPath!.split('/').last}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  value: _minutesPerPart,
                  decoration: const InputDecoration(labelText: 'အပိုင်းတစ်ပိုင်း အရှည်', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 3, child: Text('၃ မိနစ်စီ ခွဲထုတ်မယ် (ဖုန်းအပေါ့ဆုံး)')),
                    DropdownMenuItem(value: 5, child: Text('၅ မိနစ်စီ ခွဲထုတ်မယ်')),
                    DropdownMenuItem(value: 8, child: Text('၈ မိနစ်စီ ခွဲထုတ်မယ်')),
                    DropdownMenuItem(value: 10, child: Text('၁၀ မိနစ်စီ ခွဲထုတ်မယ်')),
                  ],
                  onChanged: _isAligningAll ? null : (v) => setState(() => _minutesPerPart = v ?? 8),
                ),
              ],
            ),

            _buildCard(
              title: '၂။ Copyright-Safe Edit (Mirror + Speed + Freeze/Zoom)',
              icon: Icons.shield_rounded,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('ဗီဒီယို ဘယ်/ညာ လှည့်မယ် (Mirror)', style: TextStyle(fontSize: 13)),
                  value: _enableMirror,
                  onChanged: (v) => setState(() => _enableMirror = v),
                ),
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
                      const Text('မူရင်းဗီဒီယို Speed', style: TextStyle(fontSize: 12)),
                      Text('${_videoSpeed.toStringAsFixed(2)}x', style: const TextStyle(color: Colors.lightBlueAccent)),
                    ],
                  ),
                  Slider(
                    value: _videoSpeed,
                    min: 0.50,
                    max: 1.00,
                    divisions: 10,
                    onChanged: (v) => setState(() => _videoSpeed = v),
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
                  title: const Text('Blur Box ဖွင့်မယ်', style: TextStyle(fontSize: 13)),
                  value: _enableBlur,
                  onChanged: (v) => setState(() => _enableBlur = v),
                ),
              ],
            ),

            _buildCard(
              title: '၃။ Edge TTS နှင့် Resolution',
              icon: Icons.record_voice_over_rounded,
              children: [
                DropdownButtonFormField<String>(
                  value: _voice,
                  decoration: const InputDecoration(labelText: 'အသံရွေးပါ', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'my-MM-ThihaNeural', child: Text('Thiha (အမျိုးသား)')),
                    DropdownMenuItem(value: 'my-MM-NilarNeural', child: Text('Nilar (အမျိုးသမီး)')),
                  ],
                  onChanged: (v) => setState(() => _voice = v ?? 'my-MM-ThihaNeural'),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('TTS Speed', style: TextStyle(fontSize: 12)),
                    Text('${_ttsRate.round()}%', style: const TextStyle(color: Colors.lightBlueAccent)),
                  ],
                ),
                Slider(
                  value: _ttsRate,
                  min: -50,
                  max: 100,
                  divisions: 30,
                  onChanged: (v) => setState(() => _ttsRate = v),
                ),
                DropdownButtonFormField<String>(
                  value: _resolution,
                  decoration: const InputDecoration(labelText: 'Resolution', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: '720p', child: Text('720p HD (မြန် / CPU သက်သာ)')),
                    DropdownMenuItem(value: '1080p', child: Text('1080p Full HD')),
                  ],
                  onChanged: (v) => setState(() => _resolution = v ?? '720p'),
                ),
              ],
            ),

            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7C4DFF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _isAligningAll ? null : _prepareParts,
              icon: const Icon(Icons.auto_awesome),
              label: Text(
                _isAligningAll ? 'အပိုင်းများ တွဲနေပါသည်...' : '⚡ ၁။ AI ဖြင့် အချိန်တွဲပြီး Part များ ခွဲမယ်',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),

            if (_parts.isNotEmpty) ...[
              const SizedBox(height: 14),
              _buildCard(
                title: '၄။ အပိုင်းအလိုက် Render ထုတ်ပါ (${_parts.length} ပိုင်း)',
                icon: Icons.playlist_play_rounded,
                children: [
                  ...List.generate(_parts.length, (i) {
                    final item = _parts[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF11131A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: item.outputPath != null
                              ? Colors.greenAccent.withOpacity(0.5)
                              : item.alignStatus == 'error'
                                  ? Colors.redAccent.withOpacity(0.6)
                                  : const Color(0xFF262A38),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Part ${item.partNumber}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                const SizedBox(height: 2),
                                if (item.alignStatus == 'pending')
                                  const Text('⏳ စောင့်ဆိုင်းနေသည်...', style: TextStyle(fontSize: 11, color: Colors.white54))
                                else if (item.alignStatus == 'aligning')
                                  const Text('✨ Gemini အချိန်တွဲနေသည်...', style: TextStyle(fontSize: 11, color: Colors.amberAccent))
                                else if (item.alignStatus == 'error')
                                  const Text('❌ မအောင်မြင်ပါ (Retry ပြန်နှိပ်ပါ)', style: TextStyle(fontSize: 11, color: Colors.redAccent))
                                else if (item.outputPath != null)
                                  const Text('✅ ဗီဒီယိုထုတ်ပြီး (Gallery ထဲသိမ်းပြီး)', style: TextStyle(fontSize: 11, color: Colors.greenAccent))
                                else
                                  Text('🟢 အသင့်ဖြစ်ပြီ (${item.alignedSegments?.length ?? 0} ခန်း)', style: const TextStyle(fontSize: 11, color: Colors.lightBlueAccent)),
                              ],
                            ),
                          ),
                          if (item.alignStatus == 'error')
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent, foregroundColor: Colors.black),
                              onPressed: () => _retryPart(i),
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('Retry', style: TextStyle(fontSize: 12)),
                            )
                          else if (item.alignStatus == 'ready')
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: item.outputPath != null ? Colors.green : Colors.blueAccent,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: item.isRendering ? null : () => _renderSinglePart(i),
                              icon: item.isRendering
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.movie_filter_rounded, size: 16),
                              label: Text(
                                item.isRendering
                                    ? 'ထုတ်နေသည်'
                                    : item.outputPath != null
                                        ? 'ပြန်ထုတ်'
                                        : '🎬 Render',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    );
                  }),
                  if (completedCount >= 2) ...[
                    const SizedBox(height: 6),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _isMerging ? null : _mergeCompletedParts,
                      icon: const Icon(Icons.merge_type_rounded),
                      label: Text(_isMerging ? 'ပေါင်းနေပါသည်...' : '🎞️ ပြီးသမျှ $completedCount ပိုင်းလုံးကို ၁ ပုဒ်တည်း ပေါင်းမယ်'),
                    ),
                  ],
                ],
              ),
            ],

            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF262A38)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('📋 Live Log', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                    const SizedBox(height: 6),
                    ..._logs.reversed.take(8).map((l) => Text(l, style: const TextStyle(fontSize: 11, color: Colors.white70))),
                  ],
                ),
              ),
            ],

            if (_errorMsg.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('❌ $_errorMsg', style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}
