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

  void _executeRange(int start, int end, int surfaceSize) {
    final sz = math.max(4, surfaceSize);
    final szD = sz.toDouble();
    final bounds = ui.Rect.fromLTWH(0, 0, szD, szD);
    final size = ui.Size(szD, szD);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, bounds);
    final paint = ui.Paint();

    for (var i = start; i < end; i++) {
      final entry = _entries[i];
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

    final picture = recorder.endRecording();
    final rasterized = picture.toImageSync(sz, sz);
    rasterized.dispose();
    picture.dispose();
  }

  /// Synchronously executes and disposes all queued warmup passes in one batch.
  void warmupAllSync({int surfaceSize = 16}) {
    if (_entries.isEmpty) {
      return;
    }
    _executeRange(0, _entries.length, surfaceSize);
  }

  /// Incrementally executes all queued warmup passes in chunks of
  /// [tasksPerYield], reporting `[0.0 .. 1.0]` progress via [onProgress] and
  /// yielding to the event loop between chunks so loading animations remain
  /// responsive.
  Future<void> warmupAll({
    int surfaceSize = 16,
    int tasksPerYield = 4,
    void Function(double progress)? onProgress,
  }) async {
    final total = _entries.length;
    if (total == 0) {
      onProgress?.call(1.0);
      return;
    }
    final chunk = tasksPerYield <= 0 ? total : tasksPerYield;
    var index = 0;
    while (index < total) {
      final end = math.min(total, index + chunk);
      _executeRange(index, end, surfaceSize);
      index = end;
      onProgress?.call(index / total);
      if (index < total && tasksPerYield > 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }
}
