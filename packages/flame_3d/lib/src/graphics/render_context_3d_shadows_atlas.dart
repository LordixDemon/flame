part of 'render_context_3d.dart';

extension _ShadowPassAtlas on _ShadowPass {
  bool _beginUnifiedAtlas({
    required DirectionalShadowProjection projection,
    required Object? castersKey,
    required Object? stillCastersKey,
    required Aabb3 sceneBounds,
    required Light? dirLight,
    required int dirIndex,
    required ShadowSettings? dirSettings,
  }) {
    final spotCount = _spotCasterCount;
    final pointCaster = _pointCaster;
    final pointSettings = (pointCaster?.source as PointLight?)?.shadows;
    final firstSpotSettings = spotCount > 0
        ? (_spotCasters[0]!.source as SpotLight).shadows
        : null;
    final context = _context;
    final device = context.device;
    _csmTiles.clear();
    _spotTiles.clear();
    _pointFrontTile = null;
    _pointBackTile = null;

    final csmCount = dirSettings?.cascades ?? 0;
    final totalRequestedTiles =
        csmCount + spotCount + (pointCaster != null ? 2 : 0);
    final preferredRes =
        dirSettings?.resolution ??
        firstSpotSettings?.resolution ??
        pointSettings?.resolution ??
        512;
    final tileSize = atlas.recommendedTileSize(
      totalRequestedTiles,
      preferred: preferredRes,
    );

    _atlasDirLightIndex = -1;
    _atlasCascadeCount = 0;

    final primarySettings = dirSettings ?? firstSpotSettings ?? pointSettings!;

    // ShadowSettings.cacheStillCasters, when every light that casts shadows
    // sets it.
    final split =
        stillCastersKey != null &&
        (dirSettings?.cacheStillCasters ?? true) &&
        _spotCastersKeepStill(spotCount) &&
        (pointSettings?.cacheStillCasters ?? true);

    _cascadeMask = 0;
    final cascades = _cascadesOf(projection);
    if (dirLight != null && dirSettings != null && csmCount > 0) {
      _fitCascades(
        cascades,
        dirLight.direction(_ShadowPass._direction),
        sceneBounds,
        dirSettings,
        csmCount,
        tileSize,
        hold: split,
      );
    }
    // The atlas holds the cascades kept and the tiles of the other lights, in
    // a grid of tiles as square as it can be.
    var tileCount = spotCount + (pointCaster != null ? 2 : 0);
    for (var c = 0; c < csmCount; c++) {
      if (_cascadeMask & (1 << c) != 0) {
        tileCount++;
      }
    }
    atlas.reset(
      width: ShadowAtlas3D.columnsFor(tileCount) * tileSize,
      height: ShadowAtlas3D.rowsFor(tileCount) * tileSize,
    );

    if (dirLight != null && dirSettings != null && csmCount > 0) {
      final dir = dirLight.direction(_ShadowPass._direction);
      for (var c = 0; c < csmCount; c++) {
        if (_cascadeMask & (1 << c) == 0) {
          continue;
        }
        final proj = cascades[c];
        final tile = atlas.allocateTile(
          kind: ShadowAtlasTileKind3D.directionalCascade,
          lightIndex: dirIndex,
          subIndex: c,
          tileSize: tileSize,
          view: proj.view,
          projection: proj.projection,
          viewProjection: proj.viewProjection,
          texelWorldSize: math.max(proj.texelWidth, proj.texelHeight),
          depthBias: dirSettings.depthBias,
          softness: dirSettings.softness.toDouble(),
          strength: dirSettings.strength.clamp(0.0, 1.0),
          blendRange: dirSettings.cascadeBlendRange.clamp(0.0, 0.35),
          color: dirSettings.color,
        );
        if (tile != null) {
          _csmTiles.add(tile);
        }
      }
      if (_csmTiles.isNotEmpty) {
        _atlasDirLightIndex = dirIndex;
        _atlasCascadeCount = _csmTiles.length;
        _toLight.setValues(-dir.x, -dir.y, -dir.z, dirIndex.toDouble());
      } else {
        _toLight.setFrom(_ShadowPass._noShadows);
      }
    } else {
      _toLight.setFrom(_ShadowPass._noShadows);
    }

    for (var k = 0; k < spotCount; k++) {
      final spotLight = _spotCasters[k]!;
      final spotSource = spotLight.source as SpotLight;
      final sSettings = spotSource.shadows!;
      final sIdx = _spotCasterIndices[k];
      final dir = spotLight.direction(_ShadowPass._spotDirScratch);
      final eye = spotLight.position;
      _spotTarget
        ..setFrom(eye)
        ..add(dir);
      _spotUp.setValues(0, 1, 0);
      if (dir.y.abs() > 0.92) {
        _spotUp.setValues(0, 0, 1);
      }
      _spotView.setAsViewMatrix(eye, _spotTarget, _spotUp);
      final fovDeg = (spotSource.outerConeAngle * 2.0 * 180.0 / math.pi).clamp(
        10.0,
        165.0,
      );
      final zFar = math.max(1.0, spotSource.range ?? 32.0);
      _spotProj.setAsPerspective(fovDeg, 1.0, 0.12, zFar);
      _spotVp
        ..setFrom(_spotProj)
        ..multiply(_spotView);
      final texelWorld =
          (2.0 *
              math.tan(spotSource.outerConeAngle.clamp(0.05, 1.4)) *
              zFar *
              0.35) /
          tileSize;
      final tile = atlas.allocateTile(
        kind: ShadowAtlasTileKind3D.spotLight,
        lightIndex: sIdx,
        tileSize: tileSize,
        lightPosition: eye,
        lightRange: zFar,
        view: _spotView,
        projection: _spotProj,
        viewProjection: _spotVp,
        texelWorldSize: texelWorld,
        depthBias: sSettings.depthBias,
        softness: sSettings.softness.toDouble(),
        strength: sSettings.strength.clamp(0.0, 1.0),
        color: sSettings.color,
      );
      if (tile != null) {
        _spotTiles.add(tile);
      }
    }
    _atlasSpotShadowCount = _spotTiles.length;

    if (pointCaster != null) {
      final ptLight = pointCaster;
      final ptSource = pointCaster.source as PointLight;
      final ptSettings = pointSettings!;
      final ptIdx = _pointCasterIndex;
      final ptRange = math.max(1.0, ptSource.range ?? 24.0);
      _pointFrontTile = atlas.allocateTile(
        kind: ShadowAtlasTileKind3D.pointParaboloidFront,
        lightIndex: ptIdx,
        tileSize: tileSize,
        lightPosition: ptLight.position,
        lightRange: ptRange,
        depthBias: ptSettings.depthBias,
        softness: ptSettings.softness.toDouble(),
        strength: ptSettings.strength.clamp(0.0, 1.0),
        color: ptSettings.color,
      );
      _pointBackTile = atlas.allocateTile(
        kind: ShadowAtlasTileKind3D.pointParaboloidBack,
        lightIndex: ptIdx,
        subIndex: 1,
        tileSize: tileSize,
        lightPosition: ptLight.position,
        lightRange: ptRange,
        depthBias: ptSettings.depthBias,
        softness: ptSettings.softness.toDouble(),
        strength: ptSettings.strength.clamp(0.0, 1.0),
        color: ptSettings.color,
      );
    }

    if (atlas.tiles.isEmpty) {
      return _none();
    }

    final float = switch (primarySettings.encoding) {
      ShadowMapEncoding.auto => device.backend.supportsFloatTextureTargets,
      ShadowMapEncoding.float32 => true,
      ShadowMapEncoding.rgba8 => false,
    };
    final format = float ? GpuPixelFormat.r32Float : GpuPixelFormat.rgba8888;
    _packDepth = !float;
    if (float) {
      _decode.setValues(1, 0, 0, 0);
    } else {
      _decode.setFrom(_ShadowPass._packedDecode);
    }

    final atlasWidth = atlas.width;
    final atlasHeight = atlas.height;
    _staticMaps[projection] = null;
    if (split) {
      _writeAtlasMap(atlasWidth, atlasHeight, primarySettings);
      return _beginSplit(
        owner: projection,
        atlasPath: true,
        castersKey: castersKey,
        stillKey: stillCastersKey,
        width: atlasWidth,
        height: atlasHeight,
        float: float,
        format: format,
      );
    }
    _stillLayers[projection] = null;
    final cache =
        castersKey != null &&
        (dirSettings?.cacheWhenStatic ?? true) &&
        _spotCastersCache(spotCount) &&
        (pointSettings?.cacheWhenStatic ?? true);
    final GpuTextureTarget target;
    if (cache) {
      _writeAtlasSignature(atlasWidth, atlasHeight, float);
      var entry = _staticAtlases[projection];
      if (entry != null && entry.castersKey == castersKey) {
        if (entry.matches(_atlasSignature, _atlasSignatureLength)) {
          // The atlas of an earlier frame holds the same tiles of the same
          // casters: receive it again, without rendering.
          if (!identical(_texture, entry.texture)) {
            version++;
            _target = entry.target;
            _texture = entry.texture;
          }
          _writeAtlasMap(atlasWidth, atlasHeight, primarySettings);
          active = true;
          atlasActive = true;
          _mapIsAtlas = true;
          RenderProfile.switchPass(RenderPhase.shadowSetup, shadow: false);
          return false;
        }
      }
      if (entry == null ||
          entry.width != atlasWidth ||
          entry.height != atlasHeight ||
          entry.packDepth != !float) {
        final owned = device.backend.createTextureTarget(
          width: atlasWidth,
          height: atlasHeight,
          format: format,
          clearValue: const Color(0xFFFFFFFF),
        );
        entry = _StaticShadowAtlas(
          width: atlasWidth,
          height: atlasHeight,
          packDepth: !float,
          target: owned,
          texture: Texture(
            null,
            width: atlasWidth,
            height: atlasHeight,
            gpuTexture: owned.texture,
          ),
        );
        _staticAtlases[projection] = entry;
      }
      entry
        ..castersKey = castersKey
        ..store(_atlasSignature, _atlasSignatureLength);
      target = entry.target;
      _target = target;
      _texture = entry.texture;
    } else {
      _staticAtlases[projection] = null;
      target = device.textureTarget(atlasWidth, atlasHeight, format);
      if (!identical(target, _target)) {
        _target = target;
        _texture = Texture(
          null,
          width: atlasWidth,
          height: atlasHeight,
          gpuTexture: target.texture,
        );
      }
    }
    _unifiedAtlasTarget = target;

    _writeAtlasMap(atlasWidth, atlasHeight, primarySettings);

    version++;
    _mapIsAtlas = true;
    context._saveCameraSnapshot(_mainCamera);
    atlasActive = true;
    recording = true;
    _currentTileIndex = 0;
    _drawCallsBefore = device.stats.drawCalls;
    _trianglesBefore = device.stats.triangles;

    device.beginTexturePass(_unifiedAtlasTarget!, frontFace: context.frontFace);
    device.stats.shadowPasses++;
    _configureAtlasTile(atlas.tiles[0]);
    RenderProfile.lap(RenderPhase.passBegin);
    return true;
  }

