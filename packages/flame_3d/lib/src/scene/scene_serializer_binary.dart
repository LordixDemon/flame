part of 'scene_serializer_3d.dart';

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) {
    return null;
  }
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return null;
}

List<double> _encodeVec2(Vector2 v) => <double>[v.x, v.y];

List<double> _encodeVec3(Vector3 v) => <double>[v.x, v.y, v.z];

List<double> _encodeVec4(Vector4 v) => <double>[v.x, v.y, v.z, v.w];

List<double> _encodeQuat(Quaternion q) => <double>[q.x, q.y, q.z, q.w];

List<double> _encodeColor(Color c) => <double>[c.a, c.r, c.g, c.b];

Vector2? _decodeVec2OrNull(Object? raw) {
  final list = _asDoubleList(raw);
  return list != null && list.length >= 2 ? Vector2(list[0], list[1]) : null;
}

Vector3? _decodeVec3OrNull(Object? raw) {
  final list = _asDoubleList(raw);
  return list != null && list.length >= 3
      ? Vector3(list[0], list[1], list[2])
      : null;
}

Vector4? _decodeVec4OrNull(Object? raw) {
  final list = _asDoubleList(raw);
  return list != null && list.length >= 4
      ? Vector4(list[0], list[1], list[2], list[3])
      : null;
}

Quaternion? _decodeQuatOrNull(Object? raw) {
  final list = _asDoubleList(raw);
  return list != null && list.length >= 4
      ? Quaternion(list[0], list[1], list[2], list[3])
      : null;
}

Matrix4? _decodeMatrix4OrNull(Object? raw) {
  final list = _asDoubleList(raw);
  if (list == null || list.length < 16) {
    return null;
  }
  return Matrix4.fromList(list.sublist(0, 16));
}

Color? _decodeColorOrNull(Object? raw) {
  final list = _asDoubleList(raw);
  if (list == null || list.length < 4) {
    return null;
  }
  return Color.from(
    alpha: list[0].clamp(0.0, 1.0),
    red: list[1].clamp(0.0, 1.0),
    green: list[2].clamp(0.0, 1.0),
    blue: list[3].clamp(0.0, 1.0),
  );
}

int? _asInt(Object? v) {
  if (v is int) {
    return v;
  }
  if (v is num) {
    return v.toInt();
  }
  return null;
}

double? _asDouble(Object? v) => v is num ? v.toDouble() : null;

