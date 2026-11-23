part of 'render_context_3d.dart';

extension _ShadowPassCascades on _ShadowPass {
  List<DirectionalShadowProjection> _cascadesOf(
    DirectionalShadowProjection owner,
  ) {
    return _cascadeProjections[owner] ??= List.generate(
      ShadowSettings.maxCascades,
      (_) => DirectionalShadowProjection(),
    );
  }

  /// Sets the values of the `Shadows` block that describe a single map of
  /// the light that travels along [direction], of index [index] (100 plus
  /// the index of a spot light), with [settings].
  void _writeSingleMap(
    Vector3 direction,
    int index,
    ShadowSettings settings,
    double texelWorldSize,
    bool float,
  ) {
    final size = settings.resolution.toDouble();
    _packDepth = !float;
    if (float) {
      _decode.setValues(1, 0, 0, 0);
    } else {
      _decode.setFrom(_ShadowPass._packedDecode);
    }
    _toLight.setValues(
      -direction.x,
      -direction.y,
      -direction.z,
      index.toDouble(),
    );
    final color = settings.color;
    _color.setValues(
      color.r,
      color.g,
      color.b,
      settings.strength.clamp(0, 1).toDouble(),
    );
    _map.setValues(size, size, 1 / size, 1 / size);
    _bias.setValues(
      texelWorldSize,
      settings.depthBias,
      settings.normalBias,
      settings.softness.toDouble(),
    );
  }

