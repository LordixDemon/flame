import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/text/renderers/dynamic_font_atlas.dart';

/// Runtime state of a [DialogueBoxComponent].
enum DialogueBoxState() {
  idle,
  revealing,
  waitingForPage,
  awaitingChoice,
  finished,
}

///Selectable choice item presented at the end of a dialogue passage.
class const DialogueChoiceOption({
  required this.label,
  this.enabled = true,
  this.id = '',
}) {
  final String label;
  final bool enabled;
  final String id;
}

/// Speaker voice-blip configuration for [DialogueBoxComponent].
class const VoiceBlipConfig({
  this.enabled = true,
  this.basePitch = 1.0,
  this.pitchJitter = 0.06,
  this.minIntervalSeconds = 0.045,
}) {
  final bool enabled;
  final double basePitch;
  final double pitchJitter;
  final double minIntervalSeconds;
}

enum _InlineEventKind() {
  wait,
  speed,
  instantStart,
  instantEnd,
  portrait,
  sfx,
  shakeCam,
}

class const _DialogueInlineEvent({
  required this.glyphIndex,
  required this.kind,
  this.numValue = 0.0,
  this.strValue = '',
}) {
  final int glyphIndex;
  final _InlineEventKind kind;
  final double numValue;
  final String strValue;
}

/// Pre-laid-out glyph inside a [DialoguePageLayout] whose `(x, y)` coordinates
/// are resolved **upfront** before typewriter reveal begins, guaranteeing zero
/// mid-word line-jumping during progressive reveal.
class const DialoguePositionedGlyph({
  required this.rune,
  required this.x,
  required this.y,
  required this.lineIndex,
  required this.color,
  required this.scale,
  required this.wave,
  required this.shake,
}) {
  final int rune;
  final double x;
  final double y;
  final int lineIndex;
  final ui.Color color;
  final double scale;
  final bool wave;
  final bool shake;
}

/// Single paginated page inside a [DialogueBoxComponent].
class DialoguePageLayout._(
  this.glyphs,
  this._events,
  this.lineCount,
) {
  final List<DialoguePositionedGlyph> glyphs;
  final List<_DialogueInlineEvent> _events;
  final int lineCount;
}

class const _RawToken({
  required this.rune,
  required this.color,
  required this.scale,
  required this.wave,
  required this.shake,
}) {
  final int rune;
  final ui.Color color;
  final double scale;
  final bool wave;
  final bool shake;
}

