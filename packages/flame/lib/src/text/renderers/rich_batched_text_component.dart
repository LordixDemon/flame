import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/text/renderers/raster_font_atlas.dart';

/// Inline sprite icon descriptor for `[icon:key]` tags inside
/// [RichBatchedTextComponent].
class const RichTextIconSpan({
  required final ui.Image image,
  required final ui.Rect srcRect,
  required final double logicalWidth,
  required final double logicalHeight,
  final double baselineOffsetY = 0.0,
});

class _ParsedRichToken {
  const _ParsedRichToken.glyph({
    required this.rune,
    required this.color,
    required this.scale,
    required this.wave,
    required this.shake,
  }) : iconKey = null;

  const _ParsedRichToken.icon({
    required String this.iconKey,
    required this.color,
    required this.scale,
    required this.wave,
    required this.shake,
  }) : rune = 0;

  final int rune;
  final String? iconKey;
  final ui.Color color;
  final double scale;
  final bool wave;
  final bool shake;
}

/// GPU-batched rich-text component supporting inline markup tags, per-glyph
/// wave/shake animation, `[icon:key]` inline sprite icons, and typewriter
/// progressive reveal over a [RasterFontAtlas].
///
/// Supported tags:
/// - `<color=#RRGGBB>...</color>` or `<color=#AARRGGBB>...</color>`
/// - `<wave>...</wave>`
/// - `<shake>...</shake>`
/// - `<scale=1.3>...</scale>`
/// - `[icon:coin]`
class RichBatchedTextComponent({
  required var RasterFontAtlas atlas,
  String markup = '',
  var ui.Color defaultColor = const ui.Color(0xFFFFFFFF),
  var double letterSpacing = 0.0,
  var double waveAmplitude = 2.5,
  var double waveFrequency = 7.5,
  var double shakeAmplitude = 1.4,
  Map<String, RichTextIconSpan>? icons,
  var int? visibleTokenLimit,
  var double revealTokensPerSecond = 0.0,
  super.position,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.key,
}) extends PositionComponent with HasVisibility {
  this {
    _reparse();
  }

  /// Registered inline `[icon:key]` definitions.
  final Map<String, RichTextIconSpan> icons =
      icons ?? <String, RichTextIconSpan>{};

  String _markup = markup;
  double _revealAccumulator = 0.0;
  double _elapsed = 0.0;
  int _lineCount = 1;
  bool _hasAnimatedTokens = false;

  final List<_ParsedRichToken> _tokens = <_ParsedRichToken>[];
  final GlyphBatchRenderer _glyphBatch = GlyphBatchRenderer(
    initialGlyphCapacity: 128,
  );
  final ui.Paint _iconPaint = ui.Paint()..filterQuality = ui.FilterQuality.low;
  Float32List _iconTransforms = Float32List(32);
  Float32List _iconRects = Float32List(32);
  Int32List _iconColors = Int32List(8);

  /// Raw markup string. Setting this reparses tokens once (zero per-frame
  /// regex/string work).
  String get markup => _markup;
  set markup(String value) {
    if (_markup != value) {
      _markup = value;
      _reparse();
      Game.notifyVisualMutation();
    }
  }

  /// Plain-text + icon token count parsed from [markup].
  int get tokenCount => _tokens.length;

  /// Number of vertical text lines parsed from [markup] (`>= 1`).
  int get lineCount => _lineCount;

  /// Starts a typewriter reveal from `0` tokens up to [tokenCount].
  void startTypewriter({double tokensPerSecond = 30.0}) {
    revealTokensPerSecond = tokensPerSecond;
    visibleTokenLimit = 0;
    _revealAccumulator = 0.0;
    Game.notifyVisualMutation();
  }

  void _reparse() {
    _tokens.clear();
    _hasAnimatedTokens = false;
    final colorStack = <ui.Color>[defaultColor];
    final scaleStack = <double>[1.0];
    var waveDepth = 0;
    var shakeDepth = 0;

    final src = _markup;
    final len = src.length;
    var i = 0;

    while (i < len) {
      final cu = src.codeUnitAt(i);
      if (cu == 0x3C) {
        // '<'
        final closeBracket = src.indexOf('>', i + 1);
        if (closeBracket > i + 1) {
          final tag = src.substring(i + 1, closeBracket).trim();
          if (tag == '/color') {
            if (colorStack.length > 1) {
              colorStack.removeLast();
            }
            i = closeBracket + 1;
            continue;
          } else if (tag.startsWith('color=')) {
            final parsed = _parseHexColor(tag.substring(6).trim());
            if (parsed != null) {
              colorStack.add(parsed);
              i = closeBracket + 1;
              continue;
            }
          } else if (tag == 'wave') {
            waveDepth++;
            i = closeBracket + 1;
            continue;
          } else if (tag == '/wave') {
            waveDepth = math.max(0, waveDepth - 1);
            i = closeBracket + 1;
            continue;
          } else if (tag == 'shake') {
            shakeDepth++;
            i = closeBracket + 1;
            continue;
          } else if (tag == '/shake') {
            shakeDepth = math.max(0, shakeDepth - 1);
            i = closeBracket + 1;
            continue;
          } else if (tag.startsWith('scale=')) {
            final s = double.tryParse(tag.substring(6).trim());
            if (s != null && s > 0) {
              scaleStack.add(s);
              i = closeBracket + 1;
              continue;
            }
          } else if (tag == '/scale') {
            if (scaleStack.length > 1) {
              scaleStack.removeLast();
            }
            i = closeBracket + 1;
            continue;
          }
        }
      } else if (cu == 0x5B && src.startsWith('[icon:', i)) {
        // '[icon:key]'
        final closeSq = src.indexOf(']', i + 6);
        if (closeSq > i + 6) {
          final key = src.substring(i + 6, closeSq).trim();
          _tokens.add(
            _ParsedRichToken.icon(
              iconKey: key,
              color: colorStack.last,
              scale: scaleStack.last,
              wave: waveDepth > 0,
              shake: shakeDepth > 0,
            ),
          );
          i = closeSq + 1;
          continue;
        }
      }

      if (cu == 0x0D) {
        // Ignore CR in CRLF sequences.
        i++;
        continue;
      }

      // Decode UTF-16 code point cleanly (including surrogate pairs).
      var rune = cu;
      var step = 1;
      if (cu >= 0xD800 && cu <= 0xDBFF && i + 1 < len) {
        final next = src.codeUnitAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          rune = 0x10000 + ((cu - 0xD800) << 10) + (next - 0xDC00);
          step = 2;
        }
      }
      _tokens.add(
        _ParsedRichToken.glyph(
          rune: rune,
          color: colorStack.last,
          scale: scaleStack.last,
          wave: waveDepth > 0,
          shake: shakeDepth > 0,
        ),
      );
      i += step;
    }

    _recomputeMeasuredSize();
    for (var k = 0; k < _tokens.length; k++) {
      if (_tokens[k].wave || _tokens[k].shake) {
        _hasAnimatedTokens = true;
        break;
      }
    }
  }

  static ui.Color? _parseHexColor(String raw) {
    final cleaned = raw.startsWith('#') ? raw.substring(1) : raw;
    if (cleaned.length == 6) {
      final rgb = int.tryParse(cleaned, radix: 16);
      if (rgb != null) {
        return ui.Color(0xFF000000 | rgb);
      }
    } else if (cleaned.length == 8) {
      final argb = int.tryParse(cleaned, radix: 16);
      if (argb != null) {
        return ui.Color(argb);
      }
    }
    return null;
  }

  void _recomputeMeasuredSize() {
    if (_tokens.isEmpty) {
      _lineCount = 1;
      size.setValues(0.0, atlas.lineHeight);
      return;
    }
    var maxW = 0.0;
    var lineW = 0.0;
    var lineMaxH = atlas.lineHeight;
    var totalH = 0.0;
    var lines = 1;
    var hasPrevOnLine = false;

    for (var i = 0; i < _tokens.length; i++) {
      final tok = _tokens[i];
      if (tok.iconKey == null && tok.rune == 0x0A) {
        if (lineW > maxW) {
          maxW = lineW;
        }
        totalH += lineMaxH;
        lineW = 0.0;
        lineMaxH = atlas.lineHeight;
        hasPrevOnLine = false;
        lines++;
        continue;
      }
      if (hasPrevOnLine) {
        lineW += letterSpacing;
      }
      hasPrevOnLine = true;
      if (tok.iconKey != null) {
        final ic = icons[tok.iconKey];
        final iw = (ic?.logicalWidth ?? atlas.lineHeight) * tok.scale;
        final ih = (ic?.logicalHeight ?? atlas.lineHeight) * tok.scale;
        lineW += iw;
        if (ih > lineMaxH) {
          lineMaxH = ih;
        }
      } else if (tok.rune == 0x20) {
        lineW += atlas.spaceAdvance * tok.scale;
      } else {
        final m = atlas.metricsForRune(tok.rune);
        lineW += (m?.advance ?? atlas.spaceAdvance) * tok.scale;
        final gh = atlas.lineHeight * tok.scale;
        if (gh > lineMaxH) {
          lineMaxH = gh;
        }
      }
    }
    if (lineW > maxW) {
      maxW = lineW;
    }
    totalH += lineMaxH;
    _lineCount = lines;
    size.setValues(maxW, totalH);
  }

  void _ensureIconCapacity(int needed) {
    if (_iconColors.length >= needed) {
      return;
    }
    var cap = _iconColors.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    _iconTransforms = Float32List(cap * 4);
    _iconRects = Float32List(cap * 4);
    _iconColors = Int32List(cap);
  }

  @override
  void update(double dt) {
    _elapsed += dt;
    var advancedTypewriter = false;
    if (revealTokensPerSecond > 0.0 && visibleTokenLimit != null) {
      if (visibleTokenLimit! < _tokens.length) {
        _revealAccumulator += dt * revealTokensPerSecond;
        final steps = _revealAccumulator.floor();
        if (steps > 0) {
          _revealAccumulator -= steps;
          visibleTokenLimit = math.min(
            _tokens.length,
            visibleTokenLimit! + steps,
          );
          advancedTypewriter = true;
        }
      }
    }
    if (dt > 0.0 && isVisible && (_hasAnimatedTokens || advancedTypewriter)) {
      Game.notifyVisualMutation();
    }
  }

  @override
  void render(ui.Canvas canvas) {
    if (_tokens.isEmpty || atlas.isDisposed) {
      return;
    }
    final limit = visibleTokenLimit == null
        ? _tokens.length
        : visibleTokenLimit!.clamp(0, _tokens.length);
    if (limit <= 0) {
      return;
    }

    _glyphBatch.begin();
    var penX = 0.0;
    var lineY = 0.0;
    ui.Image? sharedIconAtlas;
    var iconCount = 0;

    for (var i = 0; i < limit; i++) {
      final tok = _tokens[i];
      if (tok.iconKey == null && tok.rune == 0x0A) {
        penX = 0.0;
        lineY += atlas.lineHeight;
        continue;
      }
      var dx = 0.0;
      var dy = 0.0;
      if (tok.wave) {
        dy += math.sin(_elapsed * waveFrequency + i * 0.65) * waveAmplitude;
      }
      if (tok.shake) {
        // Fast deterministic pseudo-jitter per index + 60Hz tick bucket.
        final bucket = (_elapsed * 60.0).floor();
        final h1 = ((i * 73856093) ^ (bucket * 19349663)) & 0xFFFF;
        final h2 = ((i * 83492791) ^ (bucket * 2971215073)) & 0xFFFF;
        dx += ((h1 / 32767.5) - 1.0) * shakeAmplitude;
        dy += ((h2 / 32767.5) - 1.0) * shakeAmplitude;
      }

      if (tok.iconKey != null) {
        final icon = icons[tok.iconKey];
        if (icon != null) {
          if (sharedIconAtlas != null &&
              !identical(sharedIconAtlas, icon.image) &&
              iconCount > 0) {
            canvas.drawRawAtlas(
              sharedIconAtlas,
              Float32List.sublistView(_iconTransforms, 0, iconCount * 4),
              Float32List.sublistView(_iconRects, 0, iconCount * 4),
              Int32List.sublistView(_iconColors, 0, iconCount),
              ui.BlendMode.modulate,
              null,
              _iconPaint,
            );
            iconCount = 0;
          }
          sharedIconAtlas = icon.image;
          _ensureIconCapacity(iconCount + 1);
          final slot = iconCount++;
          final sx =
              (icon.logicalWidth * tok.scale) /
              math.max(1.0, icon.srcRect.width);
          final t4 = slot * 4;
          _iconTransforms[t4] = sx;
          _iconTransforms[t4 + 1] = 0.0;
          _iconTransforms[t4 + 2] = penX + dx;
          _iconTransforms[t4 + 3] = lineY + icon.baselineOffsetY + dy;
          _iconRects[t4] = icon.srcRect.left;
          _iconRects[t4 + 1] = icon.srcRect.top;
          _iconRects[t4 + 2] = icon.srcRect.right;
          _iconRects[t4 + 3] = icon.srcRect.bottom;
          _iconColors[slot] = tok.color.toARGB32();
          penX += icon.logicalWidth * tok.scale + letterSpacing;
        } else {
          penX += atlas.lineHeight * tok.scale + letterSpacing;
        }
        continue;
      }

      if (tok.rune == 0x20) {
        penX += atlas.spaceAdvance * tok.scale + letterSpacing;
        continue;
      }

      final m = atlas.metricsForRune(tok.rune);
      if (m == null) {
        penX += atlas.spaceAdvance * tok.scale + letterSpacing;
        continue;
      }

      final yAlign = (atlas.lineHeight - atlas.lineHeight * tok.scale) * 0.5;
      _glyphBatch.addGlyph(
        atlas,
        m,
        x: penX + dx,
        y: lineY + yAlign + dy,
        scale: tok.scale,
        color: tok.color,
      );
      penX += m.advance * tok.scale + letterSpacing;
    }

    _glyphBatch.flush(canvas, atlas);
    if (sharedIconAtlas != null && iconCount > 0) {
      canvas.drawRawAtlas(
        sharedIconAtlas,
        Float32List.sublistView(_iconTransforms, 0, iconCount * 4),
        Float32List.sublistView(_iconRects, 0, iconCount * 4),
        Int32List.sublistView(_iconColors, 0, iconCount),
        ui.BlendMode.modulate,
        null,
        _iconPaint,
      );
    }
  }
}
