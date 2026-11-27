import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../helpers/automix/automix_analysis.dart';
import '../helpers/automix/automix_plan.dart';
import '../helpers/automix/automix_renderer.dart';
import '../helpers/separation/audio_io.dart';
import '../models/unmixed_song.dart';
import '../providers/library_provider.dart';
import '../utils.dart';

enum AutoMixStage { pick, working, done }

class AutoMixResult {
  AutoMixResult({
    required this.plan,
    required this.title,
    required this.files,
  });

  final AutoMixPlan plan;
  final String title;

  /// Paths by name: drums, bass, other, vocals, mixture.
  Map<String, String> files;
  bool saved = false;
}

/// State for the AutoMix screen: song choice, the run, and the result.
class AutoMixProvider extends ChangeNotifier {
  UnmixedSong? outgoing;
  UnmixedSong? incoming;
  bool waitForVocalGaps = true;

  AutoMixStage stage = AutoMixStage.pick;
  int step = 0;
  double renderProgress = 0;
  String? error;
  AutoMixResult? result;

  int _run = 0;
  Directory? _workDir;

  bool get canStart => outgoing != null && incoming != null;

  void setOutgoing(UnmixedSong song) {
    outgoing = song;
    error = null;
    notifyListeners();
  }

  void setIncoming(UnmixedSong song) {
    incoming = song;
    error = null;
    notifyListeners();
  }

  void swap() {
    final a = outgoing;
    outgoing = incoming;
    incoming = a;
    error = null;
    notifyListeners();
  }

  void setWaitForVocalGaps(bool value) {
    waitForVocalGaps = value;
    notifyListeners();
  }

  Future<void> start() async {
    final a = outgoing;
    final b = incoming;
    if (a == null || b == null) return;

    await _cleanup();
    final run = ++_run;
    bool cancelled() => run != _run;

    stage = AutoMixStage.working;
    step = 0;
    renderProgress = 0;
    error = null;
    notifyListeners();

    try {
      final drumsA = (await decodeToFloatPcm(
        a.drums,
        sampleRate: analysisRate,
        channels: 1,
      )).first;
      if (cancelled()) return;
      final beatsA = await compute(analyzeBeats, drumsA);

      final drumsB = (await decodeToFloatPcm(
        b.drums,
        sampleRate: analysisRate,
        channels: 1,
      )).first;
      if (cancelled()) return;
      final beatsB = await compute(analyzeBeats, drumsB);

      if (beatsA.isEmpty) {
        throw AutoMixException('Could not find a steady beat in “${a.title}”.');
      }
      if (beatsB.isEmpty) {
        throw AutoMixException('Could not find a steady beat in “${b.title}”.');
      }

      step = 1;
      notifyListeners();

      final outLength = drumsA.length / analysisRate;
      final inLength = drumsB.length / analysisRate;
      AutoMixPlan build(double? gap) => AutoMixPlan.create(
        outBpm: beatsA['bpm']!,
        outDownbeat: beatsA['downbeat']!,
        outDuration: outLength,
        inBpm: beatsB['bpm']!,
        inDownbeat: beatsB['downbeat']!,
        inDuration: inLength,
        vocalGap: gap,
      );

      var plan = build(null);
      if (waitForVocalGaps) {
        final vocalsA = (await decodeToFloatPcm(
          a.vocals,
          sampleRate: analysisRate,
          channels: 1,
        )).first;
        if (cancelled()) return;
        final gap = findVocalGap(
          vocalsA,
          from: plan.exitTime + plan.blend * 0.25,
          to: plan.exitTime + plan.blend * 0.9,
        );
        if (gap != null) plan = build(gap);
      }

      step = 2;
      notifyListeners();

      final dir = Directory(
        p.join(
          await getAppTemp(),
          'automix_${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      await dir.create(recursive: true);
      _workDir = dir;

      final files = await AutoMixRenderer().render(
        outgoing: a,
        incoming: b,
        plan: plan,
        outDir: dir.path,
        isCancelled: cancelled,
        onDone: (done) {
          if (cancelled()) return;
          renderProgress = done / 5;
          step = done >= 4 ? 3 : 2;
          notifyListeners();
        },
      );
      if (cancelled()) return;

      result = AutoMixResult(
        plan: plan,
        title: '${a.title} → ${b.title}',
        files: files,
      );
      stage = AutoMixStage.done;
      notifyListeners();
    } on AutoMixException catch (e) {
      if (cancelled()) return;
      _fail(e.message);
    } catch (e) {
      debugPrint('AutoMix failed: $e');
      if (cancelled()) return;
      _fail('Something went wrong while making the transition.');
    }
  }

  void _fail(String message) {
    error = message;
    stage = AutoMixStage.pick;
    notifyListeners();
  }

  Future<void> cancel() async {
    _run++;
    stage = AutoMixStage.pick;
    notifyListeners();
    await _cleanup();
  }

  /// Back to song choice; unsaved render files are deleted.
  Future<void> reset() async {
    _run++;
    stage = AutoMixStage.pick;
    error = null;
    notifyListeners();
    await _cleanup();
  }

  Future<void> saveToLibrary(LibraryProvider library) async {
    final r = result;
    final a = outgoing;
    final b = incoming;
    if (r == null || a == null || b == null || r.saved) return;
    final f = r.files;
    // No cover on purpose: saving moves the cover file into the new song's
    // folder, which would take it away from the original song.
    final song = UnmixedSong(
      title: r.title,
      artists: {...a.artists, ...b.artists}.toList(),
      duration: Duration(milliseconds: (r.plan.total * 1000).round()),
      mixture: f['mixture']!,
      vocals: f['vocals']!,
      bass: f['bass']!,
      drums: f['drums']!,
      other: f['other']!,
      modelName: a.modelName,
    );
    await library.saveSong(song);
    r.files = {
      'mixture': song.mixture,
      'vocals': song.vocals,
      'bass': song.bass,
      'drums': song.drums,
      'other': song.other,
    };
    r.saved = true;
    _workDir = null; // files now belong to the library
    notifyListeners();
  }

  Future<void> _cleanup() async {
    final dir = _workDir;
    _workDir = null;
    result = null;
    if (dir != null) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
  }
}
