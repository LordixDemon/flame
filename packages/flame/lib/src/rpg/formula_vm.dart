import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/math/seeded_rng.dart';
import 'package:flame/src/rpg/attribute_set.dart';

enum _FormulaOp(this.code) {
  pushConst(0),
  loadAttackerStat(1),
  loadDefenderStat(2),
  loadWorldVar(3),
  loadContextVar(4),
  neg(5),
  not(6),
  add(7),
  sub(8),
  mul(9),
  div(10),
  mod(11),
  lt(12),
  le(13),
  gt(14),
  ge(15),
  eq(16),
  ne(17),
  and(18),
  or(19),
  fnAbs(20),
  fnFloor(21),
  fnCeil(22),
  fnRound(23),
  fnSqrt(24),
  fnMin(25),
  fnMax(26),
  fnPow(27),
  fnClamp(28),
  fnLerp(29),
  fnIf(30);

  final int code;
}

enum _TokKind() {
  number,
  ident,
  lParen,
  rParen,
  comma,
  op,
}

class _Token(this.kind, this.lexeme, [this.numValue = 0.0]) {
  final _TokKind kind;
  final String lexeme;
  final double numValue;
}

/// Pre-compiled, immutable RPN bytecode program produced by [FormulaVM.compile]
/// for zero-allocation combat damage, healing, hit-chance, and AI utility
/// scoring.
class CompiledFormula._({
  required this.source,
  required this._opcodes,
  required this._operands,
  required this._constants,
  required this._symbols,
}) {
  /// Original human-readable formula string.
  final String source;

  final Int32List _opcodes;
  final Int32List _operands;
  final Float64List _constants;
  final List<String> _symbols;

  /// Number of bytecode instructions in this compiled formula.
  int get instructionCount => _opcodes.length;
}

/// AOT-safe mathematical & RPG combat expression compiler and zero-allocation
/// stack machine.
///
/// Supported syntax:
/// - Scoped attributes: `a.atk`, `b.def` (`attacker` / `defender`
///   [AttributeSet]s)
/// - World variables: `v[10]` or `v.10`
/// - Context bindings: `level`, `power`, `combo`, etc.
/// - Operators: unary `-`, `!`, binary `* / %`, `+ -`, `< <= > >=`, `== !=`,
///   `&&`, `||`
/// - Functions: `abs`, `floor`, `ceil`, `round`, `sqrt`, `min`, `max`, `pow`,
///   `clamp`, `lerp`, `if(cond, thenExpr, elseExpr)`
/// - Safe division/modulo by zero (`0.0`) and `NaN`/`Infinity` clamping.
class FormulaVM({int stackCapacity = 64}) {
  Float64List _stack = Float64List(math.max(16, stackCapacity));

