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
  }

  /// Resolves the [PluralCategory] for integer [count] under [localeCode].
  PluralCategory resolvePluralCategory(int count, [String? localeCode]) {
    final n = count.abs();
    final lang = (localeCode ?? _locale)
        .split(RegExp('[-_]'))
        .first
        .toLowerCase();

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

  /// Formats translation [key] using [params] under the active [locale]
  /// (falling back to [fallbackLocale], or returning `key` if missing).
  String tr(
    String key, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    final template =
        _bundles[_locale]?[key] ?? _bundles[fallbackLocale]?[key] ?? key;
    return formatTemplate(template, params, localeCode: _locale);
  }

  /// Formats an arbitrary template string against [params].
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
      final close = template.indexOf('}', open + 1);
      if (close < 0) {
        sb.write(template.substring(open));
        break;
      }

      final expr = template.substring(open + 1, close);
      if (expr.startsWith('plural:')) {
        sb.write(_evalPlural(expr.substring(7), params, localeCode));
      } else if (expr.startsWith('gender:')) {
        sb.write(_evalGender(expr.substring(7), params));
      } else {
        final v = params[expr];
        sb.write(v?.toString() ?? '{$expr}');
      }
      i = close + 1;
    }
    return sb.toString();
  }

  String _evalPlural(
    String body,
    Map<String, Object?> params,
    String? localeCode,
  ) {
    final parts = body.split('|');
    if (parts.isEmpty) {
      return '';
    }
    final varName = parts[0].trim();
    final rawVal = params[varName];
    final count = rawVal is num
        ? rawVal.round()
        : (int.tryParse(rawVal?.toString() ?? '') ?? 0);
    final cat = resolvePluralCategory(count, localeCode);

    String? matched;
    String? otherFallback;
    for (var i = 1; i < parts.length; i++) {
      final eq = parts[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final k = parts[i].substring(0, eq).trim();
      final v = parts[i].substring(eq + 1);
      if (k == cat.name) {
        matched = v;
        break;
      }
      if (k == 'other') {
        otherFallback = v;
      }
    }
    final chosen = matched ?? otherFallback ?? '';
    return chosen.replaceAll('#', count.toString());
  }

  String _evalGender(String body, Map<String, Object?> params) {
    final parts = body.split('|');
    if (parts.isEmpty) {
      return '';
    }
    final varName = parts[0].trim();
    final genderVal = (params[varName]?.toString() ?? 'other').toLowerCase();

    String? matched;
    String? otherFallback;
    for (var i = 1; i < parts.length; i++) {
      final eq = parts[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final k = parts[i].substring(0, eq).trim().toLowerCase();
      final v = parts[i].substring(eq + 1);
      if (k == genderVal) {
        matched = v;
        break;
      }
      if (k == 'other') {
        otherFallback = v;
      }
    }
    return matched ?? otherFallback ?? '';
  }
}
