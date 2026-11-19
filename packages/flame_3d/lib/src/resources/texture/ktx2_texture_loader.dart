import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// Metadata of a single mip level in a parsed [Ktx2Container].
class const Ktx2MipLevel({
  required final int byteOffset,
  required final int byteLength,
  required final int uncompressedByteLength,
  required final int width,
  required final int height,
});

/// Parsed Khronos KTX 2.0 binary texture container.
class Ktx2Container({
  required final int vkFormat,
  required final GpuPixelFormat gpuFormat,
  required final bool isSrgb,
  required final int width,
  required final int height,
  required final int levelCount,
  required final int supercompressionScheme,
  required final List<Ktx2MipLevel> levels,
  required final Uint8List bytes,
}) {
  /// Returns a zero-copy view over the payload bytes of [mipLevel].
  ByteData levelData(int mipLevel) {
    final entry = levels[mipLevel];
    return ByteData.sublistView(
      bytes,
      entry.byteOffset,
      entry.byteOffset + entry.byteLength,
    );
  }
}

/// Loader, encoder, and software block-decompression fallback for Khronos
/// KTX 2.0 (`.ktx2`) textures.
///
/// When the active [GpuBackend] supports the container's [GpuPixelFormat]
/// natively (e.g. `BC1`/`BC3`/`BC7` on desktop GPUs, `ETC2`/`ASTC` on mobile
/// GPUs, or `rgbaFloat16`/`rgba8888Srgb`), compressed mip payloads are uploaded
/// directly to GPU memory without CPU expansion. When hardware lacks support
/// for that compression family, blocks are decoded to `RGBA8888` seamlessly.
abstract final class Ktx2TextureLoader() {
  /// Khronos KTX 2.0 12-byte file identifier (`«KTX 20»\r\n\x1A\n`).
  static const List<int> identifier = [
    0xAB,
    0x4B,
    0x54,
    0x58,
    0x20,
    0x32,
    0x30,
    0xBB,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];

  // Common Vulkan VkFormat constants stored in KTX 2.0 headers.
  static const int vkFormatR8G8B8A8Unorm = 37;
  static const int vkFormatR8G8B8A8Srgb = 43;
  static const int vkFormatB8G8R8A8Unorm = 44;
  static const int vkFormatB8G8R8A8Srgb = 50;
  static const int vkFormatR16G16B16A16Sfloat = 97;
  static const int vkFormatR32G32B32A32Sfloat = 109;
  static const int vkFormatBc1RgbUnormBlock = 131;
  static const int vkFormatBc1RgbSrgbBlock = 132;
  static const int vkFormatBc1RgbaUnormBlock = 133;
  static const int vkFormatBc1RgbaSrgbBlock = 134;
  static const int vkFormatBc3UnormBlock = 137;
  static const int vkFormatBc3SrgbBlock = 138;
  static const int vkFormatBc7UnormBlock = 145;
  static const int vkFormatBc7SrgbBlock = 146;
  static const int vkFormatEtc2R8G8B8UnormBlock = 147;
  static const int vkFormatEtc2R8G8B8SrgbBlock = 148;
  static const int vkFormatEtc2R8G8B8A8UnormBlock = 151;
  static const int vkFormatEtc2R8G8B8A8SrgbBlock = 152;
  static const int vkFormatAstc4x4UnormBlock = 157;
  static const int vkFormatAstc4x4SrgbBlock = 158;
  static const int vkFormatAstc8x8UnormBlock = 171;
  static const int vkFormatAstc8x8SrgbBlock = 172;

