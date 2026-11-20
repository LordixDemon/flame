import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/scene.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGpuBackend backend;
  late GraphicsDevice device;
  late List<String> events;
  late GpuDeviceListener listener;

  setUp(() {
    backend = FakeGpuBackend()..completeImmediately = true;
    device = GraphicsDevice(backend: backend);
    events = [];
    listener = GpuDeviceListener(
      onLost: (reason) => events.add('lost: $reason'),
      onRecovered: (generation) => events.add('recovered $generation'),
      onRecoveryFailed: (error) => events.add('failed'),
    );
    GpuBackend.addDeviceListener(listener);
  });

  tearDown(GpuBackend.debugResetDeviceState);

  Surface quad() => Surface.fromBuffers(
    vertices: Float32List(12),
    indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
    layout: VertexLayout(const [
      VertexAttribute(VertexLayout.positionAttribute, 3),
    ]),
  );

  void frame(void Function() draw) {
    device
      ..begin()
      ..beginPass(const Size(8, 8));
    draw();
    device
      ..endPass()
      ..end();
  }

  group('detection', () {
    test('a failed command buffer stops drawing and starts recovery', () async {
      final surface = quad();
      backend.failSubmissions = true;
      frame(() => device.bindGeometry(surface));
      backend.failSubmissions = false;

      expect(backend.deviceState, GpuDeviceState.lost);
      expect(backend.isDeviceReady, isFalse);
      expect(backend.lastDeviceLossReason, 'a fake command buffer failed');
      expect(events, ['lost: a fake command buffer failed']);

      // A frame while the device is lost records nothing.
      backend.commands.clear();
      frame(() => device.bindGeometry(surface));
      expect(device.isSuspended, isFalse);
      expect(backend.commands, isEmpty);

      // Recovery runs right after the task that found the loss.
      await pumpEventQueue();
      expect(backend.deviceState, GpuDeviceState.ready);
      expect(backend.rebuildCount, 1);
      expect(backend.deviceLossCount, 1);
      expect(backend.deviceRecoveryCount, 1);
      expect(events.last, 'recovered ${GpuBackend.deviceGeneration}');

      frame(() => device.bindGeometry(surface));
      expect(backend.countCommands('drawIndexed'), 1);
    });

    test('a loss reported while one is handled is ignored', () async {
      backend
        ..reportDeviceLost('first')
        ..reportDeviceLost('second');
      expect(backend.deviceLossCount, 1);
      expect(backend.lastDeviceLossReason, 'first');
      await pumpEventQueue();
      expect(backend.deviceState, GpuDeviceState.ready);
    });

    test('a failed device check reports a loss and recovers', () async {
      backend.deviceRenders = false;
      final checking = backend.checkDevice();
      // Recovery checks the device again: let it pass now.
      backend.deviceRenders = true;
      expect(await checking, isFalse);
      expect(backend.deviceState, GpuDeviceState.lost);
      await pumpEventQueue();
      expect(backend.deviceState, GpuDeviceState.ready);
      expect(await backend.checkDevice(), isTrue);
      expect(backend.deviceLossCount, 1);
    });

    test('returning to the foreground checks the device', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      backend.deviceRenders = false;
      binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(backend.deviceLossCount, 0);
      binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(backend.deviceLossCount, 1);
      backend.deviceRenders = true;
      await pumpEventQueue();
      expect(backend.deviceState, GpuDeviceState.ready);

      // Without checkDeviceOnResume nothing is checked.
      GpuBackend.checkDeviceOnResume = false;
      backend.deviceRenders = false;
      binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(backend.deviceLossCount, 1);
    });
  });

  group('recovery', () {
    test('creates every resource again before its next use', () async {
      final surface = quad();
      frame(() => device.bindGeometry(surface));
      final before = surface.resource;
      final generation = GpuBackend.deviceGeneration;

      expect(await backend.debugSimulateDeviceLoss(), isTrue);

      expect(GpuBackend.deviceGeneration, generation + 1);
      expect(surface.hasResource, isFalse);
      final after = surface.resource;
      expect(identical(after, before), isFalse);
      expect(surface.hasResource, isTrue);
    });

    test('fails while the device does not render, and is retried', () async {
      backend.deviceRenders = false;
      backend.reportDeviceLost('test');
      await pumpEventQueue();
      expect(backend.deviceState, GpuDeviceState.failed);
      expect(events, ['lost: test', 'failed']);

      // Nothing is drawn while it failed.
      final surface = quad();
      backend.commands.clear();
      frame(() => device.bindGeometry(surface));
      expect(backend.commands, isEmpty);

      backend.deviceRenders = true;
      expect(await backend.checkDevice(), isTrue);
      expect(backend.deviceState, GpuDeviceState.ready);
      expect(backend.rebuildCount, 2);
      expect(events.last, startsWith('recovered'));
    });

    test('suspended passes return a transparent image', () async {
      backend.reportDeviceLost('test');
      device
        ..begin()
        ..beginPass(const Size(8, 8));
      expect(device.isSuspended, isTrue);
      final image = device.endPass();
      device.end();
      expect(image.width, 1);
      expect(image.height, 1);
      final bytes = await image.toByteData();
      expect(bytes!.getUint32(0), 0);
      image.dispose();
      await pumpEventQueue();
    });

    test('changes the versions of every world, at loss and recovery', () async {
      final world = World3D();
      final scene = world.sceneVersion;
      final casters = world.castersVersion;
      backend.reportDeviceLost('test');
      expect(world.sceneVersion, scene + 1);
      expect(world.castersVersion, casters + 1);
      await pumpEventQueue();
      expect(world.sceneVersion, scene + 2);
      expect(world.castersVersion, casters + 2);
    });

    test('runs the hooks of resource managers', () async {
      final runs = <String>[];
      final manager = GpuResourceManager3D();
      manager.deviceLossRecovery.registerCallback(
        'atlas',
        () => runs.add('atlas'),
      );
      final manual = GpuResourceManager3D(recoverOnDeviceLoss: false);
      manual.deviceLossRecovery.registerCallback(
        'manual',
        () => runs.add('manual'),
      );

      expect(await backend.debugSimulateDeviceLoss(), isTrue);
      expect(runs, ['atlas']);
      expect(manager.deviceLossRecovery.recoveryCount, 1);
      expect(manual.deviceLossRecovery.recoveryCount, 0);
    });

    test('a removed listener is not called', () async {
      expect(GpuBackend.removeDeviceListener(listener), isTrue);
      expect(await backend.debugSimulateDeviceLoss(), isTrue);
      expect(events, isEmpty);
    });
  });
}
