import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

sealed class const _WarmupEntry();

class _ShaderWarmupEntry({
  required final ui.FragmentShader shader,
  required final void Function(ui.FragmentShader shader, ui.Size size)?
  configure,
  required final ui.BlendMode blendMode,
}) extends _WarmupEntry;

class _TextureWarmupEntry({
  required final ui.Image image,
  required final ui.BlendMode blendMode,
}) extends _WarmupEntry;

class _VerticesWarmupEntry({
  required final ui.BlendMode blendMode,
  required final ui.Shader? shader,
}) extends _WarmupEntry;

class _CustomWarmupEntry({
  required final void Function(ui.Canvas canvas, ui.Rect bounds) draw,
}) extends _WarmupEntry;

/// Pre-warms GPU render pipelines (`FragmentShader` PSOs, `BlendMode` variants,
/// `drawRawAtlas` texture upload paths, and `drawVertices` pipelines) onto a
/// tiny offscreen raster target during game load so first-use bursts never
/// cause frame hitches.
///
/// The passes are recorded into a picture that is handed to the raster thread.
/// By default nothing waits for the raster thread: [warmupAllSync] and
/// [warmupAll] return once the picture is queued, and the engine is free to
/// drop a queued picture whose image was already released, so the warm-up is
/// best effort. Pass `awaitRasterization: true` to [warmupAll] to wait until
/// the GPU has actually drawn every pass.
class RenderWarmupQueue() {
  final List<_WarmupEntry> _entries = <_WarmupEntry>[];

  int _warmedShaderCount = 0;
  int _warmedTextureCount = 0;
  int _completedTaskCount = 0;

  /// Total tasks currently queued in this warmup queue.
  int get length => _entries.length;

  /// Number of shader PSOs warmed so far by this queue.
  int get warmedShaderCount => _warmedShaderCount;

  /// Number of GPU textures warmed so far by this queue.
  int get warmedTextureCount => _warmedTextureCount;

  /// Total warmup tasks executed so far by this queue.
  int get completedTaskCount => _completedTaskCount;

  /// Registers a [ui.FragmentShader] pipeline for offscreen compilation/PSO
  /// warmup.
  ///
  /// Provide [configure] when your shader requires custom uniform slots or
  /// image samplers bound prior to `drawRect`.
  void addShader(
    ui.FragmentShader shader, {
    void Function(ui.FragmentShader shader, ui.Size size)? configure,
    ui.BlendMode blendMode = ui.BlendMode.srcOver,
  }) {
    _entries.add(
      _ShaderWarmupEntry(
        shader: shader,
        configure: configure,
        blendMode: blendMode,
      ),
    );
  }

  /// Registers a GPU [ui.Image] texture for `drawRawAtlas` / sampler upload
  /// warmup.
  void addTexture(
    ui.Image image, {
    ui.BlendMode blendMode = ui.BlendMode.modulate,
  }) {
    _entries.add(_TextureWarmupEntry(image: image, blendMode: blendMode));
  }

  /// Registers a `Canvas.drawVertices` (`Vertices.raw`) pipeline warmup pass.
  void addVertices({
    ui.BlendMode blendMode = ui.BlendMode.dst,
    ui.Shader? shader,
  }) {
    _entries.add(_VerticesWarmupEntry(blendMode: blendMode, shader: shader));
  }

  /// Registers an arbitrary offscreen [draw] callback for pipeline warmup.
  void addCustom(void Function(ui.Canvas canvas, ui.Rect bounds) draw) {
    _entries.add(_CustomWarmupEntry(draw: draw));
  }

  /// Clears all pending entries without resetting historical telemetry
  /// counters.
  void clear() => _entries.clear();

  /// Records the passes `[start, end)` of [entries] into a picture of
  /// [surfaceSize] pixels. The caller owns the returned picture.
  ui.Picture _recordRange(
    List<_WarmupEntry> entries,
    int start,
    int end,
    int surfaceSize,
  ) {
    final szD = _surfaceDimension(surfaceSize).toDouble();
    final bounds = ui.Rect.fromLTWH(0, 0, szD, szD);
    final size = ui.Size(szD, szD);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, bounds);
    final paint = ui.Paint();

