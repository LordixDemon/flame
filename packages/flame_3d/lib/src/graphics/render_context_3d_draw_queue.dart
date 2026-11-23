part of 'render_context_3d.dart';

class _DrawQueue() {
  int count = 0;
  int lastDrawCount = 0;
  int capacity = 0;

  bool hasRecordedRefractive = false;
  bool hasRecordedTranslucent = false;
  int cachedOpaqueCount = -1;

  int activePrepassGroup = 0;
  int nextPrepassGroupId = 1;
  int prepassGroupNesting = 0;
  double prepassGroupDepth = double.nan;

  final List<Object?> _sharedGroupKeys = [];
  final List<int> _sharedGroupIds = [];
  final List<double> _sharedGroupDepths = [];
  int _sharedGroupCount = 0;

  List<Surface?> surfaces = [];
  List<Material?> materials = [];
  List<DevicePipeline?> pipelines = [];
  List<Shader?> vertexShaders = [];
  List<Shader?> fragmentShaders = [];
  List<List<Matrix4>?> joints = [];
  List<Float32List?> external = [];
  Int32List externalCounts = Int32List(0);
  Int32List externalOffsets = Int32List(0);
  Int32List externalVersions = Int32List(0);
  Int32List externalCacheSpans = Int32List(0);
  Float32List instances = Float32List(0);
  Float64List depths = Float64List(0);
  Int32List groupKeysHi = Int32List(0);
  Int32List groupKeysLo = Int32List(0);
  Uint8List mirrored = Uint8List(0);
  Int32List surfaceKeys = Int32List(0);
  Int32List prepassGroups = Int32List(0);
  Int32List probeSlots = Int32List(0);
  Float64List probeWeights = Float64List(0);
  Int32List opaque = Int32List(0);
  Int32List translucent = Int32List(0);
  Int32List sortScratch = Int32List(0);
  Float64List sortDepths = Float64List(0);

  bool _sortByProbe = false;

  void beginDepthPrepassGroup() {
    if (prepassGroupNesting++ == 0) {
      activePrepassGroup = nextPrepassGroupId++;
      prepassGroupDepth = double.nan;
    }
  }

  void endDepthPrepassGroup() {
    if (--prepassGroupNesting <= 0) {
      prepassGroupNesting = 0;
      activePrepassGroup = 0;
      prepassGroupDepth = double.nan;
    }
  }

  double joinSharedPrepassGroup(int i, Object key, double depth) {
    for (var k = 0; k < _sharedGroupCount; k++) {
      if (identical(_sharedGroupKeys[k], key)) {
        prepassGroups[i] = _sharedGroupIds[k];
        return _sharedGroupDepths[k];
      }
    }
    final id = nextPrepassGroupId++;
    if (_sharedGroupCount == _sharedGroupKeys.length) {
      _sharedGroupKeys.add(key);
      _sharedGroupIds.add(id);
      _sharedGroupDepths.add(depth);
    } else {
      _sharedGroupKeys[_sharedGroupCount] = key;
      _sharedGroupIds[_sharedGroupCount] = id;
      _sharedGroupDepths[_sharedGroupCount] = depth;
    }
    _sharedGroupCount++;
    prepassGroups[i] = id;
    return depth;
  }

  bool batchesBasic(int first, int other) =>
      identical(surfaces[first], surfaces[other]) &&
      identical(pipelines[first], pipelines[other]) &&
      joints[other] == null &&
      external[other] == null;

