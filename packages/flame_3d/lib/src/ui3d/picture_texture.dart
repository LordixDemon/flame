import 'dart:async';
import 'dart:ui' as ui;

import 'package:flame_3d/graphics.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

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
  unawaited(
    picture
        .toImage(width, height)
        .then((image) {
          try {
            final texture = GpuBackend.instance.createTextureFromImage(image);
            if (texture == null) {
              debugPrint(
                'flame_3d: $owner could not use its rasterized picture as a '
                'texture.',
              );
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
