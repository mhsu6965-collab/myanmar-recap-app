import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'services/long_form_service.dart';
import 'services/ffmpeg_service.dart';

class _PartItem {
  final int partNumber;
  final double startSec;
  final double durSec;
  List? alignedSegments;
  String summary;
  String tailLines;
  String status; // pending, generating, ready, error
  String? errorText;
  bool isRendering;
  String? outputPath;

  _PartItem({
    required this.partNumber,
    required this.startSec,
    required this.durSec,
    this.alignedSegments,
    this.summary = '',
    this.tailLines = '',
    this.status = 'pending',
    this.errorText,
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
  String _geminiKeysRaw = '';
  String _groqKey = '';
  final _geminiCtrl = TextEditingController();
  final _groqCtrl = TextEditingController();

  // Script Editor State
  final _scriptEditCtrl = TextEditingController();
  int? _editingPartIndex;

  // Mode: 'groq_only' (Groq Script ထုတ် + ကိုယ်တိုင်ဘာသာပြန်) | 'dubbing' (Groq + Gemini Auto) | 'recap' (Gemini Recap)
  String _workMode = 'groq_only';

  String? _videoPath;
  VideoPlayerController? _videoController;
  double _videoAspect = 16 / 9;
  double _videoTotalSec = 0.0;

  String? _bgmPath;
  String? _mergedOutputPath;

  // Settings
  int _minutesPerPart = 3;
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

  String _voice = 'my-MM-NilarNeural';
  double _ttsRate = 20.0;
  final int _ttsPitch = 0;
  String _resolution = '720p';

  bool _isGeneratingAll = false;
  bool _stopRequested = false;
  int _cooldownSec = 0;
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
    _geminiCtrl.dispose();
    _groqCtrl.dispose();
    _scriptEditCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final gem = (prefs.getString('gemini_keys') ?? prefs.getString('gemini_api_keys') ?? '').trim();
    final groq = (prefs.getString('groq_api_key') ?? '').trim();
    setState(() {
      _geminiKeysRaw = gem;
      _groqKey = groq;
      _geminiCtrl.text = gem;
      _groqCtrl.text = groq;
    });
  }

  Future<void> _saveKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final gem = _geminiCtrl.text.trim();
    final groq = _groqCtrl.text.trim();
    await prefs.setString('gemini_keys', gem);
    await prefs.setString('groq_api_key', groq);
    setState(() {
      _geminiKeysRaw = gem;
      _groqKey = groq;
      _errorMsg = '';
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ API Keys သိမ်းဆည်းပြီးပါပြီ!'),
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

  void _openScriptEditor(int index) {
    final item = _parts[index];
    if (item.alignedSegments == null || item.alignedSegments!.isEmpty) return;

    final buf = StringBuffer();
    for (final seg in item.alignedSegments!) {
      final s = (seg['vStart'] as num).toDouble().toStringAsFixed(2);
      final e = (seg['vEnd'] as num).toDouble().toStringAsFixed(2);
      final txt = (seg['text'] ?? '').toString().trim();
      buf.writeln('[$s-$e] $txt');
    }

    setState(() {
      _editingPartIndex = index;
      _scriptEditCtrl.text = buf.toString().trim();
    });
  }

  // Gemini Web / ChatGPT မှာ တန်းကူးထည့်ပြီး ဘာသာပြန်ခိုင်းနိုင်ရန် Prompt ပါ Copy ကူးပေးမည်
  Future<void> _copyScriptWithPrompt() async {
    final raw = _scriptEditCtrl.text.trim();
    if (raw.isEmpty) return;

    final promptText = '''
အောက်က Script ကို ဇာတ်ကားထဲကလို သဘာဝကျတဲ့ မြန်မာပြောစကား (တိုတိုနဲ့ သွက်သွက်) အတိအကျ ဘာသာပြန်ပေးပါ။
စည်းကမ်း:
1. ရှေ့က [start-end] အချိန်တွေကို လုံးဝမပြောင်းပါနဲ့။
2. စာကြောင်းတစ်ကြောင်းမှ မကျော်ဘဲ တစ်ကြောင်းချင်းစီ ပြန်ပေးပါ။
3. ဘာသာပြန်ထားတဲ့ [start-end] စာကြောင်းတွေကိုပဲ ထုတ်ပေးပါ (အပိုစကားမထည့်ပါနဲ့)။

$raw
''';

    await Clipboard.setData(ClipboardData(text: promptText));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('📋 Prompt + Script Copy ကူးပြီးပါပြီ! Gemini/ChatGPT မှာ Paste ချပြီး ဘာသာပြန်ပါ။'),
          backgroundColor: Colors.blueAccent,
        ),
      );
    }
  }