  /// Whether the first [count] spot lights that cast shadows all set
  /// [ShadowSettings.cacheWhenStatic].
  bool _spotCastersCache(int count) {
    for (var k = 0; k < count; k++) {
      if (!(_spotCasters[k]!.source as SpotLight).shadows!.cacheWhenStatic) {
        return false;
      }
    }
    return true;
  }

  /// Whether the first [count] spot lights that cast shadows all set
  /// [ShadowSettings.cacheStillCasters].
  bool _spotCastersKeepStill(int count) {
    for (var k = 0; k < count; k++) {
      if (!(_spotCasters[k]!.source as SpotLight).shadows!.cacheStillCasters) {
        return false;
      }
    }
    return true;
  }

  /// Sets the values of the `Shadows` block that describe the atlas of
  /// [width] by [height] texels and its directional light, of [settings].
  void _writeAtlasMap(int width, int height, ShadowSettings settings) {
    _map.setValues(
      width.toDouble(),
      height.toDouble(),
      1.0 / width,
      1.0 / height,
    );
    final c = settings.color;
    _color.setValues(c.r, c.g, c.b, settings.strength.clamp(0.0, 1.0));
    _bias.setValues(
      _csmTiles.isNotEmpty ? _csmTiles.first.texelWorldSize : 0.02,
      settings.depthBias,
      settings.normalBias,
      settings.softness.toDouble(),
    );
  }