  /// Maps a Vulkan `vkFormat` code to `(GpuPixelFormat, isSrgb)`.
  static (GpuPixelFormat, bool) mapVkFormat(int vkFormat) {
    return switch (vkFormat) {
      vkFormatR8G8B8A8Unorm => (GpuPixelFormat.rgba8888, false),
      vkFormatR8G8B8A8Srgb => (GpuPixelFormat.rgba8888Srgb, true),
      vkFormatB8G8R8A8Unorm => (GpuPixelFormat.bgra8888, false),
      vkFormatB8G8R8A8Srgb => (GpuPixelFormat.bgra8888Srgb, true),
      vkFormatR16G16B16A16Sfloat => (GpuPixelFormat.rgbaFloat16, false),
      vkFormatR32G32B32A32Sfloat => (GpuPixelFormat.rgbaFloat32, false),
      vkFormatBc1RgbUnormBlock ||
      vkFormatBc1RgbaUnormBlock => (GpuPixelFormat.bc1Rgba, false),
      vkFormatBc1RgbSrgbBlock ||
      vkFormatBc1RgbaSrgbBlock => (GpuPixelFormat.bc1RgbaSrgb, true),
      vkFormatBc3UnormBlock => (GpuPixelFormat.bc3Rgba, false),
      vkFormatBc3SrgbBlock => (GpuPixelFormat.bc3RgbaSrgb, true),
      vkFormatBc7UnormBlock => (GpuPixelFormat.bc7Rgba, false),
      vkFormatBc7SrgbBlock => (GpuPixelFormat.bc7RgbaSrgb, true),
      vkFormatEtc2R8G8B8UnormBlock => (GpuPixelFormat.etc2Rgb8, false),
      vkFormatEtc2R8G8B8SrgbBlock => (GpuPixelFormat.etc2Rgb8Srgb, true),
      vkFormatEtc2R8G8B8A8UnormBlock => (GpuPixelFormat.etc2Rgba8, false),
      vkFormatEtc2R8G8B8A8SrgbBlock => (GpuPixelFormat.etc2Rgba8Srgb, true),
      vkFormatAstc4x4UnormBlock => (GpuPixelFormat.astc4x4, false),
      vkFormatAstc4x4SrgbBlock => (GpuPixelFormat.astc4x4Srgb, true),
      vkFormatAstc8x8UnormBlock => (GpuPixelFormat.astc8x8, false),
      vkFormatAstc8x8SrgbBlock => (GpuPixelFormat.astc8x8Srgb, true),
      _ => throw FormatException('Unsupported KTX2 vkFormat: $vkFormat'),
    };
  }

  /// Parses the KTX 2.0 header and level index table from [bytes].
  static Ktx2Container parse(Uint8List bytes) {
    if (bytes.length < 80) {
      throw const FormatException('KTX2 file is shorter than 80-byte header');
    }
    for (var i = 0; i < identifier.length; i++) {
      if (bytes[i] != identifier[i]) {
        throw const FormatException('Invalid KTX 2.0 magic identifier');
      }
    }

    final header = ByteData.sublistView(bytes);
    final vkFormat = header.getUint32(12, Endian.little);
    final pixelWidth = header.getUint32(20, Endian.little);
    final pixelHeight = math.max(1, header.getUint32(24, Endian.little));
    final rawLevelCount = header.getUint32(40, Endian.little);
    final levelCount = math.max(1, rawLevelCount);
    final supercompression = header.getUint32(44, Endian.little);
    if (supercompression != 0) {
      throw UnsupportedError(
        'KTX2 supercompressionScheme $supercompression is not supported '
        '(expected 0 / uncompressed container)',
      );
    }
    if (pixelWidth <= 0) {
      throw const FormatException('KTX2 pixelWidth must be positive');
    }
    final indexTableEnd = 80 + levelCount * 24;
    if (bytes.length < indexTableEnd) {
      throw const FormatException('KTX2 truncated inside level index table');
    }

    final (gpuFormat, isSrgb) = mapVkFormat(vkFormat);
    final levels = <Ktx2MipLevel>[];
    for (var i = 0; i < levelCount; i++) {
      final base = 80 + i * 24;
      final byteOffset = _readUint64LE(header, base);
      final byteLength = _readUint64LE(header, base + 8);
      final uncompressedLength = _readUint64LE(header, base + 16);
      if (byteOffset < 0 || byteOffset + byteLength > bytes.length) {
        throw FormatException('KTX2 mip level $i exceeds file bounds');
      }
      final mipW = math.max(1, pixelWidth >> i);
      final mipH = math.max(1, pixelHeight >> i);
      levels.add(
        Ktx2MipLevel(
          byteOffset: byteOffset,
          byteLength: byteLength,
          uncompressedByteLength: uncompressedLength,
          width: mipW,
          height: mipH,
        ),
      );
    }

    return Ktx2Container(
      vkFormat: vkFormat,
      gpuFormat: gpuFormat,
      isSrgb: isSrgb,
      width: pixelWidth,
      height: pixelHeight,
      levelCount: levelCount,
      supercompressionScheme: supercompression,
      levels: List.unmodifiable(levels),
      bytes: bytes,
    );
  }

