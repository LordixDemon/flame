import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/ui3d/picture_texture.dart';
import 'package:flutter/painting.dart'
    show EdgeInsets, TextPainter, TextSpan, TextStyle;

/// Depth-tested 3D world-space text badge / floating label rendered on the GPU
/// via [BillboardMaterial3D] so 3D geometry accurately occludes it.
///
/// The text, its background and its border are rasterized into a texture,
/// again whenever [text], [style], [backgroundColor], [borderColor],
/// [cornerRadius] or [padding] change; the previous texture is disposed, and
/// so is the last one when the label is removed.
///
/// It needs a GPU backend that can use a `dart:ui` image as a texture
/// (Flutter GPU on Android, iOS and macOS): on another one, such as WebGPU on
/// the web, creating a label throws an [UnsupportedError]. On devices the
/// text is rasterized asynchronously: a new label shows nothing, and a
/// changed one its previous text, for a frame or two. After a GPU device
/// loss the label rasterizes its text again.
class Text3DComponent({
  required String text,
  TextStyle style = const TextStyle(
    color: ui.Color(0xFFFFFFFF),
    fontSize: 28,
    fontWeight: ui.FontWeight.w700,
  ),
  double worldHeight = 0.55,
  ui.Color? backgroundColor = const ui.Color(0xB30F172A),
  ui.Color? borderColor = const ui.Color(0xFF38BDF8),
  double cornerRadius = 10.0,
  EdgeInsets padding = const EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 6,
  ),
  BillboardOrientation3D orientation = BillboardOrientation3D.spherical,
  Vector3? upAxis,
  super.position,
}) extends Object3D {
  this : super(castsShadows: false) {
    _upAxis = upAxis?.clone() ?? Vector3(0, 1, 0);
    _rebuildTexture();
  }

  String _text = text;
  String get text => _text;
  set text(String value) {
    if (value == _text) {
      return;
    }
    _text = value;
    _restyle();
  }

  TextStyle _style = style;
  TextStyle get style => _style;
  set style(TextStyle value) {
    _style = value;
    _restyle();
  }

  ui.Color? _backgroundColor = backgroundColor;

  /// The color of the rounded background, or `null` for none.
  ui.Color? get backgroundColor => _backgroundColor;
  set backgroundColor(ui.Color? value) {
    if (value != _backgroundColor) {
      _backgroundColor = value;
      _restyle();
    }
  }

  ui.Color? _borderColor = borderColor;

  /// The color of the border, or `null` for none.
  ui.Color? get borderColor => _borderColor;
  set borderColor(ui.Color? value) {
    if (value != _borderColor) {
      _borderColor = value;
      _restyle();
    }
  }

  double _cornerRadius = cornerRadius;

  /// The radius of the background's corners, in logical pixels.
  double get cornerRadius => _cornerRadius;
  set cornerRadius(double value) {
    if (value != _cornerRadius) {
      _cornerRadius = value;
      _restyle();
    }
  }

  EdgeInsets _padding = padding;

  /// The space around the text, in logical pixels.
  EdgeInsets get padding => _padding;
  set padding(EdgeInsets value) {
    if (value != _padding) {
      _padding = value;
      _restyle();
    }
  }

  double _worldHeight = worldHeight;

  /// The height of the label in world units; its width follows the aspect
  /// ratio of its texture.
  double get worldHeight => _worldHeight;
  set worldHeight(double value) {
    if (value != _worldHeight) {
      _worldHeight = value;
      _changed();
    }
  }

  BillboardOrientation3D _orientation = orientation;

  /// How the label turns to face the camera.
  BillboardOrientation3D get orientation => _orientation;
  set orientation(BillboardOrientation3D value) {
    if (value != _orientation) {
      _orientation = value;
      _changed();
    }
  }

  void _restyle() {
    _rebuildTexture();
    _changed();
  }

  /// Reports a change of what the label draws: its bounds, and its world's
  /// `World3D.sceneVersion`, so that a retained `Scene3DComponent` renders it
  /// again.
  void _changed() {
    _visualVersion++;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  ImageTexture? _texture;

  late Vector3 _upAxis;

  late final BillboardMaterial3D _material = BillboardMaterial3D(
    shadeWeight: 0.0,
    translucent: true,
  );

  late final BillboardBatch3D _batch = BillboardBatch3D(
    material: _material,
    initialCapacity: 1,
  );

  double _aspect = 2.0;
  double get worldWidth => worldHeight * _aspect;

  final ui.Paint _bgPaint = ui.Paint();
  final ui.Paint _borderPaint = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2.0;
  final Aabb3 _localAabb = Aabb3();
  int _visualVersion = 0;
  int _syncedVisualVersion = -1;
  int _syncedWorldVersion = -1;

  void _rebuildTexture() {
    _visualVersion++;
    final painter = TextPainter(
      text: TextSpan(text: _text, style: _style),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final texW = math.max(
      8,
      (painter.width + _padding.horizontal).ceil(),
    );
    final texH = math.max(
      8,
      (painter.height + _padding.vertical).ceil(),
    );
    _aspect = texW / texH;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final rect = ui.Rect.fromLTWH(0, 0, texW.toDouble(), texH.toDouble());
    final rrect = ui.RRect.fromRectAndRadius(
      rect.deflate(1.5),
      ui.Radius.circular(_cornerRadius),
    );
    if (_backgroundColor case final background?) {
      canvas.drawRRect(rrect, _bgPaint..color = background);
    }
    if (_borderColor case final border?) {
      canvas.drawRRect(rrect, _borderPaint..color = border);
    }
    painter.paint(canvas, ui.Offset(_padding.left, _padding.top));
    painter.dispose();

    final picture = recorder.endRecording();
    final request = ++_rasterRequest;
    final ready = rasterizePictureTexture(
      picture,
      texW,
      texH,
      'Text3DComponent',
      (gpuTex) {
        // A later rebuild, or the label's removal, replaced this request.
        if (request != _rasterRequest || _textureReleased) {
          return;
        }
        _disposeTexture();
        if (gpuTex != null) {
          _material.albedoTexture = _texture = ImageTexture(
            null,
            width: texW,
            height: texH,
            sampler: TextureSampler.linear,
            gpuTexture: gpuTex,
          );
        } else {
          // Without a GPU (a plain `flutter test`) nothing is drawn.
          _material.albedoTexture = ColorTexture(const ui.Color(0xFFFFFFFF));
        }
        worldOrNull?.markSceneDirty(shadows: false);
      },
    );
    if (!ready && _texture == null) {
      // Nothing to show until the picture is rasterized (on devices).
      _material.albedoTexture = Texture.empty;
    }
  }

  // The number of texture rebuilds requested, so that a rasterization that
  // completes after a newer request is dropped.
  int _rasterRequest = 0;

  // Rebuilds the texture after a GPU device loss: it wrapped an image of the
  // lost device.
  late final GpuDeviceListener _deviceListener = GpuDeviceListener(
    onRecovered: (_) {
      if (!_textureReleased) {
        _rebuildTexture();
      }
    },
  );

  void _disposeTexture() {
    final texture = _texture;
    _texture = null;
    if (texture != null && texture.hasResource) {
      texture.dispose();
    }
  }

  @override
  void onMount() {
    super.onMount();
    GpuBackend.addDeviceListener(_deviceListener);
    if (_textureReleased) {
      _textureReleased = false;
      _rebuildTexture();
    }
  }

  // Whether the texture was disposed when the label was removed.
  bool _textureReleased = false;

  @override
  void onRemove() {
    GpuBackend.removeDeviceListener(_deviceListener);
    _disposeTexture();
    _textureReleased = true;
    super.onRemove();
  }

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == Text3DComponent;

  @override
  Aabb3? computeLocalAabb() {
    final hw = worldWidth * 0.5;
    final hh = worldHeight * 0.5;
    return _localAabb
      ..min.setValues(-hw, -hh, -hw)
      ..max.setValues(hw, hh, hw);
  }

  final Vector3 _worldPos = Vector3.zero();

  @override
  void draw(covariant RenderContext3D context) {
    if (context.isShadowPass) {
      return;
    }
    final worldVer = worldTransformVersion;
    if (_batch.isEmpty ||
        _syncedWorldVersion != worldVer ||
        _syncedVisualVersion != _visualVersion) {
      final m = worldTransformMatrix.storage;
      _worldPos.setValues(m[12], m[13], m[14]);
      if (_batch.isEmpty) {
        _batch.addBillboard(
          position: _worldPos,
          width: worldWidth,
          height: worldHeight,
          orientation: orientation,
          upAxis: _upAxis,
          anchorY: 0.0,
          unlit: 1.0,
        );
      } else {
        _batch.setBillboard(
          0,
          position: _worldPos,
          width: worldWidth,
          height: worldHeight,
          orientation: orientation,
          upAxis: _upAxis,
          anchorY: 0.0,
          unlit: 1.0,
        );
      }
      _syncedWorldVersion = worldVer;
      _syncedVisualVersion = _visualVersion;
    }
    _batch.draw(context);
  }
}