  /// Starts a frame that keeps the depths of the still casters
  /// ([ShadowSettings.cacheStillCasters]) of [owner] in a layer per view:
  /// the single map of [width] by [height] texels whose view is
  /// [_singleView], or the tiles of the [atlas] of that size.
  ///
  /// The map is reused whole when it holds the casters of [castersKey] in
  /// the same views. Otherwise each view reuses its layer when it holds the
  /// still casters of [stillKey] in the same view; a view whose projection
  /// changed since the previous frame is rendered whole (its layer would not
  /// last), and the layers of the other views are rendered again first.
  bool _beginSplit({
    required DirectionalShadowProjection owner,
    required bool atlasPath,
    required Object? castersKey,
    required Object stillKey,
    required int width,
    required int height,
    required bool float,
    required GpuPixelFormat format,
  }) {
    final context = _context;
    final device = context.device;
    final stats = device.stats;
    _staticMaps[owner] = null;
    _staticAtlases[owner] = null;
    final layers = _stillLayers[owner] ??= _StillLayers();
    _splitAtlas = atlasPath;
    final viewCount = atlasPath ? atlas.tiles.length : 1;

    // The map the receivers sample, kept with the layers.
    var live = layers.live;
    if (live == null ||
        layers.liveWidth != width ||
        layers.liveHeight != height ||
        layers.livePacked != !float) {
      live = layers.live = device.backend.createTextureTarget(
        width: width,
        height: height,
        format: format,
        clearValue: const Color(0xFFFFFFFF),
      );
      layers
        ..liveTexture = Texture(
          null,
          width: width,
          height: height,
          gpuTexture: live.texture,
        )
        ..liveWidth = width
        ..liveHeight = height
        ..livePacked = !float
        ..liveKey = null;
    }
    if (atlasPath) {
      _writeAtlasSignature(width, height, float);
    } else {
      _writeSingleSignature(width, float);
    }
    final reuseWhole =
        castersKey != null &&
        layers.liveKey == castersKey &&
        layers.liveSignatureLength == _atlasSignatureLength &&
        _ShadowPass._sameValues(
          layers.liveSignature,
          _atlasSignature,
          _atlasSignatureLength,
        );

    layers.ensureViews(viewCount);
    for (var i = 0; i < viewCount; i++) {
      final view = layers.views[i];
      _writeViewSignature(_tileSignature, i);
      if (reuseWhole) {
        view.storeLast(_tileSignature);
        continue;
      }
      final size = atlasPath ? atlas.tiles[i].width : width;
      view.ensureTarget(device, size, format: format, float: float);
      if (view.valid &&
          view.key == stillKey &&
          _ShadowPass._sameValues(
            view.signature,
            _tileSignature,
            _ShadowPass._tileSignatureLength,
          )) {
        _viewKinds[i] = _ShadowPass._stepOver;
      } else if (!view.hasLast ||
          !_ShadowPass._sameValues(
            view.last,
            _tileSignature,
            _ShadowPass._tileSignatureLength,
          )) {
        _viewKinds[i] = _ShadowPass._stepWhole;
        view.valid = false;
      } else {
        _viewKinds[i] = _ShadowPass._stepStill;
        view
          ..key = stillKey
          ..valid = true
          ..storeSignature(_tileSignature);
      }
      view.storeLast(_tileSignature);
    }

    if (reuseWhole) {
      // The map of an earlier frame holds the same casters in the same
      // views: receive it again, without rendering.
      stats
        ..shadowLayersReused += viewCount
        ..shadowReusedDrawCalls += layers.liveDrawCalls
        ..shadowReusedTriangles += layers.liveTriangles;
      if (!identical(_texture, layers.liveTexture)) {
        version++;
        _target = live;
        _texture = layers.liveTexture;
      }
      active = true;
      atlasActive = atlasPath;
      _mapIsAtlas = atlasPath;
      RenderProfile.switchPass(RenderPhase.shadowSetup, shadow: false);
      return false;
    }

    // The layers to render again, then the map.
    _stepCount = 0;
    for (var i = 0; i < viewCount; i++) {
      if (_viewKinds[i] == _ShadowPass._stepStill) {
        _stepTiles[_stepCount] = i;
        _stepKinds[_stepCount++] = _ShadowPass._stepStill;
      }
    }
    for (var i = 0; i < viewCount; i++) {
      final kind = _viewKinds[i];
      if (kind == _ShadowPass._stepOver) {
        final view = layers.views[i];
        stats
          ..shadowLayersReused += 1
          ..shadowReusedDrawCalls += view.drawCalls
          ..shadowReusedTriangles += view.triangles;
      }
      _stepTiles[_stepCount] = i;
      _stepKinds[_stepCount++] = kind == _ShadowPass._stepWhole
          ? _ShadowPass._stepWhole
          : _ShadowPass._stepOver;
    }
    layers
      ..liveKey = castersKey
      ..storeLiveSignature(_atlasSignature, _atlasSignatureLength);

    version++;
    _target = live;
    _texture = layers.liveTexture;
    _mapIsAtlas = atlasPath;
    context._saveCameraSnapshot(_mainCamera);
    _split = layers;
    recording = true;
    _drawCallsBefore = stats.drawCalls;
    _trianglesBefore = stats.triangles;
    _step = 0;
    _stepsDone = false;
    _startStep(0);
    RenderProfile.lap(RenderPhase.passBegin);
    return true;
  }

  /// Starts step [step] of the frame begun by [_beginSplit].
  void _startStep(int step) {
    final context = _context;
    final device = context.device;
    final layers = _split!;
    final kind = _stepKinds[step];
    final index = _stepTiles[step];
    final view = layers.views[index];
    if (kind == _ShadowPass._stepStill) {
      device.beginTexturePass(view.target!, frontFace: context.frontFace);
      RenderProfile.lap(RenderPhase.passBegin);
      _passOpen = true;
      final stats = device.stats;
      stats.shadowPasses++;
      stats.shadowLayersRendered++;
      _configureView(index, inMap: false);
      layer = ShadowCasterLayer.still;
      _recordingMovers = false;
      _stillTexture = null;
    } else {
      if (step == 0 || _stepKinds[step - 1] == _ShadowPass._stepStill) {
        device.beginTexturePass(layers.live!, frontFace: context.frontFace);
        RenderProfile.lap(RenderPhase.passBegin);
        _passOpen = true;
        device.stats.shadowPasses++;
      }
      _configureView(index, inMap: true);
      if (kind == _ShadowPass._stepOver) {
        device.drawTextureCopy(view.texture!);
        RenderProfile.lap(RenderPhase.draw);
        layer = ShadowCasterLayer.moving;
        _recordingMovers = true;
        _stillTexture = view.texture;
      } else {
        layer = ShadowCasterLayer.all;
        _recordingMovers = false;
        _stillTexture = null;
      }
    }
    _stepDrawCalls = device.stats.drawCalls;
    _stepTriangles = device.stats.triangles;
  }