/// JRPG / Visual-Novel / RPG Maker dialogue box component powered by
/// [DynamicFontAtlas] featuring:
/// - **Upfront Lookahead Word-Wrapping (`maxTextWidth`)** so partially revealed
///   words NEVER jump to the next line mid-typing,
/// - **Multi-page automatic & explicit (`[page]`) pagination**
///   (`maxLinesPerPage`),
/// - **Zero-width inline event tags**: `[wait:0.4]`, `[speed:0.3]`,
///   `[instant]...[/instant]`, `[portrait:angry]`, `[sfx:chime]`,
///   `[shakeCam:0.3]`, `<color=#RRGGBB>...</color>`, `<wave>`, `<shake>`,
///   `<scale=1.2>`, and `{varName}` variable interpolation,
/// - **Smart `advanceOrSkip()`**: first press finishes revealing the current
///   page while firing skipped state events (`[portrait]`, `[sfx]`,
///   `[shakeCam]`) without waiting on `[wait]` timers; second press advances to
///   the next page or opens choices,
/// - **Pitch-jittered `VoiceBlipConfig`** skipping whitespace & punctuation,
/// - **Integrated Choice Cursor** (`moveChoiceCursor`, `confirmChoice`).
class DialogueBoxComponent({
  required this.atlas,
  this.defaultColor = const ui.Color(0xFFFFFFFF),
  this.backgroundColor = const ui.Color(0xDD141829),
  this.borderColor = const ui.Color(0xFFE2C98B),
  this.choiceHighlightColor = const ui.Color(0x44FFD66B),
  this.padding = 14.0,
  this.lineSpacing = 4.0,
  this.maxLinesPerPage = 3,
  this.baseCharsPerSecond = 35.0,
  this.voiceBlip = const VoiceBlipConfig(),
  this.onPortraitChanged,
  this.onPlaySfx,
  this.onCameraShake,
  this.onVoiceBlip,
  this.onChoiceSelected,
  this.onDialogueFinished,
  super.position,
  Vector2? size,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.sortKey,
  super.cameraMask,
  super.key,
}) extends PositionComponent with HasVisibility {
  this {
    this.size.setFrom(size ?? Vector2(360, 112));
  }

  final DynamicFontAtlas atlas;
  ui.Color defaultColor;
  ui.Color backgroundColor;
  ui.Color borderColor;
  ui.Color choiceHighlightColor;
  double padding;
  double lineSpacing;
  int maxLinesPerPage;
  double baseCharsPerSecond;
  VoiceBlipConfig voiceBlip;

  void Function(String portraitId)? onPortraitChanged;
  void Function(String sfxId)? onPlaySfx;
  void Function(double trauma)? onCameraShake;
  void Function(double pitch)? onVoiceBlip;
  void Function(int index, DialogueChoiceOption option)? onChoiceSelected;
  void Function()? onDialogueFinished;

  final List<DialoguePageLayout> _pages = <DialoguePageLayout>[];
  List<DialogueChoiceOption> _choices = const <DialogueChoiceOption>[];

  DialogueBoxState _state = DialogueBoxState.idle;
  String _speaker = '';
  String _activePortrait = '';
  int _pageIndex = 0;
  int _visibleGlyphs = 0;
  int _nextEventCursor = 0;
  double _speedMultiplier = 1.0;
  bool _instantMode = false;
  double _waitTimer = 0.0;
  double _charAccum = 0.0;
  double _elapsed = 0.0;
  double _timeSinceLastBlip = 999.0;
  int _selectedChoiceIndex = 0;

  final ui.Paint _bgPaint = ui.Paint();
  final ui.Paint _borderPaint = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2.0;
  final ui.Paint _batchPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium;

  DialogueBoxState get state => _state;
  String get speaker => _speaker;
  String get activePortrait => _activePortrait;
  int get pageCount => _pages.length;
  int get currentPageIndex => _pageIndex;
  int get visibleGlyphCount => _visibleGlyphs;
  int get selectedChoiceIndex => _selectedChoiceIndex;
  List<DialogueChoiceOption> get choices => _choices;

  /// Pre-laid-out pages for inspection and layout stability verification.
  List<DialoguePageLayout> get pages =>
      List<DialoguePageLayout>.unmodifiable(_pages);

  /// Starts a new dialogue passage from [markup], interpolating [variables],
  /// pre-baking unseen glyphs into [atlas], pre-computing word-wrapped glyph
  /// positions across pages, and optionally attaching [choices] to the final
  /// page.
  void showPassage(
    String markup, {
    String speaker = '',
    String initialPortrait = '',
    Map<String, Object?> variables = const <String, Object?>{},
    List<DialogueChoiceOption> choices = const <DialogueChoiceOption>[],
  }) {
    _speaker = speaker;
    _choices = List<DialogueChoiceOption>.unmodifiable(choices);
    _selectedChoiceIndex = _firstEnabledChoice(_choices);
    if (initialPortrait.isNotEmpty) {
      _activePortrait = initialPortrait;
      onPortraitChanged?.call(initialPortrait);
    }

    final interpolated = _interpolateVariables(markup, variables);
    _buildPages(interpolated);

    _pageIndex = 0;
    _elapsed = 0.0;
    _beginCurrentPage();
    markSubtreeDirty();
    Game.notifyVisualMutation();
  }

  void _beginCurrentPage() {
    _visibleGlyphs = 0;
    _nextEventCursor = 0;
    _speedMultiplier = 1.0;
    _instantMode = false;
    _waitTimer = 0.0;
    _charAccum = 0.0;

    if (_pages.isEmpty) {
      _transitionAfterLastGlyph();
      return;
    }

    _state = DialogueBoxState.revealing;
    _consumeEventsAtCurrentGlyph(skipWaits: false);
    if (_instantMode) {
      _revealImmediatelyUntilEndOrInstantClose();
    }
    if (_visibleGlyphs >= _pages[_pageIndex].glyphs.length &&
        _waitTimer <= 0.0) {
      _transitionAfterLastGlyph();
    }
  }

  /// Player Confirm action:
  /// - If currently `revealing`, snaps the current page to 100% revealed
  ///   (executing skipped `[portrait]`, `[sfx]`, and `[shakeCam]` tags in order
  ///   without stalling on `[wait]` tags!).
  /// - If `waitingForPage`, advances to the next page (or finishes).
  /// - If `awaitingChoice`, confirms the currently highlighted enabled choice.
  void advanceOrSkip() {
    switch (_state) {
      case DialogueBoxState.idle:
      case DialogueBoxState.finished:
        return;
      case DialogueBoxState.revealing:
        final page = _pages[_pageIndex];
        while (_nextEventCursor < page._events.length) {
          final ev = page._events[_nextEventCursor++];
          _applyEvent(ev, skipWaits: true);
        }
        _waitTimer = 0.0;
        _visibleGlyphs = page.glyphs.length;
        _transitionAfterLastGlyph();
        markSubtreeDirty();
        Game.notifyVisualMutation();
      case DialogueBoxState.waitingForPage:
        if (_pageIndex + 1 < _pages.length) {
          _pageIndex++;
          _beginCurrentPage();
        } else if (_choices.isNotEmpty) {
          _state = DialogueBoxState.awaitingChoice;
        } else {
          _state = DialogueBoxState.finished;
          onDialogueFinished?.call();
        }
        markSubtreeDirty();
        Game.notifyVisualMutation();
      case DialogueBoxState.awaitingChoice:
        confirmChoice();
    }
  }

  /// Moves the choice cursor by `delta` (`-1` up, `+1` down), skipping disabled
  /// choices cleanly.
  void moveChoiceCursor(int delta) {
    if (_state != DialogueBoxState.awaitingChoice || _choices.isEmpty) {
      return;
    }
    final n = _choices.length;
    var cur = _selectedChoiceIndex;
    for (var step = 0; step < n; step++) {
      cur = ((cur + (delta >= 0 ? 1 : -1)) % n + n) % n;
      if (_choices[cur].enabled) {
        if (_selectedChoiceIndex != cur) {
          _selectedChoiceIndex = cur;
          markSubtreeDirty();
          Game.notifyVisualMutation();
        }
        return;
      }
    }
  }

  /// Confirms choice at [explicitIndex] (or [selectedChoiceIndex] if omitted).
  /// Returns `true` when an enabled choice was accepted.
  bool confirmChoice([int? explicitIndex]) {
    if (_state != DialogueBoxState.awaitingChoice || _choices.isEmpty) {
      return false;
    }
    final idx = (explicitIndex ?? _selectedChoiceIndex).clamp(
      0,
      _choices.length - 1,
    );
    final opt = _choices[idx];
    if (!opt.enabled) {
      return false;
    }
    _selectedChoiceIndex = idx;
    _state = DialogueBoxState.finished;
    onChoiceSelected?.call(idx, opt);
    onDialogueFinished?.call();
    markSubtreeDirty();
    Game.notifyVisualMutation();
    return true;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_state == DialogueBoxState.idle ||
        _state == DialogueBoxState.finished ||
        dt <= 0.0) {
      return;
    }
    _elapsed += dt;
    _timeSinceLastBlip += dt;

    final page = _pages.isEmpty ? null : _pages[_pageIndex];
    var animatedTokensActive = false;
    if (page != null) {
      final limit = math.min(_visibleGlyphs, page.glyphs.length);
      for (var i = 0; i < limit; i++) {
        if (page.glyphs[i].wave || page.glyphs[i].shake) {
          animatedTokensActive = true;
          break;
        }
      }
    }

    if (_state == DialogueBoxState.revealing && page != null) {
      var remainingDt = dt;
      while (remainingDt > 1e-7 && _state == DialogueBoxState.revealing) {
        if (_waitTimer > 0.0) {
          if (remainingDt < _waitTimer) {
            _waitTimer -= remainingDt;
            remainingDt = 0.0;
            break;
          } else {
            remainingDt -= _waitTimer;
            _waitTimer = 0.0;
          }
        }

        if (_instantMode) {
          _revealImmediatelyUntilEndOrInstantClose();
          if (_visibleGlyphs >= page.glyphs.length && _waitTimer <= 0.0) {
            _transitionAfterLastGlyph();
            break;
          }
          continue;
        }

        final rate = math.max(0.1, baseCharsPerSecond * _speedMultiplier);
        final secPerChar = 1.0 / rate;
        final needed = secPerChar - _charAccum;
        if (remainingDt < needed) {
          _charAccum += remainingDt;
          remainingDt = 0.0;
        } else {
          remainingDt -= needed;
          _charAccum = 0.0;
          if (_visibleGlyphs < page.glyphs.length) {
            final g = page.glyphs[_visibleGlyphs];
            _visibleGlyphs++;
            _maybeEmitVoiceBlip(g.rune);
            _consumeEventsAtCurrentGlyph(skipWaits: false);
          }
          if (_visibleGlyphs >= page.glyphs.length && _waitTimer <= 0.0) {
            _transitionAfterLastGlyph();
          }
        }
      }
      markSubtreeDirty();
      Game.notifyVisualMutation();
    } else if (animatedTokensActive ||
        _state == DialogueBoxState.waitingForPage) {
      Game.notifyVisualMutation();
    }
  }

  void _revealImmediatelyUntilEndOrInstantClose() {
    final page = _pages[_pageIndex];
    while (_instantMode &&
        _waitTimer <= 0.0 &&
        _visibleGlyphs < page.glyphs.length) {
      _visibleGlyphs++;
      _consumeEventsAtCurrentGlyph(skipWaits: false);
    }
  }

  void _consumeEventsAtCurrentGlyph({required bool skipWaits}) {
    final page = _pages[_pageIndex];
    while (_nextEventCursor < page._events.length &&
        page._events[_nextEventCursor].glyphIndex <= _visibleGlyphs) {
      final ev = page._events[_nextEventCursor++];
      _applyEvent(ev, skipWaits: skipWaits);
      if (!skipWaits && _waitTimer > 0.0) {
        break;
      }
    }
  }

  void _applyEvent(_DialogueInlineEvent ev, {required bool skipWaits}) {
    switch (ev.kind) {
      case _InlineEventKind.wait:
        if (!skipWaits) {
          _waitTimer += math.max(0.0, ev.numValue);
        }
      case _InlineEventKind.speed:
        _speedMultiplier = math.max(0.05, ev.numValue);
      case _InlineEventKind.instantStart:
        _instantMode = true;
      case _InlineEventKind.instantEnd:
        _instantMode = false;
      case _InlineEventKind.portrait:
        _activePortrait = ev.strValue;
        onPortraitChanged?.call(ev.strValue);
      case _InlineEventKind.sfx:
        onPlaySfx?.call(ev.strValue);
      case _InlineEventKind.shakeCam:
        onCameraShake?.call(ev.numValue);
    }
  }

  void _maybeEmitVoiceBlip(int rune) {
    if (!voiceBlip.enabled || onVoiceBlip == null) {
      return;
    }
    // Skip whitespace & punctuation:
    if (rune <= 0x20 ||
        rune == 0x2E ||
        rune == 0x2C ||
        rune == 0x21 ||
        rune == 0x3F ||
        rune == 0x3A ||
        rune == 0x3B ||
        rune == 0x2D ||
        rune == 0x2026) {
      return;
    }
    if (_timeSinceLastBlip < voiceBlip.minIntervalSeconds) {
      return;
    }
    _timeSinceLastBlip = 0.0;
    final hashJitter =
        (((_visibleGlyphs * 73 + rune * 17) % 100) / 50.0 - 1.0) *
        voiceBlip.pitchJitter;
    onVoiceBlip!(math.max(0.25, voiceBlip.basePitch + hashJitter));
  }

  void _transitionAfterLastGlyph() {
    if (_pageIndex + 1 < _pages.length) {
      _state = DialogueBoxState.waitingForPage;
    } else if (_choices.isNotEmpty) {
      _state = DialogueBoxState.awaitingChoice;
    } else {
      _state = DialogueBoxState.waitingForPage;
    }
  }

  @override
  void render(ui.Canvas canvas) {
    if (_state == DialogueBoxState.idle) {
      return;
    }
    final boxRect = ui.RRect.fromRectAndRadius(
      ui.Rect.fromLTWH(0, 0, size.x, size.y),
      const ui.Radius.circular(8.0),
    );
    _bgPaint.color = backgroundColor;
    _borderPaint.color = borderColor;
    canvas.drawRRect(boxRect, _bgPaint);
    canvas.drawRRect(boxRect, _borderPaint);

    var headerOffsetY = padding;
    if (_speaker.isNotEmpty) {
      atlas.drawText(
        canvas,
        _speaker,
        x: padding,
        y: padding,
        color: borderColor,
        scale: 0.92,
      );
      headerOffsetY += atlas.lineHeight + 4.0;
    }

    if (_pages.isNotEmpty && _pageIndex < _pages.length) {
      final page = _pages[_pageIndex];
      final count = math.min(_visibleGlyphs, page.glyphs.length);
      final invScaleBase = 1.0 / atlas.pixelRatio;

      final txByPage = <int, List<double>>{};
      final rxByPage = <int, List<double>>{};
      final colByPage = <int, List<int>>{};

      for (var i = 0; i < count; i++) {
        final g = page.glyphs[i];
        if (g.rune == 0x20) {
          continue;
        }
        final entry = atlas.ensureGlyph(g.rune);
        var dx = 0.0;
        var dy = 0.0;
        if (g.wave) {
          dy += math.sin(_elapsed * 7.5 + i * 0.65) * 2.2;
        }
        if (g.shake) {
          dx += math.sin(_elapsed * 43.0 + i * 1.9) * 1.2;
          dy += math.cos(_elapsed * 37.0 + i * 2.7) * 1.2;
        }

        final tx = txByPage.putIfAbsent(entry.pageIndex, () => <double>[]);
        final rx = rxByPage.putIfAbsent(entry.pageIndex, () => <double>[]);
        final cl = colByPage.putIfAbsent(entry.pageIndex, () => <int>[]);

        final s = invScaleBase * g.scale;
        tx.addAll(<double>[
          s,
          0.0,
          padding + g.x + entry.drawOffsetX * g.scale + dx,
          headerOffsetY + g.y + entry.drawOffsetY * g.scale + dy,
        ]);
        rx.addAll(<double>[
          entry.atlasRect.left,
          entry.atlasRect.top,
          entry.atlasRect.right,
          entry.atlasRect.bottom,
        ]);
        cl.add(g.color.toARGB32());
      }

      txByPage.forEach((pIdx, txList) {
        canvas.drawRawAtlas(
          atlas.pageImage(pIdx),
          Float32List.fromList(txList),
          Float32List.fromList(rxByPage[pIdx]!),
          Int32List.fromList(colByPage[pIdx]!),
          ui.BlendMode.modulate,
          null,
          _batchPaint,
        );
      });
    }

    // Render choice overlay list if awaitingChoice:
    if (_state == DialogueBoxState.awaitingChoice && _choices.isNotEmpty) {
      final choiceRowH = atlas.lineHeight + 4.0;
      var cy = size.y - padding - _choices.length * choiceRowH;
      for (var i = 0; i < _choices.length; i++) {
        final opt = _choices[i];
        if (i == _selectedChoiceIndex) {
          _bgPaint.color = choiceHighlightColor;
          canvas.drawRRect(
            ui.RRect.fromRectAndRadius(
              ui.Rect.fromLTWH(
                padding - 4.0,
                cy - 1.0,
                math.max(40.0, size.x - padding * 2.0 + 8.0),
                choiceRowH,
              ),
              const ui.Radius.circular(4.0),
            ),
            _bgPaint,
          );
        }
        final textColor = !opt.enabled
            ? const ui.Color(0x77999999)
            : (i == _selectedChoiceIndex ? borderColor : defaultColor);
        final prefix = i == _selectedChoiceIndex ? '▸ ' : '  ';
        atlas.drawText(
          canvas,
          '$prefix${opt.label}',
          x: padding,
          y: cy,
          color: textColor,
          scale: 0.92,
        );
        cy += choiceRowH;
      }
    } else if (_state == DialogueBoxState.waitingForPage) {
      // Bouncing page-advance indicator triangle:
      final bob = math.sin(_elapsed * 6.0) * 2.5;
      atlas.drawText(
        canvas,
        '▼',
        x: size.x - padding - 12.0,
        y: size.y - padding - atlas.lineHeight + bob,
        color: borderColor,
        scale: 0.85,
      );
    }
  }

  static int _firstEnabledChoice(List<DialogueChoiceOption> opts) {
    for (var i = 0; i < opts.length; i++) {
      if (opts[i].enabled) {
        return i;
      }
    }
    return 0;
  }

  static String _interpolateVariables(
    String src,
    Map<String, Object?> variables,
  ) {
    if (!src.contains('{') || variables.isEmpty) {
      return src;
    }
    return src.replaceAllMapped(RegExp(r'\{([a-zA-Z0-9_.:]+)\}'), (m) {
      final k = m.group(1)!;
      return variables.containsKey(k) ? '${variables[k]}' : m.group(0)!;
    });
  }

  void _buildPages(String src) {
    _pages.clear();

    final maxTextWidth = math.max(24.0, size.x - padding * 2.0);
    final lineH = atlas.lineHeight + lineSpacing;
    final maxLines = math.max(1, maxLinesPerPage);

    // Split explicit `[page]` breaks first:
    final explicitSections = src.split('[page]');

    for (final section in explicitSections) {
      final rawTokens = <_RawToken>[];
      final rawEvents = <_DialogueInlineEvent>[];
      _parseSectionMarkup(section, rawTokens, rawEvents);

      // Ensure all display glyphs are baked in DynamicFontAtlas upfront so we
      // have exact horizontal advances for lookahead word-wrapping!
      atlas.ensureGlyphs(rawTokens.map((t) => t.rune));

      // Perform greedy word-wrapping across `rawTokens` BEFORE reveal!
      var curPageGlyphs = <DialoguePositionedGlyph>[];
      var curPageEvents = <_DialogueInlineEvent>[];
      var curPageStartRawIdx = 0;
      var lineIdx = 0;
      var penX = 0.0;
      var eventPtr = 0;

      void flushPage(int nextRawIdx) {
        while (eventPtr < rawEvents.length &&
            rawEvents[eventPtr].glyphIndex <= nextRawIdx) {
          final ev = rawEvents[eventPtr++];
          curPageEvents.add(
            _DialogueInlineEvent(
              glyphIndex: (ev.glyphIndex - curPageStartRawIdx).clamp(
                0,
                curPageGlyphs.length,
              ),
              kind: ev.kind,
              numValue: ev.numValue,
              strValue: ev.strValue,
            ),
          );
        }
        _pages.add(
          DialoguePageLayout._(
            List<DialoguePositionedGlyph>.unmodifiable(curPageGlyphs),
            List<_DialogueInlineEvent>.unmodifiable(curPageEvents),
            lineIdx + 1,
          ),
        );
        curPageGlyphs = <DialoguePositionedGlyph>[];
        curPageEvents = <_DialogueInlineEvent>[];
        curPageStartRawIdx = nextRawIdx;
        lineIdx = 0;
        penX = 0.0;
      }

      var idx = 0;
      while (idx < rawTokens.length) {
        final tok = rawTokens[idx];
        if (tok.rune == 0x0A) {
          // Explicit newline '\n':
          idx++;
          if (lineIdx + 1 >= maxLines) {
            flushPage(idx);
          } else {
            lineIdx++;
            penX = 0.0;
          }
          continue;
        }

        if (tok.rune == 0x20) {
          // Collapse leading spaces at the start of a wrapped line:
          if (penX <= 1e-4) {
            idx++;
            continue;
          }
          final adv = atlas.spaceAdvance * tok.scale;
          if (penX + adv > maxTextWidth) {
            if (lineIdx + 1 >= maxLines) {
              idx++;
              flushPage(idx);
            } else {
              lineIdx++;
              penX = 0.0;
              idx++;
            }
          } else {
            curPageGlyphs.add(
              DialoguePositionedGlyph(
                rune: 0x20,
                x: penX,
                y: lineIdx * lineH,
                lineIndex: lineIdx,
                color: tok.color,
                scale: tok.scale,
                wave: tok.wave,
                shake: tok.shake,
              ),
            );
            penX += adv;
            idx++;
          }
          continue;
        }

        // Measure full contiguous non-whitespace word `[idx .. wordEnd)`!
        var wordEnd = idx;
        var wordWidth = 0.0;
        while (wordEnd < rawTokens.length &&
            rawTokens[wordEnd].rune != 0x20 &&
            rawTokens[wordEnd].rune != 0x0A) {
          final wt = rawTokens[wordEnd];
          wordWidth += atlas.ensureGlyph(wt.rune).advance * wt.scale;
          wordEnd++;
        }

        // If the whole word overflows remaining width on a non-empty line, wrap
        // BEFORE placing the very first letter of the word!
        if (penX > 1e-4 && penX + wordWidth > maxTextWidth) {
          if (lineIdx + 1 >= maxLines) {
            flushPage(idx);
          } else {
            lineIdx++;
            penX = 0.0;
          }
        }

        // Place each glyph of the word (hard-wrapping only if a single gigantic
        // word exceeds `maxTextWidth` all by itself):
        while (idx < wordEnd) {
          final wt = rawTokens[idx];
          final adv = atlas.ensureGlyph(wt.rune).advance * wt.scale;
          if (penX > 1e-4 && penX + adv > maxTextWidth) {
            if (lineIdx + 1 >= maxLines) {
              flushPage(idx);
            } else {
              lineIdx++;
              penX = 0.0;
            }
          }
          curPageGlyphs.add(
            DialoguePositionedGlyph(
              rune: wt.rune,
              x: penX,
              y: lineIdx * lineH,
              lineIndex: lineIdx,
              color: wt.color,
              scale: wt.scale,
              wave: wt.wave,
              shake: wt.shake,
            ),
          );
          penX += adv;
          idx++;
        }
      }

      if (curPageGlyphs.isNotEmpty || rawEvents.isNotEmpty || _pages.isEmpty) {
        flushPage(rawTokens.length);
      }
    }
  }

  void _parseSectionMarkup(
    String src,
    List<_RawToken> outTokens,
    List<_DialogueInlineEvent> outEvents,
  ) {
    final colorStack = <ui.Color>[defaultColor];
    final scaleStack = <double>[1.0];
    var waveDepth = 0;
    var shakeDepth = 0;

    var i = 0;
    while (i < src.length) {
      final cu = src.codeUnitAt(i);

      // 1. Style tags `<...>`:
      if (cu == 0x3C) {
        final close = src.indexOf('>', i + 1);
        if (close > i) {
          final tag = src.substring(i + 1, close).trim();
          if (_handleStyleTag(
            tag,
            colorStack,
            scaleStack,
            () => waveDepth++,
            () => waveDepth = math.max(0, waveDepth - 1),
            () => shakeDepth++,
            () => shakeDepth = math.max(0, shakeDepth - 1),
          )) {
            i = close + 1;
            continue;
          }
        }
      }

      // 2. Zero-width control event tags `[...]`:
      if (cu == 0x5B) {
        final close = src.indexOf(']', i + 1);
        if (close > i) {
          final tag = src.substring(i + 1, close).trim();
          if (_handleControlTag(tag, outTokens.length, outEvents)) {
            i = close + 1;
            continue;
          }
        }
      }

      // 3. Regular Unicode rune (properly handling UTF-16 surrogate pairs!):
      final int rune;
      if ((cu & 0xFC00) == 0xD800 && i + 1 < src.length) {
        final low = src.codeUnitAt(i + 1);
        if ((low & 0xFC00) == 0xDC00) {
          rune = 0x10000 + ((cu & 0x3FF) << 10) + (low & 0x3FF);
          i += 2;
        } else {
          rune = cu;
          i++;
        }
      } else {
        rune = cu;
        i++;
      }

      if (rune == 0x0D) {
        continue;
      }
      outTokens.add(
        _RawToken(
          rune: rune,
          color: colorStack.last,
          scale: scaleStack.last,
          wave: waveDepth > 0,
          shake: shakeDepth > 0,
        ),
      );
    }
  }

  static bool _handleStyleTag(
    String tag,
    List<ui.Color> colors,
    List<double> scales,
    void Function() incWave,
    void Function() decWave,
    void Function() incShake,
    void Function() decShake,
  ) {
    final lower = tag.toLowerCase();
    if (lower == 'wave') {
      incWave();
      return true;
    }
    if (lower == '/wave') {
      decWave();
      return true;
    }
    if (lower == 'shake') {
      incShake();
      return true;
    }
    if (lower == '/shake') {
      decShake();
      return true;
    }
    if (lower.startsWith('color=#')) {
      final hex = tag.substring(7);
      final parsed = int.tryParse(
        hex.length == 6 ? 'FF$hex' : hex,
        radix: 16,
      );
      if (parsed != null) {
        colors.add(ui.Color(parsed));
        return true;
      }
    }
    if (lower == '/color') {
      if (colors.length > 1) {
        colors.removeLast();
      }
      return true;
    }
    if (lower.startsWith('scale=')) {
      final v = double.tryParse(tag.substring(6));
      if (v != null && v > 0.0) {
        scales.add(v);
        return true;
      }
    }
    if (lower == '/scale') {
      if (scales.length > 1) {
        scales.removeLast();
      }
      return true;
    }
    return false;
  }

  static bool _handleControlTag(
    String tag,
    int glyphIndex,
    List<_DialogueInlineEvent> outEvents,
  ) {
    final lower = tag.toLowerCase();
    if (lower == 'instant') {
      outEvents.add(
        _DialogueInlineEvent(
          glyphIndex: glyphIndex,
          kind: _InlineEventKind.instantStart,
        ),
      );
      return true;
    }
    if (lower == '/instant') {
      outEvents.add(
        _DialogueInlineEvent(
          glyphIndex: glyphIndex,
          kind: _InlineEventKind.instantEnd,
        ),
      );
      return true;
    }
    final colon = tag.indexOf(':');
    if (colon <= 0) {
      return false;
    }
    final key = tag.substring(0, colon).trim().toLowerCase();
    final arg = tag.substring(colon + 1).trim();
    switch (key) {
      case 'wait':
        final sec = double.tryParse(arg);
        if (sec != null) {
          outEvents.add(
            _DialogueInlineEvent(
              glyphIndex: glyphIndex,
              kind: _InlineEventKind.wait,
              numValue: sec,
            ),
          );
          return true;
        }
      case 'speed':
        final sp = double.tryParse(arg);
        if (sp != null) {
          outEvents.add(
            _DialogueInlineEvent(
              glyphIndex: glyphIndex,
              kind: _InlineEventKind.speed,
              numValue: sp,
            ),
          );
          return true;
        }
      case 'portrait':
      case 'face':
        outEvents.add(
          _DialogueInlineEvent(
            glyphIndex: glyphIndex,
            kind: _InlineEventKind.portrait,
            strValue: arg,
          ),
        );
        return true;
      case 'sfx':
        outEvents.add(
          _DialogueInlineEvent(
            glyphIndex: glyphIndex,
            kind: _InlineEventKind.sfx,
            strValue: arg,
          ),
        );
        return true;
      case 'shakecam':
      case 'shake':
        final tr = double.tryParse(arg);
        if (tr != null) {
          outEvents.add(
            _DialogueInlineEvent(
              glyphIndex: glyphIndex,
              kind: _InlineEventKind.shakeCam,
              numValue: tr,
            ),
          );
          return true;
        }
    }
    return false;
  }
}
