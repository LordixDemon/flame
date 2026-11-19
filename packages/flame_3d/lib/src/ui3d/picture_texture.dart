import 'dart:ui' as ui;

import 'package:flame_3d/graphics.dart';
import 'package:meta/meta.dart';

/// The GPU texture that shares the pixels of [image], an image that [owner]
/// rasterized from a picture, or `null` when no GPU backend can run in this
/// process (a plain `flutter test`), where nothing is drawn anyway.
///
/// Throws an [UnsupportedError] when the backend runs but cannot use an
/// image as a texture, as the WebGPU backend cannot: [owner] would otherwise
/// show a placeholder instead of its picture.
@internal
GpuTexture? textureOfRasterizedImage(ui.Image image, String owner) {
  if (!GpuBackend.isAvailable) {
    return null;
  }
  final texture = GpuBackend.instance.createTextureFromImage(image);
  if (texture == null) {
    throw UnsupportedError(
      '$owner needs a GPU backend that can use a dart:ui Image as a texture, '
      'as Flutter GPU does on Android, iOS and macOS. This backend (WebGPU on '
      'the web, for instance) cannot, so $owner cannot be shown.',
    );
  }
  return texture;
}
