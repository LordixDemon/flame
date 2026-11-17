import 'package:flame/text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalizationTable plural rules', () {
    // CLDR cardinal categories for East Slavic languages.
    const slavic = <int, String>{
      0: 'many',
      1: 'one',
      2: 'few',
      3: 'few',
      4: 'few',
      5: 'many',
      11: 'many',
      12: 'many',
      14: 'many',
      21: 'one',
      22: 'few',
      25: 'many',
      100: 'many',
      101: 'one',
      102: 'few',
      111: 'many',
      112: 'many',
      1001: 'one',
    };

    test('Russian and Ukrainian follow the one / few / many rules', () {
      final table = LocalizationTable();
      for (final locale in <String>['ru', 'uk', 'ru-RU', 'uk_UA']) {
        slavic.forEach((n, category) {
          expect(
            table.resolvePluralCategory(n, locale).name,
            category,
            reason: '$locale $n',
          );
          expect(
            table.resolvePluralCategory(-n, locale).name,
            category,
            reason: '$locale -$n',
          );
        });
      }
    });

    test('English is one for 1 and other for everything else', () {
      final table = LocalizationTable();
      expect(table.resolvePluralCategory(1, 'en'), PluralCategory.one);
      expect(table.resolvePluralCategory(-1, 'en-GB'), PluralCategory.one);
      for (final n in <int>[0, 2, 5, 11, 21, 101, 111]) {
        expect(
          table.resolvePluralCategory(n, 'en'),
          PluralCategory.other,
          reason: 'en $n',
        );
      }
    });

    test('templates pick the form of the count', () {
      final table = LocalizationTable(initialLocale: 'ru')
        ..registerTranslations('ru', <String, String>{
          'cards':
              '{plural:count|one=# карта|few=# карты|many=# '
              'карт|other=# карты} · {deck}',
        })
        ..registerTranslations('uk', <String, String>{
          'cards':
              '{plural:count|one=# картка|few=# картки|many=# '
              'карток|other=# картки} · {deck}',
        })
        ..registerTranslations('en', <String, String>{
          'cards': '{plural:count|one=# card|other=# cards} · {deck}',
        });

      String cards(Object? count) =>
          table.tr('cards', <String, Object?>{'count': count, 'deck': 3});

      expect(cards(1), '1 карта · 3');
      expect(cards(2), '2 карты · 3');
      expect(cards(5), '5 карт · 3');
      expect(cards(12), '12 карт · 3');
      expect(cards(21), '21 карта · 3');
      expect(cards('4'), '4 карты · 3');
      expect(cards(3.0), '3 карты · 3');
      // A missing count formats as zero.
      expect(table.tr('cards', <String, Object?>{'deck': 3}), '0 карт · 3');

      table.locale = 'uk';
      expect(cards(1), '1 картка · 3');
      expect(cards(22), '22 картки · 3');
      expect(cards(25), '25 карток · 3');

      table.locale = 'en';
      expect(cards(1), '1 card · 3');
      expect(cards(21), '21 cards · 3');
    });
  });

  group('LocalizationTable fallback locale', () {
    test('a template taken from the fallback locale is pluralized by the '
        'fallback language', () {
      final table = LocalizationTable(initialLocale: 'ru')
        ..registerTranslations('en', <String, String>{
          'votes': '{plural:count|one=# vote|other=# votes}',
        })
        ..registerTranslations('ru', <String, String>{'title': 'Голоса'})
        ..registerTranslations('uk', <String, String>{'title': 'Голоси'});

      for (final locale in <String>['ru', 'uk']) {
        table.locale = locale;
        expect(table.tr('votes', <String, Object?>{'count': 1}), '1 vote');
        expect(table.tr('votes', <String, Object?>{'count': 2}), '2 votes');
        expect(table.tr('votes', <String, Object?>{'count': 21}), '21 votes');
        expect(
          table.tr('votes', <String, Object?>{'count': 101}),
          '101 votes',
        );
      }
    });

    test('a key in neither locale is returned as is', () {
      final table = LocalizationTable(initialLocale: 'ru');
      expect(table.tr('missing.key'), 'missing.key');
    });
  });

  group('LocalizationTable template syntax', () {
    test('a count that is not a whole number is printed as passed and takes '
        'the other form', () {
      final table = LocalizationTable();
      const template = '{plural:n|one=# coin|other=# coins}';
      String coins(Object? n, [String? locale]) => table.formatTemplate(
        template,
        <String, Object?>{'n': n},
        localeCode: locale,
      );

      expect(coins(1.4), '1.4 coins');
      expect(coins(0.5), '0.5 coins');
      expect(coins('2.5'), '2.5 coins');
      expect(coins(1.0), '1 coin');
      expect(coins(double.nan), 'NaN coins');
      expect(coins(double.infinity), 'Infinity coins');
      // Slavic fractions have no one / few / many form either.
      expect(
        table.formatTemplate(
          '{plural:n|one=# рубль|few=# рубля|many=# рублей|other=# рубля}',
          <String, Object?>{'n': 1.5},
          localeCode: 'ru',
        ),
        '1.5 рубля',
      );
      // French counts everything below two as singular.
      expect(
        table.formatTemplate(
          '{plural:n|one=# point|other=# points}',
          <String, Object?>{'n': 1.5},
          localeCode: 'fr',
        ),
        '1.5 point',
      );
    });

    test('parameters and directives nest inside plural and gender forms', () {
      final table = LocalizationTable();
      expect(
        table.formatTemplate(
          '{plural:n|one={who} has # coin|other={who} has # coins}',
          <String, Object?>{'n': 1, 'who': 'Bob'},
        ),
        'Bob has 1 coin',
      );
      expect(
        table.formatTemplate(
          '{gender:sex|f={name} found her '
          '{plural:n|one=# key|other=# keys}|other={name} '
          'found their {plural:n|one=# key|other=# keys}}!',
          <String, Object?>{'sex': 'F', 'name': 'Ann', 'n': 3},
        ),
        'Ann found her 3 keys!',
      );
      // `#` belongs to the innermost plural.
      expect(
        table.formatTemplate(
          '{plural:a|other=# of {plural:b|one=# team|other=# teams}}',
          <String, Object?>{'a': 2, 'b': 1},
        ),
        '2 of 1 team',
      );
    });

    test('unbalanced braces and unknown parameters stay literal', () {
      final table = LocalizationTable();
      expect(table.formatTemplate('a {b', const <String, Object?>{}), 'a {b');
      expect(
        table.formatTemplate('{a {b}', <String, Object?>{'b': 1}),
        '{a 1',
      );
      expect(table.formatTemplate('{x} }', const <String, Object?>{}), '{x} }');
      expect(
        table.formatTemplate('{x}/{y}', <String, Object?>{'y': 2}),
        '{x}/2',
      );
    });
  });

  group('LocalizationTable version', () {
    test('changes whenever the output of tr can change', () {
      final table = LocalizationTable();
      var notified = 0;
      table.addListener(() => notified++);

      final v0 = table.version;
      table.registerTranslations('en', <String, String>{'k': 'v'});
      expect(table.version, greaterThan(v0));

      final v1 = table.version;
      table.locale = 'ru';
      expect(table.version, greaterThan(v1));
      expect(notified, 1);
      table.locale = 'ru';
      expect(notified, 1);

      final v2 = table.version;
      table.registerPluralResolver('ru', (n) => PluralCategory.other);
      expect(table.version, greaterThan(v2));
      expect(table.resolvePluralCategory(1, 'ru'), PluralCategory.other);
    });
  });
}
