/// {@template raster_scale}
/// The scale from logical pixels to the pixels of the offscreen image that
/// the components being rendered draw into, while they draw into one.
///
/// On screen, the canvas components draw on is in logical pixels: Flutter
/// applies the device pixel ratio after the picture is recorded, and
/// `Canvas.getTransform` does not include it. A renderer that records
/// components into an offscreen picture and rasterizes it at a resolution of
/// its own (`Picture.toImageSync`) scales the canvas itself, so the transform
/// the components see includes that scale: the units of the canvas are
/// already the pixels of the image. A component that renders an image of its
/// own at the resolution of the pixels it covers multiplies the canvas units
/// by the device pixel ratio on screen, and must not do so inside such a
/// picture, where it reads [isActive] instead.
///
/// The renderers of Flame push the scale of their picture with [push] while
/// the components render into it, and [pop] it after:
///
/// - `PostProcess.rasterizeSubtree` and `PostProcess.rasterizePass`;
/// - the offscreen world of a `CameraComponent` whose
///   `effectiveWorldRenderScale` is not `1`;
/// - `CameraComponent.renderToImageSync` and what is built on it
///   (`renderToImage`, `renderHighResImageSync`, `RenderTextureComponent`).
///
/// A renderer of your own that rasterizes components into an offscreen image
/// through a scaled canvas does the same. Pictures that are drawn back onto
/// the screen canvas as they are (`Canvas.drawPicture`, retained layers) are
/// in logical pixels and push nothing.
/// {@endtemplate}
abstract final class RasterScale._() {
  static final List<double> _scales = [];

  /// Whether the components being rendered draw into an offscreen picture
  /// whose canvas transform includes the scale to the picture's pixels.
  static bool get isActive => _scales.isNotEmpty;

  /// The scale of the innermost such picture, in its pixels per logical
  /// pixel of the content it rasterizes, or `null` on screen.
  static double? get current => _scales.isEmpty ? null : _scales.last;

  /// The number of nested offscreen pictures the components being rendered
  /// draw into.
  static int get depth => _scales.length;

  /// Starts an offscreen picture that rasterizes at [scale] pixels per
  /// logical pixel (the horizontal scale when the two differ). Every [push]
  /// is followed by a [pop], also when rendering throws.
  static void push(double scale) {
    assert(
      scale > 0 && scale.isFinite,
      'A raster scale must be positive and finite: $scale',
    );
    _scales.add(scale);
  }

  /// Ends the innermost offscreen picture started by [push].
  static void pop() {
    assert(_scales.isNotEmpty, 'RasterScale.pop() without a push()');
    _scales.removeLast();
  }
}
