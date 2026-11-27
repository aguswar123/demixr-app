import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../components/buttons.dart';
import '../../components/navbar.dart';
import '../../constants.dart';
import '../../helpers/automix/automix_plan.dart';
import '../../models/unmixed_song.dart';
import '../../providers/automix_provider.dart';
import '../../providers/library_provider.dart';
import '../../services/song_export_service.dart';
import '../../utils.dart';

class AutoMixScreen extends StatelessWidget {
  const AutoMixScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Consumer<AutoMixProvider>(
                builder: (context, auto, _) {
                  switch (auto.stage) {
                    case AutoMixStage.pick:
                      return _PickView(auto: auto);
                    case AutoMixStage.working:
                      return _WorkingView(auto: auto);
                    case AutoMixStage.done:
                      return _ResultView(
                        key: ValueKey(auto.result),
                        auto: auto,
                      );
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _muted = TextStyle(color: ColorPalette.onSurfaceVariant, fontSize: 13);

Widget _cover(String? path) {
  final file = path == null ? null : File(path);
  return ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(
      width: 56,
      height: 56,
      child: file != null && file.existsSync()
          ? Image.file(file, fit: BoxFit.cover)
          : Container(
              color: ColorPalette.surfaceVariant,
              child: const Icon(
                Icons.music_note_rounded,
                color: ColorPalette.onSurfaceVariant,
              ),
            ),
    ),
  );
}

class _PickView extends StatelessWidget {
  const _PickView({required this.auto});
  final AutoMixProvider auto;

  Future<void> _pick(BuildContext context, {required bool outgoing}) async {
    final songs = context.read<LibraryProvider>().songList;
    final other = outgoing ? auto.incoming : auto.outgoing;
    if (songs.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unmix at least two songs first.')),
      );
      return;
    }
    final picked = await showModalBottomSheet<UnmixedSong>(
      context: context,
      backgroundColor: ColorPalette.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheet).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    outgoing ? 'Outgoing song' : 'Incoming song',
                    style: Theme.of(sheet).textTheme.titleLarge,
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in songs.reversed)
                      ListTile(
                        enabled: !identical(s, other),
                        leading: _cover(s.coverPath),
                        title: Text(s.title, maxLines: 1),
                        subtitle: Text(s.artists.join(', '), maxLines: 1),
                        onTap: () => Navigator.pop(sheet, s),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    outgoing ? auto.setOutgoing(picked) : auto.setIncoming(picked);
  }

  @override
  Widget build(BuildContext context) {
    final texts = Theme.of(context).textTheme;
    final ready = auto.canStart;
    return ListView(
      children: [
        const Align(alignment: Alignment.centerLeft, child: NavBar()),
        const SizedBox(height: 16),
        Text('AutoMix', style: texts.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Pick two songs from your library. They will blend like a DJ '
          'transition, matched to the beat.',
          style: texts.bodyLarge,
        ),
        const SizedBox(height: 20),
        _SongSlot(
          label: 'Outgoing song',
          song: auto.outgoing,
          onTap: () => _pick(context, outgoing: true),
        ),
        Center(
          child: IconButton(
            tooltip: 'Swap songs',
            onPressed: auto.swap,
            icon: const Icon(Icons.swap_vert_rounded),
          ),
        ),
        _SongSlot(
          label: 'Incoming song',
          song: auto.incoming,
          onTap: () => _pick(context, outgoing: false),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          decoration: BoxDecoration(
            color: ColorPalette.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: ColorPalette.outline),
          ),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Wait for vocal gaps'),
                    SizedBox(height: 2),
                    Text(
                      'Keeps lyrics from being cut off mid-line',
                      style: _muted,
                    ),
                  ],
                ),
              ),
              Switch(
                value: auto.waitForVocalGaps,
                onChanged: auto.setWaitForVocalGaps,
              ),
            ],
          ),
        ),
        if (auto.error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: ColorPalette.errorContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              auto.error!,
              style: const TextStyle(color: ColorPalette.onError),
            ),
          ),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: Button(
            'Make transition',
            textSize: 16,
            radius: 28,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            color: ready
                ? ColorPalette.primary
                : ColorPalette.surfaceContainerHigh,
            textColor: ready
                ? ColorPalette.onPrimary
                : ColorPalette.onSurfaceVariant,
            onPressed: ready ? auto.start : null,
          ),
        ),
      ],
    );
  }
}

