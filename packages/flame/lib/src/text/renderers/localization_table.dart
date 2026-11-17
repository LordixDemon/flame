/// CLDR-aligned grammatical plural categories.
enum PluralCategory() {
  zero,
  one,
  two,
  few,
  many,
  other,
}

/// Function mapping an integer quantity `n` (`>= 0`) to a [PluralCategory].
typedef PluralRuleResolver = PluralCategory Function(int n);

/// Multi-locale string table with built-in CLDR pluralization (including full
/// Slavic `ru`/`uk`/`pl` `one/few/many` rules), gender agreement tags,
/// parameter interpolation, fallback locale resolution, and live hot-swap
/// version tracking.
///
/// Supported inline directives:
/// - `{name}` -> parameter value
/// - `{plural:count|one=# монета|few=# монеты|many=# монет|other=# монеты}`
/// - `{gender:heroSex|m=Готов|f=Готова|other=Готово}`
///
/// The forms of a `plural` or `gender` directive may themselves contain
/// `{name}` parameters and further directives, for example
/// `{plural:n|one={who} has # coin|other={who} has # coins}`; `#` stands for
/// the count of the innermost enclosing `plural`.
///
/// A template is always pluralized by the rules of the language it is written
/// in: when [tr] falls back to [fallbackLocale] for a missing key, the
/// fallback locale's plural rules apply, not those of the active locale.
///
/// A count that is not a whole number takes the `other` form (in French the
/// `one` form below `2`) and is printed as passed, as CLDR prescribes.
class LocalizationTable({
  String initialLocale = 'en',
  this.fallbackLocale = 'en',
}) {
  String _locale = initialLocale;
  final String fallbackLocale;

  final Map<String, Map<String, String>> _bundles =
      <String, Map<String, String>>{};
  final Map<String, PluralRuleResolver> _pluralResolvers =
      <String, PluralRuleResolver>{};
  final Set<void Function()> _listeners = <void Function()>{};
  int _version = 0;

  String get locale => _locale;
  int get version => _version;

  set locale(String next) {
    if (_locale != next) {
      _locale = next;
      _version++;
      final copy = List<void Function()>.of(_listeners, growable: false);
      for (var i = 0; i < copy.length; i++) {
        copy[i]();
      }
    }
  }

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Registers or merges key-value translations for [localeCode].
  void registerTranslations(String localeCode, Map<String, String> entries) {
    final target = _bundles.putIfAbsent(localeCode, () => <String, String>{});
    target.addAll(entries);
    _version++;
  }

  /// Registers a custom [PluralRuleResolver] for [languagePrefix] (e.g.
  /// `'ar'`).
  void registerPluralResolver(
    String languagePrefix,
    PluralRuleResolver resolver,
  ) {
    _pluralResolvers[languagePrefix.toLowerCase()] = resolver;
    _version++;
  }

  static final RegExp _localeSeparator = RegExp('[-_]');

  static String _languageOf(String localeCode) =>
      localeCode.split(_localeSeparator).first.toLowerCase();

  /// Resolves the [PluralCategory] for integer [count] under [localeCode].
  PluralCategory resolvePluralCategory(int count, [String? localeCode]) {
    final n = count.abs();
    final lang = _languageOf(localeCode ?? _locale);

    final custom = _pluralResolvers[lang];
    if (custom != null) {
      return custom(n);
    }

    switch (lang) {
      case 'ru':
      case 'uk':
      case 'be':
      case 'sr':
      case 'hr':
        final mod10 = n % 10;
        final mod100 = n % 100;
        if (mod10 == 1 && mod100 != 11) {
          return PluralCategory.one;
        }
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return PluralCategory.few;
        }
        return PluralCategory.many;
      case 'pl':
        if (n == 1) {
          return PluralCategory.one;
        }
        final mod10 = n % 10;
        final mod100 = n % 100;
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return PluralCategory.few;
        }
        return PluralCategory.many;
      case 'fr':
        return (n == 0 || n == 1) ? PluralCategory.one : PluralCategory.other;
      case 'ja':
      case 'zh':
      case 'ko':
        return PluralCategory.other;
      default:
        return n == 1 ? PluralCategory.one : PluralCategory.other;
    }
  }

  /// The category of a count that is not a whole number: `other`, except in
  /// French, where everything below `2` is `one`.
  PluralCategory _resolveFractionCategory(double value, String? localeCode) {
    final lang = _languageOf(localeCode ?? _locale);
    if (lang == 'fr' &&
        !_pluralResolvers.containsKey(lang) &&
        value.abs() < 2) {
      return PluralCategory.one;
    }
    return PluralCategory.other;
  }

  /// Formats translation [key] using [params] under the active [locale]
  /// (falling back to [fallbackLocale], or returning `key` if missing).
  ///
  /// A template found in [fallbackLocale] is formatted with that locale's
  /// plural rules.
  String tr(
    String key, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    final own = _bundles[_locale]?[key];
    if (own != null) {
      return formatTemplate(own, params, localeCode: _locale);
    }
    final fallback = _bundles[fallbackLocale]?[key];
    if (fallback != null) {
      return formatTemplate(fallback, params, localeCode: fallbackLocale);
    }
    return formatTemplate(key, params, localeCode: _locale);
  }

  /// Formats an arbitrary template string against [params], using the plural
  /// rules of [localeCode] (the active [locale] by default).
  ///
  /// A `{` without a matching `}` is ordinary text, and so is a `{name}` whose
  /// parameter is missing.
  String formatTemplate(
    String template,
    Map<String, Object?> params, {
    String? localeCode,
  }) {
    if (!template.contains('{')) {
      return template;
    }

    final sb = StringBuffer();
    var i = 0;
    while (i < template.length) {
      final open = template.indexOf('{', i);
      if (open < 0) {
        sb.write(template.substring(i));
        break;
      }
      sb.write(template.substring(i, open));
      final close = _matchingBrace(template, open);
      if (close < 0) {
        sb.write('{');
        i = open + 1;
        continue;
      }

      final expr = template.substring(open + 1, close);
      if (expr.startsWith('plural:')) {
        sb.write(_evalPlural(expr.substring(7), params, localeCode));
      } else if (expr.startsWith('gender:')) {
        sb.write(_evalGender(expr.substring(7), params, localeCode));
      } else {
        final v = params[expr];
        sb.write(v?.toString() ?? '{$expr}');
      }
      i = close + 1;
    }
    return sb.toString();
  }

  static const int _openBrace = 0x7B;
  static const int _closeBrace = 0x7D;
  static const int _pipe = 0x7C;
  static const int _hash = 0x23;

  /// Index of the `}` that closes the `{` at [open], or `-1` if there is none.
  static int _matchingBrace(String text, int open) {
    var depth = 0;
    for (var i = open + 1; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == _openBrace) {
        depth++;
      } else if (c == _closeBrace) {
        if (depth == 0) {
          return i;
        }
        depth--;
      }
    }
    return -1;
  }

  /// Splits a directive body at the `|` separators that are not inside a
  /// nested `{...}`.
  static List<String> _splitForms(String body) {
    final parts = <String>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i < body.length; i++) {
      final c = body.codeUnitAt(i);
      if (c == _openBrace) {
        depth++;
      } else if (c == _closeBrace) {
        if (depth > 0) {
          depth--;
        }
      } else if (c == _pipe && depth == 0) {
        parts.add(body.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(body.substring(start));
    return parts;
  }

  /// Replaces the `#` signs of [form] that are not inside a nested `{...}`
  /// (those belong to a nested directive) with [shown].
  static String _substituteCount(String form, String shown) {
    if (!form.contains('#')) {
      return form;
    }
    final sb = StringBuffer();
    var depth = 0;
    for (var i = 0; i < form.length; i++) {
      final c = form.codeUnitAt(i);
      if (c == _openBrace) {
        depth++;
      } else if (c == _closeBrace) {
        if (depth > 0) {
          depth--;
        }
      }
      if (c == _hash && depth == 0) {
        sb.write(shown);
      } else {
        sb.writeCharCode(c);
      }
    }
    return sb.toString();
  }

  /// Picks the form of [parts] (`key=text` entries after the variable name)
  /// whose key is [wanted], falling back to the `other` form.
  static String _pickForm(List<String> parts, String wanted) {
    String? otherFallback;
    for (var i = 1; i < parts.length; i++) {
      final eq = parts[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final k = parts[i].substring(0, eq).trim().toLowerCase();
      final v = parts[i].substring(eq + 1);
      if (k == wanted) {
        return v;
      }
      if (k == 'other') {
        otherFallback = v;
      }
    }
    return otherFallback ?? '';
  }

  String _evalPlural(
    String body,
    Map<String, Object?> params,
    String? localeCode,
  ) {
    final parts = _splitForms(body);
    final rawVal = params[parts[0].trim()];
    final num number;
    if (rawVal is num) {
      number = rawVal;
    } else {
      number = num.tryParse(rawVal?.toString().trim() ?? '') ?? 0;
    }

    final PluralCategory cat;
    final String shown;
    // Whole numbers that a double represents exactly, in either form.
    if (number is int ||
        (number.abs() < 9007199254740992.0 &&
            number == number.roundToDouble())) {
      final count = number.toInt();
      cat = resolvePluralCategory(count, localeCode);
      shown = count.toString();
    } else {
      cat = _resolveFractionCategory(number.toDouble(), localeCode);
      shown = number.toString();
    }

    final chosen = _substituteCount(_pickForm(parts, cat.name), shown);
    return formatTemplate(chosen, params, localeCode: localeCode);
  }

  String _evalGender(
    String body,
    Map<String, Object?> params,
    String? localeCode,
  ) {
    final parts = _splitForms(body);
    final genderVal = (params[parts[0].trim()]?.toString() ?? 'other')
        .toLowerCase();
    return formatTemplate(
      _pickForm(parts, genderVal),
      params,
      localeCode: localeCode,
    );
  }
}
