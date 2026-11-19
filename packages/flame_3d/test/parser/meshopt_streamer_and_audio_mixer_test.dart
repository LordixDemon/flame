import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/audio.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/parser.dart';
import 'package:flutter_test/flutter_test.dart';

class _ChunkMarker({required final ChunkCoord3D coord, super.position})
    extends Component3D;

class _RecordingVoiceBackend() implements AudioVoiceBackend3D {
  int _nextHandle = 1;
  final Map<int, SpatialAudioEmitter3D> activeHandles = {};
  final Map<SpatialAudioEmitter3D, AudioVoiceParams3D> startedWith = {};
  final Map<SpatialAudioEmitter3D, AudioVoiceParams3D> updatedWith = {};
  final List<SpatialAudioEmitter3D> stoppedEmitters = [];

  @override
  int startVoice(SpatialAudioEmitter3D emitter, AudioVoiceParams3D params) {
    final handle = _nextHandle++;
    activeHandles[handle] = emitter;
    startedWith[emitter] = params;
    updatedWith[emitter] = params;
    return handle;
  }

  @override
  void updateVoice(
    int voiceHandle,
    SpatialAudioEmitter3D emitter,
    AudioVoiceParams3D params,
  ) {
    updatedWith[emitter] = params;
  }

  @override
  void stopVoice(int voiceHandle, SpatialAudioEmitter3D emitter) {
    activeHandles.remove(voiceHandle);
    stoppedEmitters.add(emitter);
  }
}

Uint8List _packGlb(Map<String, Object?> gltfJson, Uint8List binPayload) {
  final jsonRaw = utf8.encode(jsonEncode(gltfJson));
  final jsonPad = (4 - (jsonRaw.length % 4)) % 4;
  final jsonChunkLen = jsonRaw.length + jsonPad;
  final binPad = (4 - (binPayload.length % 4)) % 4;
  final binChunkLen = binPayload.length + binPad;

  final totalLen = 12 + 8 + jsonChunkLen + 8 + binChunkLen;
  final out = Uint8List(totalLen);
  final bd = ByteData.sublistView(out);

  out.setRange(0, 4, 'glTF'.codeUnits);
  bd
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, totalLen, Endian.little)
    ..setUint32(12, jsonChunkLen, Endian.little);
  out
    ..setRange(16, 20, 'JSON'.codeUnits)
    ..setRange(20, 20 + jsonRaw.length, jsonRaw)
    ..fillRange(20 + jsonRaw.length, 20 + jsonChunkLen, 0x20);

  final binOff = 20 + jsonChunkLen;
  bd.setUint32(binOff, binChunkLen, Endian.little);
  out
    ..setRange(binOff + 4, binOff + 8, 'BIN\x00'.codeUnits)
    ..setRange(binOff + 8, binOff + 8 + binPayload.length, binPayload);
  return out;
}

