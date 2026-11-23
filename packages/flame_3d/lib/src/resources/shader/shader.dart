import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// {@template shader}
/// A shader [Resource] that represents a compiled shader program and the
/// uniform data that will be bound to it.
///
/// Uniform values are set by string key (`'Material.albedoColor'`,
/// `'Lights.positions[0]'`, `'someColor'`) and are automatically packed
/// into GPU buffers using shader reflection for layout.
///
/// Samplers are auto-detected at compile time via [GpuUniformSlot.sizeInBytes]
/// returning `null` — no need to declare them separately.
///
/// Some uniform blocks are filled by the [RenderContext3D] instead of by the
/// material, once per render pass (see [RenderContext3D.passUniforms]): a
/// shader declares them like any other slot and does not set them.
/// {@endtemplate}
class Shader._(
  final GpuShader Function(String key) _getShader, {

  /// The shader entry point name within the bundle.
  required final String entryPoint,

  /// Names of all uniform slots — both struct blocks and samplers.
  ///
  /// The type of each slot is auto-detected at compile time:
  /// struct blocks have a non-null [GpuUniformSlot.sizeInBytes],
  /// samplers return `null`.
  required final List<String> slots,

  /// The shader bundle asset the shader is loaded from.
  final String? assetName,
}) extends Resource<GpuShader> {
  /// Load a [Shader] from asset.
  Shader.fromAsset(
    String assetName, {
    required String entryPoint,
    List<String> slots = const [],
  }) : this._(
         _assetLibrary(assetName),
         entryPoint: entryPoint,
         slots: slots,
         assetName: assetName,
       );

  /// Whether this shader can run on the device of the active backend:
  /// `null` when that is not known (no backend yet, or a backend that does
  /// not check), see [GpuBackend.shaderSupport].
  GpuShaderSupport? get deviceSupport {
    final asset = assetName;
    final backend = GpuBackend.activeOrNull;
    if (asset == null || backend == null) {
      return null;
    }
    return backend.shaderSupport(asset, entryPoint);
  }

  /// Throws an [UnsupportedError] naming what is missing when this shader
  /// needs more than the device of the active backend offers (an extension,
  /// uniform vectors or textures, see [GpuBackend.shaderSupport]); does
  /// nothing when it can run or when that is not known.
  ///
  /// Materials check their shaders when they are created, and every shader
  /// is checked when its GPU shader is first resolved, so that a material the
  /// device cannot draw fails with this error instead of drawing nothing.
  void checkDeviceSupport({Object? owner}) {
    final support = deviceSupport;
    if (support == null || support.isSupported) {
      return;
    }
    final caps = GpuBackend.activeOrNull!.capabilities;
    final device = [
      caps.api.name,
      if (caps.renderer != null) caps.renderer,
    ].join(', ');
    throw UnsupportedError(
      '${owner ?? 'A material'} cannot run on this device ($device): the '
      'shader "$entryPoint" of $assetName ${support.problems.join('; ')}.',
    );
  }

  final Map<String, GpuUniformSlot> _slots = {};
  final List<GpuUniformSlot> _orderedSlots = [];
  final Map<String, int> _blockIndices = {};
  final List<GpuUniformSlot> _blockSlots = [];
  final List<UniformBlock?> _blockValues = [];
  final List<UniformBlock> _boundBlocks = [];
  final Map<String, int> _samplerIndices = {};
  final List<GpuUniformSlot> _samplerSlots = [];
  final List<Texture?> _samplerValues = [];
  final Map<String, _UniformField> _fields = {};

  /// Incremented every time the shader resource is created, so that state
  /// derived from its slots can tell when it is stale.
  @internal
  int get generation => _generation;
  int _generation = 0;

  /// State the render context derives from this shader's slots.
  @internal
  Object? renderCache;

  /// Dense integer index of the uniform block [name] in this shader, or `-1`
  /// when absent or not a uniform block.
  @internal
  int blockIndexOf(String name) {
    resource;
    return _blockIndices[name] ?? -1;
  }

  /// Dense integer index of the sampler [name] in this shader, or `-1` when
  /// absent or not a sampler.
  @internal
  int samplerIndexOf(String name) {
    resource;
    return _samplerIndices[name] ?? -1;
  }

  /// The uniform block at dense [index] (from [blockIndexOf]).
  @internal
  UniformBlock blockAt(int index) {
    return _blockValues[index] ??= () {
      final created = UniformBlock(_blockSlots[index]);
      _boundBlocks.add(created);
      return created;
    }();
  }

  /// The texture at dense [index] (from [samplerIndexOf]), or `null`.
  @internal
  Texture? textureAt(int index) => _samplerValues[index];

  /// Sets the texture at dense [index] (from [samplerIndexOf]).
  @internal
  void setTextureAt(int index, Texture texture) {
    _samplerValues[index] = texture;
  }

  /// The resolved GPU slot matching index `i` of [slots].
  @internal
  List<GpuUniformSlot> get resolvedSlots {
    resource;
    return _orderedSlots;
  }

  /// The resolved slot named [name].
  ///
  /// Throws when [name] is not one of the declared [slots].
  GpuUniformSlot slot(String name) {
    resource;
    return _slots[name] ??
        (throw StateError('Shader "$entryPoint" has no slot "$name"'));
  }

  /// The uniform block named [name] holding this shader's own values,
  /// created the first time it is requested.
  UniformBlock block(String name) {
    resource;
    final idx = _blockIndices[name];
    if (idx == null) {
      final s = slot(name);
      if (s.sizeInBytes == null) {
        throw StateError('Slot "$name" is a sampler block, not a uniform');
      }
      final created = UniformBlock(s);
      _blockIndices[name] = _blockSlots.length;
      _blockSlots.add(s);
      _blockValues.add(created);
      _boundBlocks.add(created);
      return created;
    }
    return blockAt(idx);
  }

  /// The texture set for the sampler [name], or `null` when none was set.
  Texture? texture(String name) {
    final idx = _samplerIndices[name];
    return idx == null ? null : _samplerValues[idx];
  }

  /// Set a [Texture] at the given [key].
  void setTexture(String key, Texture texture) {
    resource;
    final idx = _samplerIndices[key];
    if (idx != null) {
      _samplerValues[idx] = texture;
      return;
    }
    final slot = _slots[key];
    if (slot == null) {
      throw StateError('Shader "$entryPoint" has no slot "$key"');
    }
    throw StateError('Slot "$key" is a uniform block, not a sampler');
  }

  /// Set a [Vector2] at the given [key].
  void setVector2(String key, Vector2 vector) => _set(key, vector.storage);

  /// Set a [Vector3] at the given [key].
  void setVector3(String key, Vector3 vector) => _set(key, vector.storage);

  /// Set a [Vector4] at the given [key].
  void setVector4(String key, Vector4 vector) => _set(key, vector.storage);

  /// Set an [int] (encoded as uint) at the given [key].
  void setUint(String key, int value) {
    _scalarData.setUint32(0, value, Endian.little);
    return _set(key, _scalarBuf);
  }

  /// Set a [double] at the given [key].
  void setFloat(String key, double value) {
    _scalarData.setFloat32(0, value, Endian.little);
    return _set(key, _scalarBuf);
  }

  /// Set a [Matrix2] at the given [key].
  void setMatrix2(String key, Matrix2 matrix) => _set(key, matrix.storage);

  /// Set a [Matrix3] at the given [key].
  void setMatrix3(String key, Matrix3 matrix) => _set(key, matrix.storage);

  /// Set a [Matrix4] at the given [key].
  void setMatrix4(String key, Matrix4 matrix) => _set(key, matrix.storage);

  /// Set a [Color] at the given [key].
  void setColor(String key, Color color) {
    _colorBuf
      ..[0] = color.r
      ..[1] = color.g
      ..[2] = color.b
      ..[3] = color.a;
    return _set(key, _colorBuf);
  }

  /// Bind all uniform blocks and textures this shader has values for to the
  /// [device].
  ///
  /// Unchanged blocks are not uploaded again within a frame.
  void bind(GraphicsDevice device) {
    for (var i = 0; i < _boundBlocks.length; i++) {
      device.bindUniformBlock(_boundBlocks[i]);
    }
    for (var i = 0; i < _samplerValues.length; i++) {
      final texture = _samplerValues[i];
      if (texture != null) {
        device.bindTexture(_samplerSlots[i], texture);
      }
    }
  }

  @override
  GpuShader createResource() {
    // Always clear up old data to prevent memory leaks.
    _slots.clear();
    _orderedSlots.clear();
    _blockIndices.clear();
    _blockSlots.clear();
    _blockValues.clear();
    _boundBlocks.clear();
    _samplerIndices.clear();
    _samplerSlots.clear();
    _samplerValues.clear();
    _fields.clear();
    _generation++;
    renderCache = null;

    checkDeviceSupport();
    final shader = _getShader(entryPoint);
    for (final name in slots) {
      final s = shader.getUniformSlot(name);
      _slots[name] = s;
      _orderedSlots.add(s);
      if (s.sizeInBytes == null) {
        _samplerIndices[name] = _samplerSlots.length;
        _samplerSlots.add(s);
        _samplerValues.add(null);
      } else {
        _blockIndices[name] = _blockSlots.length;
        _blockSlots.add(s);
        _blockValues.add(null);
      }
    }
    return shader;
  }

  void _set(String key, Float32List data) {
    (_fields[key] ?? _resolveField(key)).write(data);
  }

  _UniformField _resolveField(String key) {
    final (slotName, field, index) = parseKey(key);
    resource;
    final slot = _slots[slotName];
    if (slot == null) {
      throw StateError('Shader "$entryPoint" has no slot "$slotName"');
    }
    if (slot.sizeInBytes == null) {
      throw StateError('Slot "$key" is a sampler block, not a uniform');
    }
    final uniformBlock = blockAt(_blockIndices[slotName]!);

    final int? offset;
    if (field != null) {
      offset = uniformBlock.memberOffset(field);
      if (offset == null) {
        throw StateError('Field "$field" not found in uniform struct');
      }
    } else {
      offset = null;
    }
    return _fields[key] = _UniformField(uniformBlock, offset, index);
  }

  /// Parse a uniform key into (structName, memberName, arrayIndex).
  ///
  /// Examples:
  /// - `'Material.albedoColor'` becomes `('Material', 'albedoColor', null)`
  /// - `'Lights.positions[0]'` becomes `('Lights', 'positions', 0)`
  /// - `'albedoTexture'` becomes `('albedoTexture', null, null)`
  static (String, String?, int?) parseKey(String key) {
    final match = _keyMatches.putIfAbsent(key, () {
      final match = _keyRegex.firstMatch(key);
      if (match == null) {
        throw StateError('Invalid uniform key: "$key"');
      }
      return match;
    });

    final struct = match.group(1)!;
    final member = match.group(2);
    final index = match.group(3);
    return (struct, member, index != null ? int.parse(index) : null);
  }

  static final _keyRegex = RegExp(r'^(\w+)(?:\.(\w+))?(?:\[(\d+)\])?$');
  static final _keyMatches = <String, RegExpMatch>{};

  static final _scalarData = ByteData(4);
  static final _scalarBuf = _scalarData.buffer.asFloat32List();

  static final _colorBuf = Float32List(4);

  static GpuShader Function(String key) _assetLibrary(String assetName) {
    return (key) => GpuBackend.instance.loadShaderLibrary(assetName)[key];
  }
}

/// A uniform key resolved once to the block and offset it writes to.
class _UniformField(
  final UniformBlock _block,
  final int? _memberOffset,
  final int? _index,
) {
  void write(Float32List data) {
    switch (_memberOffset) {
      case final offset?:
        _block.writeAt(
          switch (_index) {
            // Std140 array element stride: round up to a 16-byte boundary.
            final i? => offset + i * ((data.length + 3) & ~3),
            _ => offset,
          },
          data,
        );
      case null:
        _block.writeAt(0, data);
    }
  }
}