  /// Loads [bytes] as a [Texture] (uploading compressed blocks directly when
  /// [backend] supports the format, or decoding to `RGBA8888` otherwise).
  static Texture load(
    Uint8List bytes, {
    GpuBackend? backend,
    TextureSampler sampler = TextureSampler.linear,
  }) {
    final container = parse(bytes);
    return _Ktx2Texture(container, sampler: sampler, explicitBackend: backend);
  }

  /// Encodes raw `RGBA8888` [rgbaPixels] (with optional prebuilt [mipLevels])
  /// into a valid Khronos KTX 2.0 binary container.
  static Uint8List encodeUncompressedRgba8(
    Uint8List rgbaPixels, {
    required int width,
    required int height,
    bool srgb = false,
    List<Uint8List>? mipLevels,
  }) {
    final levels = mipLevels ?? <Uint8List>[rgbaPixels];
    if (levels.isEmpty || levels.first.length != width * height * 4) {
      throw ArgumentError('Base mip level must have width * height * 4 bytes');
    }
    return _packContainer(
      vkFormat: srgb ? vkFormatR8G8B8A8Srgb : vkFormatR8G8B8A8Unorm,
      typeSize: 1,
      width: width,
      height: height,
      mipPayloads: levels,
    );
  }

  /// Compresses `RGBA8888` [rgbaPixels] into `4x4` `BC1` (`DXT1`) 8-byte blocks
  /// and wraps them in a valid Khronos KTX 2.0 binary container.
  static Uint8List encodeBc1(
    Uint8List rgbaPixels, {
    required int width,
    required int height,
    bool srgb = false,
  }) {
    if (rgbaPixels.length != width * height * 4) {
      throw ArgumentError(
        'rgbaPixels length (${rgbaPixels.length}) must equal '
        'width * height * 4 (${width * height * 4})',
      );
    }
    final compressed = compressRgba8ToBc1Blocks(rgbaPixels, width, height);
    return _packContainer(
      vkFormat: srgb ? vkFormatBc1RgbaSrgbBlock : vkFormatBc1RgbaUnormBlock,
      typeSize: 1,
      width: width,
      height: height,
      mipPayloads: <Uint8List>[compressed],
    );
  }

