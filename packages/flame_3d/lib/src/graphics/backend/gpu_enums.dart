/// How a GPU resource's memory is allocated and accessed.
enum GpuStorageMode() {
  /// Memory visible to the host (CPU): used for resources written from Dart.
  hostVisible,

  /// Memory private to the device (GPU): fastest for GPU-only resources.
  devicePrivate,

  /// Transient device memory whose contents need not survive a render pass.
  deviceTransient,
}

/// Pixel layout of a GPU texture.
enum GpuPixelFormat() {
  /// 8 bits per channel, RGBA order.
  rgba8888,

  /// 8 bits per channel, BGRA order.
  bgra8888,

  /// 8 bits per channel in sRGB color space, RGBA order (decoded to linear on
  /// sample).
  rgba8888Srgb,

  /// 8 bits per channel in sRGB color space, BGRA order (decoded to linear on
  /// sample).
  bgra8888Srgb,

  /// 16-bit half-float per channel, RGBA order (64 bits per pixel, linear HDR).
  rgbaFloat16,

  /// 32-bit float per channel, RGBA order.
  rgbaFloat32,

  /// A single 32-bit float channel (red), for instance depth written by a
  /// shader into a texture that later passes sample.
  r32Float,

  /// The backend's default depth/stencil format.
  depthStencil,

  /// BC1 / DXT1 compressed RGBA, 4x4 texel blocks, 8 bytes per block.
  bc1Rgba,

  /// BC3 / DXT5 compressed RGBA, 4x4 texel blocks, 16 bytes per block.
  bc3Rgba,

  /// BC7 compressed high-quality RGBA, 4x4 texel blocks, 16 bytes per block.
  bc7Rgba,

  /// ETC2 compressed RGB8, 4x4 texel blocks, 8 bytes per block.
  etc2Rgb8,

  /// ETC2 compressed RGBA8, 4x4 texel blocks, 16 bytes per block.
  etc2Rgba8,

  /// ASTC LDR compressed RGBA, 4x4 texel blocks, 16 bytes per block.
  astc4x4,

  /// ASTC LDR compressed RGBA, 8x8 texel blocks, 16 bytes per block.
  astc8x8,

  /// [bc1Rgba] with sRGB-encoded colors (decoded to linear on sample).
  bc1RgbaSrgb,

  /// [bc3Rgba] with sRGB-encoded colors (decoded to linear on sample).
  bc3RgbaSrgb,

  /// [bc7Rgba] with sRGB-encoded colors (decoded to linear on sample).
  bc7RgbaSrgb,

  /// [etc2Rgb8] with sRGB-encoded colors (decoded to linear on sample).
  etc2Rgb8Srgb,

  /// [etc2Rgba8] with sRGB-encoded colors (decoded to linear on sample).
  etc2Rgba8Srgb,

  /// [astc4x4] with sRGB-encoded colors (decoded to linear on sample).
  astc4x4Srgb,

  /// [astc8x8] with sRGB-encoded colors (decoded to linear on sample).
  astc8x8Srgb;

  /// Whether this format stores block-compressed texels.
  bool get isCompressed => blockWidth > 1 || blockHeight > 1;

  /// Width of one compression block in texels (`1` for uncompressed formats).
  int get blockWidth => switch (this) {
    astc8x8 || astc8x8Srgb => 8,
    bc1Rgba ||
    bc3Rgba ||
    bc7Rgba ||
    etc2Rgb8 ||
    etc2Rgba8 ||
    astc4x4 ||
    bc1RgbaSrgb ||
    bc3RgbaSrgb ||
    bc7RgbaSrgb ||
    etc2Rgb8Srgb ||
    etc2Rgba8Srgb ||
    astc4x4Srgb => 4,
    _ => 1,
  };

  /// Height of one compression block in texels (`1` for uncompressed formats).
  int get blockHeight => blockWidth;

  /// Byte size of one texel (uncompressed) or one compressed block.
  int get bytesPerBlock => switch (this) {
    rgba8888 ||
    bgra8888 ||
    rgba8888Srgb ||
    bgra8888Srgb ||
    r32Float ||
    depthStencil => 4,
    rgbaFloat16 || bc1Rgba || etc2Rgb8 || bc1RgbaSrgb || etc2Rgb8Srgb => 8,
    rgbaFloat32 ||
    bc3Rgba ||
    bc7Rgba ||
    etc2Rgba8 ||
    astc4x4 ||
    astc8x8 ||
    bc3RgbaSrgb ||
    bc7RgbaSrgb ||
    etc2Rgba8Srgb ||
    astc4x4Srgb ||
    astc8x8Srgb => 16,
  };
}

/// Color-space interpretation of an 8-bit texture's stored texels.
enum TextureColorSpace() {
  /// Stored values are already linear (data maps: normals, ORM, LUTs).
  linear,

  /// Stored values are sRGB-encoded and converted to linear when sampled.
  srgb,
}

/// Width of the integers stored in an index buffer.
enum GpuIndexType(
  /// The size of a single index, in bytes.
  final int bytesPerIndex,
) {
  /// 16-bit unsigned indices.
  uint16(2),

  /// 32-bit unsigned indices.
  uint32(4),
}

/// How the color a draw outputs is combined with the color already in the
/// render target.
///
/// `src` is the fragment's output, `dst` the color in the render target.
enum BlendState() {
  /// No blending, the source overwrites the destination.
  opaque,

