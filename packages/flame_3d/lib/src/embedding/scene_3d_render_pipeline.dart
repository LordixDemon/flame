part of 'scene_3d_component.dart';

extension _Scene3DRenderPipeline on Scene3DComponent {
  void _renderScene(Canvas canvas) {
    final transform = canvas.getTransform();
    final a = transform[0];
    final b = transform[1];
    final c = transform[4];
    final d = transform[5];
    final tx = transform[12];
    final ty = transform[13];
    final determinant = a * d - b * c;
    if (!(determinant.abs() > 1e-12)) {
      return;
    }

    var visible = canvas.getDestinationClipBounds();
    final game = _resolveGame();
    if (visible.width > Scene3DComponent._unclipped ||
        visible.height > Scene3DComponent._unclipped) {
      if (game == null || !game.hasLayout) {
        return;
      }
      // The game's area, in the pixels of an offscreen picture when the
      // layer draws into one.
      final gameSize = game.canvasSize;
      final scale = RasterScale.current ?? 1.0;
      visible = visible.intersect(
        Rect.fromLTWH(0, 0, gameSize.x * scale, gameSize.y * scale),
      );
    }
    final width = size.x;
    final height = size.y;
    final bounded = width != 0 || height != 0;
    var localClip = bounded ? Rect.fromLTWH(0, 0, width, height) : null;
    final rect = visibleRect;
    if (rect != null) {
      localClip = localClip?.intersect(rect) ?? rect;
      if (localClip.isEmpty) {
        return;
      }
    }
    if (localClip != null) {
      visible = visible.intersect(
        _deviceBounds(
          a,
          b,
          c,
          d,
          tx + a * localClip.left + c * localClip.top,
          ty + b * localClip.left + d * localClip.top,
          localClip.width,
          localClip.height,
        ),
      );
    }
    if (visible.isEmpty) {
      return;
    }
    // What is seen of the layer, which the vignette is centered on, whatever
    // part of it the scene covers.
    final frame = visible;
    final scene = _sceneBounds(a, b, c, d, tx, ty);
    if (scene != null) {
      visible = visible.intersect(scene);
    }
    if (visible.isEmpty || !visible.isFinite) {
      return;
    }

    // On screen the canvas is in logical pixels; in an offscreen picture
    // that rasterizes at a scale of its own (a post process, a camera's
    // scaled world), its units are already the picture's pixels.
    final canvasPixelRatio = RasterScale.isActive
        ? 1.0
        : _pixelRatioOfGame(game);
    final fullScale = canvasPixelRatio * world.renderScale;
    var pixelScale = fullScale;
    var left = (visible.left * pixelScale).floor();
    var top = (visible.top * pixelScale).floor();
    var pixelWidth = (visible.right * pixelScale).ceil() - left;
    var pixelHeight = (visible.bottom * pixelScale).ceil() - top;
    final maxSize = _maxTextureSize;
    if (pixelWidth > maxSize || pixelHeight > maxSize) {
      pixelScale *= (maxSize - 2) / math.max(pixelWidth, pixelHeight);
      left = (visible.left * pixelScale).floor();
      top = (visible.top * pixelScale).floor();
      pixelWidth = (visible.right * pixelScale).ceil() - left;
      pixelHeight = (visible.bottom * pixelScale).ceil() - top;
    }
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      return;
    }

    final neededWidth = math.min(_roundUp(pixelWidth), maxSize);
    final neededHeight = math.min(_roundUp(pixelHeight), maxSize);
    if (_targetWidth < neededWidth ||
        _targetHeight < neededHeight ||
        _targetWidth > maxSize ||
        _targetHeight > maxSize ||
        _targetWidth * _targetHeight > 2 * neededWidth * neededHeight) {
      _targetWidth = neededWidth;
      _targetHeight = neededHeight;
    }
    final targetWidth = _targetWidth;
    final targetHeight = _targetHeight;

    _writeCamera(
      a,
      b,
      c,
      d,
      tx,
      ty,
      pixelScale,
      left,
      top,
      targetWidth,
      targetHeight,
    );

    final destination = Rect.fromLTRB(
      left / pixelScale,
      top / pixelScale,
      (left + pixelWidth) / pixelScale,
      (top + pixelHeight) / pixelScale,
    );
    final visibleFrame = Rect.fromLTRB(
      frame.left * pixelScale - left,
      frame.top * pixelScale - top,
      frame.right * pixelScale - left,
      frame.bottom * pixelScale - top,
    );