  /// Compiles [expression] into a reusable [CompiledFormula], throwing
  /// [FormatException] on syntax or arity errors.
  static CompiledFormula compile(String expression) {
    final tokens = _tokenize(expression);
    if (tokens.isEmpty) {
      throw const FormatException('Formula expression cannot be empty.');
    }

    final opcodes = <int>[];
    final operands = <int>[];
    final constants = <double>[];
    final symbols = <String>[];
    final symbolIndex = <String, int>{};

    int internSymbol(String s) => symbolIndex.putIfAbsent(s, () {
      symbols.add(s);
      return symbols.length - 1;
    });

    void emit(_FormulaOp op, [int operand = 0]) {
      opcodes.add(op.code);
      operands.add(operand);
    }

    var cursor = 0;

    _Token? peek() => cursor < tokens.length ? tokens[cursor] : null;
    _Token consume() => tokens[cursor++];

    void parseExpr(int minPrec) {
      final tok = peek();
      if (tok == null) {
        throw FormatException(
          'Unexpected end of formula in "$expression".',
        );
      }

      if (tok.kind == _TokKind.number) {
        consume();
        final cIdx = constants.length;
        constants.add(tok.numValue);
        emit(_FormulaOp.pushConst, cIdx);
      } else if (tok.kind == _TokKind.op &&
          (tok.lexeme == '-' || tok.lexeme == '+' || tok.lexeme == '!')) {
        consume();
        parseExpr(70);
        if (tok.lexeme == '-') {
          emit(_FormulaOp.neg);
        } else if (tok.lexeme == '!') {
          emit(_FormulaOp.not);
        }
      } else if (tok.kind == _TokKind.lParen) {
        consume();
        parseExpr(0);
        final close = peek();
        if (close == null || close.kind != _TokKind.rParen) {
          throw FormatException('Missing closing ")" in "$expression".');
        }
        consume();
      } else if (tok.kind == _TokKind.ident) {
        consume();
        final ident = tok.lexeme;
        if (peek()?.kind == _TokKind.lParen) {
          consume();
          final fnSpec = _lookupFunction(ident, expression);
          var argCount = 0;
          if (peek()?.kind != _TokKind.rParen) {
            while (true) {
              parseExpr(0);
              argCount++;
              if (peek()?.kind == _TokKind.comma) {
                consume();
              } else {
                break;
              }
            }
          }
          if (peek()?.kind != _TokKind.rParen) {
            throw FormatException(
              'Missing ")" after call to $ident in "$expression".',
            );
          }
          consume();
          if (argCount != fnSpec.arity) {
            throw FormatException(
              'Function "$ident" expects ${fnSpec.arity} arguments, '
              'got $argCount in "$expression".',
            );
          }
          emit(fnSpec.op);
        } else if (ident.startsWith('a.') && ident.length > 2) {
          emit(_FormulaOp.loadAttackerStat, internSymbol(ident.substring(2)));
        } else if (ident.startsWith('b.') && ident.length > 2) {
          emit(_FormulaOp.loadDefenderStat, internSymbol(ident.substring(2)));
        } else if (ident.startsWith('v[') && ident.endsWith(']')) {
          final idStr = ident.substring(2, ident.length - 1);
          final varId = int.tryParse(idStr);
          if (varId == null) {
            throw FormatException('Invalid variable index "$ident".');
          }
          emit(_FormulaOp.loadWorldVar, varId);
        } else if (ident.startsWith('v.') && ident.length > 2) {
          final varId = int.tryParse(ident.substring(2));
          if (varId == null) {
            throw FormatException('Invalid variable index "$ident".');
          }
          emit(_FormulaOp.loadWorldVar, varId);
        } else {
          emit(_FormulaOp.loadContextVar, internSymbol(ident));
        }
      } else {
        throw FormatException(
          'Unexpected token "${tok.lexeme}" in "$expression".',
        );
      }

      while (true) {
        final next = peek();
        if (next == null || next.kind != _TokKind.op) {
          break;
        }
        final bin = _binaryInfo(next.lexeme);
        if (bin == null || bin.prec < minPrec) {
          break;
        }
        consume();
        parseExpr(bin.prec + 1);
        emit(bin.op);
      }
    }

    parseExpr(0);
    if (cursor != tokens.length) {
      throw FormatException(
        'Unexpected trailing token "${tokens[cursor].lexeme}" '
        'in "$expression".',
      );
    }

    return CompiledFormula._(
      source: expression,
      opcodes: Int32List.fromList(opcodes),
      operands: Int32List.fromList(operands),
      constants: Float64List.fromList(constants),
      symbols: List<String>.unmodifiable(symbols),
    );
  }

