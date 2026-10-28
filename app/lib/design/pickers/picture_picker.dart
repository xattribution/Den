import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../avatar.dart';
import '../motion.dart';
import '../pictures.dart';
import '../tokens.dart';

/// A person's picture and color, as the canvas's "Pick a picture" draws it: their avatar as it
/// will look, their initial as a choice, the eight family colors, and the pack by group. One tap
/// on anything chooses it.
class PicturePicker extends StatefulWidget {
  const PicturePicker({
    super.key,
    required this.name,
    required this.picture,
    required this.color,
    required this.onPicture,
    required this.onColor,
    this.colorLabel = 'Color',
    this.takenBy = const {},
  });

  /// Their name, for the initial and what screen readers say.
  final String name;

  /// A [Picture]: a pack id or [Picture.initial].
  final String picture;
  final Marker color;
  final ValueChanged<String> onPicture;
  final ValueChanged<Marker> onColor;

  /// The words over the colors: "Her color", "Your color".
  final String colorLabel;

  /// Colors other people already have, with their names, so two people don't end up sharing
  /// one by accident.
  final Map<Marker, String> takenBy;

  @override
  State<PicturePicker> createState() => _PicturePickerState();
}

class _PicturePickerState extends State<PicturePicker> {
  late int _group = _groupOf(widget.picture);

  static int _groupOf(String picture) {
    final i = DenPictures.groups.indexWhere((g) => g.pictures.any((p) => p.id == picture));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final color = PersonColor.forMarker(widget.color).color;
    final initial = widget.picture == Picture.initial;
    final group = DenPictures.groups[_group];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            initial
                ? DenAvatar.initial(widget.name, color: color, size: 96, semanticLabel: widget.name)
                : DenAvatar.picture(widget.picture, color: color, size: 96, semanticLabel: widget.name),
            const SizedBox(width: Sp.l),
            Expanded(
              child: _InitialChoice(
                letter: widget.name.characters.isEmpty ? '' : widget.name.characters.first.toUpperCase(),
                selected: initial,
                onTap: () => widget.onPicture(Picture.initial),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.l),
        Text(widget.colorLabel, style: t.meta(c.ink2)),
        const SizedBox(height: Sp.xs),
        ColorChoices(value: widget.color, onChanged: widget.onColor, takenBy: widget.takenBy),
        const SizedBox(height: Sp.m),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              for (final (i, g) in DenPictures.groups.indexed) ...[
                if (i > 0) const SizedBox(width: Sp.s),
                _GroupChip(name: g.name, selected: i == _group, onTap: () => setState(() => _group = i)),
              ],
            ],
          ),
        ),
        const SizedBox(height: Sp.l),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = (constraints.maxWidth / 88).floor().clamp(4, 8);
            final rows = (group.pictures.length / columns).ceil();
            return Column(
              children: [
                for (var r = 0; r < rows; r++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.m),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var col = 0; col < columns; col++)
                          Expanded(
                            child: r * columns + col < group.pictures.length
                                ? _PictureChoice(
                                    picture: group.pictures[r * columns + col],
                                    color: color,
                                    selected: group.pictures[r * columns + col].id == widget.picture,
                                    onTap: () => widget.onPicture(group.pictures[r * columns + col].id),
                                  )
                                : const SizedBox.shrink(),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Colors already used by anyone except [except], with their names.
Map<Marker, String> colorsTaken(Iterable<Member> members, {String? except}) => {
      for (final m in members)
        if (m.id != except) m.marker: m.name,
    };

/// The eight family colors in assignment order. The chosen one has an ink ring with a gap; one
/// someone else has carries their initial.
class ColorChoices extends StatelessWidget {
  const ColorChoices({super.key, required this.value, required this.onChanged, this.takenBy = const {}});

  final Marker value;
  final ValueChanged<Marker> onChanged;
  final Map<Marker, String> takenBy;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      children: [
        for (final m in Marker.values)
          _Swatch(
            color: PersonColor.forMarker(m),
            selected: m == value,
            takenBy: takenBy[m],
            onTap: () => onChanged(m),
            ink: c.ink,
            onMarker: c.onMarker,
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.takenBy,
    required this.onTap,
    required this.ink,
    required this.onMarker,
  });

  final PersonColor color;
  final bool selected;
  final String? takenBy;
  final VoidCallback onTap;
  final Color ink;
  final Color onMarker;

  @override
  Widget build(BuildContext context) {
    final letter = takenBy == null || takenBy!.isEmpty ? null : takenBy!.characters.first.toUpperCase();
    return DenPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: takenBy == null ? color.label : '${color.label}, ${takenBy!} has it',
      shape: const CircleBorder(),
      child: SizedBox.square(
        dimension: Targets.adult,
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? ink : const Color(0x00000000), width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, color: color.color),
                child: SizedBox.square(
                  dimension: 30,
                  child: letter == null
                      ? null
                      : Center(
                          child: Text(
                            letter,
                            textScaler: TextScaler.noScaling,
                            style: context.text.caption(onMarker).bold,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InitialChoice extends StatelessWidget {
  const _InitialChoice({required this.letter, required this.selected, required this.onTap});

  final String letter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPressable(
      onTap: onTap,
      selected: selected,
      color: c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
        side: BorderSide(color: selected ? c.ink : c.line, width: 1.5),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Targets.kid),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: Sp.s),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(letter, style: t.section(c.ink)),
              const SizedBox(height: 2),
              Text('Initial', style: t.caption(c.ink).bold),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({required this.name, required this.selected, required this.onTap});

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DenPressable(
      onTap: onTap,
      selected: selected,
      color: selected ? c.primary : c.card,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Targets.adult),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
          child: Center(
            widthFactor: 1,
            child: Text(name, style: context.text.meta(selected ? c.onPrimary : c.ink).bold),
          ),
        ),
      ),
    );
  }
}

class _PictureChoice extends StatelessWidget {
  const _PictureChoice({required this.picture, required this.color, required this.selected, required this.onTap});

  final DenPicture picture;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: picture.name,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
        side: selected ? BorderSide(color: c.ink, width: 2) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DenAvatar.picture(picture.id, color: color, size: 64),
            const SizedBox(height: 6),
            Text(
              picture.label,
              style: selected ? t.caption(c.ink).bold : t.caption(c.ink2),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