    // The map of a shadow group is fitted to what all its layers show: a
    // layer reports a camera that sees the part of the screen it may draw on
    // (whatever part of it its scene covers, so that the camera only changes
    // when the layer moves on the screen) on every frame, also when it draws
    // its retained image again.
    final group = world.shadowGroup;
    if (group != null) {
      _writeGroupCamera(group, frame, a, b, c, d, tx, ty);
    }

    final isRetained = _cacheMode == Scene3DCacheMode.retained;
    if (isRetained) {
      final retainedImage = _retainedImage;
      final retainedTarget = _retainedImageTarget;
      var hit = false;
      if (retainedImage != null && retainedTarget != null) {
        final kept = _retainedNumbers;
        final sceneMatch =
            world.sceneVersion.toDouble() == kept[0] &&
            _manualVersion.toDouble() == kept[1] &&
            (group?.castersVersion ?? world.castersVersion).toDouble() ==
                kept[2] &&
            (group?.viewsVersion ?? 0).toDouble() == kept[38] &&
            left.toDouble() == kept[3] &&
            top.toDouble() == kept[4] &&
            pixelWidth.toDouble() == kept[5] &&
            pixelHeight.toDouble() == kept[6] &&
            targetWidth.toDouble() == kept[7] &&
            targetHeight.toDouble() == kept[8] &&
            pixelScale == kept[9] &&
            msaa.sampleCount.toDouble() == kept[10] &&
            cameraMask.toDouble() == kept[11];
        if (sceneMatch &&
            sameMatrix16Approx(_viewMatrix.storage, _retainedView, 1e-9) &&
            sameMatrix16Approx(
              _projectionMatrix.storage,
              _retainedProj,
              1e-9,
            )) {
          final vignette = (world.postProcess?.vignetteIntensity ?? 0) > 0;
          if (!vignette ||
              (visibleFrame.left == kept[34] &&
                  visibleFrame.top == kept[35] &&
                  visibleFrame.right == kept[36] &&
                  visibleFrame.bottom == kept[37])) {
            hit = true;
          }
        }
      }
      if (!hit) {
        _writeKey(
          left,
          top,
          pixelWidth,
          pixelHeight,
          targetWidth,
          targetHeight,
          pixelScale,
          visibleFrame,
        );
        hit =
            retainedImage != null &&
            retainedTarget != null &&
            _keyMatches() &&
            sameMatrix16Approx(_viewMatrix.storage, _retainedView, 1e-9) &&
            sameMatrix16Approx(_projectionMatrix.storage, _retainedProj, 1e-9);
      }
      if (hit) {
        _cacheHitCount++;
        // The image is drawn again in this frame: its color texture must not
        // be rendered into before Flutter has finished drawing it.
        _resolveRenderer();
        _device!.backend.representLastImage(retainedTarget!);
        _compositeImage(
          canvas,
          retainedImage!,
          pixelWidth,
          pixelHeight,
          destination,
          a,
          b,
          c,
          d,
          tx,
          ty,
          determinant,
          localClip,
          pixelScale,
          fullScale,
        );
        return;
      }
    }

    _resolveRenderer();
    final device = _device!;
    final context = _context!;
    final game3D = _game3D;
    final bool closeFrame;
    if (game3D != null) {
      closeFrame = !game3D.isRenderingFrame;
      if (closeFrame) {
        device.begin();
      }
    } else {
      closeFrame = _renderer!.open();
    }

    _statsBefore.setFrom(device.stats);
    context
      ..cameraMask = cameraMask
      ..setCamera(_viewMatrix, _projectionMatrix);
    world.syncContextOptions(context);
    RenderProfile.lap(RenderPhase.setup);
    world
      ..renderShadows(canvas)
      ..renderDepthNormals(canvas, targetWidth, targetHeight);