  /// Draws the casters recorded for the current step of the frame begun by
  /// [_beginSplit], and ends its pass when it is that of a layer.
  void _finishStep() {
    final device = _context.device;
    flushCasters();
    final drawCalls = device.stats.drawCalls - _stepDrawCalls;
    final triangles = device.stats.triangles - _stepTriangles;
    final view = _split!.views[_stepTiles[_step]];
    switch (_stepKinds[_step]) {
      case _ShadowPass._stepStill:
        view
          ..drawCalls = drawCalls
          ..triangles = triangles;
        device.endTexturePass();
        _passOpen = false;
      case _ShadowPass._stepOver:
        view
          ..mapDrawCalls = view.drawCalls + drawCalls
          ..mapTriangles = view.triangles + triangles;
      default:
        view
          ..mapDrawCalls = drawCalls
          ..mapTriangles = triangles;
    }
  }

  /// Sets the camera (and the viewport of an atlas tile) of view [index] of
  /// the frame begun by [_beginSplit]: in the map when [inMap], else at the
  /// origin of the view's own layer.
  void _configureView(int index, {required bool inMap}) {
    if (_splitAtlas) {
      _configureAtlasTile(atlas.tiles[index], atOrigin: !inMap);
    } else {
      _recordingParaboloidTile = false;
      _context.setCamera(_singleView!, _singleProjection!);
    }
  }

  /// Writes what view [index] of the frame begun by [_beginSplit] renders
  /// into [out]: its kind, light and size, and its view-projection (or the
  /// position and range of a point light).
  void _writeViewSignature(Float64List out, int index) {
    if (!_splitAtlas) {
      out[0] = -1;
      out[1] = 0;
      out[2] = _singleSize.toDouble();
      final m = _lightViewProjection.storage;
      for (var k = 0; k < 16; k++) {
        out[3 + k] = m[k];
      }
      return;
    }
    final tile = atlas.tiles[index];
    out[0] = tile.kind.index.toDouble();
    out[1] = tile.lightIndex.toDouble();
    out[2] = tile.width.toDouble();
    final viewProjection = tile.viewProjection;
    if (viewProjection != null) {
      final m = viewProjection.storage;
      for (var k = 0; k < 16; k++) {
        out[3 + k] = m[k];
      }
    } else {
      final position = tile.lightPosition;
      out[3] = position?.x ?? 0;
      out[4] = position?.y ?? 0;
      out[5] = position?.z ?? 0;
      out[6] = tile.lightRange;
      for (var k = 7; k < _ShadowPass._tileSignatureLength; k++) {
        out[k] = 0;
      }
    }
  }

  /// Writes what a single map of [size] texels renders into
  /// [_atlasSignature].
  void _writeSingleSignature(int size, bool float) {
    final out = _atlasSignature;
    out[0] = size.toDouble();
    out[1] = float ? 1 : 0;
    final m = _lightViewProjection.storage;
    for (var k = 0; k < 16; k++) {
      out[2 + k] = m[k];
    }
    _atlasSignatureLength = 18;
  }

