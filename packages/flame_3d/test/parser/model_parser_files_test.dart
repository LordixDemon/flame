import 'dart:convert';

import 'package:flame/cache.dart';
import 'package:flame/flame.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/parser.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

/// An asset bundle that serves [files] by exact key and records every key
/// asked for.
class _RecordingBundle(final Map<String, Uint8List> files)
    extends CachingAssetBundle {
  final List<String> requested = [];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    final bytes = files[key];
    if (bytes == null) {
      throw FlutterError('Unable to load asset: "$key".');
    }
    return ByteData.sublistView(bytes);
  }
}

Uint8List _text(String value) => Uint8List.fromList(utf8.encode(value));

/// `(position, uv)` of every corner of every triangle of [surface], in index
/// order.
List<(List<double>, List<double>)> _corners(Surface surface) {
  final stride = surface.layout.strideInFloats;
  final data = surface.vertexData;
  return [
    for (final i in surface.indices)
      (
        [data[i * stride], data[i * stride + 1], data[i * stride + 2]],
        [data[i * stride + 3], data[i * stride + 4]],
      ),
  ];
}

void main() {
  late AssetsCache previous;

  setUp(() {
    FakeGpuBackend();
    previous = Flame.assets;
  });

  tearDown(() => Flame.assets = previous);

  group('ModelParser OBJ files', () {
    test('keeps each corner with its own texture coordinates', () async {
      Flame.assets = AssetsCache(
        bundle: _RecordingBundle({
          'assets/m/tri.obj': _text(
            '# a textured triangle\n'
            'v 0 0 0\nv 1 0 0\nv 0 1 0\n'
            'vt 0.1 0.2\nvt 0.3 0.4\nvt 0.5 0.6\n'
            'f 1/1 2/2 3/3\n',
          ),
        }),
      );
      final model = await ModelParser.parse('assets/m/tri.obj');
      final surface = model.nodes[0]!.mesh!.surfaces.single;

      final corners = _corners(surface);
      expect(corners, hasLength(3));
      final byPosition = {
        for (final (p, uv) in corners) p.join(','): uv,
      };
      expect(byPosition['0.0,0.0,0.0'], [
        closeTo(0.1, 1e-6),
        closeTo(0.2, 1e-6),
      ]);
      expect(byPosition['1.0,0.0,0.0'], [
        closeTo(0.3, 1e-6),
        closeTo(0.4, 1e-6),
      ]);
      expect(byPosition['0.0,1.0,0.0'], [
        closeTo(0.5, 1e-6),
        closeTo(0.6, 1e-6),
      ]);
    });

    test('triangulates quads and polygons, with any whitespace', () async {
      Flame.assets = AssetsCache(
        bundle: _RecordingBundle({
          'assets/m/shapes.obj': _text(
            'v  0 0 0\r\nv 1 0 0 \r\nv\t1 1 0\r\nv 0 1 0\r\n'
            'v 2 0 0\nv 3 0 0\nv 3.5 1 0\nv 2.5 2 0\nv 1.5 1 0\n'
            'vn 0 0 1\n'
            'f  1//1  2//1 3//1   4//1 \n'
            'f -5 -4 -3 -2 -1\n',
          ),
        }),
      );
      final model = await ModelParser.parse('assets/m/shapes.obj');
      final surface = model.nodes[0]!.mesh!.surfaces.single;

      // A quad (2 triangles) and a pentagon (3 triangles).
      expect(surface.indexCount, (2 + 3) * 3);
      final stride = surface.layout.strideInFloats;
      for (var t = 0; t < surface.indexCount; t += 3) {
        Vector3 p(int k) {
          final i = surface.indices[t + k];
          return Vector3(
            surface.vertexData[i * stride],
            surface.vertexData[i * stride + 1],
            surface.vertexData[i * stride + 2],
          );
        }

        // Fans keep the counter-clockwise winding of the polygons.
        expect((p(1) - p(0)).cross(p(2) - p(0)).z, greaterThan(0));
      }
    });
  });
}