    try {
      for (var i = start; i < end; i++) {
        final entry = entries[i];
        switch (entry) {
          case _ShaderWarmupEntry():
            entry.configure?.call(entry.shader, size);
            paint
              ..shader = entry.shader
              ..blendMode = entry.blendMode;
            canvas.drawRect(bounds, paint);
            paint.shader = null;
            _warmedShaderCount++;
          case _TextureWarmupEntry():
            final transforms = Float32List.fromList(<double>[1, 0, 0, 0]);
            final rects = Float32List.fromList(<double>[
              0,
              0,
              math.min(szD, entry.image.width.toDouble()),
              math.min(szD, entry.image.height.toDouble()),
            ]);
            final colors = Int32List.fromList(<int>[0xFFFFFFFF]);
            paint
              ..shader = null
              ..blendMode = ui.BlendMode.srcOver;
            canvas.drawRawAtlas(
              entry.image,
              transforms,
              rects,
              colors,
              entry.blendMode,
              null,
              paint,
            );
            _warmedTextureCount++;
          case _VerticesWarmupEntry():
            final hasShader = entry.shader != null;
            final positions = Float32List.fromList(<double>[
              0,
              0,
              szD,
              0,
              0,
              szD,
            ]);
            final uvs = hasShader
                ? Float32List.fromList(<double>[0, 0, 1, 0, 0, 1])
                : null;
            final colors = Int32List.fromList(<int>[
              0xFFFFFFFF,
              0xFFCCCCCC,
              0xFF999999,
            ]);
            final indices = Uint16List.fromList(<int>[0, 1, 2]);
            final vertices = ui.Vertices.raw(
              ui.VertexMode.triangles,
              positions,
              textureCoordinates: uvs,
              colors: colors,
              indices: indices,
            );
            paint
              ..shader = entry.shader
              ..blendMode = ui.BlendMode.srcOver;
            canvas.drawVertices(vertices, entry.blendMode, paint);
            vertices.dispose();
            paint.shader = null;
          case _CustomWarmupEntry():
            entry.draw(canvas, bounds);
        }
        _completedTaskCount++;
      }
    } on Object {
      // Do not leave the recording open when a pass throws.
      recorder.endRecording().dispose();
      rethrow;
    }
    return recorder.endRecording();
  }

  static int _surfaceDimension(int surfaceSize) => math.max(4, surfaceSize);

  /// Synchronously records all queued warmup passes in one batch and queues
  /// them for rasterization, without waiting for the raster thread.
  void warmupAllSync({int surfaceSize = 16}) {
    if (_entries.isEmpty) {
      return;
    }
    final sz = _surfaceDimension(surfaceSize);
    final picture = _recordRange(_entries, 0, _entries.length, surfaceSize);
    picture.toImageSync(sz, sz).dispose();
    picture.dispose();
  }

  /// Incrementally executes all queued warmup passes in chunks of
  /// [tasksPerYield], reporting `[0.0 .. 1.0]` progress via [onProgress] and
  /// yielding to the event loop between chunks so loading animations remain
  /// responsive.
  ///
  /// With [awaitRasterization] every chunk is awaited until the raster thread
  /// has drawn it (`Picture.toImage`), which is the only way to be sure that
  /// the pipelines were really compiled before the returned future completes.
  /// It needs real asynchronous work to finish, so inside a widget test it
  /// only completes within `WidgetTester.runAsync`.
  ///
  /// The passes that are queued when this method is called are the ones that
  /// run; adding to or clearing the queue while it runs has no effect on it.
  Future<void> warmupAll({
    int surfaceSize = 16,
    int tasksPerYield = 4,
    void Function(double progress)? onProgress,
    bool awaitRasterization = false,
  }) async {
    final entries = List<_WarmupEntry>.of(_entries, growable: false);
    final total = entries.length;
    if (total == 0) {
      onProgress?.call(1.0);
      return;
    }
    final sz = _surfaceDimension(surfaceSize);
    final chunk = tasksPerYield <= 0 ? total : tasksPerYield;
    var index = 0;
    while (index < total) {
      final end = math.min(total, index + chunk);
      final picture = _recordRange(entries, index, end, surfaceSize);
      try {
        if (awaitRasterization) {
          (await picture.toImage(sz, sz)).dispose();
        } else {
          picture.toImageSync(sz, sz).dispose();
        }
      } finally {
        picture.dispose();
      }
      index = end;
      onProgress?.call(index / total);
      if (index < total && tasksPerYield > 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }
}