  /// Fits the [count] cascades of a directional light travelling along
  /// [direction] into [cascades], setting a bit of [_cascadeMask] for each
  /// cascade kept.
  ///
  /// The last cascade covers what one map would (see [ShadowSettings.fit]
  /// and [ShadowSettings.maxDistance]). With a perspective camera and
  /// [ShadowFit.view], cascade `c` covers what the camera sees up to
  /// `split[c]` of the farthest distance that receives shadows (the
  /// [ShadowSettings.maxDistance], or the farthest point of the receiving
  /// region); otherwise the central `split[c]` of the receiving region. A
  /// cascade that is not sharper than the next one is dropped: it would only
  /// lower the resolution where it is used.
  void _fitCascades(
    List<DirectionalShadowProjection> cascades,
    Vector3 direction,
    Aabb3 sceneBounds,
    ShadowSettings settings,
    int count,
    int tileSize, {
    required bool hold,
  }) {
    final context = _context;
    _ShadowPass._cascadeSplits(settings, count);
    final perspective = context._projectionMatrix.storage[15].abs() < 0.5;
    final fixed = settings.fit == ShadowFit.fixed;
    final fitView = settings.fit == ShadowFit.view;
    final views = _fitViewProjections;
    final region = fixed
        ? _ShadowPass._fixedBounds(settings)
        : settings.bounds ?? sceneBounds;
    final fixedCasters = settings.casterBounds ?? region;
    final far = settings.maxDistance ?? _viewDepthExtent(region);
    _cascadeMask = 0;
    var outerTexel = double.infinity;
    for (var c = count - 1; c >= 0; c--) {
      final proj = cascades[c];
      final bool fitted;
      if (fixed && c == count - 1) {
        proj.fitBounds(
          direction: direction,
          receivers: region,
          casters: fixedCasters,
          resolution: tileSize,
        );
        fitted = true;
      } else if (c == count - 1) {
        fitted = proj.update(
          direction: direction,
          casters: sceneBounds,
          receivers: settings.bounds,
          cameraViewProjection: fitView && views == null
              ? context._viewProjectionMatrix
              : null,
          cameraView: context._viewMatrix,
          cameraViewProjections: fitView ? views : null,
          cameraViews: _fitViews,
          maxDistance: settings.maxDistance,
          resolution: tileSize,
          stabilize: settings.stabilize,
          holdNear: hold,
          holdWindow: hold,
        );
        if (!fitted) {
          return;
        }
      } else if (perspective && fitView) {
        fitted = proj.update(
          direction: direction,
          casters: sceneBounds,
          receivers: settings.bounds,
          cameraViewProjection: context._viewProjectionMatrix,
          cameraView: context._viewMatrix,
          cameraViewProjections: views,
          cameraViews: _fitViews,
          maxDistance: far * _ShadowPass._splits[c],
          resolution: tileSize,
          stabilize: settings.stabilize,
          holdNear: hold,
        );
      } else {
        final scale = 0.5 * _ShadowPass._splits[c];
        final min = region.min;
        final max = region.max;
        final cx = (min.x + max.x) * 0.5;
        final cy = (min.y + max.y) * 0.5;
        final cz = (min.z + max.z) * 0.5;
        final hx = (max.x - min.x) * scale;
        final hy = (max.y - min.y) * scale;
        final hz = (max.z - min.z) * scale;
        _ShadowPass._subBox.min.setValues(cx - hx, cy - hy, cz - hz);
        _ShadowPass._subBox.max.setValues(cx + hx, cy + hy, cz + hz);
        if (fixed) {
          proj.fitBounds(
            direction: direction,
            receivers: _ShadowPass._subBox,
            casters: fixedCasters,
            resolution: tileSize,
          );
          fitted = true;
        } else {
          fitted = proj.update(
            direction: direction,
            casters: sceneBounds,
            receivers: _ShadowPass._subBox,
            resolution: tileSize,
            stabilize: settings.stabilize,
            holdNear: hold,
          );
        }
      }
      if (!fitted) {
        continue;
      }
      final texel = math.max(proj.texelWidth, proj.texelHeight);
      if (texel < outerTexel * 0.999) {
        _cascadeMask |= 1 << c;
        outerTexel = texel;
      }
    }
  }

  /// The farthest distance from the camera, along the direction it looks
  /// in, of a corner of [box]: from the farthest of the cameras the map is
  /// fitted to, when it is fitted to several.
  double _viewDepthExtent(Aabb3 box) {
    final views = _fitViews;
    if (views == null) {
      return _ShadowPass._viewDepthExtentFrom(_context._viewMatrix, box);
    }
    var far = 1e-3;
    for (var i = 0; i < views.length; i++) {
      far = math.max(far, _ShadowPass._viewDepthExtentFrom(views[i], box));
    }
    return far;
  }

