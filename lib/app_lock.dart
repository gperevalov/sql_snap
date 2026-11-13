import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import 'pin_code.dart';
import 'store.dart';

final _auth = LocalAuthentication();

/// Fingerprint / face / device PIN prompt. Returns true on success.
/// [error] receives a human-readable reason when it fails (not on user cancel).
Future<bool> authenticateUser({void Function(String message)? error}) async {
  try {
    if (!await _auth.isDeviceSupported()) {
      error?.call('На телефоне не настроена блокировка экрана (отпечаток, лицо или PIN)');
      return false;
    }
    return await _auth.authenticate(
      localizedReason: 'Разблокируйте SQL Snap',
      biometricOnly: false, // allow device PIN as fallback
      persistAcrossBackgrounding: true,
    );
  } on LocalAuthException catch (e) {
    if (e.code != LocalAuthExceptionCode.userCanceled && e.code != LocalAuthExceptionCode.systemCanceled) {
      error?.call(e.description ?? e.code.name);
    }
    return false;
  } catch (e) {
    error?.call(e.toString());
    return false;
  }
}

/// Covers the whole app with a lock screen when lock is enabled in settings:
/// on start and after the app has been in background for [AppSettings.lockAfterMinutes].
/// Unlocks with the app passcode ([PinCode]) and/or fingerprint / face / phone screen lock.
class AppLock extends StatefulWidget {
  final Widget child;
  const AppLock({super.key, required this.child});

  @override
  State<AppLock> createState() => _AppLockState();
}

class _AppLockState extends State<AppLock> with WidgetsBindingObserver {
  final store = AppStore.instance;
  late bool _locked = _lockConfigured;
  DateTime? _backgroundSince;
  bool _authInProgress = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometrics());
  }

  /// Lock is on and there is at least one way to unlock (never lock the user out).
  bool get _lockConfigured =>
      store.settings.lockEnabled && (PinCode.instance.isSet || store.settings.useBiometrics);

  bool get _biometricsAllowed => store.settings.useBiometrics;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The system prompt itself sends the app to background — ignore that.
    if (_authInProgress) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundSince ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundSince;
      _backgroundSince = null;
      if (!_lockConfigured || _locked || since == null) return;
      if (DateTime.now().difference(since) >= Duration(minutes: store.settings.lockAfterMinutes)) {
        setState(() => _locked = true);
        _tryBiometrics();
      }
    }
  }

  Future<void> _tryBiometrics() async {
    if (!_biometricsAllowed || _authInProgress) return;
    setState(() {
      _authInProgress = true;
      _error = null;
    });
    final ok = await authenticateUser(error: (m) => _error = m);
    if (!mounted) return;
    setState(() {
      _authInProgress = false;
      _backgroundSince = null;
      if (ok) _locked = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      if (_locked)
        Positioned.fill(
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    // No Tooltip widgets here: the lock screen sits above the Navigator (no Overlay).
                    Icon(Icons.lock_outline, size: 40, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 16),
                    if (PinCode.instance.isSet)
                      PinPad(
                        title: 'Введите код',
                        subtitle: _error,
                        length: PinCode.instance.length,
                        onSubmit: (pin) async {
                          final error = await PinCode.instance.check(pin);
                          if (error == null && mounted) setState(() => _locked = false);
                          return error;
                        },
                        extraKey: _biometricsAllowed
                            ? IconButton(
                                iconSize: 36,
                                onPressed: _authInProgress ? null : _tryBiometrics,
                                icon: const Icon(Icons.fingerprint),
                              )
                            : null,
                      )
                    else ...[
                      Text('SQL Snap заблокирован', style: Theme.of(context).textTheme.titleLarge),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _authInProgress ? null : _tryBiometrics,
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('Разблокировать'),
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}