  void grow() {
    final nextCapacity = capacity == 0 ? 64 : capacity * 2;
    List<T?> growList<T>(List<T?> existing) =>
        List<T?>.filled(nextCapacity, null)
          ..setRange(0, existing.length, existing);

    surfaces = growList(surfaces);
    materials = growList(materials);
    pipelines = growList(pipelines);
    vertexShaders = growList(vertexShaders);
    fragmentShaders = growList(fragmentShaders);
    joints = growList(joints);
    external = growList(external);
    externalCounts = Int32List(nextCapacity)
      ..setRange(0, externalCounts.length, externalCounts);
    externalOffsets = Int32List(nextCapacity)
      ..setRange(0, externalOffsets.length, externalOffsets);
    externalVersions = Int32List(nextCapacity)
      ..setRange(0, externalVersions.length, externalVersions);
    externalCacheSpans = Int32List(nextCapacity)
      ..setRange(0, externalCacheSpans.length, externalCacheSpans);
    instances = Float32List(nextCapacity * VertexLayout.instanceStrideInFloats)
      ..setRange(0, instances.length, instances);
    depths = Float64List(nextCapacity)..setRange(0, depths.length, depths);
    mirrored = Uint8List(nextCapacity)..setRange(0, mirrored.length, mirrored);
    groupKeysHi = Int32List(nextCapacity);
    groupKeysLo = Int32List(nextCapacity);
    surfaceKeys = Int32List(nextCapacity);
    prepassGroups = Int32List(nextCapacity)
      ..setRange(0, prepassGroups.length, prepassGroups);
    probeSlots = Int32List(nextCapacity)
      ..setRange(0, probeSlots.length, probeSlots);
    probeWeights = Float64List(nextCapacity)
      ..setRange(0, probeWeights.length, probeWeights);
    sortDepths = Float64List(nextCapacity);
    opaque = Int32List(nextCapacity);
    translucent = Int32List(nextCapacity);
    sortScratch = Int32List(nextCapacity);
    capacity = nextCapacity;
  }

  void release(int releasedCount, _OitAndGrabPass oitGrab) {
    hasRecordedRefractive = false;
    hasRecordedTranslucent = false;
    cachedOpaqueCount = -1;
    oitGrab.resetSortCache();
    surfaces.fillRange(0, releasedCount, null);
    materials.fillRange(0, releasedCount, null);
    pipelines.fillRange(0, releasedCount, null);
    vertexShaders.fillRange(0, releasedCount, null);
    fragmentShaders.fillRange(0, releasedCount, null);
    joints.fillRange(0, releasedCount, null);
    external.fillRange(0, releasedCount, null);
  }

  void resetPrepassGroups() {
    nextPrepassGroupId = 1;
    activePrepassGroup = 0;
    prepassGroupNesting = 0;
    if (_sharedGroupCount > 0) {
      _sharedGroupKeys.fillRange(0, _sharedGroupCount, null);
      _sharedGroupCount = 0;
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _compareDraws(int a, int b) {
    final hiA = groupKeysHi[a];
    final hiB = groupKeysHi[b];
    if (hiA != hiB) {
      return hiA < hiB ? -1 : 1;
    }
    final loA = groupKeysLo[a];
    final loB = groupKeysLo[b];
    if (loA != loB) {
      return loA < loB ? -1 : 1;
    }
    final surfaceA = surfaceKeys[a];
    final surfaceB = surfaceKeys[b];
    if (surfaceA != surfaceB) {
      return surfaceA < surfaceB ? -1 : 1;
    }
    if (_sortByProbe) {
      final probeA = probeSlots[a];
      final probeB = probeSlots[b];
      if (probeA != probeB) {
        return probeA < probeB ? -1 : 1;
      }
      final weightA = probeWeights[a];
      final weightB = probeWeights[b];
      if (weightA != weightB) {
        return weightA < weightB ? -1 : 1;
      }
    }
    final depthA = sortDepths[a];
    final depthB = sortDepths[b];
    if (depthA != depthB) {
      return depthA < depthB ? -1 : 1;
    }
    return a - b;
  }

  void sort(Int32List list, int length, {bool sortByProbe = false}) {
    if (length < 2) {
      return;
    }
    _sortByProbe = sortByProbe;
    const run = 8;
    for (var start = 0; start < length; start += run) {
      final end = start + run < length ? start + run : length;
      for (var i = start + 1; i < end; i++) {
        final value = list[i];
        var j = i - 1;
        while (j >= start && _compareDraws(list[j], value) > 0) {
          list[j + 1] = list[j];
          j--;
        }
        list[j + 1] = value;
      }
    }
    var source = list;
    var target = sortScratch;
    for (var width = run; width < length; width *= 2) {
      for (var left = 0; left < length; left += 2 * width) {
        final middle = left + width < length ? left + width : length;
        final right = left + 2 * width < length ? left + 2 * width : length;
        var i = left;
        var j = middle;
        var k = left;
        while (i < middle && j < right) {
          if (_compareDraws(source[j], source[i]) < 0) {
            target[k++] = source[j++];
          } else {
            target[k++] = source[i++];
          }
        }
        while (i < middle) {
          target[k++] = source[i++];
        }
        while (j < right) {
          target[k++] = source[j++];
        }
      }
      final swap = source;
      source = target;
      target = swap;
    }
    if (!identical(source, list)) {
      list.setRange(0, length, source);
    }
    _sortByProbe = false;
  }
}