  /// Evaluates [formula] with zero heap allocations.
  ///
  /// When [variance] `> 0.0` and [rng] is supplied, applies uniform RPG Maker
  /// damage spread in `[1.0 - variance, 1.0 + variance]`.
  double evaluate(
    CompiledFormula formula, {
    AttributeSet? attacker,
    AttributeSet? defender,
    double Function(int varId)? worldVariableLookup,
    Map<String, double>? contextVars,
    double variance = 0.0,
    SeededRng? rng,
    bool isCritical = false,
    double criticalMultiplier = 2.0,
    double? minResult,
    double? maxResult,
  }) {
    final ops = formula._opcodes;
    final args = formula._operands;
    final consts = formula._constants;
    final syms = formula._symbols;

    var sp = 0;
    void push(double v) {
      if (sp >= _stack.length) {
        final grown = Float64List(_stack.length * 2)
          ..setRange(0, _stack.length, _stack);
        _stack = grown;
      }
      _stack[sp++] = (v.isNaN || v.isInfinite) ? 0.0 : v;
    }

    for (var ip = 0; ip < ops.length; ip++) {
      final op = ops[ip];
      final arg = args[ip];
      switch (op) {
        case 0:
          push(consts[arg]);
        case 1:
          push(attacker?.get(syms[arg]) ?? 0.0);
        case 2:
          push(defender?.get(syms[arg]) ?? 0.0);
        case 3:
          push(worldVariableLookup?.call(arg) ?? 0.0);
        case 4:
          push(contextVars?[syms[arg]] ?? 0.0);
        case 5:
          _stack[sp - 1] = -_stack[sp - 1];
        case 6:
          _stack[sp - 1] = _stack[sp - 1] == 0.0 ? 1.0 : 0.0;
        case 7:
          final b = _stack[--sp];
          _stack[sp - 1] = _sanitize(_stack[sp - 1] + b);
        case 8:
          final b = _stack[--sp];
          _stack[sp - 1] = _sanitize(_stack[sp - 1] - b);
        case 9:
          final b = _stack[--sp];
          _stack[sp - 1] = _sanitize(_stack[sp - 1] * b);
        case 10:
          final b = _stack[--sp];
          _stack[sp - 1] = b.abs() <= 1e-12
              ? 0.0
              : _sanitize(_stack[sp - 1] / b);
        case 11:
          final b = _stack[--sp];
          _stack[sp - 1] = b.abs() <= 1e-12
              ? 0.0
              : _sanitize(_stack[sp - 1] % b);
        case 12:
          final b = _stack[--sp];
          _stack[sp - 1] = _stack[sp - 1] < b ? 1.0 : 0.0;
        case 13:
          final b = _stack[--sp];
          _stack[sp - 1] = _stack[sp - 1] <= b ? 1.0 : 0.0;
        case 14:
          final b = _stack[--sp];
          _stack[sp - 1] = _stack[sp - 1] > b ? 1.0 : 0.0;
        case 15:
          final b = _stack[--sp];
          _stack[sp - 1] = _stack[sp - 1] >= b ? 1.0 : 0.0;
        case 16:
          final b = _stack[--sp];
          _stack[sp - 1] = (_stack[sp - 1] - b).abs() <= 1e-9 ? 1.0 : 0.0;
        case 17:
          final b = _stack[--sp];
          _stack[sp - 1] = (_stack[sp - 1] - b).abs() > 1e-9 ? 1.0 : 0.0;
        case 18:
          final b = _stack[--sp];
          _stack[sp - 1] = (_stack[sp - 1] != 0.0 && b != 0.0) ? 1.0 : 0.0;
        case 19:
          final b = _stack[--sp];
          _stack[sp - 1] = (_stack[sp - 1] != 0.0 || b != 0.0) ? 1.0 : 0.0;
        case 20:
          _stack[sp - 1] = _stack[sp - 1].abs();
        case 21:
          _stack[sp - 1] = _stack[sp - 1].floorToDouble();
        case 22:
          _stack[sp - 1] = _stack[sp - 1].ceilToDouble();
        case 23:
          _stack[sp - 1] = _stack[sp - 1].roundToDouble();
        case 24:
          final x = _stack[sp - 1];
          _stack[sp - 1] = x <= 0.0 ? 0.0 : _sanitize(math.sqrt(x));
        case 25:
          final b = _stack[--sp];
          _stack[sp - 1] = math.min(_stack[sp - 1], b);
        case 26:
          final b = _stack[--sp];
          _stack[sp - 1] = math.max(_stack[sp - 1], b);
        case 27:
          final b = _stack[--sp];
          _stack[sp - 1] = _sanitize(math.pow(_stack[sp - 1], b).toDouble());
        case 28:
          final hi = _stack[--sp];
          final lo = _stack[--sp];
          final effLo = math.min(lo, hi);
          final effHi = math.max(lo, hi);
          _stack[sp - 1] = _stack[sp - 1].clamp(effLo, effHi);
        case 29:
          final t = _stack[--sp];
          final b = _stack[--sp];
          final a = _stack[sp - 1];
          _stack[sp - 1] = _sanitize(a + (b - a) * t);
        case 30:
          final elseVal = _stack[--sp];
          final thenVal = _stack[--sp];
          final cond = _stack[sp - 1];
          _stack[sp - 1] = cond != 0.0 ? thenVal : elseVal;
      }
    }

    var result = sp > 0 ? _sanitize(_stack[0]) : 0.0;
    if (isCritical) {
      result = _sanitize(result * criticalMultiplier);
    }
    if (variance > 0.0 && rng != null) {
      final v = variance.clamp(0.0, 1.0);
      final factor = 1.0 - v + rng.nextDouble() * (2.0 * v);
      result = _sanitize(result * factor);
    }
    if (minResult != null && result < minResult) {
      result = minResult;
    }
    if (maxResult != null && result > maxResult) {
      result = maxResult;
    }
    return _sanitize(result);
  }

  static double _sanitize(double v) => (v.isNaN || v.isInfinite) ? 0.0 : v;