void main() {
  group('MeshoptDecoder3D & glTF EXT_meshopt_compression', () {
    test(
      'round-trips ATTRIBUTES, TRIANGLES, and INDICES streams with strong '
      'compression ratios',
      () {
        // 1. 300 smooth quantized 16-byte vertices (`ATTRIBUTES`, multi-block).
        const vertCount = 300;
        const stride = 16;
        final rawVerts = Uint8List(vertCount * stride);
        final vbd = ByteData.sublistView(rawVerts);
        for (var i = 0; i < vertCount; i++) {
          final b = i * stride;
          vbd
            ..setInt16(b, i * 3, Endian.little)
            ..setInt16(b + 2, i * 2, Endian.little)
            ..setInt16(b + 4, -i, Endian.little)
            ..setInt16(b + 6, 1, Endian.little)
            ..setUint16(b + 8, (i * 64) & 0xFFFF, Endian.little)
            ..setUint16(b + 10, (i * 32) & 0xFFFF, Endian.little)
            ..setUint32(b + 12, 0xFF804020, Endian.little);
        }

        final encodedVerts = MeshoptDecoder3D.encodeVertexStream(
          rawVerts,
          count: vertCount,
          byteStride: stride,
        );
        expect(encodedVerts.length, lessThan(rawVerts.length ~/ 2));
        final decodedVerts = MeshoptDecoder3D.decodeVertexStream(
          encodedVerts,
          count: vertCount,
          byteStride: stride,
        );
        expect(decodedVerts, rawVerts);

        // 2. Connected 12x12 triangle grid (`288` triangles = `864` Uint16
        // indices = 1728 raw bytes -> compresses via EdgeFifo + VertexFifo!).
        const gridN = 12;
        final triIndices = <int>[];
        for (var z = 0; z < gridN; z++) {
          for (var x = 0; x < gridN; x++) {
            final i0 = z * (gridN + 1) + x;
            final i1 = i0 + 1;
            final i2 = i0 + (gridN + 1);
            final i3 = i2 + 1;
            triIndices.addAll([i0, i2, i1, i1, i2, i3]);
          }
        }
        final rawTris = Uint8List(triIndices.length * 2);
        final tbd = ByteData.sublistView(rawTris);
        for (var i = 0; i < triIndices.length; i++) {
          tbd.setUint16(i * 2, triIndices[i], Endian.little);
        }

        final encTris = MeshoptDecoder3D.encodeIndexStream(
          rawTris,
          count: triIndices.length,
          byteStride: 2,
        );
        expect(encTris.length, lessThan(rawTris.length ~/ 3));

        final decTrisBytes = MeshoptDecoder3D.decodeIndexStream(
          encTris,
          count: triIndices.length,
          byteStride: 2,
        );
        final decBd = ByteData.sublistView(decTrisBytes);
        // Verify every decoded triangle preserves its exact cyclic `(a, b, c)`
        // vertex triple!
        for (var t = 0; t < triIndices.length ~/ 3; t++) {
          final origA = triIndices[t * 3];
          final origB = triIndices[t * 3 + 1];
          final origC = triIndices[t * 3 + 2];
          final gotA = decBd.getUint16(t * 6, Endian.little);
          final gotB = decBd.getUint16(t * 6 + 2, Endian.little);
          final gotC = decBd.getUint16(t * 6 + 4, Endian.little);
          final cyclicMatch =
              (gotA == origA && gotB == origB && gotC == origC) ||
              (gotA == origB && gotB == origC && gotC == origA) ||
              (gotA == origC && gotB == origA && gotC == origB);
          expect(cyclicMatch, isTrue);
        }

        // Also test non-sequential Uint32 triangles (`0xFF` escape path) &
        // `INDICES` (`0xD1`) general sequence!
        final sparseTris = Uint32List.fromList(const [
          42, 17, 99, //
          5, 1024, 3, //
        ]);
        final encSparse = MeshoptDecoder3D.encodeIndexStream(
          sparseTris.buffer.asUint8List(),
          count: sparseTris.length,
          byteStride: 4,
        );
        final decSparse = MeshoptDecoder3D.decodeIndexStream(
          encSparse,
          count: sparseTris.length,
          byteStride: 4,
        );
        expect(decSparse.buffer.asUint32List(), sparseTris);

        final seqIndices = Uint16List.fromList(const [
          0,
          100,
          1,
          101,
          2,
          102,
          5,
        ]);
        final encSeq = MeshoptDecoder3D.encodeIndexStream(
          seqIndices.buffer.asUint8List(),
          count: seqIndices.length,
          byteStride: 2,
          mode: MeshoptMode3D.indices,
        );
        final decSeq = MeshoptDecoder3D.decodeIndexStream(
          encSeq,
          count: seqIndices.length,
          byteStride: 2,
          mode: MeshoptMode3D.indices,
        );
        expect(decSeq.buffer.asUint16List(), seqIndices);
      },
    );

    test(
      'decodes OCTAHEDRAL, QUATERNION, and EXPONENTIAL filters and parses '
      'meshopt-compressed GLB end-to-end via GlbParser',
      () async {
        // 1. Direct OCTAHEDRAL (16-bit), QUATERNION, and EXPONENTIAL accuracy.
        final testNormals = [
          Vector4(0.0, 1.0, 0.0, 1.0),
          Vector4(0.57735, -0.57735, -0.57735, -1.0),
          Vector4(-0.6, 0.0, 0.8, 1.0),
        ];
        final octBuf = MeshoptDecoder3D.encodeFilterOct(
          testNormals,
          byteStride: 8,
          bits: 14,
        );
        MeshoptDecoder3D.decodeFilterOct(octBuf, count: 3, byteStride: 8);
        final octBd = ByteData.sublistView(octBuf);
        expect(
          octBd.getInt16(10, Endian.little) / 32767.0,
          closeTo(-0.57735, 2e-3),
        );
        expect(octBd.getInt16(14, Endian.little), -32767);

        final testQuats = [
          Quaternion.identity(),
          Quaternion.axisAngle(Vector3(1.0, 0.0, 0.0), 2.4)..scale(-1.0),
          Quaternion.axisAngle(Vector3(0.0, 1.0, 0.0), 1.1),
          Quaternion.axisAngle(Vector3(0.0, 0.0, 1.0), 2.8),
        ];
        final quatRaw = MeshoptDecoder3D.encodeFilterQuat(testQuats, bits: 14);
        MeshoptDecoder3D.decodeFilterQuat(quatRaw, count: testQuats.length);
        final quatBd = ByteData.sublistView(quatRaw);
        for (var i = 0; i < testQuats.length; i++) {
          final b = i * 8;
          final rec = Quaternion(
            quatBd.getInt16(b, Endian.little) / 32767.0,
            quatBd.getInt16(b + 2, Endian.little) / 32767.0,
            quatBd.getInt16(b + 4, Endian.little) / 32767.0,
            quatBd.getInt16(b + 6, Endian.little) / 32767.0,
          )..normalize();
          final expected = testQuats[i].normalized();
          expect(rec.dot(expected).abs(), closeTo(1.0, 1e-3));
        }

        // 2. Build an in-memory `.glb` whose positions (`EXPONENTIAL`),
        // normals (`OCTAHEDRAL`), indices (`TRIANGLES`), and rotations
        // (`QUATERNION`) use `EXT_meshopt_compression`!
        final positions = Float32List.fromList(const [
          0.0, 0.0, 0.0, //
          2.0, 0.0, 0.0, //
          0.0, 3.0, 0.0, //
        ]);
        final expFilteredPos = MeshoptDecoder3D.encodeFilterExp(
          positions,
          count: 3,
          byteStride: 12,
          bits: 20,
        );
        final compPos = MeshoptDecoder3D.encodeVertexStream(
          expFilteredPos,
          count: 3,
          byteStride: 12,
        );

        final octFilteredNorm = MeshoptDecoder3D.encodeFilterOct([
          Vector4(0.0, 0.0, 1.0, 0.0),
          Vector4(0.0, 0.0, 1.0, 0.0),
          Vector4(0.0, 0.0, 1.0, 0.0),
        ]);
        final compNorm = MeshoptDecoder3D.encodeVertexStream(
          octFilteredNorm,
          count: 3,
          byteStride: 4,
        );

        final rawIdx = Uint16List.fromList(const [0, 1, 2]).buffer
            .asUint8List();
        final compIdx = MeshoptDecoder3D.encodeIndexStream(
          rawIdx,
          count: 3,
          byteStride: 2,
        );

        final animTimes = Float32List.fromList(const [0.0, 1.0]).buffer
            .asUint8List();
        final targetRot = Quaternion.axisAngle(
          Vector3(0.0, 1.0, 0.0),
          math.pi * 0.5,
        );
        final quatAnimFiltered = MeshoptDecoder3D.encodeFilterQuat(
          [Quaternion.identity(), targetRot],
          bits: 14,
        );
        final compAnimRot = MeshoptDecoder3D.encodeVertexStream(
          quatAnimFiltered,
          count: 2,
          byteStride: 8,
        );

        final binBuilder = BytesBuilder(copy: false);
        int appendAligned(Uint8List chunk) {
          final rem = binBuilder.length % 4;
          if (rem != 0) {
            binBuilder.add(Uint8List(4 - rem));
          }
          final off = binBuilder.length;
          binBuilder.add(chunk);
          return off;
        }

        final posOff = appendAligned(compPos);
        final normOff = appendAligned(compNorm);
        final idxOff = appendAligned(compIdx);
        final timeOff = appendAligned(animTimes);
        final rotOff = appendAligned(compAnimRot);
        final binBytes = binBuilder.toBytes();

        final gltfJson = <String, Object?>{
          'asset': {'version': '2.0'},
          'extensionsUsed': [
            'EXT_meshopt_compression',
            'KHR_mesh_quantization',
          ],
          'buffers': [
            {'byteLength': binBytes.length},
            {
              'byteLength': 64,
              'extensions': {
                'EXT_meshopt_compression': {'fallback': true},
              },
            },
          ],
          'bufferViews': [
            {
              'buffer': 1,
              'byteLength': 36,
              'byteStride': 12,
              'extensions': {
                'EXT_meshopt_compression': {
                  'buffer': 0,
                  'byteOffset': posOff,
                  'byteLength': compPos.length,
                  'byteStride': 12,
                  'count': 3,
                  'mode': 'ATTRIBUTES',
                  'filter': 'EXPONENTIAL',
                },
              },
            },
            {
              'buffer': 1,
              'byteLength': 12,
              'byteStride': 4,
              'extensions': {
                'EXT_meshopt_compression': {
                  'buffer': 0,
                  'byteOffset': normOff,
                  'byteLength': compNorm.length,
                  'byteStride': 4,
                  'count': 3,
                  'mode': 'ATTRIBUTES',
                  'filter': 'OCTAHEDRAL',
                },
              },
            },
            {
              'buffer': 1,
              'byteLength': 6,
              'extensions': {
                'EXT_meshopt_compression': {
                  'buffer': 0,
                  'byteOffset': idxOff,
                  'byteLength': compIdx.length,
                  'byteStride': 2,
                  'count': 3,
                  'mode': 'TRIANGLES',
                },
              },
            },
            {
              'buffer': 0,
              'byteOffset': timeOff,
              'byteLength': animTimes.length,
            },
            {
              'buffer': 1,
              'byteLength': 16,
              'byteStride': 8,
              'extensions': {
                'EXT_meshopt_compression': {
                  'buffer': 0,
                  'byteOffset': rotOff,
                  'byteLength': compAnimRot.length,
                  'byteStride': 8,
                  'count': 2,
                  'mode': 'ATTRIBUTES',
                  'filter': 'QUATERNION',
                },
              },
            },
          ],
          'accessors': [
            {
              'bufferView': 0,
              'componentType': 5126, // FLOAT
              'count': 3,
              'type': 'VEC3',
            },
            {
              'bufferView': 1,
              'componentType': 5120, // BYTE normalized (4-byte stride)
              'normalized': true,
              'count': 3,
              'type': 'VEC3',
            },
            {
              'bufferView': 2,
              'componentType': 5123, // UNSIGNED_SHORT
              'count': 3,
              'type': 'SCALAR',
            },
            {
              'bufferView': 3,
              'componentType': 5126, // FLOAT
              'count': 2,
              'type': 'SCALAR',
            },
            {
              'bufferView': 4,
              'componentType': 5122, // SHORT normalized
              'normalized': true,
              'count': 2,
              'type': 'VEC4',
            },
          ],
          'meshes': [
            {
              'name': 'CompressedTri',
              'primitives': [
                {
                  'attributes': {'POSITION': 0, 'NORMAL': 1},
                  'indices': 2,
                },
              ],
            },
          ],
          'nodes': [
            {'name': 'SpinTri', 'mesh': 0},
          ],
          'scenes': [
            {
              'nodes': [0],
            },
          ],
          'scene': 0,
          'animations': [
            {
              'name': 'turn',
              'samplers': [
                {'input': 3, 'output': 4, 'interpolation': 'LINEAR'},
              ],
              'channels': [
                {
                  'sampler': 0,
                  'target': {'node': 0, 'path': 'rotation'},
                },
              ],
            },
          ],
        };

        final glbBytes = _packGlb(gltfJson, binBytes);
        final model = await GlbParser().parseModelBytes(glbBytes);

        final mesh = model.nodes[0]!.mesh!;
        expect(mesh.aabb.max.x, closeTo(2.0, 1e-4));
        expect(mesh.aabb.max.y, closeTo(3.0, 1e-4));
        expect(mesh.surfaces.single.indexCount, 3);

        final comp = ModelComponent(model: model)..playAnimationByName('turn');
        comp.update(1.0);
        final fwd = Vector3(1.0, 0.0, 0.0);
        comp.nodeTransform(0)!.rotate3(fwd);
        expect(fwd.z, closeTo(-1.0, 2e-3));
      },
    );
  });

  group('WorldChunkStreamer3D spatial grid/radius streaming', () {
    test(
      'throttles maxConcurrentLoads, respects load/unload hysteresis, and '
      'reuses LRU unloaded chunks with 0 reload IO',
      () async {
        final loadOrder = <ChunkCoord3D>[];
        final pendingCompleters =
            <ChunkCoord3D, Completer<List<Component3D>>>{};
        var peakConcurrent = 0;
        var currentConcurrent = 0;
        final evicted = <ChunkCoord3D>[];

        final world = World3D();
        final streamer = WorldChunkStreamer3D(
          chunkSize: 10.0,
          loadRadius: 12.0,
          unloadRadius: 22.0,
          maxConcurrentLoads: 2,
          maxCachedUnloadedChunks: 2,
          chunkContainer: world,
          onChunkEvicted: (coord, _) => evicted.add(coord),
          chunkLoader: (coord) {
            loadOrder.add(coord);
            currentConcurrent++;
            if (currentConcurrent > peakConcurrent) {
              peakConcurrent = currentConcurrent;
            }
            final c = Completer<List<Component3D>>();
            pendingCompleters[coord] = c;
            return c.future.whenComplete(() => currentConcurrent--);
          },
        );

        // Focus at `(5, 0, 5)` = exact center of `ChunkCoord3D(0, 0)`.
        // Within `loadRadius = 12`: `(0,0)` (dist 0) + 4 cardinal neighbors
        // `(1,0), (-1,0), (0,1), (0,-1)` (dist 10) = 5 chunks total!
        streamer.updateFocus(Vector3(5.0, 0.0, 5.0));
        expect(
          streamer.loadingChunks.length,
          2,
        ); // Capped by maxConcurrentLoads!
        expect(loadOrder.first, const ChunkCoord3D(0, 0)); // Closest first!

        // Resolve waves of async chunk loads until all 5 finish.
        while (pendingCompleters.isNotEmpty) {
          final batch = Map<ChunkCoord3D, Completer<List<Component3D>>>.of(
            pendingCompleters,
          );
          pendingCompleters.clear();
          for (final entry in batch.entries) {
            entry.value.complete([
              _ChunkMarker(
                coord: entry.key,
                position: streamer.chunkCenterWorld(entry.key),
              ),
            ]);
          }
          await Future<void>.delayed(Duration.zero);
        }
        await streamer.flushPending();

        expect(peakConcurrent, 2);
        expect(streamer.activeChunks.length, 5);
        expect(streamer.totalLoadsCompleted, 5);

        // Hysteresis check: nudge focus to `(11, 0, 5)` -> chunk `(-1, 0)`
        // center `(-5, 5)` is at dist `16` (`> loadRadius 12`, `< unloadRadius
        // 22`), so it stays mounted!
        streamer.updateFocus(Vector3(11.0, 0.0, 5.0));
        expect(
          streamer.activeChunks.contains(const ChunkCoord3D(-1, 0)),
          isTrue,
        );
        while (pendingCompleters.isNotEmpty) {
          final batch = Map<ChunkCoord3D, Completer<List<Component3D>>>.of(
            pendingCompleters,
          );
          pendingCompleters.clear();
          for (final entry in batch.entries) {
            entry.value.complete([_ChunkMarker(coord: entry.key)]);
          }
          await Future<void>.delayed(Duration.zero);
        }

        // Teleport far away to `(105, 0, 5)` -> all 5 origin chunks exceed
        // `unloadRadius` (`22`) and unmount into the 2-slot LRU cache!
        streamer.updateFocus(Vector3(105.0, 0.0, 5.0));
        while (pendingCompleters.isNotEmpty) {
          final batch = Map<ChunkCoord3D, Completer<List<Component3D>>>.of(
            pendingCompleters,
          );
          pendingCompleters.clear();
          for (final entry in batch.entries) {
            entry.value.complete([_ChunkMarker(coord: entry.key)]);
          }
          await Future<void>.delayed(Duration.zero);
        }
        expect(streamer.cachedChunkCount, 2);
        expect(evicted.length, greaterThanOrEqualTo(3));

        // Teleport back to one of the cached chunks -> instant LRU cache hit!
        final loadsBeforeReturn = streamer.totalLoadsCompleted;
        streamer.updateFocus(Vector3(5.0, 0.0, 5.0));
        expect(streamer.cacheHitCount, greaterThanOrEqualTo(1));
        expect(streamer.activeChunks, isNotEmpty);
        // Drain any remaining uncached neighbor loads across concurrency waves.
        while (pendingCompleters.isNotEmpty) {
          final batch = Map<ChunkCoord3D, Completer<List<Component3D>>>.of(
            pendingCompleters,
          );
          pendingCompleters.clear();
          for (final entry in batch.entries) {
            entry.value.complete([_ChunkMarker(coord: entry.key)]);
          }
          await Future<void>.delayed(Duration.zero);
        }
        await streamer.flushPending();
        expect(streamer.totalLoadsCompleted, lessThan(loadsBeforeReturn + 5));
      },
    );
  });

  group('SpatialAudioMixer3D voice pool, occlusion & AudioZone3D', () {
    test(
      'pools real vs virtual voices with seamless playbackPosition promotion, '
      'attenuates occluded low-pass cutoff, and crossfades AudioZone3D reverb',
      () {
        final backend = _RecordingVoiceBackend();
        final listener = SpatialAudioListener3D(
          position: Vector3.zero(),
          autoComputeVelocity: false,
        );

        // Create 20 looping emitters spaced along `+X` (`1, 3, ..., 39`).
        final emitters = <SpatialAudioEmitter3D>[
          for (var i = 0; i < 20; i++)
            SpatialAudioEmitter3D(
              clipId: 'torch_$i',
              clipDuration: 10.0,
              maxDistance: 80.0,
              occlusionGain: 0.25,
              autoComputeVelocity: false,
              position: Vector3(1.0 + i * 2.0, 0.0, 0.0),
            ),
        ];

        final caveZone = AudioZone3D(
          preset: ReverbPreset3D.cave,
          radius: 6.0,
          position: Vector3(38.0, 0.0, 0.0),
        );

        var wallActive = false;
        final mixer = SpatialAudioMixer3D(
          backend: backend,
          listener: listener,
          maxRealVoices: 4,
          reverbCrossfadeSpeed: 8.0,
          emitters: emitters,
          zones: [caveZone],
          occlusionQuery: (earPos, srcPos) => wallActive ? 0.8 : 0.0,
        );

        // 1. Tick `2.5s` while listener is at `(0, 0, 0)`:
        // Only the 4 closest emitters (`0..3`) allocate real voices, while
        // the other 16 advance `playbackPosition` virtually at zero cost!
        mixer.update(2.5);
        expect(mixer.realVoiceCount, 4);
        expect(mixer.virtualVoiceCount, 16);
        expect(backend.activeHandles.length, 4);
        expect(mixer.isEmitterReal(emitters[0]), isTrue);
        expect(mixer.isEmitterReal(emitters[19]), isFalse);
        expect(emitters[19].playbackPosition, closeTo(2.5, 1e-5));
        expect(mixer.currentReverb.wetMix, closeTo(0.0, 1e-5));
        expect(
          mixer.voiceParamsFor(emitters[0])!.lowPassCutoffHz,
          closeTo(20000.0, 1e-3),
        );

        // 2. Enable 80% wall occlusion and move listener next to
        // `emitters[19]` (`x = 39`, inside `caveZone`):
        // - `emitters[19]` promotes from virtual -> real starting right at
        //   its accumulated `playbackPosition` (`2.5 + 0.5 = 3.0s`)!
        // - Distant `emitters[0]` demotes to virtual (`stopVoice` called)!
        // - Occlusion drops `lowPassCutoffHz` below `2000 Hz` & scales gain!
        // - `currentReverb` smoothly crossfades toward `ReverbPreset3D.cave`!
        wallActive = true;
        listener.position.setValues(38.5, 0.0, 0.0);
        mixer.update(0.5);

        expect(mixer.realVoiceCount, 4);
        expect(mixer.isEmitterReal(emitters[19]), isTrue);
        expect(mixer.isEmitterReal(emitters[0]), isFalse);
        expect(backend.stoppedEmitters, contains(emitters[0]));

        final promotedStart = backend.startedWith[emitters[19]]!;
        expect(promotedStart.playbackPosition, closeTo(3.0, 1e-4));
        expect(promotedStart.occlusion, closeTo(0.8, 1e-5));
        expect(promotedStart.lowPassCutoffHz, lessThan(2000.0));
        expect(promotedStart.volume, lessThan(0.45));

        expect(mixer.currentReverb.wetMix, greaterThan(0.4));
        for (var i = 0; i < 10; i++) {
          mixer.update(0.1);
        }
        expect(
          mixer.currentReverb.wetMix,
          closeTo(ReverbPreset3D.cave.wetMix, 1e-2),
        );
        expect(
          mixer.currentReverb.decaySeconds,
          closeTo(ReverbPreset3D.cave.decaySeconds, math.max(0.05, 1e-2)),
        );
      },
    );
  });
}
