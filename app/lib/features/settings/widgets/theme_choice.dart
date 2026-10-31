import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/family_colors.dart';
import '../../../design/motion.dart';
import '../../../design/theme.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

/// Settings, Appearance: Day, Night, Auto or Soft for this device, and under them a live
/// preview of the chosen one drawn by the real tokens, by day and at night where it follows the
/// device: the page, a card, the chosen day, someone's event in their color and an ink button.
/// The family's own colors are in it, as the theme would draw them.
class ThemeChoiceSection extends StatelessWidget {
  const ThemeChoiceSection({super.key});

  static const choices = [
    Choice(ThemeChoice.day, 'Day'),
    Choice(ThemeChoice.night, 'Night', detail: 'True black, easy on the eyes after dark'),
    Choice(ThemeChoice.auto, 'Auto', detail: 'Follows this device'),
    Choice(ThemeChoice.soft, 'Soft', detail: 'Baby blue and navy, light or dark as this device is'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {Changes.prefs, RecordType.family, RecordType.member});
    final choice = app.theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupCard(
          child: ChoiceRows<ThemeChoice>(choices: choices, value: choice, onChanged: (t) => app.theme = t),
        ),
        const SizedBox(height: Sp.m),
        DenCrossfade(child: ThemePreview(key: ValueKey(choice), choice: choice)),
      ],
    );
  }
}

/// [choice] in miniature: one scene for Day or Night, two (by day, at night) for a choice that
/// follows the device. Only a picture: the rows above are the control.
class ThemePreview extends StatelessWidget {
  const ThemePreview({super.key, required this.choice});

  final ThemeChoice choice;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.family, RecordType.member});
    final follows = choice.mode == ThemeMode.system;
    final scenes = [
      if (choice.mode != ThemeMode.dark) (choice.light, follows ? 'By day' : null),
      if (choice.mode != ThemeMode.light) (choice.dark, follows ? 'At night' : null),
    ];
    final people = app.den.members;
    final markers = [for (final m in people.take(2)) m.marker];
    final t = context.text;
    final c = context.colors;
    return ExcludeSemantics(
      // A picture of the theme: past 130 % its words would crowd it; the rows above follow 200 %.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, (colors, label)) in scenes.indexed) ...[
              if (i > 0) const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Scene(
                      colors: colors.withPack(familyPack(app.den.family, colors.palette)),
                      scale: t.scale,
                      markers: markers.isEmpty ? const [Marker.sky, Marker.grass] : markers,
                    ),
                    if (label != null) ...[
                      const SizedBox(height: Sp.xs),
                      Text(label, textAlign: TextAlign.center, style: t.caption(c.ink2)),
                    ],
                  ],
                ),
              ),
            ],
            if (scenes.length == 1) ...[const SizedBox(width: Sp.m), const Expanded(child: SizedBox())],
          ],
        ),
      ),
    );
  }
}

/// One miniature screen in [colors].
class _Scene extends StatelessWidget {
  const _Scene({required this.colors, required this.scale, required this.markers});

  final DenColors colors;
  final double scale;
  final List<Marker> markers;

  static final Map<(DenColors, double), ThemeData> _themes = {};

  @override
  Widget build(BuildContext context) {
    final theme = _themes[(colors, scale)] ??= denTheme(colors, typeScale: scale);
    return Theme(
      data: theme,
      child: Builder(builder: (context) {
        final c = context.colors;
        final t = context.text;
        final person = c.marker(markers.first);
        return Container(
          padding: const EdgeInsets.all(Sp.s + 2),
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(Radii.tile),
            border: Border.all(color: context.colors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The week strip: the chosen day in `selection`, people's dots.
              Container(
                padding: const EdgeInsets.all(Sp.xs),
                decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(Radii.input)),
                child: Row(
                  children: [
                    for (final (i, day) in ['28', '29', '30'].indexed)
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: Sp.xs),
                          decoration: i == 1
                              ? BoxDecoration(color: c.selection, borderRadius: BorderRadius.circular(10))
                              : null,
                          child: Column(
                            children: [
                              Text(day, style: t.label(i == 1 ? c.onSelection : c.ink), maxLines: 1),
                              const SizedBox(height: 2),
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: c.marker(markers[i % markers.length]),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.s),
              // Someone's event, in their color with dark text.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: Sp.s - 2),
                decoration: BoxDecoration(color: person, borderRadius: BorderRadius.circular(Radii.input)),
                child: Row(
                  children: [
                    Icon(PhosphorIconsBold.soccerBall, size: 16, color: c.onMarker),
                    const SizedBox(width: Sp.xs + 2),
                    Expanded(
                      child: Text('Soccer', style: t.label(c.onMarker).copyWith(fontSize: 14 * t.scale)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.s),
              // An ink button, and quiet text beside it, or under it with large text.
              Wrap(
                spacing: Sp.s,
                runSpacing: Sp.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: Sp.xs + 1),
                    decoration: ShapeDecoration(color: c.primary, shape: const StadiumBorder()),
                    child: Text('Approve', style: t.label(c.onPrimary).copyWith(fontSize: 13 * t.scale)),
                  ),
                  Text('3:30 PM', style: t.caption(c.ink2)),
                ],
              ),
            ],
          ),
        );
      }),
    );
  }
}
