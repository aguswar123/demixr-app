import 'dart:math' as math;
import 'dart:typed_data';

/// Sample rate (mono) the analysis functions expect.
const int analysisRate = 11025;
const int _hop = 256;
const int _win = 512;
const double _fps = analysisRate / _hop;

/// Estimates tempo and the first bar start from a mono drums stem.
///
/// Returns `{'bpm': .., 'downbeat': ..}` (seconds), or an empty map when no
/// steady beat is found. Top-level so it can run through `compute`.
Map<String, double> analyzeBeats(Float32List drums) {
  final env = _onsetEnvelope(drums);
  if (env.length < 200) return {};

  var mean = 0.0;
  for (final v in env) {
    mean += v;
  }
  mean /= env.length;
  if (mean <= 1e-9) return {};

  final coarse = _search(env, 70, 180, 0.25, 0.5, usePrior: true);
  final fine = _search(
    env,
    coarse.bpm - 0.5,
    coarse.bpm + 0.5,
    0.02,
    0.25,
    usePrior: false,
  );
  if (fine.score / mean < 1.3) return {};

  final period = 60.0 * _fps / fine.bpm;
  final sums = List<double>.filled(4, 0);
  final counts = List<int>.filled(4, 0);
  var k = 0;
  for (var t = fine.phase; t < env.length - 1; t += period) {
    final i = t.round();
    var v = env[i];
    if (i > 0) v = math.max(v, env[i - 1]);
    if (i + 1 < env.length) v = math.max(v, env[i + 1]);
    sums[k % 4] += v;
    counts[k % 4]++;
    k++;
  }
  var bar = 0;
  var bestMean = -1.0;
  for (var o = 0; o < 4; o++) {
    final m = counts[o] == 0 ? 0.0 : sums[o] / counts[o];
    if (m > bestMean) {
      bestMean = m;
      bar = o;
    }
  }
  final frame = fine.phase + bar * period;
  return {
    'bpm': fine.bpm,
    'downbeat': (frame * _hop + _win - _hop / 2) / analysisRate,
  };
}

/// Start time (seconds) of the first silence of at least [minGap] seconds
/// between [from] and [to] in a mono vocals stem, or null if there is none.
double? findVocalGap(
  Float32List vocals, {
  required double from,
  required double to,
  double minGap = 0.4,
}) {
  const frameSeconds = 0.05;
  final n = (frameSeconds * analysisRate).round();
  final frames = vocals.length ~/ n;
  if (frames < 20) return null;

  final db = Float64List(frames);
  for (var i = 0; i < frames; i++) {
    var e = 0.0;
    for (var k = 0; k < n; k++) {
      final v = vocals[i * n + k];
      e += v * v;
    }
    db[i] = 20 * math.log(math.sqrt(e / n) + 1e-9) / math.ln10;
  }
  final sorted = db.toList()..sort();
  final ref = sorted[(frames * 0.9).floor().clamp(0, frames - 1).toInt()];
  if (ref < -50) return null; // essentially no vocals
  final threshold = ref - 25;
  final need = (minGap / frameSeconds).ceil();

  final a = (from / frameSeconds).floor().clamp(0, frames - 1).toInt();
  final b = (to / frameSeconds).ceil().clamp(0, frames).toInt();
  var run = 0;
  for (var i = a; i < b; i++) {
    if (db[i] < threshold) {
      run++;
      if (run >= need) return (i - run + 1) * frameSeconds;
    } else {
      run = 0;
    }
  }
  return null;
}

Float64List _onsetEnvelope(Float32List x) {
  final n = (x.length - _win) ~/ _hop;
  if (n <= 0) return Float64List(0);
  final env = Float64List(n);
  var prev = 0.0;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = i * _hop;
    var e = 0.0;
    for (var k = 0; k < _win; k++) {
      final v = x[s + k];
      e += v * v;
    }
    final level = math.log(1.0 + 1000.0 * math.sqrt(e / _win));
    final d = level - prev;
    prev = level;
    env[i] = d > 0 ? d : 0;
    sum += env[i];
  }
  final mean = sum / n;
  for (var i = 0; i < n; i++) {
    env[i] = math.max(0.0, env[i] - mean);
  }
  return env;
}

double _comb(Float64List env, double period, double phase) {
  var s = 0.0;
  var c = 0;
  final last = env.length - 1;
  for (var t = phase; t < last; t += period) {
    s += env[t.round()];
    c++;
  }
  return c == 0 ? 0 : s / c;
}

({double bpm, double phase, double score}) _search(
  Float64List env,
  double lo,
  double hi,
  double step,
  double phaseStep, {
  required bool usePrior,
}) {
  var best = (bpm: lo, phase: 0.0, score: -1.0);
  for (var bpm = lo; bpm <= hi; bpm += step) {
    final period = 60.0 * _fps / bpm;
    final octaves = math.log(bpm / 120.0) / math.ln2;
    final weight = usePrior ? math.exp(-0.5 * octaves * octaves / 0.36) : 1.0;
    for (var ph = 0.0; ph < period; ph += phaseStep) {
      final s = _comb(env, period, ph) * weight;
      if (s > best.score) best = (bpm: bpm, phase: ph, score: s);
    }
  }
  return best;
}
