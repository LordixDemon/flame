import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Line 3D Mesh Component', () {
    test('can create vertical line', () {
      final line = Line3D.generate(
        start: Vector3(0, -1, 0),
        end: Vector3(0, 1, 0),
        material: UnlitMaterial(),
      );

      expect(
        line.transform.transformMatrix,
        equals(Matrix4.identity()),
      );
    });

    test('can create horizontal line', () {
      final line = Line3D.generate(
        start: Vector3(-1, 0, 0),
        end: Vector3(1, 0, 0),
        material: UnlitMaterial(),
      );

      expect(
        line.transform.transformMatrix,
        closeToMatrix4(
          Matrix4.columns(
            Vector4(0, -1, 0, 0),
            Vector4(1, 0, 0, 0),
            Vector4(0, 0, 1, 0),
            Vector4(0, 0, 0, 1),
          ),
          10e-6,
        ),
      );
    });

    test('can create a line pointing straight down', () {
      final line = Line3D.generate(
        start: Vector3.zero(),
        end: Vector3(0, -2, 0),
        material: UnlitMaterial(),
      );

      // The cylinder spans y in [-1, 1] before the transform.
      final matrix = line.transform.transformMatrix;
      expect(
        matrix.transformed3(Vector3(0, -1, 0)),
        closeToVector3(Vector3.zero(), 1e-6),
      );
      expect(
        matrix.transformed3(Vector3(0, 1, 0)),
        closeToVector3(Vector3(0, -2, 0), 1e-6),
      );
    });
  });
}
