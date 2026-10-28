import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'pictograms.dart';
import 'pictures.dart';
import 'tokens.dart';

enum _Kind { member, picture, initial, photo }

/// A person: their picture from the pack, a photo, or their initial, with their color. A picture
/// or photo sits inside a solid ring of their color; an initial is the letter in dark ink on
/// their color. Color is never the only clue: a name goes beside it, and the picture or letter
/// tells people apart too.
class DenAvatar extends StatelessWidget {
  /// A member as the model describes them today: their animal pictogram on their color.
  // TODO(design phase 2): once members carry a picture, initial or photo, build those here.
  const DenAvatar(Member this.member, {super.key, this.size = 32})
      : _kind = _Kind.member,
        color = null,
        picture = null,
        initial = null,
        photo = null,
        semanticLabel = null;

  /// [picture] is a [DenPicture] id from the pack.
  const DenAvatar.picture(String this.picture, {super.key, required Color this.color, this.size = 40, this.semanticLabel})
      : _kind = _Kind.picture,
        member = null,
        initial = null,
        photo = null;

  /// The first letter of [initial], in dark ink on [color].
  const DenAvatar.initial(String this.initial, {super.key, required Color this.color, this.size = 40, this.semanticLabel})
      : _kind = _Kind.initial,
        member = null,
        picture = null,
        photo = null;

  /// An encoded image (JPEG, PNG). Null draws the empty-photo silhouette.
  const DenAvatar.photo(this.photo, {super.key, required Color this.color, this.size = 40, this.semanticLabel})
      : _kind = _Kind.photo,
        member = null,
        picture = null,
        initial = null;

  final _Kind _kind;
  final Member? member;
  final String? picture;
  final String? initial;
  final Uint8List? photo;

  /// The person's color; for [DenAvatar.new] it comes from the member.
  final Color? color;
  final double size;

  /// What a screen reader says: usually the person's name.
  final String? semanticLabel;

  /// The ring's width at [size]: a 24th of the size, at least 2.
  static double ringWidth(double size) => math.max(2.0, (size / 24).roundToDouble());

  /// The initial's size: 45 % of the avatar.
  static double letterSize(double size) => (size * 0.45).roundToDouble();

  /// How much of the inside of the ring a picture fills.
  static const double pictureFill = 0.84;

  String get _label => switch (_kind) {
        _Kind.member => member!.name,
        _Kind.picture => semanticLabel ?? DenPictures.find(picture)?.name ?? 'Picture',
        _Kind.initial => semanticLabel ?? initial!,
        _Kind.photo => semanticLabel ?? 'Photo',
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ring = color ?? c.marker(member!.marker);
    final Widget face = switch (_kind) {
      _Kind.member => DecoratedBox(
          decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
          child: Center(child: Icon(Pictograms.animal(member!.animal), size: size * 0.6, color: c.onMarker)),
        ),
      _Kind.initial => DecoratedBox(
          decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
          child: Center(
            child: Text(
              initial!.characters.isEmpty ? '' : initial!.characters.first.toUpperCase(),
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontFamily: DenType.family,
                fontSize: letterSize(size),
                fontWeight: FontWeight.w700,
                fontVariations: [ui.FontVariation.weight(FontWeight.w700.value.toDouble())],
                height: 1,
                leadingDistribution: ui.TextLeadingDistribution.even,
                color: c.onMarker,
              ),
            ),
          ),
        ),
      _Kind.picture => _Ring(
          size: size,
          color: ring,
          background: c.pictureBg,
          child: Center(
            child: FractionallySizedBox(
              widthFactor: pictureFill,
              heightFactor: pictureFill,
              child: _PictureView(picture!),
            ),
          ),
        ),
      _Kind.photo => _Ring(
          size: size,
          color: ring,
          background: c.photoBg,
          child: photo == null
              ? CustomPaint(painter: _PhotoPlaceholder(c.photoFg))
              : Image.memory(photo!, fit: BoxFit.cover, gaplessPlayback: true),
        ),
    };
    return Semantics(
      label: _label,
      image: true,
      excludeSemantics: true,
      child: SizedBox.square(dimension: size, child: RepaintBoundary(child: face)),
    );
  }
}

/// A solid ring of the person's color around [child], clipped to a circle.
class _Ring extends StatelessWidget {
  const _Ring({required this.size, required this.color, required this.background, required this.child});

  final double size;
  final Color color;
  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = DenAvatar.ringWidth(size);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: width),
      ),
      child: Padding(
        padding: EdgeInsets.all(width),
        child: ClipOval(child: SizedBox.expand(child: child)),
      ),
    );
  }
}

/// A pack picture: drawn from the parsed cache when DenPictures.load has run, otherwise
/// loaded from its asset.
class _PictureView extends StatelessWidget {
  const _PictureView(this.id);

  final String id;

  @override
  Widget build(BuildContext context) {
    final drawn = DenPictures.drawn(id);
    if (drawn != null) return CustomPaint(painter: _PicturePainter(drawn.picture, drawn.size), size: Size.infinite);
    final picture = DenPictures.find(id);
    if (picture == null) return const SizedBox.expand();
    return SvgPicture.asset(picture.asset, fit: BoxFit.contain, excludeFromSemantics: true);
  }
}

class _PicturePainter extends CustomPainter {
  _PicturePainter(this.picture, this.source);

  final ui.Picture picture;
  final Size source;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / source.width, size.height / source.height);
    canvas.save();
    canvas.translate((size.width - source.width * scale) / 2, (size.height - source.height * scale) / 2);
    canvas.scale(scale);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PicturePainter old) => old.picture != picture || old.source != source;
}

/// A head and shoulders, for a photo that isn't there yet.
class _PhotoPlaceholder extends CustomPainter {
  _PhotoPlaceholder(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 64;
    final paint = Paint()..color = color;
    canvas.drawCircle(Offset(32 * s, 25 * s), 11 * s, paint);
    final body = Path()
      ..moveTo(10 * s, 64 * s)
      ..cubicTo(10 * s, 51 * s, 20 * s, 42 * s, 32 * s, 42 * s)
      ..cubicTo(44 * s, 42 * s, 54 * s, 51 * s, 54 * s, 64 * s)
      ..close();
    canvas.drawPath(body, paint);
  }

  @override
  bool shouldRepaint(_PhotoPlaceholder old) => old.color != color;
}
