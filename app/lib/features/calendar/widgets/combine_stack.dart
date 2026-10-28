import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../design/motion.dart';

/// Events at the same time, stacked like bricks or combined into one. Combining slides the
/// blocks up into the first on the UI spring while the combined block fades in over them, and
/// the height follows, so what's below moves with it instead of jumping. Interruptible: tap
/// again mid-flight and it turns around from where it is, at the speed it had. Under Reduce
/// Motion the two simply crossfade in 100 ms.
class CombineStack extends StatefulWidget {
  const CombineStack({super.key, required this.combined, required this.blocks, required this.merged, this.gap = 3});

  final bool combined;
  final List<Widget> blocks;
  final Widget merged;

  /// Between stacked blocks.
  final double gap;

  @override
  State<CombineStack> createState() => _CombineStackState();
}

class _CombineStackState extends State<CombineStack> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController.unbounded(vsync: this, value: widget.combined ? 1 : 0);
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = DenMotion.reduced(context);
  }

  @override
  void didUpdateWidget(CombineStack old) {
    super.didUpdateWidget(old);
    if (old.combined == widget.combined) return;
    final target = widget.combined ? 1.0 : 0.0;
    if (_reduced) {
      _t.animateTo(target, duration: DenMotion.fade);
    } else {
      _t.springTo(target);
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _CombineLayout(
        progress: _t,
        gap: widget.gap,
        slide: !_reduced,
        target: widget.combined ? 1 : 0,
        children: [
          for (final block in widget.blocks) RepaintBoundary(child: block),
          RepaintBoundary(child: widget.merged),
        ],
      );
}

class _CombineLayout extends MultiChildRenderObjectWidget {
  const _CombineLayout({
    required this.progress,
    required this.gap,
    required this.slide,
    required this.target,
    required super.children,
  });

  final Animation<double> progress;
  final double gap;
  final bool slide;
  final double target;

  @override
  _RenderCombine createRenderObject(BuildContext context) =>
      _RenderCombine(progress: progress, gap: gap, slide: slide, target: target);

  @override
  void updateRenderObject(BuildContext context, _RenderCombine renderObject) {
    renderObject
      ..progress = progress
      ..gap = gap
      ..slide = slide
      ..target = target;
  }
}

class _CombineParentData extends ContainerBoxParentData<RenderBox> {}

/// Lays out every block and the combined one at full width. Its height goes from the stack's to
/// the combined block's as the progress goes from 0 to 1; each block rides up toward the top by
/// the same amount and fades as the combined block fades in.
class _RenderCombine extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _CombineParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _CombineParentData> {
  _RenderCombine({required Animation<double> progress, required double gap, required bool slide, required double target})
      : _progress = progress,
        _gap = gap,
        _slide = slide,
        _target = target;

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(markNeedsLayout);
    _progress = value;
    if (attached) _progress.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  bool _slide;
  set slide(bool value) {
    if (value == _slide) return;
    _slide = value;
    markNeedsLayout();
  }

  /// Where it's going: under Reduce Motion the size goes there at once and only the opacity
  /// follows the progress.
  double _target;
  set target(double value) {
    if (value == _target) return;
    _target = value;
    markNeedsLayout();
  }

  final List<double> _tops = [];
  double _stackHeight = 0;
  double _mergedHeight = 0;

  double get _t => _progress.value.clamp(0.0, 1.0);

  /// How far along the movement is: the progress, or under Reduce Motion the target.
  double get _move => _slide ? _t : _target;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CombineParentData) child.parentData = _CombineParentData();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsLayout);
    super.detach();
  }

  List<RenderBox> get _children {
    final out = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      out.add(child);
      child = childAfter(child);
    }
    return out;
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final inner = BoxConstraints.tightFor(width: width);
    final children = _children;
    final blocks = children.sublist(0, children.length - 1);
    final merged = children.last;
    _tops.clear();
    var y = 0.0;
    for (final (i, block) in blocks.indexed) {
      if (i > 0) y += _gap;
      block.layout(inner, parentUsesSize: true);
      _tops.add(y);
      y += block.size.height;
    }
    _stackHeight = y;
    merged.layout(inner, parentUsesSize: true);
    _mergedHeight = merged.size.height;
    final move = _move;
    final height = _stackHeight + (_mergedHeight - _stackHeight) * move;
    for (final (i, block) in blocks.indexed) {
      (block.parentData! as _CombineParentData).offset = Offset(0, _tops[i] * (1 - move));
    }
    (merged.parentData! as _CombineParentData).offset = Offset.zero;
    size = constraints.constrain(Size(width, height));
  }

  @override
  double computeMinIntrinsicHeight(double width) => _target == 1 ? _mergedIntrinsic(width) : _stackIntrinsic(width);

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  double _stackIntrinsic(double width) {
    final children = _children;
    var h = 0.0;
    for (final (i, block) in children.sublist(0, children.length - 1).indexed) {
      if (i > 0) h += _gap;
      h += block.getMaxIntrinsicHeight(width);
    }
    return h;
  }

  double _mergedIntrinsic(double width) => lastChild?.getMaxIntrinsicHeight(width) ?? 0;

  bool get _showsBlocks => _t < 1;
  bool get _showsMerged => _t > 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    final t = _t;
    final children = _children;
    final blocks = children.sublist(0, children.length - 1);
    final merged = children.last;

    void paintChild(PaintingContext ctx, Offset base, RenderBox child, double opacity) {
      if (opacity <= 0) return;
      final at = base + (child.parentData! as _CombineParentData).offset;
      if (opacity >= 1) {
        ctx.paintChild(child, at);
      } else {
        ctx.pushOpacity(at, (opacity * 255).round(), (inner, o) => inner.paintChild(child, o));
      }
    }

    void paintAll(PaintingContext ctx, Offset base) {
      if (_showsBlocks) {
        // The lower blocks slide under the first: paint them first.
        for (final block in blocks.reversed) {
          paintChild(ctx, base, block, 1 - t);
        }
      }
      if (_showsMerged) paintChild(ctx, base, merged, t);
    }

    final clips = size.height < _stackHeight - 0.5 || size.height < _mergedHeight - 0.5;
    if (clips) {
      _clip.layer = context.pushClipRect(needsCompositing, offset, Offset.zero & size, paintAll, oldLayer: _clip.layer);
    } else {
      _clip.layer = null;
      paintAll(context, offset);
    }
  }

  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final children = _children;
    final candidates = _t >= 0.5 ? [children.last] : children.sublist(0, children.length - 1).reversed;
    for (final child in candidates) {
      final data = child.parentData! as _CombineParentData;
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, transformed) => child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final children = _children;
    if (_target >= 0.5) {
      visitor(children.last);
    } else {
      children.sublist(0, children.length - 1).forEach(visitor);
    }
  }
}