  /// Compresses `RGBA8888` pixels into tightly packed `4x4` BC1 (`DXT1`)
  /// blocks (`8` bytes per `4x4` block).
  static Uint8List compressRgba8ToBc1Blocks(
    Uint8List rgba,
    int width,
    int height,
  ) {
    final blocksWide = (width + 3) ~/ 4;
    final blocksHigh = (height + 3) ~/ 4;
    final out = Uint8List(blocksWide * blocksHigh * 8);
    final outData = ByteData.sublistView(out);

    final blockR = Int32List(16);
    final blockG = Int32List(16);
    final blockB = Int32List(16);

    var blockOffset = 0;
    for (var by = 0; by < blocksHigh; by++) {
      for (var bx = 0; bx < blocksWide; bx++) {
        for (var py = 0; py < 4; py++) {
          final sy = math.min(height - 1, by * 4 + py);
          for (var px = 0; px < 4; px++) {
            final sx = math.min(width - 1, bx * 4 + px);
            final p = (sy * width + sx) * 4;
            final t = py * 4 + px;
            blockR[t] = rgba[p];
            blockG[t] = rgba[p + 1];
            blockB[t] = rgba[p + 2];
          }
        }

        // Select the pair of texels with maximal Euclidean RGB separation as
        // endpoints so opposite-channel colors (e.g. red vs green) are
        // preserved instead of collapsing onto a yellow-black bounding box!
        var endA = 0;
        var endB = 0;
        var bestDist = -1;
        for (var i = 0; i < 16; i++) {
          for (var j = i + 1; j < 16; j++) {
            final dr = blockR[i] - blockR[j];
            final dg = blockG[i] - blockG[j];
            final db = blockB[i] - blockB[j];
            final dist = dr * dr + dg * dg + db * db;
            if (dist > bestDist) {
              bestDist = dist;
              endA = i;
              endB = j;
            }
          }
        }

        var c0 = _packRgb565(blockR[endA], blockG[endA], blockB[endA]);
        var c1 = _packRgb565(blockR[endB], blockG[endB], blockB[endB]);
        if (c0 < c1) {
          final tmp = c0;
          c0 = c1;
          c1 = tmp;
        }

        final (r0, g0, b0) = _unpackRgb565(c0);
        final (r1, g1, b1) = _unpackRgb565(c1);
        final palR = <int>[
          r0,
          r1,
          if (c0 > c1) (2 * r0 + r1 + 1) ~/ 3 else (r0 + r1) ~/ 2,
          if (c0 > c1) (r0 + 2 * r1 + 1) ~/ 3 else 0,
        ];
        final palG = <int>[
          g0,
          g1,
          if (c0 > c1) (2 * g0 + g1 + 1) ~/ 3 else (g0 + g1) ~/ 2,
          if (c0 > c1) (g0 + 2 * g1 + 1) ~/ 3 else 0,
        ];
        final palB = <int>[
          b0,
          b1,
          if (c0 > c1) (2 * b0 + b1 + 1) ~/ 3 else (b0 + b1) ~/ 2,
          if (c0 > c1) (b0 + 2 * b1 + 1) ~/ 3 else 0,
        ];
        final paletteCount = c0 > c1 ? 4 : 3;

        var indices = 0;
        for (var py = 0; py < 4; py++) {
          final sy = math.min(height - 1, by * 4 + py);
          for (var px = 0; px < 4; px++) {
            final sx = math.min(width - 1, bx * 4 + px);
            final p = (sy * width + sx) * 4;
            final r = rgba[p];
            final g = rgba[p + 1];
            final b = rgba[p + 2];

            var bestIdx = 0;
            var bestErr = 0x7FFFFFFF;
            for (var k = 0; k < paletteCount; k++) {
              final dr = r - palR[k];
              final dg = g - palG[k];
              final db = b - palB[k];
              final err = dr * dr + dg * dg + db * db;
              if (err < bestErr) {
                bestErr = err;
                bestIdx = k;
              }
            }
            final bitPos = (py * 4 + px) * 2;
            indices |= (bestIdx & 0x3) << bitPos;
          }
        }

        outData
          ..setUint16(blockOffset, c0, Endian.little)
          ..setUint16(blockOffset + 2, c1, Endian.little)
          ..setUint32(blockOffset + 4, indices, Endian.little);
        blockOffset += 8;
      }
    }
    return out;
  }