    final usePost = world.needsPostCompositePass(device);
    GpuRenderTarget? ownedTarget;
    if (isRetained) {
      if (usePost) {
        if (_retainedBloomTarget == null ||
            _bloomTargetWidth != targetWidth ||
            _bloomTargetHeight != targetHeight) {
          _bloomTargetWidth = targetWidth;
          _bloomTargetHeight = targetHeight;
          _retainedBloomTarget = device.backend.createRenderTarget(
            width: targetWidth,
            height: targetHeight,
            clearValue: device.clearValue,
          );
        }
        ownedTarget = _retainedBloomTarget;
      } else {
        if (_retainedSceneTarget == null ||
            _sceneTargetWidth != targetWidth ||
            _sceneTargetHeight != targetHeight ||
            _sceneTargetMsaa != msaa.sampleCount) {
          _sceneTargetWidth = targetWidth;
          _sceneTargetHeight = targetHeight;
          _sceneTargetMsaa = msaa.sampleCount;
          _retainedSceneTarget = device.backend.createRenderTarget(
            width: targetWidth,
            height: targetHeight,
            clearValue: device.clearValue,
            msaaSampleCount: msaa.sampleCount,
          );
        }
        ownedTarget = _retainedSceneTarget;
      }
    }

    final image = world.executeWorldRenderPipeline(
      device: device,
      renderContext: context,
      width: targetWidth,
      height: targetHeight,
      msaaSampleCount: msaa.sampleCount,
      clearValue: device.clearValue,
      ownedOutputTarget: ownedTarget,
      recordDraws: () => world.renderScene(canvas),
      visibleFrame: visibleFrame,
    );

    _stats.setDifference(device.stats, _statsBefore);
    if (closeFrame) {
      if (game3D != null) {
        device.end();
      } else {
        _renderer!.close();
      }
    }
    RenderProfile.lap(RenderPhase.passEnd);

    _compositeImage(
      canvas,
      image,
      pixelWidth,
      pixelHeight,
      destination,
      a,
      b,
      c,
      d,
      tx,
      ty,
      determinant,
      localClip,
      pixelScale,
      fullScale,
    );