  /// Writes what the tiles of the [atlas] render into
  /// [_atlasSignature].
  void _writeAtlasSignature(int width, int height, bool float) {
    final out = _atlasSignature;
    var n = 0;
    out[n++] = width.toDouble();
    out[n++] = height.toDouble();
    out[n++] = float ? 1 : 0;
    final tiles = atlas.tiles;
    out[n++] = tiles.length.toDouble();
    for (var i = 0; i < tiles.length; i++) {
      final tile = tiles[i];
      out[n++] = tile.kind.index.toDouble();
      out[n++] = tile.lightIndex.toDouble();
      out[n++] = tile.x.toDouble();
      out[n++] = tile.y.toDouble();
      out[n++] = tile.width.toDouble();
      final viewProjection = tile.viewProjection;
      if (viewProjection != null) {
        final m = viewProjection.storage;
        for (var k = 0; k < 16; k++) {
          out[n++] = m[k];
        }
      } else {
        final position = tile.lightPosition;
        out[n++] = position?.x ?? 0;
        out[n++] = position?.y ?? 0;
        out[n++] = position?.z ?? 0;
        out[n++] = tile.lightRange;
      }
    }
    _atlasSignatureLength = n;
  }

  /// Sets the viewport and the camera of [tile]: the viewport of its own
  /// texture, where it starts at the origin, when [atOrigin].
  void _configureAtlasTile(ShadowAtlasTile3D tile, {bool atOrigin = false}) {
    final context = _context;
    final device = context.device;
    if (!atOrigin) {
      device
        ..setViewport(tile.x, tile.y, tile.width, tile.height)
        ..setScissor(tile.x, tile.y, tile.width, tile.height);
    }

    if (tile.kind == ShadowAtlasTileKind3D.pointParaboloidFront ||
        tile.kind == ShadowAtlasTileKind3D.pointParaboloidBack) {
      _recordingParaboloidTile = true;
      _paraboloidTileEpoch++;
      final pos = tile.lightPosition!;
      _paraboloidPosInvRange.setValues(
        pos.x,
        pos.y,
        pos.z,
        1.0 / math.max(1e-3, tile.lightRange),
      );
      final side = tile.kind == ShadowAtlasTileKind3D.pointParaboloidFront
          ? 1.0
          : -1.0;
      _paraboloidParams.setValues(side, 0, 0, 0);
      // The casters are culled with a box around the hemisphere of the light
      // the tile covers (its shaders do not use the camera's matrices).
      final range = tile.lightRange;
      writeLookAt(
        _pointCullView.storage,
        pos.x,
        pos.y,
        pos.z,
        pos.x,
        pos.y,
        pos.z + side,
        0,
        1,
        0,
      );
      writeOrthographic(
        _pointCullProjection.storage,
        -range,
        range,
        -range,
        range,
        -0.05 * range,
        range,
      );
      context.setCamera(_pointCullView, _pointCullProjection);
    } else {
      _recordingParaboloidTile = false;
      context.setCamera(tile.view!, tile.projection!);
    }
    atlasActive = true;
  }