  /// Decodes `4x4` BC1 (`DXT1`) compressed blocks into `RGBA8888` pixels.
  static Uint8List decodeBc1ToRgba8(
    Uint8List bc1Blocks,
    int width,
    int height,
  ) {
    final blocksWide = (width + 3) ~/ 4;
    final blocksHigh = (height + 3) ~/ 4;
    final out = Uint8List(width * height * 4);
    final src = ByteData.sublistView(bc1Blocks);

    var blockOffset = 0;
    for (var by = 0; by < blocksHigh; by++) {
      for (var bx = 0; bx < blocksWide; bx++) {
        final c0 = src.getUint16(blockOffset, Endian.little);
        final c1 = src.getUint16(blockOffset + 2, Endian.little);
        final bits = src.getUint32(blockOffset + 4, Endian.little);
        blockOffset += 8;

        final (r0, g0, b0) = _unpackRgb565(c0);
        final (r1, g1, b1) = _unpackRgb565(c1);

        final int r2;
        final int g2;
        final int b2;
        const a2 = 255;
        final int r3;
        final int g3;
        final int b3;
        final int a3;
        if (c0 > c1) {
          r2 = (2 * r0 + r1 + 1) ~/ 3;
          g2 = (2 * g0 + g1 + 1) ~/ 3;
          b2 = (2 * b0 + b1 + 1) ~/ 3;
          r3 = (r0 + 2 * r1 + 1) ~/ 3;
          g3 = (g0 + 2 * g1 + 1) ~/ 3;
          b3 = (b0 + 2 * b1 + 1) ~/ 3;
          a3 = 255;
        } else {
          r2 = (r0 + r1) ~/ 2;
          g2 = (g0 + g1) ~/ 2;
          b2 = (b0 + b1) ~/ 2;
          r3 = 0;
          g3 = 0;
          b3 = 0;
          a3 = 0;
        }

        for (var py = 0; py < 4; py++) {
          final dy = by * 4 + py;
          if (dy >= height) {
            continue;
          }
          for (var px = 0; px < 4; px++) {
            final dx = bx * 4 + px;
            if (dx >= width) {
              continue;
            }
            final code = (bits >> ((py * 4 + px) * 2)) & 0x3;
            final dst = (dy * width + dx) * 4;
            switch (code) {
              case 0:
                out[dst] = r0;
                out[dst + 1] = g0;
                out[dst + 2] = b0;
                out[dst + 3] = 255;
              case 1:
                out[dst] = r1;
                out[dst + 1] = g1;
                out[dst + 2] = b1;
                out[dst + 3] = 255;
              case 2:
                out[dst] = r2;
                out[dst + 1] = g2;
                out[dst + 2] = b2;
                out[dst + 3] = a2;
              default:
                out[dst] = r3;
                out[dst + 1] = g3;
                out[dst + 2] = b3;
                out[dst + 3] = a3;
            }
          }
        }
      }
    }
    return out;
  }

  /// Decodes `4x4` BC3 (`DXT5`) compressed blocks into `RGBA8888` pixels.
  static Uint8List decodeBc3ToRgba8(
    Uint8List bc3Blocks,
    int width,
    int height,
  ) {
    final blocksWide = (width + 3) ~/ 4;
    final blocksHigh = (height + 3) ~/ 4;
    final out = Uint8List(width * height * 4);
    final src = ByteData.sublistView(bc3Blocks);

    var blockOffset = 0;
    for (var by = 0; by < blocksHigh; by++) {
      for (var bx = 0; bx < blocksWide; bx++) {
        final a0 = bc3Blocks[blockOffset];
        final a1 = bc3Blocks[blockOffset + 1];
        var alphaBitsLo = 0;
        var alphaBitsHi = 0;
        for (var i = 0; i < 3; i++) {
          alphaBitsLo |= bc3Blocks[blockOffset + 2 + i] << (i * 8);
          alphaBitsHi |= bc3Blocks[blockOffset + 5 + i] << (i * 8);
        }

        final c0 = src.getUint16(blockOffset + 8, Endian.little);
        final c1 = src.getUint16(blockOffset + 10, Endian.little);
        final colorBits = src.getUint32(blockOffset + 12, Endian.little);
        blockOffset += 16;

        final (r0, g0, b0) = _unpackRgb565(c0);
        final (r1, g1, b1) = _unpackRgb565(c1);
        final r2 = (2 * r0 + r1 + 1) ~/ 3;
        final g2 = (2 * g0 + g1 + 1) ~/ 3;
        final b2 = (2 * b0 + b1 + 1) ~/ 3;
        final r3 = (r0 + 2 * r1 + 1) ~/ 3;
        final g3 = (g0 + 2 * g1 + 1) ~/ 3;
        final b3 = (b0 + 2 * b1 + 1) ~/ 3;

        for (var py = 0; py < 4; py++) {
          final dy = by * 4 + py;
          if (dy >= height) {
            continue;
          }
          for (var px = 0; px < 4; px++) {
            final dx = bx * 4 + px;
            if (dx >= width) {
              continue;
            }
            final texelIdx = py * 4 + px;
            final int aCode;
            if (texelIdx < 8) {
              aCode = (alphaBitsLo >> (texelIdx * 3)) & 0x7;
            } else {
              aCode = (alphaBitsHi >> ((texelIdx - 8) * 3)) & 0x7;
            }
            final int alpha;
            if (aCode == 0) {
              alpha = a0;
            } else if (aCode == 1) {
              alpha = a1;
            } else if (a0 > a1) {
              alpha = ((8 - aCode) * a0 + (aCode - 1) * a1 + 3) ~/ 7;
            } else if (aCode == 6) {
              alpha = 0;
            } else if (aCode == 7) {
              alpha = 255;
            } else {
              alpha = ((6 - aCode) * a0 + (aCode - 1) * a1 + 2) ~/ 5;
            }

            final cCode = (colorBits >> (texelIdx * 2)) & 0x3;
            final dst = (dy * width + dx) * 4;
            switch (cCode) {
              case 0:
                out[dst] = r0;
                out[dst + 1] = g0;
                out[dst + 2] = b0;
              case 1:
                out[dst] = r1;
                out[dst + 1] = g1;
                out[dst + 2] = b1;
              case 2:
                out[dst] = r2;
                out[dst + 1] = g2;
                out[dst + 2] = b2;
              default:
                out[dst] = r3;
                out[dst + 1] = g3;
                out[dst + 2] = b3;
            }
            out[dst + 3] = alpha;
          }
        }
      }
    }
    return out;
  }

