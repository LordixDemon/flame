import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DynamicFontAtlas multi-page Unicode stability & rendering', () {
    test(
      'preserves earlier glyph (pageIndex, atlasRect) invariants across '
      'multi-page Cyrillic/CJK/emoji overflow',
      () async {
        final atlas = DynamicFontAtlas(
          style: const TextStyle(fontSize: 18, color: ui.Color(0xFFFFFFFF)),
          pageSizePx: 96,
          outlineWidth: 1.5,
          preloadCharset: 'Hero ',
        );
        addTearDown(atlas.dispose);

        final hBefore = atlas.ensureGlyph('H'.runes.first);
        final eBefore = atlas.ensureGlyph('e'.runes.first);
        final rBefore = atlas.ensureGlyph('r'.runes.first);
        final oBefore = atlas.ensureGlyph('o'.runes.first);

        // Overflow onto multiple 96x96 GPU pages with Cyrillic, CJK, and
        // supplementary emoji:
        atlas.ensureGlyphsForText(
          'ПриветМирГеройМечЩитЗолото竜騎士伝説魔法剣士王国物語🐉⚔️🔥✨',
        );
        expect(atlas.pageCount, greaterThanOrEqualTo(3));

        // Earlier baked glyphs MUST keep their exact pageIndex and atlasRect:
        expect(atlas.ensureGlyph('H'.runes.first).pageIndex, hBefore.pageIndex);
        expect(atlas.ensureGlyph('H'.runes.first).atlasRect, hBefore.atlasRect);
        expect(atlas.ensureGlyph('e'.runes.first).atlasRect, eBefore.atlasRect);
        expect(atlas.ensureGlyph('r'.runes.first).atlasRect, rBefore.atlasRect);
        expect(atlas.ensureGlyph('o'.runes.first).atlasRect, oBefore.atlasRect);

        // Render mixed-page string into an image and verify multi-page draw
        // calls & pixels:
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        final draws = atlas.drawText(
          canvas,
          'Hero Герой 竜 🐉',
          x: 8,
          y: 28,
          color: const ui.Color(0xFFFFD866),
        );
        expect(draws, greaterThanOrEqualTo(2));

        final pic = recorder.endRecording();
        final img = await pic.toImage(260, 64);
        pic.dispose();
        final rgba = (await img.toByteData())!;
        img.dispose();

        var nonZeroAlphaPixels = 0;
        for (var i = 3; i < rgba.lengthInBytes; i += 4) {
          if (rgba.getUint8(i) > 20) {
            nonZeroAlphaPixels++;
          }
        }
        expect(nonZeroAlphaPixels, greaterThan(40));
      },
    );
  });

  group('LocalizationTable Slavic/Polish/English pluralization & gender', () {
    test(
      'evaluates Russian vs Polish CLDR plural categories, gender tags, '
      'fallback, and live hot-swap',
      () {
        final loc = LocalizationTable(
          initialLocale: 'ru',
        );
        var hotSwapNotifications = 0;
        loc.addListener(() => hotSwapNotifications++);

        loc.registerTranslations('ru', const <String, String>{
          'loot_coins':
              '{hero} {gender:sex|m=нашёл|f=нашла|other=нашло} '
              '{plural:count|one=# монету|few=# монеты|many=# монет|other=# '
              'монеты}',
        });
        loc.registerTranslations('pl', const <String, String>{
          'loot_coins':
              '{plural:count|one=# moneta|few=# monety|many=# '
              'monet|other=# monet}',
        });
        loc.registerTranslations('en', const <String, String>{
          'loot_coins': '{hero} found {plural:count|one=# coin|other=# coins}',
          'only_english': 'Fallback works!',
        });

        // Russian CLDR edge cases (1, 2, 5, 11, 12, 21, 24, 25, 101, 111):
        expect(
          loc.tr('loot_coins', <String, Object?>{
            'hero': 'Ария',
            'sex': 'f',
            'count': 1,
          }),
          'Ария нашла 1 монету',
        );
        expect(
          loc.tr('loot_coins', <String, Object?>{
            'hero': 'Артур',
            'sex': 'm',
            'count': 2,
          }),
          'Артур нашёл 2 монеты',
        );
        expect(
          loc.tr('loot_coins', <String, Object?>{
            'hero': 'Артур',
            'sex': 'm',
            'count': 5,
          }),
          'Артур нашёл 5 монет',
        );
        expect(
          loc.tr('loot_coins', <String, Object?>{
            'hero': 'Артур',
            'sex': 'm',
            'count': 11,
          }),
          'Артур нашёл 11 монет',
        );
        expect(
          loc.tr('loot_coins', <String, Object?>{
            'hero': 'Артур',
            'sex': 'm',
            'count': 12,
          }),
          'Артур нашёл 12 монет',
        );
        expect(
          loc.tr('loot_coins', <String, Object?>{
            'hero': 'Ария',
            'sex': 'f',
            'count': 21,
          }),
          'Ария нашла 21 монету',
        );
        expect(
          loc.tr('loot_coins', <String, Object?>{
            'hero': 'Ария',
            'sex': 'f',
            'count': 24,
          }),
          'Ария нашла 24 монеты',
        );

        // Fallback to English when key missing in Russian:
        expect(loc.tr('only_english'), 'Fallback works!');

        // Hot-swap to Polish: note in Polish 21 is `many` ('21 monet'), NOT
        // `one`!
        loc.locale = 'pl';
        expect(hotSwapNotifications, 1);
        expect(loc.tr('loot_coins', <String, Object?>{'count': 1}), '1 moneta');
        expect(
          loc.tr('loot_coins', <String, Object?>{'count': 21}),
          '21 monet',
        );
        expect(
          loc.tr('loot_coins', <String, Object?>{'count': 22}),
          '22 monety',
        );
      },
    );
  });

  group('DialogueBoxComponent zero-jump word-wrap, tags, skip & choices', () {
    test(
      'pre-wraps long words upfront so glyphs NEVER jump lines mid-reveal',
      () {
        final atlas = DynamicFontAtlas(
          style: const TextStyle(fontSize: 16),
          pageSizePx: 256,
        );
        addTearDown(atlas.dispose);

        // Narrow width forces 'supercalifragilistic' onto line 1 right after
        // 'Hi ':
        final box = DialogueBoxComponent(
          atlas: atlas,
          size: Vector2(150, 96),
          padding: 10,
          baseCharsPerSecond: 20,
        )..showPassage('Hi supercalifragilistic');

        final page0 = box.pages.first;
        // 'H'(0), 'i'(1), ' '(2), 's'(3)... — 's' (or space-trimmed start of
        // line 1)
        // Find the index of 's':
        final sIdx = page0.glyphs.indexWhere((g) => g.rune == 's'.runes.first);
        expect(sIdx, greaterThanOrEqualTo(2));

        // Even before a single update tick, 's' is ALREADY placed on line 1!
        expect(page0.glyphs[sIdx].lineIndex, 1);
        final initialSX = page0.glyphs[sIdx].x;
        final initialSY = page0.glyphs[sIdx].y;

        // Step typewriter 1 character at a time and prove 's' NEVER shifts X or
        // Y:
        for (var step = 0; step < 30; step++) {
          box.update(0.05);
          expect(box.pages.first.glyphs[sIdx].x, initialSX);
          expect(box.pages.first.glyphs[sIdx].y, initialSY);
        }
      },
    );

    test(
      'handles inline events, voice-blip punctuation filtering, smart skip, '
      'and disabled choices',
      () {
        final atlas = DynamicFontAtlas(
          style: const TextStyle(fontSize: 14),
          pageSizePx: 256,
        );
        addTearDown(atlas.dispose);

        final portraits = <String>[];
        final sfxPlayed = <String>[];
        final shakes = <double>[];
        var blips = 0;
        DialogueChoiceOption? pickedOption;
        var pickedIdx = -1;

        final box = DialogueBoxComponent(
          atlas: atlas,
          size: Vector2(360, 120),
          baseCharsPerSecond: 50,
          voiceBlip: const VoiceBlipConfig(minIntervalSeconds: 0.0),
          onPortraitChanged: portraits.add,
          onPlaySfx: sfxPlayed.add,
          onCameraShake: shakes.add,
          onVoiceBlip: (_) => blips++,
          onChoiceSelected: (idx, opt) {
            pickedIdx = idx;
            pickedOption = opt;
          },
        );

        final scriptText = <String>[
          'A, !B[wait:5.0][portrait:fierce]',
          '[sfx:slash][shakeCam:0.6] {item}![page]',
          '[instant]Instant line[/instant]',
        ].join();
        box.showPassage(
          scriptText,
          initialPortrait: 'calm',
          variables: const <String, Object?>{'item': 'Excalibur'},
          choices: const <DialogueChoiceOption>[
            DialogueChoiceOption(
              label: 'Locked Option',
              enabled: false,
              id: 'locked',
            ),
            DialogueChoiceOption(label: 'Draw Sword', id: 'draw'),
            DialogueChoiceOption(label: 'Retreat', id: 'retreat'),
          ],
        );

        expect(portraits, const <String>['calm']);
        expect(box.pageCount, 2);
        // Initial choice cursor skips disabled index 0 and lands on index 1:
        expect(box.selectedChoiceIndex, 1);

        // Reveal 'A, !B' (5 glyphs -> 5 * 0.02s = 0.10s) where it hits
        // [wait:5.0]:
        for (var i = 0; i < 6; i++) {
          box.update(0.02);
        }
        // Only 'A' and 'B' are alphanumeric -> 2 blips (',' ' ' '!' were
        // skipped!):
        expect(blips, 2);
        expect(box.state, DialogueBoxState.revealing);
        expect(sfxPlayed, isEmpty);

        // Player presses Confirm to skip the 5.0s wait:
        // Skipped [portrait:fierce], [sfx:slash], and [shakeCam:0.6] MUST fire
        // immediately!
        box.advanceOrSkip();
        expect(box.state, DialogueBoxState.waitingForPage);
        expect(portraits.last, 'fierce');
        expect(sfxPlayed, const <String>['slash']);
        expect(shakes, const <double>[0.6]);

        // Render page 0 cleanly to verify draw pipeline:
        final rec = ui.PictureRecorder();
        box.render(ui.Canvas(rec));
        rec.endRecording().dispose();

        // Advance to Page 1 ([instant]Instant line[/instant] on final page with
        // choices
        // immediately reveals and transitions straight to awaitingChoice!):
        box.advanceOrSkip();
        expect(box.currentPageIndex, 1);
        expect(box.state, DialogueBoxState.awaitingChoice);

        // Attempting to confirm disabled index 0 returns false:
        expect(box.confirmChoice(0), isFalse);

        // Cursor wrap-around skips disabled index 0 (`1 -> 2 -> 1`):
        box.moveChoiceCursor(1);
        expect(box.selectedChoiceIndex, 2);
        box.moveChoiceCursor(1);
        expect(box.selectedChoiceIndex, 1);

        // Confirm active choice ('Draw Sword'):
        box.advanceOrSkip();
        expect(box.state, DialogueBoxState.finished);
        expect(pickedIdx, 1);
        expect(pickedOption?.id, 'draw');
      },
    );
  });
}