  Future<void> _pasteScriptFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() {
        _scriptEditCtrl.text = data.text!.trim();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📥 Paste ထည့်ပြီးပါပြီ! အောက်က "သိမ်းမယ်" ခလုတ်ကို နှိပ်ပါ။'),
            backgroundColor: Colors.teal,
          ),
        );
      }
    }
  }

  void _saveEditedScript() {
    if (_editingPartIndex == null || _editingPartIndex! >= _parts.length) return;
    final parsed = LongFormService().parseAlignedSegments(_scriptEditCtrl.text, offsetSec: 0.0);
    if (parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ [0.00-3.00] စာသား ပုံစံအတိုင်း မှန်အောင် ထည့်ပေးပါ'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final idx = _editingPartIndex!;
    setState(() {
      _parts[idx].alignedSegments = parsed;
    });
    _addLog('💾 Part ${_parts[idx].partNumber} Script သိမ်းဆည်းပြီး (${parsed.length} ကြောင်း)။');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ Part ${_parts[idx].partNumber} Script (${parsed.length} ကြောင်း) သိမ်းပြီးပါပြီ!'),
        backgroundColor: Colors.green,
      ),
    );
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
        _videoTotalSec = 0.0;
        _mergedOutputPath = null;
        _parts.clear();
        _editingPartIndex = null;
        _scriptEditCtrl.clear();
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
            _videoTotalSec = ctrl.value.duration.inMilliseconds / 1000.0;
          });
        }
      } catch (e) {
        _addLog('⚠️ Preview ဖွင့်မရပါ: $e');
      }
    }
  }

  Future<void> _pickBgm() async {
    final file = await FilePicker.pickFile(type: FileType.audio);
    if (file != null && file.path != null) {
      setState(() => _bgmPath = file.path);
    }
  }

  void _watchRenderedVideo(String path, String title) {
    if (!File(path).existsSync()) {
      setState(() => _errorMsg = 'ဗီဒီယိုဖိုင် မတွေ့ပါ');
      return;
    }
    _videoController?.pause();
    showDialog(
      context: context,
      builder: (_) => _RenderedVideoDialog(videoPath: path, title: title),
    );
  }

  Future<void> _startOrResumeAutoProcess({bool freshStart = false}) async {
    await _loadSavedKeys();
    final geminiKeys = _parseGeminiKeys();

    if (_workMode != 'groq_only' && geminiKeys.isEmpty) {
      setState(() => _errorMsg = 'အပေါ်က အကွက်မှာ Gemini API Key ထည့်ပြီး Save နှိပ်ပါ');
      return;
    }
    if ((_workMode == 'groq_only' || _workMode == 'dubbing') && _groqKey.trim().isEmpty) {
      setState(() => _errorMsg = 'Groq API Key (gsk_...) ထည့်ပြီး Save နှိပ်ပါ');
      return;
    }
    if (_videoPath == null) {
      setState(() => _errorMsg = 'ဗီဒီယိုဖိုင်ကို အရင်ရွေးပေးပါ');
      return;
    }

    setState(() {
      _isGeneratingAll = true;
      _stopRequested = false;
      _cooldownSec = 0;
      _errorMsg = '';
      if (freshStart) {
        _mergedOutputPath = null;
        _logs.clear();
        _parts.clear();
        _editingPartIndex = null;
        _scriptEditCtrl.clear();
      }
    });

    try {
      if (_parts.isEmpty) {
        double totalSec = _videoTotalSec;
        if (totalSec <= 0) {
          totalSec = await FfmpegService().getDuration(_videoPath!);
        }
        if (totalSec <= 1.0) {
          throw Exception('ဗီဒီယိုအရှည် ဖတ်၍မရပါ');
        }

        final double chunkLen = _minutesPerPart * 60.0;
        final List<_PartItem> newParts = [];
        double cursor = 0.0;
        int pNum = 1;

        while (cursor < totalSec - 1.0) {
          final double remaining = totalSec - cursor;
          final double dur = remaining >= chunkLen ? chunkLen : remaining;
          newParts.add(_PartItem(partNumber: pNum++, startSec: cursor, durSec: dur));
          cursor += dur;
        }

        setState(() => _parts.addAll(newParts));
        _addLog('ဗီဒီယို (${(totalSec / 60).toStringAsFixed(1)} မိနစ်) ကို စုစုပေါင်း ${_parts.length} ပိုင်း ခွဲပြီးပါပြီ။');
      }

      for (int i = 0; i < _parts.length; i++) {
        if (_stopRequested) {
          _addLog('⏹️ အသုံးပြုသူမှ ခဏရပ်လိုက်ပါသည်။');
          break;
        }
        if (_parts[i].status == 'ready') continue;

        final ok = await _generateSinglePart(i, geminiKeys);
        if (!ok) {
          _addLog('🛑 Part ${_parts[i].partNumber} မအောင်မြင်၍ ခဏရပ်ထားပါသည်။ ခဏစောင့်ပြီး "ဆက်ထုတ်မယ်" နှိပ်ပါ။');
          break;
        }

        final hasMore = _parts.sublist(i + 1).any((p) => p.status != 'ready');
        if (hasMore && !_stopRequested) {
          final waitSec = _workMode == 'groq_only' ? 3 : 25;
          _addLog('⏳ ခဏနားနေပါသည် (${waitSec}s)...');
          for (int sec = waitSec; sec > 0; sec--) {
            if (_stopRequested || !mounted) break;
            setState(() => _cooldownSec = sec);
            await Future.delayed(const Duration(seconds: 1));
          }
          if (mounted) setState(() => _cooldownSec = 0);
        }
      }
    } catch (e) {
      setState(() => _errorMsg = e.toString());
      _addLog('❌ $e');
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingAll = false;
          _cooldownSec = 0;
        });
      }
    }
  }

  String _getPreviousSummary(int index) {
    for (int i = index - 1; i >= 0; i--) {
      if (_parts[i].summary.trim().isNotEmpty) {
        return _parts[i].summary.trim();
      }
    }
    return '';
  }

  String _getPreviousTailLines(int index) {
    for (int i = index - 1; i >= 0; i--) {
      if (_parts[i].tailLines.trim().isNotEmpty) {
        return _parts[i].tailLines.trim();
      }
    }
    return '';
  }

  Future<bool> _generateSinglePart(int index, List<String> geminiKeys) async {
    final item = _parts[index];
    setState(() {
      item.status = 'generating';
      item.errorText = null;
    });

    try {
      if (_workMode == 'groq_only') {
        final rawList = await LongFormService().transcribePartWithGroq(
          videoPath: _videoPath!,
          partNumber: item.partNumber,
          totalParts: _parts.length,
          chunkStartSec: item.startSec,
          chunkDurSec: item.durSec,
          groqApiKey: _groqKey,
          onLog: _addLog,
        );

        final List mapped = rawList.map((e) {
          return {
            'vStart': (e['start'] as num).toDouble(),
            'vEnd': (e['end'] as num).toDouble(),
            'text': (e['text'] ?? '').toString().trim(),
          };
        }).toList();

        if (mounted) {
          setState(() {
            item.alignedSegments = mapped;
            item.status = 'ready';
          });
          if (_editingPartIndex == null) {
            _openScriptEditor(index);
          }
        }
        return true;
      }

      final prevSummary = _getPreviousSummary(index);
      final prevTail = _getPreviousTailLines(index);

      final Map result;
      if (_workMode == 'dubbing') {
        result = await LongFormService().generateDubbingScriptForPart(
          videoPath: _videoPath!,
          partNumber: item.partNumber,
          totalParts: _parts.length,
          chunkStartSec: item.startSec,
          chunkDurSec: item.durSec,
          previousSummary: prevSummary,
          previousTailLines: prevTail,
          groqApiKey: _groqKey,
          geminiKeys: geminiKeys,
          onLog: _addLog,
        );
      } else {
        result = await LongFormService().generateScriptForVideoPart(
          videoPath: _videoPath!,
          partNumber: item.partNumber,
          totalParts: _parts.length,
          chunkStartSec: item.startSec,
          chunkDurSec: item.durSec,
          previousSummary: prevSummary,
          previousTailLines: prevTail,
          geminiKeys: geminiKeys,
          onLog: _addLog,
        );
      }

      if (mounted) {
        setState(() {
          item.alignedSegments = result['segments'] as List;
          item.summary = (result['summary'] ?? '').toString();
          item.tailLines = (result['tailLines'] ?? '').toString();
          item.status = 'ready';
        });
        if (_editingPartIndex == null) {
          _openScriptEditor(index);
        }
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          item.status = 'error';
          item.errorText = e.toString();
        });
      }
      _addLog('❌ Part ${item.partNumber} မအောင်မြင်ပါ: $e');
      return false;
    }
  }

  Future<void> _retryPart(int index) async {
    await _loadSavedKeys();
    final geminiKeys = _parseGeminiKeys();
    if (_workMode != 'groq_only' && geminiKeys.isEmpty) {
      setState(() => _errorMsg = 'Gemini API Key မရှိပါ');
      return;
    }
    if ((_workMode == 'groq_only' || _workMode == 'dubbing') && _groqKey.trim().isEmpty) {
      setState(() => _errorMsg = 'Groq API Key မရှိပါ');
      return;
    }
    await _generateSinglePart(index, geminiKeys);
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
      final String outPath;

      if (_workMode == 'groq_only' || _workMode == 'dubbing') {
        outPath = await LongFormService().renderDubbingPart(
          partNumber: item.partNumber,
          chunkStartSec: item.startSec,
          chunkDurSec: item.durSec,
          partSegments: item.alignedSegments!,
          videoPath: _videoPath!,
          voice: _voice,
          ratePercent: _ttsRate.round(),
          pitchHz: _ttsPitch,
          resolution: _resolution,
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
      } else {
        outPath = await LongFormService().renderPart(
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
      }

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
      final merged = await LongFormService().mergeAllParts(partPaths: paths, onLog: _addLog);
      if (mounted) {
        setState(() => _mergedOutputPath = merged);
      }
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

  String _formatSecRange(double start, double dur) {
    return '${_formatDur(Duration(seconds: start.round()))} - ${_formatDur(Duration(seconds: (start + dur).round()))}';
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
    final hasUnfinishedParts = _parts.isNotEmpty && _parts.any((p) => p.status != 'ready');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Long-Form AI Video Studio', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF12141C),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildCard(
              title: '🎛️ အလုပ်လုပ်မည့် စနစ်ရွေးပါ (Mode)',
              icon: Icons.tune_rounded,
              children: [
                DropdownButtonFormField<String>(
                  value: _workMode,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  items: const [
                    DropdownMenuItem(
                      value: 'groq_only',
                      child: Text('⚡ Groq Script ထုတ် (ကိုယ်တိုင်ဘာသာပြန် + Smart Sync)'),
                    ),
                    DropdownMenuItem(
                      value: 'dubbing',
                      child: Text('🎙️ Dubbing Auto (Groq + Gemini API ဘာသာပြန်)'),
                    ),
                    DropdownMenuItem(
                      value: 'recap',
                      child: Text('🎬 Recap Mode (Gemini ဗီဒီယိုကြည့် + 6s/3s Freeze)'),
                    ),
                  ],
                  onChanged: _isGeneratingAll
                      ? null
                      : (v) {
                          if (v != null && v != _workMode) {
                            setState(() {
                              _workMode = v;
                              _parts.clear();
                              _mergedOutputPath = null;
                              _editingPartIndex = null;
                              _scriptEditCtrl.clear();
                            });
                          }
                        },
                ),
              ],
            ),

            _buildCard(
              title: _workMode == 'groq_only' ? '🔑 Groq API Key (Gemini Key မလို)' : '🔑 API Keys (Gemini + Groq)',
              icon: Icons.vpn_key_rounded,
              children: [
                if (_workMode != 'groq_only') ...[
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
                ],
                if (_workMode == 'groq_only' || _workMode == 'dubbing') ...[
                  TextField(
                    controller: _groqCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Groq API Key (gsk_...)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
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
              title: '၁။ ဗီဒီယို နှင့် BGM ရွေးပါ',
              icon: Icons.video_library_rounded,
              children: [
                OutlinedButton.icon(
                  onPressed: _isGeneratingAll ? null : _pickVideo,
                  icon: const Icon(Icons.movie_creation_outlined, color: Colors.lightBlueAccent),
                  label: Text(
                    _videoPath == null ? 'ဗီဒီယိုဖိုင် ရွေးမယ် (1hr+ ရသည်)' : '✅ ${_videoPath!.split('/').last}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _buildInteractivePreview(),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _isGeneratingAll ? null : _pickBgm,
                  icon: const Icon(Icons.music_note, color: Colors.pinkAccent),
                  label: Text(
                    _bgmPath == null ? 'BGM သီချင်း (မထည့်လည်းရသည်)' : '🎵 ${_bgmPath!.split('/').last}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  value: _minutesPerPart,
                  decoration: const InputDecoration(labelText: 'အပိုင်းခွဲမည့် အရှည်', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 3, child: Text('၃ မိနစ်စီ ခွဲမယ် (မြန် / Limit သက်သာ)')),
                    DropdownMenuItem(value: 5, child: Text('၅ မိနစ်စီ ခွဲမယ်')),
                    DropdownMenuItem(value: 8, child: Text('၈ မိနစ်စီ ခွဲမယ်')),
                  ],
                  onChanged: _isGeneratingAll ? null : (v) => setState(() => _minutesPerPart = v ?? 3),
                ),
              ],
            ),

            _buildCard(
              title: _workMode == 'recap'
                  ? '၂။ Copyright-Safe Edit (Zero-Drift + 6s/3s Freeze)'
                  : '၂။ Video Edit (Mirror + Blur + Subtitle + Smart Sync)',
              icon: Icons.shield_rounded,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('ဗီဒီယို ဘယ်/ညာ လှည့်မယ် (Mirror)', style: TextStyle(fontSize: 13)),
                  value: _enableMirror,
                  onChanged: (v) => setState(() => _enableMirror = v),
                ),
                if (_workMode == 'recap') ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Max 6s Play + 3s Freeze/Zoom ဖွင့်မယ်', style: TextStyle(fontSize: 13)),
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
              title: '၃။ Edge TTS နှင့် Output Resolution',
              icon: Icons.record_voice_over_rounded,
              children: [
                DropdownButtonFormField<String>(
                  value: _voice,
                  decoration: const InputDecoration(labelText: 'အသံရွေးပါ', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'my-MM-NilarNeural', child: Text('Nilar (အမျိုးသမီး)')),
                    DropdownMenuItem(value: 'my-MM-ThihaNeural', child: Text('Thiha (အမျိုးသား)')),
                  ],
                  onChanged: (v) => setState(() => _voice = v ?? 'my-MM-NilarNeural'),
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
                  decoration: const InputDecoration(labelText: 'Render ထုတ်မည့် Resolution', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: '720p', child: Text('720p HD (မြန် / CPU သက်သာ)')),
                    DropdownMenuItem(value: '1080p', child: Text('1080p Full HD')),
                  ],
                  onChanged: (v) => setState(() => _resolution = v ?? '720p'),
                ),
              ],
            ),

            if (_isGeneratingAll) ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF7C4DFF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: null,
                      icon: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                      label: Text(
                        _cooldownSec > 0
                            ? '⏳ ခဏနားနေသည် (${_cooldownSec}s)...'
                            : (_workMode == 'groq_only'
                                ? 'Groq ဖြင့် Script ထုတ်နေသည်...'
                                : _workMode == 'dubbing'
                                    ? 'Groq + Gemini ဘာသာပြန်နေသည်...'
                                    : 'Gemini ဗီဒီယိုကြည့်ပြီး Script ထုတ်နေသည်...'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                    ),
                    onPressed: () => setState(() => _stopRequested = true),
                    child: const Text('⏹️ ရပ်'),
                  ),
                ],
              ),
            ] else if (hasUnfinishedParts) ...[
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orangeAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => _startOrResumeAutoProcess(freshStart: false),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('▶️ ရပ်ထားတဲ့အပိုင်းကနေ ဆက်ထုတ်မယ်', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ] else ...[
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C4DFF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => _startOrResumeAutoProcess(freshStart: true),
                icon: const Icon(Icons.auto_awesome),
                label: Text(
                  _workMode == 'groq_only'
                      ? '⚡ ၁။ Groq ဖြင့် အပိုင်းအလိုက် Script ထုတ်မယ် (Limit မထိ)'
                      : _workMode == 'dubbing'
                          ? '⚡ ၁။ Groq အသံထုတ်ပြီး Gemini ဖြင့် ဘာသာပြန်မယ်'
                          : '⚡ ၁။ ဗီဒီယိုခွဲပြီး Gemini ဖြင့် Script ထုတ်မယ်',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],

            if (_parts.isNotEmpty) ...[
              const SizedBox(height: 14),
              _buildCard(
                title: '၄။ အပိုင်းအလိုက် Script ပြင်ပြီး Render ထုတ်ပါ (${_parts.length} ပိုင်း • Scroll)',
                icon: Icons.playlist_play_rounded,
                children: [
                  Container(
                    height: 300,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1016),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF262A38)),
                    ),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: ListView.builder(
                        itemCount: _parts.length,
                        itemBuilder: (context, i) {
                          final item = _parts[i];
                          final isEditing = _editingPartIndex == i;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: isEditing ? const Color(0xFF1C2333) : const Color(0xFF141720),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isEditing
                                    ? Colors.amberAccent
                                    : item.outputPath != null
                                        ? Colors.greenAccent.withOpacity(0.5)
                                        : item.status == 'error'
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
                                        'Part ${item.partNumber} (${_formatSecRange(item.startSec, item.durSec)})',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                      ),
                                      const SizedBox(height: 2),
                                      if (item.status == 'pending')
                                        const Text('⏳ စောင့်ဆိုင်းနေသည်...', style: TextStyle(fontSize: 11, color: Colors.white54))
                                      else if (item.status == 'generating')
                                        Text(
                                          _workMode == 'groq_only'
                                              ? '⚡ Groq Script ထုတ်နေသည်...'
                                              : _workMode == 'dubbing'
                                                  ? '🎙️ Groq + Gemini ဘာသာပြန်နေသည်...'
                                                  : '👀 Gemini ဗီဒီယိုကြည့်ပြီး Script ရေးနေသည်...',
                                          style: const TextStyle(fontSize: 11, color: Colors.amberAccent),
                                        )
                                      else if (item.status == 'error')
                                        const Text('❌ မအောင်မြင်ပါ (Retry နှိပ်ပါ)', style: TextStyle(fontSize: 11, color: Colors.redAccent))
                                      else if (item.outputPath != null)
                                        const Text('✅ ဗီဒီယိုထုတ်ပြီး (Gallery ထဲသိမ်းပြီး)', style: TextStyle(fontSize: 11, color: Colors.greenAccent))
                                      else
                                        Text('🟢 Script ရပြီ (${item.alignedSegments?.length ?? 0} ကြောင်း) • ✏️ နှိပ်ပြီး ဘာသာပြန်/ပြင်ပါ', style: const TextStyle(fontSize: 11, color: Colors.lightBlueAccent)),
                                    ],
                                  ),
                                ),
                                if (item.status == 'ready')
                                  IconButton(
                                    tooltip: 'Script ဖွင့်/ပြင်မယ်',
                                    icon: Icon(
                                      Icons.edit_note_rounded,
                                      color: isEditing ? Colors.amberAccent : Colors.lightBlueAccent,
                                      size: 26,
                                    ),
                                    onPressed: () => _openScriptEditor(i),
                                  ),
                                if (item.outputPath != null)
                                  IconButton(
                                    tooltip: 'ဗီဒီယိုကြည့်မယ်',
                                    icon: const Icon(Icons.play_circle_fill, color: Colors.amberAccent, size: 28),
                                    onPressed: () => _watchRenderedVideo(item.outputPath!, 'Part ${item.partNumber} Render Video'),
                                  ),
                                if (item.status == 'error')
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent, foregroundColor: Colors.black),
                                    onPressed: _isGeneratingAll ? null : () => _retryPart(i),
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('Retry', style: TextStyle(fontSize: 12)),
                                  )
                                else if (item.status == 'ready')
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: item.outputPath != null ? Colors.green : Colors.blueAccent,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                        },
                      ),
                    ),
                  ),
                  if (completedCount >= 2) ...[
                    const SizedBox(height: 10),
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
                  if (_mergedOutputPath != null) ...[
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amberAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => _watchRenderedVideo(_mergedOutputPath!, 'YouTube Long Video (Merged)'),
                      icon: const Icon(Icons.play_circle_filled),
                      label: const Text('▶️ ပေါင်းပြီးသား ဗီဒီယိုကို အခုကြည့်မယ်', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ],
              ),
            ],

            // Scrollable Editable Script Box + Copy Prompt & Paste
            if (_editingPartIndex != null && _editingPartIndex! < _parts.length) ...[
              _buildCard(
                title: '✏️ Part ${_parts[_editingPartIndex!].partNumber} Script (Copy ကူးပြီး ဘာသာပြန် → Paste ပြန်ထည့်ပါ)',
                icon: Icons.edit_document,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _copyScriptWithPrompt,
                          icon: const Icon(Icons.copy_all_rounded, size: 16, color: Colors.lightBlueAccent),
                          label: const Text('📋 Prompt ပါ Copy', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pasteScriptFromClipboard,
                          icon: const Icon(Icons.content_paste_rounded, size: 16, color: Colors.greenAccent),
                          label: const Text('📥 Paste ထည့်မယ်', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 230,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1016),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amberAccent.withOpacity(0.6)),
                    ),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: TextField(
                        controller: _scriptEditCtrl,
                        maxLines: null,
                        expands: true,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(fontSize: 12.5, height: 1.5, color: Colors.white),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: '[0.00-3.20] မြန်မာစာတန်း...',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amberAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    onPressed: _saveEditedScript,
                    icon: const Icon(Icons.save_alt_rounded, size: 18),
                    label: Text(
                      '💾 Part ${_parts[_editingPartIndex!].partNumber} ဘာသာပြန် Script သိမ်းမယ် (Save)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ],

            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 4),
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

class _RenderedVideoDialog extends StatefulWidget {
  final String videoPath;
  final String title;

  const _RenderedVideoDialog({required this.videoPath, required this.title});

  @override
  State<_RenderedVideoDialog> createState() => _RenderedVideoDialogState();
}

class _RenderedVideoDialogState extends State<_RenderedVideoDialog> {
  late VideoPlayerController _ctrl;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _ready = true);
          _ctrl.play();
        }
      });
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final durMs = _ctrl.value.duration.inMilliseconds.toDouble();
    final posMs = _ctrl.value.position.inMilliseconds.toDouble().clamp(0.0, durMs > 0 ? durMs : 1.0);

    return Dialog(
      backgroundColor: const Color(0xFF141720),
      insetPadding: const EdgeInsets.all(14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (!_ready)
              const Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              )
            else ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: AspectRatio(
                  aspectRatio: _ctrl.value.aspectRatio > 0 ? _ctrl.value.aspectRatio : (16 / 9),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: VideoPlayer(_ctrl),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _ctrl.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                      color: Colors.amberAccent,
                      size: 34,
                    ),
                    onPressed: () => setState(() => _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play()),
                  ),
                  Text(_fmt(_ctrl.value.position), style: const TextStyle(fontSize: 11, color: Colors.white70)),
                  Expanded(
                    child: Slider(
                      value: posMs,
                      min: 0.0,
                      max: durMs > 0 ? durMs : 1.0,
                      onChanged: (v) => _ctrl.seekTo(Duration(milliseconds: v.round())),
                    ),
                  ),
                  Text(_fmt(_ctrl.value.duration), style: const TextStyle(fontSize: 11, color: Colors.white70)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
