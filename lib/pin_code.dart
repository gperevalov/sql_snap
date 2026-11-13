import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App's own numeric passcode. Only a salted, iterated SHA-256 hash is kept,
/// in Android's encrypted storage — the code itself is never saved.
class PinCode extends ChangeNotifier {
  PinCode._();
  static final PinCode instance = PinCode._();

  static const minLength = 4;
  static const maxLength = 8;

  static const _storageKey = 'app_pin';
  static const _iterations = 20000;

  /// After this many wrong codes in a row, input is paused (30 s, then doubling, up to 15 min).
  static const _freeAttempts = 5;

  final _secure = const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  bool isSet = false;

  /// Length of the saved code, so the lock screen can check it as soon as enough digits are typed.
  int length = 0;

  int _failed = 0;
  DateTime? _pausedUntil;

  Future<void> load() async {
    final stored = await _secure.read(key: _storageKey);
    final parts = stored?.split(':');
    isSet = parts != null && parts.length == 3;
    length = isSet ? int.tryParse(parts![2]) ?? 0 : 0;
  }

  Future<void> set(String pin) async {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    await _secure.write(
      key: _storageKey,
      value: '${base64Encode(salt)}:${base64Encode(_hash(pin, salt))}:${pin.length}',
    );
    isSet = true;
    length = pin.length;
    _failed = 0;
    _pausedUntil = null;
    notifyListeners();
  }

  Future<void> remove() async {
    await _secure.delete(key: _storageKey);
    isSet = false;
    length = 0;
    notifyListeners();
  }

  /// Seconds left before the next attempt is allowed, or 0.
  int get secondsPaused {
    final until = _pausedUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inSeconds;
    return left > 0 ? left + 1 : 0;
  }

  /// Returns null if the code is right, otherwise a message for the user.
  Future<String?> check(String pin) async {
    if (secondsPaused > 0) return 'Слишком много попыток. Подождите $secondsPaused с';
    final parts = (await _secure.read(key: _storageKey))?.split(':');
    if (parts == null || parts.length != 3) return 'Код-пароль не задан';
    final ok = _equal(_hash(pin, base64Decode(parts[0])), base64Decode(parts[1]));
    if (ok) {
      _failed = 0;
      _pausedUntil = null;
      return null;
    }
    _failed++;
    if (_failed >= _freeAttempts) {
      final seconds = min(30 * pow(2, _failed - _freeAttempts).toInt(), 15 * 60);
      _pausedUntil = DateTime.now().add(Duration(seconds: seconds));
      return 'Неверный код. Следующая попытка через $seconds с';
    }
    return 'Неверный код';
  }

  static List<int> _hash(String pin, List<int> salt) {
    var h = sha256.convert([...salt, ...utf8.encode(pin)]).bytes;
    for (var i = 1; i < _iterations; i++) {
      h = sha256.convert([...h, ...salt]).bytes;
    }
    return h;
  }

  /// Constant-time comparison.
  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Dots + big numeric keypad.
/// With [length] set, the code is submitted automatically when that many digits are typed;
/// otherwise there is a «Готово» key (for choosing a new code of 4–8 digits).
class PinPad extends StatefulWidget {
  final String title;
  final String? subtitle;
  final int? length;

  /// Returns null when the code is accepted, or an error to show (input is cleared).
  final Future<String?> Function(String pin) onSubmit;

  /// Shown in the bottom-left key, e.g. a fingerprint button.
  final Widget? extraKey;

  const PinPad({
    super.key,
    required this.title,
    this.subtitle,
    this.length,
    required this.onSubmit,
    this.extraKey,
  });

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  String? _error;
  bool _busy = false;

  int get _maxDigits => widget.length ?? PinCode.maxLength;

  void _press(String d) {
    if (_busy || _pin.length >= _maxDigits) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
    if (widget.length != null && _pin.length == widget.length) _submit();
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_pin.length < PinCode.minLength) {
      setState(() => _error = 'Минимум ${PinCode.minLength} цифры');
      return;
    }
    setState(() => _busy = true);
    final error = await widget.onSubmit(_pin);
    if (!mounted) return;
    if (error != null) HapticFeedback.heavyImpact();
    setState(() {
      _busy = false;
      _error = error;
      if (error != null) _pin = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dots = widget.length ?? max(_pin.length, PinCode.minLength);

    const keySize = 76.0;
    const emptyKey = SizedBox(width: keySize, height: keySize);
    // A disabled key stays visible (dimmed) so the user knows it exists.
    Widget key(Widget child, VoidCallback? onTap) => SizedBox(
          width: keySize,
          height: keySize,
          child: Opacity(
            opacity: onTap == null ? 0.35 : 1,
            child: Material(
              color: cs.surfaceContainerHighest,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(onTap: onTap, child: Center(child: child)),
            ),
          ),
        );
    Widget digit(String d) => key(Text(d, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500)), () => _press(d));

    final Widget lastLeft = widget.length == null
        ? key(const Icon(Icons.check), _pin.length >= PinCode.minLength ? _submit : null)
        : (widget.extraKey == null
            ? emptyKey
            : SizedBox(width: keySize, height: keySize, child: Center(child: widget.extraKey)));

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(widget.title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
      if (widget.subtitle != null) ...[
        const SizedBox(height: 6),
        Text(widget.subtitle!, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
      ],
      const SizedBox(height: 20),
      Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < dots; i++)
          Container(
            width: 14,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < _pin.length ? cs.primary : null,
              border: Border.all(color: cs.primary, width: 1.5),
            ),
          ),
      ]),
      SizedBox(
        height: 40,
        child: Center(
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_error ?? '', style: TextStyle(color: cs.error), textAlign: TextAlign.center),
        ),
      ),
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final d in row) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: digit(d)),
          ]),
        ),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: lastLeft),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: digit('0')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _pin.isEmpty ? emptyKey : key(const Icon(Icons.backspace_outlined), _backspace),
        ),
      ]),
    ]);
  }
}

/// Full-screen page around a [PinPad].
class _PinPage extends StatelessWidget {
  final String title;
  final Widget pad;
  const _PinPage({required this.title, required this.pad});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(child: Center(child: SingleChildScrollView(child: pad))),
      );
}

/// Asks for a new code twice. Returns it, or null if the user went back.
Future<String?> createPinFlow(BuildContext context) async {
  final first = await Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (ctx) => _PinPage(
        title: 'Новый код-пароль',
        pad: PinPad(
          title: 'Придумайте код',
          subtitle: 'От ${PinCode.minLength} до ${PinCode.maxLength} цифр',
          onSubmit: (pin) async {
            Navigator.pop(ctx, pin);
            return null;
          },
        ),
      ),
    ),
  );
  if (first == null || !context.mounted) return null;
  return Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (ctx) => _PinPage(
        title: 'Новый код-пароль',
        pad: PinPad(
          title: 'Повторите код',
          length: first.length,
          onSubmit: (pin) async {
            if (pin != first) return 'Коды не совпадают, попробуйте ещё раз';
            Navigator.pop(ctx, pin);
            return null;
          },
        ),
      ),
    ),
  );
}

/// Asks for the current code (before changing or removing it). Returns true if it was right.
Future<bool> verifyPinFlow(BuildContext context) async {
  final ok = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (ctx) => _PinPage(
        title: 'Код-пароль',
        pad: PinPad(
          title: 'Введите текущий код',
          length: PinCode.instance.length,
          onSubmit: (pin) async {
            final error = await PinCode.instance.check(pin);
            if (error == null && ctx.mounted) Navigator.pop(ctx, true);
            return error;
          },
        ),
      ),
    ),
  );
  return ok ?? false;
}