  static Uint8List _decodeMipToRgba8(
    Ktx2Container container,
    int mipIndex,
  ) {
    final mip = container.levels[mipIndex];
    final payload = Uint8List.sublistView(
      container.bytes,
      mip.byteOffset,
      mip.byteOffset + mip.byteLength,
    );
    return switch (container.gpuFormat) {
      GpuPixelFormat.rgba8888 || GpuPixelFormat.rgba8888Srgb => payload,
      GpuPixelFormat.bgra8888 || GpuPixelFormat.bgra8888Srgb => () {
        final out = Uint8List(payload.length);
        for (var i = 0; i + 3 < payload.length; i += 4) {
          out[i] = payload[i + 2];
          out[i + 1] = payload[i + 1];
          out[i + 2] = payload[i];
          out[i + 3] = payload[i + 3];
        }
        return out;
      }(),
      GpuPixelFormat.rgbaFloat16 => _decodeHalfFloatToRgba8(payload),
      GpuPixelFormat.bc1Rgba || GpuPixelFormat.bc1RgbaSrgb => decodeBc1ToRgba8(
        payload,
        mip.width,
        mip.height,
      ),
      GpuPixelFormat.bc3Rgba || GpuPixelFormat.bc3RgbaSrgb => decodeBc3ToRgba8(
        payload,
        mip.width,
        mip.height,
      ),
      _ => throw UnsupportedError(
        'Hardware does not support ${container.gpuFormat} and no CPU '
        'decompressor is registered for this format.',
      ),
    };
  }

  static Uint8List _decodeHalfFloatToRgba8(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    final texels = bytes.length ~/ 8;
    final out = Uint8List(texels * 4);
    for (var i = 0; i < texels; i++) {
      for (var c = 0; c < 4; c++) {
        final f = _halfToDouble(view.getUint16(i * 8 + c * 2, Endian.little));
        out[i * 4 + c] = (f.clamp(0.0, 1.0) * 255.0).round();
      }
    }
    return out;
  }

  static double _halfToDouble(int h) {
    final sign = (h & 0x8000) != 0 ? -1.0 : 1.0;
    final exp = (h >> 10) & 0x1F;
    final mant = h & 0x03FF;
    if (exp == 0) {
      return sign * (mant / 1024.0) * math.pow(2.0, -14);
    }
    if (exp == 31) {
      return mant == 0 ? sign * double.infinity : double.nan;
    }
    return sign * (1.0 + mant / 1024.0) * math.pow(2.0, exp - 15);
  }

