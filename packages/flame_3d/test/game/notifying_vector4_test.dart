import 'package:flame_3d/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotifyingVector4', () {
    final mutations = <String, void Function(Vector4 v)>{
      'setValues': (v) => v.setValues(1, 2, 3, 4),
      'setFrom': (v) => v.setFrom(Vector4(1, 2, 3, 4)),
      'setZero': (v) => v.setZero(),
      'setIdentity': (v) => v.setIdentity(),
      'splat': (v) => v.splat(4),
      '[]=': (v) => v[3] = 5,
      'length=': (v) => v.length = 2,
      'length= 0': (v) => v.length = 0,
      'normalize': (v) => v.normalize(),
      'applyMatrix4': (v) => v.applyMatrix4(Matrix4.translationValues(1, 2, 3)),
      'add': (v) => v.add(Vector4.all(1)),
      'addScaled': (v) => v.addScaled(Vector4.all(1), 2),
      'sub': (v) => v.sub(Vector4.all(1)),
      'multiply': (v) => v.multiply(Vector4.all(2)),
      'div': (v) => v.div(Vector4.all(2)),
      'scale': (v) => v.scale(2),
      'negate': (v) => v.negate(),
      'absolute': (v) => v.absolute(),
      'clamp': (v) => v.clamp(Vector4.zero(), Vector4.all(0.5)),
      'clampScalar': (v) => v.clampScalar(0, 0.5),
      'floor': (v) => v.floor(),
      'ceil': (v) => v.ceil(),
      'round': (v) => v.round(),
      'roundToZero': (v) => v.roundToZero(),
      'copyFromArray': (v) => v.copyFromArray([7, 8, 9, 10]),
      'x=': (v) => v.x = 9,
      'y=': (v) => v.y = 9,
      'z=': (v) => v.z = 9,
      'w=': (v) => v.w = 9,
      'r=': (v) => v.r = 9,
      'q=': (v) => v.q = 9,
      'xy=': (v) => v.xy = Vector2(5, 6),
      'wz=': (v) => v.wz = Vector2(5, 6),
      'ba=': (v) => v.ba = Vector2(5, 6),
      'xyz=': (v) => v.xyz = Vector3(5, 6, 7),
      'wzy=': (v) => v.wzy = Vector3(5, 6, 7),
      'stp=': (v) => v.stp = Vector3(5, 6, 7),
      'xyzw=': (v) => v.xyzw = Vector4(5, 6, 7, 8),
      'wzyx=': (v) => v.wzyx = Vector4(5, 6, 7, 8),
      'rgba=': (v) => v.rgba = Vector4(5, 6, 7, 8),
    };

    for (final MapEntry(key: name, value: mutate) in mutations.entries) {
      test('$name notifies the listeners once', () {
        final vector = NotifyingVector4(0.25, 1.5, -2.75, 0.5);
        var notifications = 0;
        vector.addListener(() => notifications++);

        mutate(vector);

        expect(notifications, 1);
      });
    }

    test('writing the current value notifies nobody', () {
      final vector = NotifyingVector4(1, 2, 3, 4);
      var notifications = 0;
      vector.addListener(() => notifications++);

      vector
        ..setValues(1, 2, 3, 4)
        ..setFrom(Vector4(1, 2, 3, 4))
        ..x = 1
        ..w = 4
        ..zw = Vector2(3, 4)
        ..xyzw = Vector4(1, 2, 3, 4)
        ..scale(1)
        ..add(Vector4.zero());

      expect(notifications, 0);
    });

    test('swizzle setters write the expected components', () {
      final vector = NotifyingVector4.zero()..wx = Vector2(1, 2);
      expect(vector, Vector4(2, 0, 0, 1));
      vector.yzwx = Vector4(3, 4, 5, 6);
      expect(vector, Vector4(6, 3, 4, 5));
    });

    test('storage is an unmodifiable view, the same object every time', () {
      final vector = NotifyingVector4(1, 2, 3, 4);

      expect(identical(vector.storage, vector.storage), isTrue);
      expect(() => vector.storage[0] = 5, throwsUnsupportedError);
      vector.x = 5;
      expect(vector.storage[0], 5);
    });
  });
}