Map<String, Object?>? _asMap(Object? v) {
  if (v is Map<String, Object?>) {
    return v;
  }
  if (v is Map) {
    return <String, Object?>{
      for (final entry in v.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }
  return null;
}

List<Object?>? _asList(Object? v) {
  if (v is List<Object?>) {
    return v;
  }
  if (v is List) {
    return List<Object?>.of(v);
  }
  return null;
}

List<String>? _asStringList(Object? v) {
  final list = _asList(v);
  if (list == null) {
    return null;
  }
  return <String>[
    for (final item in list)
      if (item is String) item,
  ];
}

List<int>? _asIntList(Object? v) {
  final list = _asList(v);
  if (list == null) {
    return null;
  }
  return <int>[
    for (final item in list)
      if (item is num) item.toInt(),
  ];
}

List<double>? _asDoubleList(Object? v) {
  final list = _asList(v);
  if (list == null) {
    return null;
  }
  return <double>[
    for (final item in list)
      if (item is num) item.toDouble(),
  ];
}

Float32List? _asFloat32List(Object? v) {
  final list = _asDoubleList(v);
  return list == null ? null : Float32List.fromList(list);
}

class _BinarySceneWriter() {
  static const int _tagNull = 0;
  static const int _tagFalse = 1;
  static const int _tagTrue = 2;
  static const int _tagInt32 = 3;
  static const int _tagUint32 = 4;
  static const int _tagFloat64 = 5;
  static const int _tagString = 6;
  static const int _tagList = 7;
  static const int _tagMap = 8;

  final Map<String, int> _stringIds = {};
  final List<Uint8List> _stringBytes = [];
  final BytesBuilder _body = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(8);

  Uint8List encodeRoot(Map<String, Object?> root) {
    _writeValue(root);
    final bodyBytes = _body.takeBytes();

    final out = BytesBuilder(copy: false);
    _appendUint32(out, _stringBytes.length);
    for (final utf8Bytes in _stringBytes) {
      _appendUint32(out, utf8Bytes.length);
      out.add(utf8Bytes);
    }
    out.add(bodyBytes);
    return out.takeBytes();
  }

  int _intern(String value) {
    return _stringIds.putIfAbsent(value, () {
      final id = _stringBytes.length;
      _stringBytes.add(utf8.encode(value));
      return id;
    });
  }

  void _writeValue(Object? value) {
    if (value == null) {
      _body.addByte(_tagNull);
      return;
    }
    if (value is bool) {
      _body.addByte(value ? _tagTrue : _tagFalse);
      return;
    }
    if (value is int) {
      if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
        _body.addByte(_tagInt32);
        _scratch.setInt32(0, value, Endian.little);
        _body.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
      } else if (value >= 0 && value <= 0xFFFFFFFF) {
        _body.addByte(_tagUint32);
        _scratch.setUint32(0, value, Endian.little);
        _body.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
      } else {
        _body.addByte(_tagFloat64);
        _scratch.setFloat64(0, value.toDouble(), Endian.little);
        _body.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
      }
      return;
    }
    if (value is num) {
      _body.addByte(_tagFloat64);
      _scratch.setFloat64(0, value.toDouble(), Endian.little);
      _body.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
      return;
    }
    if (value is String) {
      _body.addByte(_tagString);
      _writeUint32(_intern(value));
      return;
    }
    if (value is List) {
      _body.addByte(_tagList);
      _writeUint32(value.length);
      for (final item in value) {
        _writeValue(item);
      }
      return;
    }
    if (value is Map) {
      _body.addByte(_tagMap);
      final entries = <MapEntry<String, Object?>>[
        for (final e in value.entries)
          if (e.key is String) MapEntry(e.key as String, e.value),
      ];
      _writeUint32(entries.length);
      for (final entry in entries) {
        _writeUint32(_intern(entry.key));
        _writeValue(entry.value);
      }
      return;
    }
    throw FormatException('Unsupported value in binary scene: $value');
  }

  void _writeUint32(int v) => _appendUint32(_body, v);

  void _appendUint32(BytesBuilder target, int v) {
    _scratch.setUint32(0, v, Endian.little);
    target.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
  }
}

class _BinarySceneReader(final Uint8List _bytes) {
  late final ByteData _view = ByteData.sublistView(_bytes);
  int _offset = 0;
  final List<String> _strings = [];

  Map<String, Object?> decodeRoot() {
    final stringCount = _readUint32();
    for (var i = 0; i < stringCount; i++) {
      final byteLen = _readUint32();
      _require(byteLen);
      _strings.add(
        utf8.decode(
          Uint8List.sublistView(_bytes, _offset, _offset + byteLen),
        ),
      );
      _offset += byteLen;
    }
    final root = _readValue();
    if (root is! Map<String, Object?>) {
      throw const FormatException('F3DS binary root is not a map.');
    }
    return root;
  }

  Object? _readValue() {
    _require(1);
    final tag = _bytes[_offset++];
    switch (tag) {
      case _BinarySceneWriter._tagNull:
        return null;
      case _BinarySceneWriter._tagFalse:
        return false;
      case _BinarySceneWriter._tagTrue:
        return true;
      case _BinarySceneWriter._tagInt32:
        _require(4);
        final v = _view.getInt32(_offset, Endian.little);
        _offset += 4;
        return v;
      case _BinarySceneWriter._tagUint32:
        _require(4);
        final v = _view.getUint32(_offset, Endian.little);
        _offset += 4;
        return v;
      case _BinarySceneWriter._tagFloat64:
        _require(8);
        final v = _view.getFloat64(_offset, Endian.little);
        _offset += 8;
        return v;
      case _BinarySceneWriter._tagString:
        return _readInternedString();
      case _BinarySceneWriter._tagList:
        final count = _readUint32();
        return <Object?>[for (var i = 0; i < count; i++) _readValue()];
      case _BinarySceneWriter._tagMap:
        final count = _readUint32();
        final map = <String, Object?>{};
        for (var i = 0; i < count; i++) {
          final key = _readInternedString();
          map[key] = _readValue();
        }
        return map;
      case _:
        throw FormatException('Invalid F3DS binary value tag: $tag');
    }
  }

  String _readInternedString() {
    final idx = _readUint32();
    if (idx >= _strings.length) {
      throw FormatException('Out-of-bounds F3DS string index: $idx');
    }
    return _strings[idx];
  }

  int _readUint32() {
    _require(4);
    final v = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  void _require(int count) {
    if (_offset + count > _bytes.length) {
      throw const FormatException('Unexpected end of F3DS binary stream.');
    }
  }
}