    if (isRetained) {
      _retainedImage?.dispose();
      _retainedImage = image;
      _retainedImageTarget = ownedTarget;
      _keepKey();
      _retainedView.setAll(0, _viewMatrix.storage);
      _retainedProj.setAll(0, _projectionMatrix.storage);
    } else {
      image.dispose();
    }
  }

  /// Reports to [group] the camera of the part [frame] of the canvas (whose
  /// transform is ([a], [b], [c], [d], [tx], [ty])) that the layer may draw
  /// on: the canvas's clip, its size and [visibleRect], and the picture of
  /// [visibleSceneBounds].
  void _writeGroupCamera(
    ShadowGroup group,
    Rect frame,
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
  ) {
    var part = frame;
    final bound = visibleSceneBounds;
    if (bound != null) {
      final picture = _boxPicture(bound, a, b, c, d, tx, ty);
      if (picture != null) {
        part = part.intersect(picture);
      }
    }
    if (!(part.width > 0 && part.height > 0)) {
      part = frame;
    }
    _writeProjection(
      _groupProjectionMatrix,
      a,
      b,
      c,
      d,
      tx,
      ty,
      1,
      part.left,
      part.top,
      part.width,
      part.height,
    );
    group.noteView(world, _viewMatrix, _groupProjectionMatrix);
  }

  void _compositeImage(
    Canvas canvas,
    Image image,
    int pixelWidth,
    int pixelHeight,
    Rect destination,
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    double determinant,
    Rect? localClip,
    double pixelScale,
    double fullScale,
  ) {
    final inverse = _inverseTransform
      ..[0] = d / determinant
      ..[1] = -b / determinant
      ..[4] = -c / determinant
      ..[5] = a / determinant
      ..[12] = (c * ty - d * tx) / determinant
      ..[13] = (b * tx - a * ty) / determinant;
    canvas.save();
    // The destination is axis-aligned on the device; a rotated or sheared
    // local rectangle needs a clip of its own.
    if (localClip != null && (b != 0 || c != 0)) {
      canvas.clipRect(localClip);
    }
    canvas.transform(inverse);
    _paint.filterQuality = pixelScale == fullScale && world.renderScale == 1.0
        ? FilterQuality.none
        : world.scaledFilterQuality;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, pixelWidth.toDouble(), pixelHeight.toDouble()),
      destination,
      _paint,
    );
    canvas.restore();
    _renderedRect = destination;
    RenderProfile.lap(RenderPhase.composite);
  }

  Rect? _sceneBounds(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
  ) {
    // A component left out of the scene bounds may draw anywhere.
    var box = world.hasUnboundedComponents ? null : world.sceneBounds;
    final bound = visibleSceneBounds;
    if (bound != null) {
      if (box == null) {
        box = bound;
      } else {
        box = _sceneBox
          ..min.setValues(
            math.max(box.min.x, bound.min.x),
            math.max(box.min.y, bound.min.y),
            math.max(box.min.z, bound.min.z),
          )
          ..max.setValues(
            math.min(box.max.x, bound.max.x),
            math.min(box.max.y, bound.max.y),
            math.min(box.max.z, bound.max.z),
          );
        if (box.min.x > box.max.x ||
            box.min.y > box.max.y ||
            box.min.z > box.max.z) {
          return Rect.zero;
        }
      }
    }
    if (box == null) {
      return null;
    }
    return _boxPicture(box, a, b, c, d, tx, ty);
  }

  /// The device rectangle that the picture of [box] covers on the canvas
  /// whose transform is ([a], [b], [c], [d], [tx], [ty]), or `null` when a
  /// corner of it lies behind the viewer.
  Rect? _boxPicture(
    Aabb3 box,
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
  ) {
    final m = projection.sceneToLocalValues;
    final min = box.min;
    final max = box.max;
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (var corner = 0; corner < 8; corner++) {
      final x = corner & 1 == 0 ? min.x : max.x;
      final y = corner & 2 == 0 ? min.y : max.y;
      final z = corner & 4 == 0 ? min.z : max.z;
      final w = m[3] * x + m[7] * y + m[11] * z + m[15];
      if (!(w > 0)) {
        return null;
      }
      final localX = (m[0] * x + m[4] * y + m[8] * z + m[12]) / w;
      final localY = (m[1] * x + m[5] * y + m[9] * z + m[13]) / w;
      final deviceX = a * localX + c * localY + tx;
      final deviceY = b * localX + d * localY + ty;
      left = math.min(left, deviceX);
      top = math.min(top, deviceY);
      right = math.max(right, deviceX);
      bottom = math.max(bottom, deviceY);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _writeCamera(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    double pixelScale,
    int left,
    int top,
    int targetWidth,
    int targetHeight,
  ) {
    _writeProjection(
      _projectionMatrix,
      a,
      b,
      c,
      d,
      tx,
      ty,
      pixelScale,
      left.toDouble(),
      top.toDouble(),
      targetWidth.toDouble(),
      targetHeight.toDouble(),
    );
    _viewMatrix.storage.setAll(0, projection.viewValues);
  }

  /// Writes into [output] the projection of the camera whose picture covers
  /// the rectangle from ([left], [top]), [width] by [height] pixels, of the
  /// canvas whose transform is ([a], [b], [c], [d], [tx], [ty]), at
  /// [pixelScale] pixels per unit of the canvas.
  void _writeProjection(
    Matrix4 output,
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    double pixelScale,
    double left,
    double top,
    double width,
    double height,
  ) {
    final sx = 2 * pixelScale / width;
    final sy = 2 * pixelScale / height;
    final c00 = sx * a;
    final c01 = sx * c;
    final c03 = 2 * (pixelScale * tx - left) / width - 1;
    final c10 = -sy * b;
    final c11 = -sy * d;
    final c13 = 1 - 2 * (pixelScale * ty - top) / height;

    final viewToLocal = projection.viewToLocalValues;
    final p = output.storage;
    for (var column = 0; column < 4; column++) {
      final i = column * 4;
      final x = viewToLocal[i];
      final y = viewToLocal[i + 1];
      final w = viewToLocal[i + 3];
      p[i] = c00 * x + c01 * y + c03 * w;
      p[i + 1] = c10 * x + c11 * y + c13 * w;
      p[i + 2] = viewToLocal[i + 2];
      p[i + 3] = w;
    }
  }
}

int _roundUp(int pixels) =>
    (pixels + Scene3DComponent._bucket - 1) ~/
    Scene3DComponent._bucket *
    Scene3DComponent._bucket;

Rect _deviceBounds(
  double a,
  double b,
  double c,
  double d,
  double tx,
  double ty,
  double width,
  double height,
) {
  final x1 = a * width;
  final y1 = b * width;
  final x2 = c * height;
  final y2 = d * height;
  return Rect.fromLTRB(
    tx + math.min(0.0, x1) + math.min(0.0, x2),
    ty + math.min(0.0, y1) + math.min(0.0, y2),
    tx + math.max(0.0, x1) + math.max(0.0, x2),
    ty + math.max(0.0, y1) + math.max(0.0, y2),
  );
}
