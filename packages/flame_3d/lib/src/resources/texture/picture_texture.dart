import 'dart:async';
import 'dart:ui' as ui;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/src/graphics/backend/texture_sampler.dart';
import 'package:flame_3d/src/resources/texture/image_texture.dart';
import 'package:flame_3d/src/resources/texture/texture.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

/// Shared picture-to-[ImageTexture] slot managing async rasterization,
/// request invalidation, GPU device-loss recovery, and safe unmount/remount
/// lifecycle across 3D text/UI surfaces.
@internal
final class PictureTextureSlot({
  required final String owner,
  required final void Function() onDeviceRecovered,
}) {
  ImageTexture? _texture;
  int _rasterRequest = 0;
  bool _released = false;

  late final GpuDeviceListener _deviceListener = GpuDeviceListener(
    onRecovered: (_) {
      if (!_released) {
        onDeviceRecovered();
      }
    },
  );

  /// Currently active rasterized [ImageTexture], or `null` before first upload
  /// or after [detach].
  ImageTexture? get texture => _texture;

  /// Attaches this slot's device-loss listener. Returns `true` when resuming
  /// after a previous [detach], signaling the caller to re-rasterize.
  bool attach() {
    GpuBackend.addDeviceListener(_deviceListener);
    if (_released) {
      _released = false;
      return true;
    }
    return false;
  }

  /// Cancels in-flight rasterization requests, detaches the device listener,
  /// disposes any owned texture, and clears the material binding.
  void detach({required void Function() clearMaterialTexture}) {
    GpuBackend.removeDeviceListener(_deviceListener);
    ++_rasterRequest;
    final current = _texture;
    if (current != null && current.hasResource) {
      current.dispose();
    }
    _texture = null;
    clearMaterialTexture();
    _released = true;
  }

  /// Rasterizes [picture] into a GPU texture (or fallback texture in headless
  /// tests), replacing any prior texture once completed.
  bool rasterize(
    ui.Picture picture, {
    required int width,
    required int height,
    required Texture Function(int width, int height) createFallbackTexture,
    required void Function(Texture texture) applyTexture,
  }) {
    final request = ++_rasterRequest;
    final ready = rasterizePictureTexture(
      picture,
      width,
      height,
      owner,
      (gpuTex) {
        if (request != _rasterRequest || _released) {
          return;
        }
        final prev = _texture;
        final Texture applied;
        if (gpuTex != null) {
          final next = ImageTexture(
            null,
            width: width,
            height: height,
            sampler: TextureSampler.linear,
            gpuTexture: gpuTex,
          );
          _texture = next;
          applied = next;
        } else {
          final fallback = createFallbackTexture(width, height);
          _texture = fallback is ImageTexture ? fallback : null;
          applied = fallback;
        }
        applyTexture(applied);
        if (prev != null && prev.hasResource) {
          prev.dispose();
        }
      },
    );
    if (!ready && _texture == null) {
      applyTexture(Texture.empty);
    }
    return ready;
  }
}

GpuBackend? _preferAsyncBackend;
int _preferAsyncGeneration = -1;

/// Rasterizes [picture] at [width] by [height] pixels into a GPU texture
/// that shares the image's pixels, for [owner], and hands it to [onTexture].
///
/// The image of `Picture.toImageSync` is used when it already has a GPU
/// texture (as under `flutter test`); on devices it is rasterized later and
/// has none yet, so the picture is rasterized again with the asynchronous
/// `Picture.toImage`, and [onTexture] is called once it completes. Returns
/// whether [onTexture] was called before returning. The picture is disposed
/// once it is no longer needed.
///
/// [onTexture] gets `null` when no GPU backend can run in this process (a
/// plain `flutter test`), where nothing is drawn anyway, and when the
/// asynchronous image could not be used either (reported with
/// `debugPrint`).
///
/// Throws an [UnsupportedError] when the backend runs but cannot use an
/// image as a texture, as the WebGPU backend cannot: [owner] would otherwise
/// show a placeholder instead of its picture.
@internal
bool rasterizePictureTexture(
  ui.Picture picture,
  int width,
  int height,
  String owner,
  void Function(GpuTexture? texture) onTexture,
) {
  if (!GpuBackend.isAvailable) {
    picture.dispose();
    onTexture(null);
    return true;
  }
  final backend = GpuBackend.instance;
  if (!backend.supportsTexturesFromImages) {
    picture.dispose();
    throw UnsupportedError(
      '$owner needs a GPU backend that can use a dart:ui Image as a texture, '
      'as Flutter GPU does on Android, iOS and macOS. This backend (WebGPU on '
      'the web, for instance) cannot, so $owner cannot be shown.',
    );
  }
  final generation = GpuBackend.deviceGeneration;
  final skipSync =
      identical(_preferAsyncBackend, backend) &&
      _preferAsyncGeneration == generation;
  if (!skipSync) {
    final image = picture.toImageSync(width, height);
    final GpuTexture? texture;
    try {
      texture = backend.createTextureFromImage(image);
    } finally {
      image.dispose();
    }
    if (texture != null) {
      picture.dispose();
      onTexture(texture);
      return true;
    }
  }
  unawaited(
    picture
        .toImage(width, height)
        .then((image) {
          try {
            final currentBackend = GpuBackend.instance;
            final texture = currentBackend.createTextureFromImage(image);
            if (texture == null) {
              debugPrint(
                'flame_3d: $owner could not use its rasterized picture as a '
                'texture.',
              );
            } else {
              _preferAsyncBackend = currentBackend;
              _preferAsyncGeneration = GpuBackend.deviceGeneration;
            }
            onTexture(texture);
          } finally {
            image.dispose();
          }
        })
        .whenComplete(picture.dispose),
  );
  return false;
}
