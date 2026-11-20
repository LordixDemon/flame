import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame_3d/core.dart';

import '../parser/glb_builder.dart';

/// Encodes [width] x [height] RGBA [pixels] as a PNG file.
Future<Uint8List> encodePng(Uint8List pixels, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final image = (await codec.getNextFrame()).image;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return png!.buffer.asUint8List();
}

/// Vertical wooden staves with grain and dark seams, [size] pixels square.
Uint8List stavesPixels({int size = 64}) {
  final bytes = Uint8List(size * size * 4);
  final rng = math.Random(11);
  final tone = [for (var i = 0; i < 8; i++) 0.82 + rng.nextDouble() * 0.3];
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final stave = x * 8 ~/ size;
      final inStave = (x * 8 % size) / size;
      final grain = 0.5 + 0.5 * math.sin(y * 0.35 + math.sin(x * 1.3) * 2);
      var r = (0.6 + 0.14 * grain) * tone[stave];
      var g = (0.4 + 0.09 * grain) * tone[stave];
      var b = (0.22 + 0.05 * grain) * tone[stave];
      if (inStave < 0.08) {
        r *= 0.45;
        g *= 0.42;
        b *= 0.4;
      }
      final o = (y * size + x) * 4;
      bytes
        ..[o] = (r.clamp(0.0, 1.0) * 255).round()
        ..[o + 1] = (g.clamp(0.0, 1.0) * 255).round()
        ..[o + 2] = (b.clamp(0.0, 1.0) * 255).round()
        ..[o + 3] = 255;
    }
  }
  return bytes;
}

/// A barrel: a [sides]-sided prism, 1 tall and 0.8 wide, standing on
/// `y = 0`, its staves textured by the base color texture of its material
/// ([png], a PNG file) and wrapped once around it, with its two hoops in
/// `_TRIM` (VEC2: x the hoop mask, y the gloss) and no vertex colors.
Uint8List barrelGlb(Uint8List png, {int sides = 14}) {
  final b = GlbBuilder();
  final positions = <double>[];
  final normals = <double>[];
  final uvs = <double>[];
  final trim = <double>[];
  final indices = <int>[];
  // The rings of the side, with the hoops between 0.1 and 0.18 and between
  // 0.82 and 0.9 of the height.
  const rings = [0.0, 0.1, 0.1, 0.18, 0.18, 0.82, 0.82, 0.9, 0.9, 1.0];
  const hoop = [0, 0, 1, 1, 0, 0, 1, 1, 0, 0];
  for (var r = 0; r < rings.length; r++) {
    final t = rings[r];
    // A slight bulge in the middle.
    final radius = 0.36 + 0.06 * math.sin(t * math.pi);
    for (var s = 0; s <= sides; s++) {
      final a = s / sides * 2 * math.pi;
      positions.addAll([math.cos(a) * radius, t, math.sin(a) * radius]);
      normals.addAll([math.cos(a), 0.15 * math.cos(t * math.pi), math.sin(a)]);
      uvs.addAll([s / sides, 1 - t]);
      final band = hoop[r] == 1;
      trim.addAll([if (band) 1 else 0, if (band) 0.9 else 0.15]);
    }
  }
  for (var r = 0; r + 1 < rings.length; r++) {
    if (rings[r] == rings[r + 1]) {
      continue;
    }
    for (var s = 0; s < sides; s++) {
      final a = r * (sides + 1) + s;
      final c = a + sides + 1;
      indices.addAll([a, c, c + 1, c + 1, a + 1, a]);
    }
  }
  // The lid, a fan of the top ring's texture.
  final center = positions.length ~/ 3;
  positions.addAll([0, 1, 0]);
  normals.addAll([0, 1, 0]);
  uvs.addAll([0.5, 0.5]);
  trim.addAll([0, 0.1]);
  for (var s = 0; s <= sides; s++) {
    final a = s / sides * 2 * math.pi;
    positions.addAll([math.cos(a) * 0.36, 1, math.sin(a) * 0.36]);
    normals.addAll([0, 1, 0]);
    uvs.addAll([0.5 + 0.5 * math.cos(a), 0.5 + 0.5 * math.sin(a)]);
    trim.addAll([0, 0.1]);
    if (s < sides) {
      indices.addAll([center, center + 2 + s, center + 1 + s]);
    }
  }
  return b.file(
    nodes: [
      {'mesh': 0},
    ],
    meshes: [
      {
        'primitives': [
          {
            'attributes': {
              'POSITION': b.floats(positions, 'VEC3'),
              'NORMAL': b.floats(normals, 'VEC3'),
              'TEXCOORD_0': b.floats(uvs, 'VEC2'),
              '_TRIM': b.floats(trim, 'VEC2'),
            },
            'indices': b.shorts(indices),
            'material': 0,
          },
        ],
      },
    ],
    materials: [
      {
        'pbrMetallicRoughness': {
          'baseColorTexture': {'index': 0},
          'metallicFactor': 0,
        },
      },
    ],
    textures: [
      {'source': b.image(png)},
    ],
  );
}