  void writeShadowAtlas(UniformBlock block) {
    final off =
        (block.cachedWriterOffsets as _ShadowAtlasOffsets?) ??
        (block.cachedWriterOffsets = _ShadowAtlasOffsets(block));
    if (!active || !atlasActive) {
      if (off.header >= 0) {
        block.writeVec4ValuesAt(off.header, 0, 0, -1, 0);
      }
      return;
    }

    final dataLen = block.data.length;
    for (var c = 0; c < 4; c++) {
      if (c < _csmTiles.length) {
        final t = _csmTiles[c];
        if (off.csmViewProj >= 0 && off.csmViewProj + c * 16 + 16 <= dataLen) {
          block.writeMatrix4At(off.csmViewProj + c * 16, t.viewProjection!);
        }
        if (off.csmUvRect >= 0 && off.csmUvRect + c * 4 + 4 <= dataLen) {
          final r = t.uvRect;
          block.writeVec4ValuesAt(off.csmUvRect + c * 4, r.x, r.y, r.z, r.w);
        }
        if (off.csmMeta >= 0 && off.csmMeta + c * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(
            off.csmMeta + c * 4,
            t.texelWorldSize,
            0,
            t.blendRange,
            1.0,
          );
        }
      } else {
        if (off.csmViewProj >= 0 && off.csmViewProj + c * 16 + 16 <= dataLen) {
          block.writeMatrix4At(
            off.csmViewProj + c * 16,
            _ShadowPass._identityMat,
          );
        }
        if (off.csmUvRect >= 0 && off.csmUvRect + c * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.csmUvRect + c * 4, 0, 0, 0, 0);
        }
        if (off.csmMeta >= 0 && off.csmMeta + c * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.csmMeta + c * 4, 0, 0, 0, 0);
        }
      }
    }

    for (var s = 0; s < 2; s++) {
      if (s < _spotTiles.length) {
        final t = _spotTiles[s];
        final col = t.color;
        if (off.spotViewProj >= 0 &&
            off.spotViewProj + s * 16 + 16 <= dataLen) {
          block.writeMatrix4At(off.spotViewProj + s * 16, t.viewProjection!);
        }
        if (off.spotUvRect >= 0 && off.spotUvRect + s * 4 + 4 <= dataLen) {
          final r = t.uvRect;
          block.writeVec4ValuesAt(off.spotUvRect + s * 4, r.x, r.y, r.z, r.w);
        }
        if (off.spotMeta >= 0 && off.spotMeta + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(
            off.spotMeta + s * 4,
            t.lightIndex.toDouble(),
            t.texelWorldSize,
            t.depthBias,
            t.strength,
          );
        }
        if (off.spotColor >= 0 && off.spotColor + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(
            off.spotColor + s * 4,
            col.r,
            col.g,
            col.b,
            1.0,
          );
        }
      } else {
        if (off.spotViewProj >= 0 &&
            off.spotViewProj + s * 16 + 16 <= dataLen) {
          block.writeMatrix4At(
            off.spotViewProj + s * 16,
            _ShadowPass._identityMat,
          );
        }
        if (off.spotUvRect >= 0 && off.spotUvRect + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.spotUvRect + s * 4, 0, 0, 0, 0);
        }
        if (off.spotMeta >= 0 && off.spotMeta + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.spotMeta + s * 4, -1, 0, 0, 0);
        }
        if (off.spotColor >= 0 && off.spotColor + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.spotColor + s * 4, 0, 0, 0, 0);
        }
      }
    }

    final ptFront = _pointFrontTile;
    final ptBack = _pointBackTile;
    if (ptFront != null && ptBack != null) {
      final pos = ptFront.lightPosition!;
      final col = ptFront.color;
      if (off.pointPosRange >= 0) {
        block.writeVec4ValuesAt(
          off.pointPosRange,
          pos.x,
          pos.y,
          pos.z,
          1.0 / math.max(1e-3, ptFront.lightRange),
        );
      }
      if (off.pointFrontUvRect >= 0) {
        final fr = ptFront.uvRect;
        block.writeVec4ValuesAt(off.pointFrontUvRect, fr.x, fr.y, fr.z, fr.w);
      }
      if (off.pointBackUvRect >= 0) {
        final br = ptBack.uvRect;
        block.writeVec4ValuesAt(off.pointBackUvRect, br.x, br.y, br.z, br.w);
      }
      if (off.pointMeta >= 0) {
        block.writeVec4ValuesAt(
          off.pointMeta,
          ptFront.lightIndex.toDouble(),
          ptFront.depthBias,
          ptFront.softness,
          ptFront.strength,
        );
      }
      if (off.pointColor >= 0) {
        block.writeVec4ValuesAt(off.pointColor, col.r, col.g, col.b, 1.0);
      }
    } else if (off.pointMeta >= 0) {
      block.writeVec4ValuesAt(off.pointMeta, -1, 0, 0, 0);
    }

    if (off.header >= 0) {
      block.writeVec4ValuesAt(
        off.header,
        1.0,
        _atlasCascadeCount.toDouble(),
        _atlasDirLightIndex.toDouble(),
        _atlasSpotShadowCount.toDouble(),
      );
    }
  }
}