  /// Ends the frame begun by [_beginSplit]: the steps not recorded yet are
  /// rendered without casters (their layers are still copied).
  void _endSplit() {
    final context = _context;
    final device = context.device;
    final layers = _split!;
    try {
      RenderProfile.lap(RenderPhase.traversal);
      if (!_stepsDone) {
        _finishStep();
        while (++_step < _stepCount) {
          _startStep(_step);
          _finishStep();
        }
        _stepsDone = true;
      }
    } finally {
      if (_passOpen) {
        device.endTexturePass();
        _passOpen = false;
      }
      device.stats
        ..shadowDrawCalls += device.stats.drawCalls - _drawCallsBefore
        ..shadowTriangles += device.stats.triangles - _trianglesBefore;
      var drawCalls = 0;
      var triangles = 0;
      final viewCount = _splitAtlas ? atlas.tiles.length : 1;
      for (var i = 0; i < viewCount; i++) {
        drawCalls += layers.views[i].mapDrawCalls;
        triangles += layers.views[i].mapTriangles;
      }
      layers
        ..liveDrawCalls = drawCalls
        ..liveTriangles = triangles;
      recording = false;
      _split = null;
      _recordingParaboloidTile = false;
      _recordingMovers = false;
      _stillTexture = null;
      layer = ShadowCasterLayer.all;
      RenderProfile.switchPass(RenderPhase.passEnd, shadow: false);
      context._restoreCameraSnapshot(
        _mainCamera,
        active: true,
        atlasActive: _splitAtlas,
      );
      RenderProfile.lap(RenderPhase.setup);
    }
  }