/// A creature: a tube of 3 joints, 1.2 tall, standing on `y = 0`, skin
/// colored (COLOR_0), with a tinted shirt, an accent belt, glowing eyes and a
/// glossy hat in `_MASKS` (VEC4 normalized bytes: tint, accent, emissive,
/// gloss) and a swaying feather in `_SWAY` (SCALAR). Its joints: the root,
/// the waist (at 0.45) and the neck (at 0.85).
Uint8List creatureGlb({int sides = 12}) {
  final b = GlbBuilder();
  final positions = <double>[];
  final normals = <double>[];
  final colors = <double>[];
  final masks = <int>[];
  final sway = <double>[];
  final joints = <int>[];
  final weights = <double>[];
  final indices = <int>[];
  // Rings: height, radius and part. A ring is repeated where the part
  // changes, so that the masks change sharply.
  const rings = [
    (0.0, 0.17, 'skin'),
    (0.18, 0.21, 'skin'),
    (0.18, 0.21, 'shirt'),
    (0.4, 0.235, 'shirt'),
    (0.4, 0.235, 'belt'),
    (0.48, 0.235, 'belt'),
    (0.48, 0.235, 'shirt'),
    (0.74, 0.19, 'shirt'),
    (0.74, 0.19, 'skin'),
    (0.84, 0.15, 'skin'),
    (0.88, 0.2, 'skin'),
    (0.95, 0.22, 'skin'),
    (0.95, 0.22, 'eyes'),
    (1.0, 0.22, 'eyes'),
    (1.0, 0.22, 'skin'),
    (1.07, 0.19, 'skin'),
    (1.07, 0.19, 'hat'),
    (1.1, 0.27, 'hat'),
    (1.13, 0.27, 'hat'),
    (1.13, 0.17, 'hat'),
    (1.25, 0.11, 'hat'),
  ];
  for (final (y, radius, part) in rings) {
    for (var s = 0; s <= sides; s++) {
      final a = s / sides * 2 * math.pi;
      positions.addAll([math.cos(a) * radius, y, math.sin(a) * radius]);
      normals.addAll([math.cos(a), 0.1, math.sin(a)]);
      final hat = part == 'hat';
      final eye = part == 'eyes' && math.sin(a) > 0.5;
      if (hat) {
        colors.addAll([0.25, 0.22, 0.3, 1]);
      } else {
        colors.addAll([0.95, 0.78, 0.62, 1]);
      }
      masks.addAll([
        if (part == 'shirt') 255 else 0,
        if (part == 'belt') 255 else 0,
        if (eye) 255 else 0,
        switch (part) {
          'hat' => 230,
          'belt' => 200,
          _ => 40,
        },
      ]);
      sway.add(0);
      final w = ((y - 0.3) / 0.3).clamp(0.0, 1.0);
      final n = ((y - 0.75) / 0.15).clamp(0.0, 1.0);
      joints.addAll([0, 1, 2, 0]);
      weights.addAll([1 - w, w * (1 - n), w * n, 0]);
    }
  }
  for (var r = 0; r + 1 < rings.length; r++) {
    if (rings[r].$1 == rings[r + 1].$1 && rings[r].$2 == rings[r + 1].$2) {
      continue;
    }
    for (var s = 0; s < sides; s++) {
      final a = r * (sides + 1) + s;
      final c = a + sides + 1;
      indices.addAll([a, c, c + 1, c + 1, a + 1, a]);
    }
  }
  // A feather on the hat, swaying, following the neck.
  final first = positions.length ~/ 3;
  for (var k = 0; k <= 4; k++) {
    final t = k / 4;
    for (final x in const [-0.04, 0.04]) {
      positions.addAll([0.12 + x + 0.1 * t, 1.18 + 0.35 * t, 0]);
      normals.addAll([0, 0, 1]);
      colors.addAll([0.9, 0.25, 0.2, 1]);
      masks.addAll([0, 255, 0, 60]);
      sway.add(t);
      joints.addAll([2, 0, 0, 0]);
      weights.addAll([1, 0, 0, 0]);
    }
    if (k < 4) {
      final a = first + k * 2;
      indices.addAll([a, a + 1, a + 3, a + 3, a + 2, a]);
    }
  }
  // The inverses of the joints' rest transforms: translations by -y.
  final ibm = <double>[
    for (final y in const [0.0, 0.45, 0.85])
      ...Matrix4.translationValues(0, -y, 0).storage,
  ];
  return b.file(
    nodes: [
      {
        'mesh': 0,
        'skin': 0,
        'children': [1],
      },
      {
        'name': 'root',
        'children': [2],
      },
      {
        'name': 'waist',
        'translation': [0, 0.45, 0],
        'children': [3],
      },
      {
        'name': 'neck',
        'translation': [0, 0.4, 0],
      },
    ],
    meshes: [
      {
        'primitives': [
          {
            'attributes': {
              'POSITION': b.floats(positions, 'VEC3'),
              'NORMAL': b.floats(normals, 'VEC3'),
              'COLOR_0': b.floats(colors, 'VEC4'),
              'JOINTS_0': b.bytesOf(joints, 'VEC4'),
              'WEIGHTS_0': b.floats(weights, 'VEC4'),
              '_MASKS': b.bytesOf(masks, 'VEC4', normalized: true),
              '_SWAY': b.floats(sway, 'SCALAR'),
            },
            'indices': b.shorts(indices),
            'material': 0,
          },
        ],
      },
    ],
    materials: [
      {
        'pbrMetallicRoughness': {'metallicFactor': 0, 'roughnessFactor': 0.8},
      },
    ],
    skins: [
      {
        'joints': [1, 2, 3],
        'inverseBindMatrices': b.floats(ibm, 'MAT4'),
      },
    ],
  );
}