class _SongSlot extends StatelessWidget {
  const _SongSlot({
    required this.label,
    required this.song,
    required this.onTap,
  });

  final String label;
  final UnmixedSong? song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = song;
    final radius = BorderRadius.circular(20);
    return Material(
      color: ColorPalette.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: s == null ? ColorPalette.outline : ColorPalette.primary,
        ),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _cover(s?.coverPath),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: _muted),
                    const SizedBox(height: 2),
                    Text(
                      s?.title ?? 'Choose a song',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s == null
                          ? 'Tap to pick from your library'
                          : '${s.artists.join(', ')} · ${s.duration.formatMinSec()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _muted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkingView extends StatelessWidget {
  const _WorkingView({required this.auto});
  final AutoMixProvider auto;

  static const _steps = [
    'Finding the beat',
    'Choosing transition points',
    'Matching tempo',
    'Rendering the mix',
  ];

  @override
  Widget build(BuildContext context) {
    final texts = Theme.of(context).textTheme;
    return ListView(
      children: [
        const SizedBox(height: 56),
        Text('Mixing…', style: texts.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'This can take a minute. Keep the app open.',
          style: texts.bodyLarge,
        ),
        const SizedBox(height: 28),
        for (var i = 0; i < _steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                Icon(
                  i < auto.step
                      ? Icons.check_circle_rounded
                      : i == auto.step
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: i <= auto.step
                      ? ColorPalette.primary
                      : ColorPalette.outline,
                ),
                const SizedBox(width: 12),
                Text(
                  _steps[i],
                  style: TextStyle(
                    fontSize: 16,
                    color: i <= auto.step
                        ? ColorPalette.onSurface
                        : ColorPalette.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 8,
            value: auto.step < 2 ? null : auto.renderProgress,
            color: ColorPalette.primary,
            backgroundColor: ColorPalette.surfaceVariant,
          ),
        ),
        const SizedBox(height: 28),
        OutlinedButton(onPressed: auto.cancel, child: const Text('Cancel')),
      ],
    );
  }
}

class _ResultView extends StatefulWidget {
  const _ResultView({super.key, required this.auto});
  final AutoMixProvider auto;

  @override
  State<_ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<_ResultView> {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  Duration _pos = Duration.zero;
  bool _playing = false;

  AutoMixResult get _result => widget.auto.result!;
  Duration get _total =>
      Duration(milliseconds: (_result.plan.total * 1000).round());

  @override
  void initState() {
    super.initState();
    _subs.add(
      _player.onPositionChanged.listen((p) {
        if (mounted) setState(() => _pos = p);
      }),
    );
    _subs.add(
      _player.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _playing = s == PlayerState.playing);
      }),
    );
    _subs.add(
      _player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _pos = Duration.zero);
      }),
    );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else if (_player.state == PlayerState.paused) {
      await _player.resume();
    } else {
      await _player.play(
        DeviceFileSource(_result.files['mixture']!),
        position: _pos,
      );
    }
  }

  Future<void> _seek(double fraction) async {
    final ms = (_total.inMilliseconds * fraction.clamp(0.0, 1.0)).round();
    setState(() => _pos = Duration(milliseconds: ms));
    if (_player.state == PlayerState.playing ||
        _player.state == PlayerState.paused) {
      await _player.seek(_pos);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final library = context.read<LibraryProvider>();
    try {
      await widget.auto.saveToLibrary(library);
      if (mounted) _snack('Saved to your library');
    } catch (_) {
      if (mounted) _snack('Could not save the transition.');
    }
  }

  Future<void> _export() async {
    try {
      final r = _result;
      final ok = await SongExportService().exportFile(
        File(r.files['mixture']!),
        '${sanitizeFilename(r.title)}.wav',
      );
      if (mounted && ok) _snack('Exported');
    } catch (_) {
      if (mounted) _snack('Could not export the transition.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final texts = Theme.of(context).textTheme;
    final auto = widget.auto;
    final r = _result;
    final plan = r.plan;
    final fraction = _total.inMilliseconds == 0
        ? 0.0
        : _pos.inMilliseconds / _total.inMilliseconds;
    final a = auto.outgoing;
    final b = auto.incoming;

    return ListView(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: NavBar(),
        ),
        const SizedBox(height: 16),
        Text('Your transition', style: texts.headlineMedium),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ColorPalette.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: ColorPalette.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                children: [
                  _legend(ColorPalette.primary, a?.title ?? ''),
                  _legend(const Color(0xFF7770ED), b?.title ?? ''),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, c) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _seek(d.localPosition.dx / c.maxWidth),
                  onHorizontalDragUpdate: (d) =>
                      _seek(d.localPosition.dx / c.maxWidth),
                  child: CustomPaint(
                    size: Size(c.maxWidth, 236),
                    painter: _TimelinePainter(plan: plan, progress: fraction),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton.filled(
              iconSize: 32,
              style: IconButton.styleFrom(
                backgroundColor: ColorPalette.primary,
                foregroundColor: ColorPalette.onPrimary,
                minimumSize: const Size(60, 60),
              ),
              tooltip: _playing ? 'Pause preview' : 'Play preview',
              onPressed: _togglePlay,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            const SizedBox(width: 14),
            Text(
              '${_pos.formatMinSec()} / ${_total.formatMinSec()}',
              style: const TextStyle(fontSize: 15),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Blend: 32 beats at ${plan.outBpm.toStringAsFixed(0)} BPM\n'
          '“${b?.title ?? ''}”: ${plan.outBpm.toStringAsFixed(0)} → '
          '${plan.inBpm.toStringAsFixed(0)} BPM over '
          '${plan.ramp.toStringAsFixed(1)} s\n'
          '${plan.usedVocalGap ? 'Vocals enter after the outgoing lyric ends' : 'Vocals follow the beat grid only'}',
          style: const TextStyle(
            color: ColorPalette.onSurfaceVariant,
            fontSize: 14,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: Button(
            r.saved ? 'Saved' : 'Save to library',
            textSize: 16,
            radius: 28,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            color: r.saved
                ? ColorPalette.surfaceContainerHigh
                : ColorPalette.primary,
            textColor: r.saved
                ? ColorPalette.onSurfaceVariant
                : ColorPalette.onPrimary,
            onPressed: r.saved ? null : _save,
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: _export, child: const Text('Export as WAV')),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: auto.reset,
          child: const Text('Try another pair'),
        ),
      ],
    );
  }

  Widget _legend(Color color, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 6),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 150),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _muted,
        ),
      ),
    ],
  );
}