  void writeShadows(UniformBlock block) {
    final off =
        (block.cachedWriterOffsets as _ShadowsOffsets?) ??
        (block.cachedWriterOffsets = _ShadowsOffsets(block));
    if (!active) {
      if (off.toLight >= 0) {
        block.writeVec4ValuesAt(off.toLight, 0, 0, 0, -1);
      }
      if (off.atlas >= 0) {
        block.writeVec4ValuesAt(off.atlas, 0, 0, 0, -1);
      }
      return;
    }
    if (off.lightViewProjection >= 0) {
      block.writeMatrix4At(off.lightViewProjection, _lightViewProjection);
    }
    if (off.cascadeViewProjection >= 0) {
      block.writeMatrix4At(off.cascadeViewProjection, _ShadowPass._identityMat);
    }
    if (off.toLight >= 0) {
      block.writeVec4ValuesAt(
        off.toLight,
        _toLight.x,
        _toLight.y,
        _toLight.z,
        _toLight.w,
      );
    }
    if (off.color >= 0) {
      block.writeVec4ValuesAt(
        off.color,
        _color.x,
        _color.y,
        _color.z,
        _color.w,
      );
    }
    if (off.map >= 0) {
      block.writeVec4ValuesAt(off.map, _map.x, _map.y, _map.z, _map.w);
    }
    if (off.bias >= 0) {
      block.writeVec4ValuesAt(off.bias, _bias.x, _bias.y, _bias.z, _bias.w);
    }
    if (off.decode >= 0) {
      block.writeVec4ValuesAt(
        off.decode,
        _decode.x,
        _decode.y,
        _decode.z,
        _decode.w,
      );
    }
    if (off.cascadeParams >= 0) {
      block.writeVec4ValuesAt(off.cascadeParams, 1, 0, 0, 0);
    }
    if (!atlasActive) {
      if (off.atlas >= 0) {
        block.writeVec4ValuesAt(off.atlas, 0, 0, 0, -1);
      }
      return;
    }
    final dataLen = block.data.length;
    for (var c = 0; c < _csmTiles.length; c++) {
      final t = _csmTiles[c];
      if (off.atlasCascadeViewProjections >= 0 &&
          off.atlasCascadeViewProjections + c * 16 + 16 <= dataLen) {
        block.writeMatrix4At(
          off.atlasCascadeViewProjections + c * 16,
          t.viewProjection!,
        );
      }
      if (off.atlasCascadeRects >= 0 &&
          off.atlasCascadeRects + c * 4 + 4 <= dataLen) {
        final r = t.uvRect;
        block.writeVec4ValuesAt(
          off.atlasCascadeRects + c * 4,
          r.x,
          r.y,
          r.z,
          r.w,
        );
      }
      if (off.atlasCascadeParams >= 0 &&
          off.atlasCascadeParams + c * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.atlasCascadeParams + c * 4,
          t.texelWorldSize,
          t.blendRange,
          0,
          0,
        );
      }
    }
    for (var s = 0; s < _spotTiles.length; s++) {
      final t = _spotTiles[s];
      final position = t.lightPosition!;
      final color = t.color;
      if (off.atlasSpotViewProjections >= 0 &&
          off.atlasSpotViewProjections + s * 16 + 16 <= dataLen) {
        block.writeMatrix4At(
          off.atlasSpotViewProjections + s * 16,
          t.viewProjection!,
        );
      }
      if (off.atlasSpotRects >= 0 &&
          off.atlasSpotRects + s * 4 + 4 <= dataLen) {
        final r = t.uvRect;
        block.writeVec4ValuesAt(off.atlasSpotRects + s * 4, r.x, r.y, r.z, r.w);
      }
      if (off.atlasSpotParams >= 0 &&
          off.atlasSpotParams + s * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.atlasSpotParams + s * 4,
          t.lightIndex.toDouble(),
          t.texelWorldSize,
          t.depthBias,
          t.strength,
        );
      }
      if (off.atlasSpotPositions >= 0 &&
          off.atlasSpotPositions + s * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.atlasSpotPositions + s * 4,
          position.x,
          position.y,
          position.z,
          t.softness,
        );
      }
      if (off.atlasSpotColors >= 0 &&
          off.atlasSpotColors + s * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.atlasSpotColors + s * 4,
          color.r,
          color.g,
          color.b,
          1,
        );
      }
    }
    final front = _pointFrontTile;
    final back = _pointBackTile;
    var pointIndex = -1.0;
    if (front != null && back != null) {
      pointIndex = front.lightIndex.toDouble();
      final position = front.lightPosition!;
      final color = front.color;
      if (off.atlasPointPosition >= 0) {
        block.writeVec4ValuesAt(
          off.atlasPointPosition,
          position.x,
          position.y,
          position.z,
          1.0 / math.max(1e-3, front.lightRange),
        );
      }
      if (off.atlasPointRects >= 0 && off.atlasPointRects + 8 <= dataLen) {
        final fr = front.uvRect;
        final br = back.uvRect;
        block
          ..writeVec4ValuesAt(
            off.atlasPointRects,
            fr.x,
            fr.y,
            fr.z,
            fr.w,
          )
          ..writeVec4ValuesAt(
            off.atlasPointRects + 4,
            br.x,
            br.y,
            br.z,
            br.w,
          );
      }
      if (off.atlasPointParams >= 0) {
        block.writeVec4ValuesAt(
          off.atlasPointParams,
          front.depthBias,
          front.softness,
          front.strength,
          0,
        );
      }
      if (off.atlasPointColor >= 0) {
        block.writeVec4ValuesAt(
          off.atlasPointColor,
          color.r,
          color.g,
          color.b,
          1,
        );
      }
    }
    if (off.atlas >= 0) {
      block.writeVec4ValuesAt(
        off.atlas,
        1,
        _csmTiles.length.toDouble(),
        _spotTiles.length.toDouble(),
        pointIndex,
      );
    }
  }
}

class _StaticShadowMap({
  required final int resolution,
  required final bool packDepth,
  required final GpuTextureTarget target,
  required final Texture texture,
}) {
  Object? castersKey;
  final Float32List lightVp = Float32List(16);
}

