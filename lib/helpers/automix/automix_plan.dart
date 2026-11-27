import 'dart:math' as math;

/// Gain breakpoints for one stem: `[seconds, gain]` pairs, linear in between.
typedef GainCurve = List<List<double>>;

class AutoMixException implements Exception {
  AutoMixException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where and how two songs are blended. All times are in seconds.
///
/// Output timeline: `lead` seconds of the outgoing song alone, then the
/// 32-beat `blend`, then `tail` seconds of the incoming song alone.
class AutoMixPlan {
  AutoMixPlan._({
    required this.outBpm,
    required this.inBpm,
    required this.beat,
    required this.exitTime,
    required this.entryTime,
    required this.lead,
    required this.blend,
    required this.tail,
    required this.hold,
    required this.ramp,
    required this.startSpeed,
    required this.vocalOutAt,
    required this.vocalOutFade,
    required this.vocalInAt,
    required this.usedVocalGap,
  });

  static const int rampChunks = 8;

  final double outBpm;
  final double inBpm;
  final double beat;

  /// Outgoing source time that maps to the start of the blend.
  final double exitTime;

  /// Incoming source time that maps to the start of the blend.
  final double entryTime;
  final double lead;
  final double blend;
  final double tail;

  /// Seconds the incoming song plays at [startSpeed] before easing back.
  final double hold;

  /// Seconds it takes the incoming song to return to normal speed.
  final double ramp;
  final double startSpeed;

  /// Blend-relative times (seconds after the blend starts).
  final double vocalOutAt;
  final double vocalOutFade;
  final double vocalInAt;
  final bool usedVocalGap;

  double get total => lead + blend + tail;
  double get tailSegment => blend + tail - hold - ramp;

  factory AutoMixPlan.create({
    required double outBpm,
    required double outDownbeat,
    required double outDuration,
    required double inBpm,
    required double inDownbeat,
    required double inDuration,
    double? vocalGap,
  }) {
    final beat = 60.0 / outBpm;
    final bar = beat * 4;
    final blend = beat * 32;
    final tail = beat * 16;

    final lastStart = outDuration - 0.5 - blend;
    if (lastStart < outDownbeat) {
      throw AutoMixException(
        'The outgoing song is too short for a 32-beat transition.',
      );
    }
    final exit = outDownbeat + ((lastStart - outDownbeat) / bar).floor() * bar;
    final lead = math.min(beat * 8, exit);

    var speed = outBpm / inBpm;
    while (speed > 1.41) {
      speed /= 2;
    }
    while (speed < 0.71) {
      speed *= 2;
    }
    speed = speed.clamp(0.6, 1.6).toDouble();

    final hold = beat * 16;
    final ramp = math.min(6.48, blend + tail - hold - 1.0);
    final tailSegment = blend + tail - hold - ramp;
    final needed = hold * speed + ramp * math.max(speed, 1.0) + tailSegment;
    if (inDuration - inDownbeat < needed) {
      throw AutoMixException('The incoming song is too short to blend into.');
    }

    final double outAt;
    final double outFade;
    if (vocalGap != null) {
      outAt = (vocalGap - exit).clamp(blend * 0.25, blend * 0.9).toDouble();
      outFade = 0.15;
    } else {
      outAt = blend * 0.5;
      outFade = 0.8;
    }
    var inAt = math.max(outAt + 0.1, hold + ramp);
    inAt = (inAt / bar).ceil() * bar;
    inAt = math.min(inAt, blend + tail - 2.0);

    return AutoMixPlan._(
      outBpm: outBpm,
      inBpm: inBpm,
      beat: beat,
      exitTime: exit,
      entryTime: inDownbeat,
      lead: lead,
      blend: blend,
      tail: tail,
      hold: hold,
      ramp: ramp,
      startSpeed: speed,
      vocalOutAt: outAt,
      vocalOutFade: outFade,
      vocalInAt: inAt,
      usedVocalGap: vocalGap != null,
    );
  }

  /// Gain of each outgoing stem over the output timeline.
  Map<String, GainCurve> get outgoingCurves => {
    'drums': [
      [0, 1],
      [lead + blend * 0.5, 1],
      [lead + blend, 0],
    ],
    'bass': [
      [0, 1],
      [lead + blend * 0.5, 1],
      [lead + blend * 0.5 + beat * 2, 0],
    ],
    'other': [
      [0, 1],
      [lead + blend * 0.25, 1],
      [lead + blend, 0],
    ],
    'vocals': [
      [0, 1],
      [lead + vocalOutAt, 1],
      [lead + vocalOutAt + vocalOutFade, 0],
    ],
  };

  /// Gain of each incoming stem over the output timeline.
  Map<String, GainCurve> get incomingCurves => {
    'drums': [
      [0, 0],
      [lead, 0],
      [lead + blend * 0.5, 1],
    ],
    'bass': [
      [0, 0],
      [lead + blend * 0.5, 0],
      [lead + blend * 0.5 + beat * 2, 1],
    ],
    'other': [
      [0, 0],
      [lead + blend * 0.25, 0],
      [lead + blend * 0.75, 1],
    ],
    'vocals': [
      [0, 0],
      [lead + vocalInAt, 0],
      [lead + vocalInAt + 0.4, 1],
    ],
  };

  static double gainAt(GainCurve curve, double t) {
    if (t <= curve.first[0]) return curve.first[1];
    for (var i = 0; i < curve.length - 1; i++) {
      final a = curve[i];
      final b = curve[i + 1];
      if (t < b[0]) {
        final span = b[0] - a[0];
        if (span <= 0) return b[1];
        return a[1] + (b[1] - a[1]) * (t - a[0]) / span;
      }
    }
    return curve.last[1];
  }
}
