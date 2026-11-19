import 'dart:ui' show Color;

import 'package:flame_3d/resources.dart';
import 'package:flame_3d/scene.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  setUp(FakeGpuBackend.new);

  test('a lease released after disposeAll leaves the new entry alone', () {
    final manager = GpuResourceManager3D();
    final lease1 = manager.acquire<Texture>(
      'checker',
      () => ColorTexture(const Color(0xFF808080)),
    );
    manager.disposeAll();
    final lease2 = manager.acquire<Texture>(
      'checker',
      () => ColorTexture(const Color(0xFF404040)),
    );
    lease1.release();
    expect(manager.refCountOf('checker'), 1);
    expect(manager.purgeUnreferenced(), 0);
    expect(manager.peek<Texture>('checker'), same(lease2.resource));

    lease2.release();
    expect(manager.refCountOf('checker'), 0);
    expect(manager.purgeUnreferenced(), 1);
  });
}