  /// Straight (non-premultiplied) alpha blending:
  /// `color = src * srcAlpha + dst * (1 - srcAlpha)`,
  /// `alpha = srcAlpha + dstAlpha * (1 - srcAlpha)`.
  alpha,

  /// Premultiplied alpha blending, for colors already multiplied by their
  /// alpha: `color = src + dst * (1 - srcAlpha)`.
  premultipliedAlpha,

  /// Additive blending: `color = src + dst`, `alpha = dstAlpha`.
  ///
  /// Added light covers nothing, so the alpha of the target is kept: where
  /// the target is transparent (a scene rendered into an image that is then
  /// drawn over 2D content, as `Scene3DComponent` does), the color is added
  /// to whatever is drawn behind the image.
  additive,

  /// No color is written: `color = dst`, `alpha = dstAlpha`.
  ///
  /// With depth writes on, a draw only fills the depth buffer: a depth
  /// prepass. Drawn right before the same object with a translucent material
  /// whose depth test passes on equal depths ([CompareFunction.lessEqual]),
  /// it leaves only the object's nearest surfaces to blend, so that the
  /// object fades as one piece instead of showing its own hidden parts.
  depthOnly,

  /// Order-independent transparency accumulation of premultiplied colors
  /// (`color = src + dst`, `alpha = srcAlpha + dstAlpha`).
  wboitAccum,

  /// Order-independent transparency revealage product
  /// (`color = dst * (1 - srcAlpha)`, `alpha = dstAlpha * (1 - srcAlpha)`).
  wboitReveal,

  /// Order-independent transparency accumulation of straight (not
  /// premultiplied) colors (`color = src * srcAlpha + dst`,
  /// `alpha = srcAlpha + dstAlpha`).
  wboitAccumStraight,
}

/// A comparison between an incoming value and a stored one, used for the
/// depth and stencil tests.
///
/// A fragment passes when `incoming <op> stored` holds.
enum CompareFunction() {
  /// The comparison never passes.
  never,

  /// Passes when the incoming value is less than the stored one.
  less,

  /// Passes when both values are equal.
  equal,

  /// Passes when the incoming value is less than or equal to the stored one.
  lessEqual,

  /// Passes when the incoming value is greater than the stored one.
  greater,

  /// Passes when both values differ.
  notEqual,

  /// Passes when the incoming value is greater than or equal to the stored
  /// one.
  greaterEqual,

  /// The comparison always passes.
  always,
}

/// Operation applied to a stencil buffer byte after stencil/depth testing.
enum StencilOp() {
  /// Keeps the current stencil value unchanged.
  keep,

  /// Sets the stencil value to `0`.
  zero,

  /// Sets the stencil value to `StencilState.referenceValue`.
  replace,

  /// Increments the stencil value, clamping at `255`.
  incrementClamp,

  /// Decrements the stencil value, clamping at `0`.
  decrementClamp,

  /// Bitwise-inverts the stencil value.
  invert,

  /// Increments the stencil value, wrapping from `255` to `0`.
  incrementWrap,

  /// Decrements the stencil value, wrapping from `0` to `255`.
  decrementWrap,
}

/// Polygon rasterization fill mode.
enum PolygonFillMode() {
  /// Fills polygon interiors normally.
  fill,

  /// Rasterizes triangle edges only (hardware wireframe).
  wireframe,
}

/// Primitive assembly topology for vertex/index buffers.
enum PrimitiveTopology() {
  /// Separate triangles (`3` indices per triangle).
  triangles,

  /// Connected strip of triangles.
  triangleStrip,

  /// Separate line segments (`2` indices per segment).
  lines,

  /// Connected polyline strip.
  lineStrip,

  /// Individual point primitives (`1` index per point).
  points,
}

/// Face culling mode. Controls which triangle faces are discarded before
/// rasterization.
enum CullMode() {
  /// No culling, both front and back faces are rendered.
  none,

  /// Cull front-facing triangles (render only back faces).
  frontFace,

  /// Cull back-facing triangles (render only front faces).
  backFace,
}

/// The vertex order, as seen on screen, that makes a triangle front-facing.
enum WindingOrder() {
  /// Triangles whose vertices appear clockwise on screen are front-facing.
  clockwise,

  /// Triangles whose vertices appear counter-clockwise on screen are
  /// front-facing.
  counterClockwise,
}

/// Order-independent transparency mode for a `World3D`.
enum OitMode3D() {
  /// Standard back-to-front per-draw alpha sorting.
  none,

  /// McGuire & Bavoil Weighted Blended Order-Independent Transparency,
  /// eliminating Z-sort popping on intersecting translucent surfaces.
  weightedBlended,
}

/// Diagnostic buffer visualization mode for a `World3D` or `Scene3DComponent`.
enum RenderDebugMode3D() {
  /// Normal lit and post-processed rendering.
  none,

  /// World/view surface normals mapped from `[-1, 1]` to `[0, 1]` RGB.
  normals,

  /// Normalized clip depth visualization.
  depth,

  /// Screen-space ambient occlusion factor in grayscale.
  ssao,

  /// Directional CSM cascade split index tint overlay.
  cascadeSplits,

  /// Hardware polygon wireframe rasterization.
  wireframe,

  /// Additive fragment overdraw heat visualization.
  overdraw,

  /// Material roughness (`G`) and metallic (`B`) channels.
  roughnessMetallic,

  /// Unlit base albedo color.
  albedo,
}
