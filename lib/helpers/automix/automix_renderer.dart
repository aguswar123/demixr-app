import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path/path.dart' as p;

import '../../constants.dart';
import '../../models/unmixed_song.dart';
import 'automix_plan.dart';

/// Renders an [AutoMixPlan] with one FFmpeg filter graph per stem.
class AutoMixRenderer {
  static const stemNames = ['drums', 'bass', 'other', 'vocals'];
  static const _stems = {
    'drums': Stem.drums,
    'bass': Stem.bass,
    'other': Stem.other,
    'vocals': Stem.vocals,
  };

  /// Writes `drums/bass/other/vocals/mixture.wav` into [outDir] and returns
  /// their paths by name. [onDone] gets the number of files finished so far.
  Future<Map<String, String>> render({
    required UnmixedSong outgoing,
    required UnmixedSong incoming,
    required AutoMixPlan plan,
    required String outDir,
    required void Function(int done) onDone,
    required bool Function() isCancelled,
  }) async {
    final files = <String, String>{};
    for (var i = 0; i < stemNames.length; i++) {
      if (isCancelled()) return files;
      final name = stemNames[i];
      final stem = _stems[name]!;
      final dest = p.join(outDir, '$name.wav');
      await _run(
        '-i ${_q(outgoing.getStem(stem))} -i ${_q(incoming.getStem(stem))} '
        '-filter_complex ${_q(_stemFilter(plan, name))} '
        '-map "[out]" -c:a pcm_s16le -ar 44100 -y ${_q(dest)}',
      );
      files[name] = dest;
      onDone(i + 1);
    }
    if (isCancelled()) return files;

    final mixture = p.join(outDir, 'mixture.wav');
    final inputs = stemNames.map((n) => '-i ${_q(files[n]!)}').join(' ');
    await _run(
      '$inputs -filter_complex '
      '${_q('[0:a][1:a][2:a][3:a]amix=inputs=4:normalize=0:dropout_transition=0,alimiter=limit=0.97[out]')} '
      '-map "[out]" -c:a pcm_s16le -ar 44100 -y ${_q(mixture)}',
    );
    files['mixture'] = mixture;
    onDone(stemNames.length + 1);
    return files;
  }

  String _stemFilter(AutoMixPlan plan, String name) {
    final total = plan.total;
    final parts = <String>[];

    // Outgoing: cut from the lead-in, apply gain, pad to the full length.
    final outGain = gainExpression(plan.outgoingCurves[name]!);
    parts.add(
      '[0:a]atrim=start=${_f(plan.exitTime - plan.lead)}:duration=${_f(total)},'
      "asetpts=PTS-STARTPTS,volume='$outGain':eval=frame,"
      'apad,atrim=end=${_f(total)}[o]',
    );

    // Incoming: hold at the matched speed, ease back to 1.0 in small steps.
    final chunks = <List<double>>[]; // [source start, source length, speed]
    var src = plan.entryTime;
    chunks.add([src, plan.hold * plan.startSpeed, plan.startSpeed]);
    src += plan.hold * plan.startSpeed;
    final step = plan.ramp / AutoMixPlan.rampChunks;
    for (var k = 0; k < AutoMixPlan.rampChunks; k++) {
      final speed =
          plan.startSpeed +
          (1.0 - plan.startSpeed) * (k + 0.5) / AutoMixPlan.rampChunks;
      chunks.add([src, speed * step, speed]);
      src += speed * step;
    }
    chunks.add([src, plan.tailSegment, 1.0]);

    final n = chunks.length;
    final splitLabels = List.generate(n, (i) => '[s$i]').join();
    parts.add('[1:a]asplit=$n$splitLabels');
    for (var i = 0; i < n; i++) {
      final c = chunks[i];
      final tempo = (c[2] - 1.0).abs() < 1e-6 ? '' : ',atempo=${_f(c[2])}';
      parts.add(
        '[s$i]atrim=start=${_f(c[0])}:duration=${_f(c[1])},'
        'asetpts=PTS-STARTPTS$tempo[c$i]',
      );
    }
    final cLabels = List.generate(n, (i) => '[c$i]').join();
    final delay = (plan.lead * 1000).round();
    final inGain = gainExpression(plan.incomingCurves[name]!);
    parts.add(
      '${cLabels}concat=n=$n:v=0:a=1[inraw]',
    );
    parts.add(
      '[inraw]adelay=$delay|$delay,'
      "volume='$inGain':eval=frame,apad,atrim=end=${_f(total)}[i]",
    );

    parts.add(
      '[o][i]amix=inputs=2:normalize=0:dropout_transition=0,'
      'alimiter=limit=0.97[out]',
    );
    return parts.join(';');
  }

  /// FFmpeg `volume` expression for a piecewise-linear gain curve.
  static String gainExpression(GainCurve pts) {
    var expr = _f(pts.last[1]);
    for (var i = pts.length - 2; i >= 0; i--) {
      final t0 = pts[i][0];
      final g0 = pts[i][1];
      final t1 = pts[i + 1][0];
      final g1 = pts[i + 1][1];
      final span = math.max(t1 - t0, 0.001);
      expr =
          'if(lt(t,${_f(t1)}),${_f(g0)}+(${_f(g1 - g0)})*(t-${_f(t0)})/${_f(span)},$expr)';
    }
    return 'if(lt(t,${_f(pts.first[0])}),${_f(pts.first[1])},$expr)';
  }

  Future<void> _run(String command) async {
    final session = await FFmpegKit.execute(command);
    final code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      throw AutoMixException('Could not render the transition.');
    }
  }

  static String _f(double v) => v.toStringAsFixed(4);

  String _q(String value) => '"${value.replaceAll('"', '\\"')}"';
}