  static Uint8List _packContainer({
    required int vkFormat,
    required int typeSize,
    required int width,
    required int height,
    required List<Uint8List> mipPayloads,
  }) {
    final levelCount = mipPayloads.length;
    final headerAndIndexSize = 80 + levelCount * 24;
    var cursor = _align4(headerAndIndexSize);

    // KTX 2.0 stores mip levels from smallest (N-1) to largest (0), or at any
    // 4-byte-aligned offset recorded in the level index table.
    final offsets = List<int>.filled(levelCount, 0);
    for (var i = levelCount - 1; i >= 0; i--) {
      offsets[i] = cursor;
      cursor = _align4(cursor + mipPayloads[i].length);
    }

    final totalBytes = Uint8List(cursor);
    for (var i = 0; i < identifier.length; i++) {
      totalBytes[i] = identifier[i];
    }
    final view = ByteData.sublistView(totalBytes)
      ..setUint32(12, vkFormat, Endian.little)
      ..setUint32(16, typeSize, Endian.little)
      ..setUint32(20, width, Endian.little)
      ..setUint32(24, height, Endian.little)
      ..setUint32(28, 0, Endian.little)
      ..setUint32(32, 0, Endian.little)
      ..setUint32(36, 1, Endian.little)
      ..setUint32(40, levelCount, Endian.little)
      ..setUint32(44, 0, Endian.little);

    for (var i = 0; i < levelCount; i++) {
      final base = 80 + i * 24;
      final len = mipPayloads[i].length;
      _writeUint64LE(view, base, offsets[i]);
      _writeUint64LE(view, base + 8, len);
      _writeUint64LE(view, base + 16, len);
      totalBytes.setRange(offsets[i], offsets[i] + len, mipPayloads[i]);
    }
    return totalBytes;
  }

  static int _align4(int n) => (n + 3) & ~3;

  static int _packRgb565(int r, int g, int b) {
    final r5 = (r * 31 + 127) ~/ 255;
    final g6 = (g * 63 + 127) ~/ 255;
    final b5 = (b * 31 + 127) ~/ 255;
    return (r5 << 11) | (g6 << 5) | b5;
  }

  static (int, int, int) _unpackRgb565(int c) {
    final r5 = (c >> 11) & 0x1F;
    final g6 = (c >> 5) & 0x3F;
    final b5 = c & 0x1F;
    return (
      (r5 << 3) | (r5 >> 2),
      (g6 << 2) | (g6 >> 4),
      (b5 << 3) | (b5 >> 2),
    );
  }

  static int _readUint64LE(ByteData view, int offset) {
    final lo = view.getUint32(offset, Endian.little);
    final hi = view.getUint32(offset + 4, Endian.little);
    return hi * 0x100000000 + lo;
  }

  static void _writeUint64LE(ByteData view, int offset, int value) {
    final lo = value & 0xFFFFFFFF;
    final hi = value ~/ 0x100000000;
    view
      ..setUint32(offset, lo, Endian.little)
      ..setUint32(offset + 4, hi, Endian.little);
  }
}

class _Ktx2Texture(
  final Ktx2Container _container, {
  required super.sampler,
  final GpuBackend? explicitBackend,
}) extends Texture {
  this
    : super(
        _dummyByteData,
        width: _container.width,
        height: _container.height,
      );
  static final ByteData _dummyByteData = ByteData(4);

  @override
  GpuTexture createResource() {
    final backend = explicitBackend ?? GpuBackend.instance;
    final maxLevels = backend.maxMipLevelCount(width, height);
    final levels = math.min(_container.levelCount, maxLevels);

    final fmt = _container.gpuFormat;
    final blockAligned =
        !fmt.isCompressed ||
        (width % fmt.blockWidth == 0 && height % fmt.blockHeight == 0);

    if (blockAligned && backend.supportsPixelFormat(fmt)) {
      final gpuTex = backend.createTexture(
        storageMode: GpuStorageMode.hostVisible,
        width: width,
        height: height,
        format: fmt,
        mipLevelCount: levels,
      );
      for (var i = 0; i < levels; i++) {
        gpuTex.write(_container.levelData(i), mipLevel: i);
      }
      return gpuTex;
    }

    final fallbackFmt =
        _container.isSrgb &&
            backend.supportsPixelFormat(GpuPixelFormat.rgba8888Srgb)
        ? GpuPixelFormat.rgba8888Srgb
        : GpuPixelFormat.rgba8888;
    final gpuTex = backend.createTexture(
      storageMode: GpuStorageMode.hostVisible,
      width: width,
      height: height,
      format: fallbackFmt,
      mipLevelCount: levels,
    );
    for (var i = 0; i < levels; i++) {
      final rgba = Ktx2TextureLoader._decodeMipToRgba8(_container, i);
      gpuTex.write(ByteData.sublistView(rgba), mipLevel: i);
    }
    return gpuTex;
  }
}