class _StillLayers() {
  final List<_StillView> views = [];

  GpuTextureTarget? live;
  Texture? liveTexture;
  int liveWidth = 0;
  int liveHeight = 0;
  bool livePacked = false;
  Object? liveKey;
  final Float64List liveSignature = Float64List(
    _StaticShadowAtlas.signatureCapacity,
  );
  int liveSignatureLength = 0;

  // What rendering the map whole would draw, for RenderStats.
  int liveDrawCalls = 0;
  int liveTriangles = 0;

  void ensureViews(int count) {
    while (views.length < count) {
      views.add(_StillView());
    }
  }

  void storeLiveSignature(Float64List signature, int length) {
    liveSignature.setRange(0, length, signature);
    liveSignatureLength = length;
  }
}

/// The kept layer of still casters of one view, see [_StillLayers].
class _StillView() {
  GpuTextureTarget? target;
  Texture? texture;
  int size = 0;
  bool packed = false;

  // The key of the still casters it holds, and the view it holds them in.
  Object? key;
  bool valid = false;
  final Float64List signature = Float64List(_ShadowPass._tileSignatureLength);

  // The view of the previous frame.
  final Float64List last = Float64List(_ShadowPass._tileSignatureLength);
  bool hasLast = false;

  // What the layer holds, and what the view of the map held in the last
  // frame that rendered it, for RenderStats.
  int drawCalls = 0;
  int triangles = 0;
  int mapDrawCalls = 0;
  int mapTriangles = 0;

  /// Makes [target] a texture of [size] texels of [format]; a new one holds
  /// nothing yet.
  void ensureTarget(
    GraphicsDevice device,
    int size, {
    required GpuPixelFormat format,
    required bool float,
  }) {
    if (target != null && this.size == size && packed == !float) {
      return;
    }
    final created = target = device.backend.createTextureTarget(
      width: size,
      height: size,
      format: format,
      clearValue: const Color(0xFFFFFFFF),
    );
    texture = Texture(
      null,
      width: size,
      height: size,
      gpuTexture: created.texture,
    );
    this.size = size;
    packed = !float;
    valid = false;
  }

  void storeSignature(Float64List values) {
    signature.setRange(0, values.length, values);
  }

  void storeLast(Float64List values) {
    last.setRange(0, values.length, values);
    hasLast = true;
  }
}

class _ShadowsOffsets(final UniformBlock _b) {
  late final int lightViewProjection = _b.resolveOffset('lightViewProjection');
  late final int cascadeViewProjection = _b.resolveOffset(
    'cascadeViewProjection',
  );
  late final int toLight = _b.resolveOffset('toLight');
  late final int color = _b.resolveOffset('color');
  late final int map = _b.resolveOffset('map');
  late final int bias = _b.resolveOffset('bias');
  late final int decode = _b.resolveOffset('decode');
  late final int cascadeParams = _b.resolveOffset('cascadeParams');
  late final int atlasCascadeViewProjections = _b.resolveOffset(
    'atlasCascadeViewProjections',
  );
  late final int atlasCascadeRects = _b.resolveOffset('atlasCascadeRects');
  late final int atlasCascadeParams = _b.resolveOffset('atlasCascadeParams');
  late final int atlasSpotViewProjections = _b.resolveOffset(
    'atlasSpotViewProjections',
  );
  late final int atlasSpotRects = _b.resolveOffset('atlasSpotRects');
  late final int atlasSpotParams = _b.resolveOffset('atlasSpotParams');
  late final int atlasSpotPositions = _b.resolveOffset('atlasSpotPositions');
  late final int atlasSpotColors = _b.resolveOffset('atlasSpotColors');
  late final int atlasPointPosition = _b.resolveOffset('atlasPointPosition');
  late final int atlasPointRects = _b.resolveOffset('atlasPointRects');
  late final int atlasPointParams = _b.resolveOffset('atlasPointParams');
  late final int atlasPointColor = _b.resolveOffset('atlasPointColor');
  late final int atlas = _b.resolveOffset('atlas');
}