/// Draws each stem's volume over time for both songs, plus the playhead.
class _TimelinePainter extends CustomPainter {
  _TimelinePainter({required this.plan, required this.progress});

  final AutoMixPlan plan;
  final double progress;

  static const _lanes = ['drums', 'bass', 'other', 'vocals'];
  static const _labels = ['Drums', 'Bass', 'Other', 'Vocals'];

  @override
  void paint(Canvas canvas, Size size) {
    const labelWidth = 46.0;
    const laneHeight = 20.0;
    const laneGap = 6.0;
    const groupGap = 14.0;
    final left = labelWidth;
    final width = size.width - labelWidth;
    if (width <= 0) return;

    // Blend zone.
    canvas.drawRect(
      Rect.fromLTWH(
        left + width * plan.lead / plan.total,
        0,
        width * plan.blend / plan.total,
        size.height,
      ),
      Paint()..color = const Color(0x0DFFFFFF),
    );

    for (var song = 0; song < 2; song++) {
      final curves = song == 0 ? plan.outgoingCurves : plan.incomingCurves;
      final color = song == 0 ? ColorPalette.primary : const Color(0xFF7770ED);
      for (var i = 0; i < _lanes.length; i++) {
        final top = song * (4 * (laneHeight + laneGap) + groupGap) +
            i * (laneHeight + laneGap);
        _label(canvas, _labels[i], Offset(0, top + 4));
        final path = Path()..moveTo(left, top + laneHeight);
        const steps = 120;
        for (var s = 0; s <= steps; s++) {
          final t = plan.total * s / steps;
          final g = AutoMixPlan.gainAt(curves[_lanes[i]]!, t);
          path.lineTo(
            left + width * s / steps,
            top + laneHeight - laneHeight * g,
          );
        }
        path
          ..lineTo(left + width, top + laneHeight)
          ..close();
        canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.8));
      }
    }

    final x = left + width * progress.clamp(0.0, 1.0);
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = ColorPalette.onSurface
        ..strokeWidth = 1.5,
    );
  }

  void _label(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: ColorPalette.onSurfaceVariant,
          fontSize: 10,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.progress != progress || old.plan != plan;
}