class _StaticShadowAtlas({
  required final int width,
  required final int height,
  required final bool packDepth,
  required final GpuTextureTarget target,
  required final Texture texture,
}) {
  /// The most floats a signature of the atlas takes: a header of 4, and 21
  /// per tile for at most 8 tiles.
  static const int signatureCapacity = 4 + 21 * 8;

  Object? castersKey;
  final Float64List _signature = Float64List(signatureCapacity);
  int _length = 0;

  bool matches(Float64List signature, int length) {
    if (length != _length) {
      return false;
    }
    for (var i = 0; i < length; i++) {
      if ((signature[i] - _signature[i]).abs() > 1e-9) {
        return false;
      }
    }
    return true;
  }

  void store(Float64List signature, int length) {
    _signature.setRange(0, length, signature);
    _length = length;
  }
}

class _ShadowAtlasOffsets(final UniformBlock _b) {
  late final int header = _b.resolveOffset('header');
  late final int csmViewProj = _b.resolveOffset('csmViewProj');
  late final int csmUvRect = _b.resolveOffset('csmUvRect');
  late final int csmMeta = _b.resolveOffset('csmMeta');
  late final int spotViewProj = _b.resolveOffset('spotViewProj');
  late final int spotUvRect = _b.resolveOffset('spotUvRect');
  late final int spotMeta = _b.resolveOffset('spotMeta');
  late final int spotColor = _b.resolveOffset('spotColor');
  late final int pointPosRange = _b.resolveOffset('pointPosRange');
  late final int pointFrontUvRect = _b.resolveOffset('pointFrontUvRect');
  late final int pointBackUvRect = _b.resolveOffset('pointBackUvRect');
  late final int pointMeta = _b.resolveOffset('pointMeta');
  late final int pointColor = _b.resolveOffset('pointColor');
}

class _ParaboloidOffsets(final UniformBlock _b) {
  late final int posInvRange = _b.resolveOffset('posInvRange');
  late final int params = _b.resolveOffset('params');
  int tileEpoch = -1;
}