  static ({_FormulaOp op, int arity}) _lookupFunction(
    String name,
    String fullExpr,
  ) => switch (name) {
    'abs' => (op: _FormulaOp.fnAbs, arity: 1),
    'floor' => (op: _FormulaOp.fnFloor, arity: 1),
    'ceil' => (op: _FormulaOp.fnCeil, arity: 1),
    'round' => (op: _FormulaOp.fnRound, arity: 1),
    'sqrt' => (op: _FormulaOp.fnSqrt, arity: 1),
    'min' => (op: _FormulaOp.fnMin, arity: 2),
    'max' => (op: _FormulaOp.fnMax, arity: 2),
    'pow' => (op: _FormulaOp.fnPow, arity: 2),
    'clamp' => (op: _FormulaOp.fnClamp, arity: 3),
    'lerp' => (op: _FormulaOp.fnLerp, arity: 3),
    'if' => (op: _FormulaOp.fnIf, arity: 3),
    _ => throw FormatException(
      'Unknown formula function "$name" in "$fullExpr".',
    ),
  };

  static ({_FormulaOp op, int prec})? _binaryInfo(String lex) => switch (lex) {
    '||' => (op: _FormulaOp.or, prec: 10),
    '&&' => (op: _FormulaOp.and, prec: 20),
    '==' => (op: _FormulaOp.eq, prec: 30),
    '!=' => (op: _FormulaOp.ne, prec: 30),
    '<' => (op: _FormulaOp.lt, prec: 40),
    '<=' => (op: _FormulaOp.le, prec: 40),
    '>' => (op: _FormulaOp.gt, prec: 40),
    '>=' => (op: _FormulaOp.ge, prec: 40),
    '+' => (op: _FormulaOp.add, prec: 50),
    '-' => (op: _FormulaOp.sub, prec: 50),
    '*' => (op: _FormulaOp.mul, prec: 60),
    '/' => (op: _FormulaOp.div, prec: 60),
    '%' => (op: _FormulaOp.mod, prec: 60),
    _ => null,
  };

  static List<_Token> _tokenize(String src) {
    final out = <_Token>[];
    final len = src.length;
    var i = 0;

    bool isDigit(int c) => c >= 0x30 && c <= 0x39;
    bool isIdentStart(int c) =>
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
    bool isIdentPart(int c) => isIdentStart(c) || isDigit(c) || c == 0x2E;

    while (i < len) {
      final ch = src.codeUnitAt(i);
      if (ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D) {
        i++;
        continue;
      }
      if (isDigit(ch) ||
          (ch == 0x2E && i + 1 < len && isDigit(src.codeUnitAt(i + 1)))) {
        final start = i;
        var seenDot = false;
        while (i < len) {
          final c = src.codeUnitAt(i);
          if (isDigit(c)) {
            i++;
          } else if (c == 0x2E && !seenDot) {
            seenDot = true;
            i++;
          } else {
            break;
          }
        }
        final text = src.substring(start, i);
        final parsed = double.tryParse(text);
        if (parsed == null) {
          throw FormatException('Malformed number "$text" in "$src".');
        }
        out.add(_Token(_TokKind.number, text, parsed));
        continue;
      }

      if (isIdentStart(ch)) {
        final start = i;
        i++;
        while (i < len && isIdentPart(src.codeUnitAt(i))) {
          i++;
        }
        if (i < len &&
            src.substring(start, i) == 'v' &&
            src.codeUnitAt(i) == 0x5B) {
          i++;
          while (i < len && src.codeUnitAt(i) != 0x5D) {
            i++;
          }
          if (i >= len || src.codeUnitAt(i) != 0x5D) {
            throw FormatException('Unclosed v[...] in "$src".');
          }
          i++;
        }
        out.add(_Token(_TokKind.ident, src.substring(start, i)));
        continue;
      }

      if (ch == 0x28) {
        out.add(_Token(_TokKind.lParen, '('));
        i++;
        continue;
      }
      if (ch == 0x29) {
        out.add(_Token(_TokKind.rParen, ')'));
        i++;
        continue;
      }
      if (ch == 0x2C) {
        out.add(_Token(_TokKind.comma, ','));
        i++;
        continue;
      }

      if (i + 1 < len) {
        final two = src.substring(i, i + 2);
        if (two == '<=' ||
            two == '>=' ||
            two == '==' ||
            two == '!=' ||
            two == '&&' ||
            two == '||') {
          out.add(_Token(_TokKind.op, two));
          i += 2;
          continue;
        }
      }

      final one = src[i];
      if (one == '+' ||
          one == '-' ||
          one == '*' ||
          one == '/' ||
          one == '%' ||
          one == '<' ||
          one == '>' ||
          one == '!') {
        out.add(_Token(_TokKind.op, one));
        i++;
        continue;
      }

      throw FormatException('Unexpected character "$one" in "$src".');
    }
    return out;
  }
}
