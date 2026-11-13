import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_lock.dart';
import '../pin_code.dart';
import '../run_history.dart';
import '../store.dart';
import 'common.dart';
import 'history_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _lockDelays = {0: 'сразу', 1: 'через 1 мин', 5: 'через 5 мин', 15: 'через 15 мин'};

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([store, RunHistory.instance, PinCode.instance]),
      builder: (context, _) {
        final s = store.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('Настройки')),
          body: ListView(children: [
            const _Header('Безопасность'),
            SwitchListTile(
              secondary: const Icon(Icons.lock_outline),
              title: const Text('Блокировка приложения'),
              subtitle: const Text('Код-пароль и/или отпечаток при открытии'),
              value: s.lockEnabled,
              onChanged: (on) => on ? _enableLock(context) : _disableLock(context),
            ),
            ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: const Text('Код-пароль'),
              subtitle: Text(PinCode.instance.isSet
                  ? 'Задан, ${PinCode.instance.length} цифр'
                  : 'Не задан — нажмите, чтобы придумать'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => PinCode.instance.isSet ? _pinMenu(context) : _setupPin(context),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('Отпечаток / лицо'),
              subtitle: const Text('Разблокировать без ввода кода'),
              value: s.useBiometrics,
              onChanged: (on) => _setBiometrics(context, on),
            ),
            ListTile(
              enabled: s.lockEnabled,
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Блокировать после сворачивания'),
              trailing: DropdownButton<int>(
                value: _lockDelays.containsKey(s.lockAfterMinutes) ? s.lockAfterMinutes : 1,
                underline: const SizedBox.shrink(),
                items: [
                  for (final e in _lockDelays.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: s.lockEnabled
                    ? (v) => store.updateSettings((x) => x.lockAfterMinutes = v ?? 1)
                    : null,
              ),
            ),
            const _Header('История'),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('История запусков'),
              subtitle: Text('${RunHistory.instance.runs.length} из ${RunHistory.maxRuns}, '
                  'до ${RunHistory.maxRowsPerRun} строк каждого результата'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Очистить историю запусков'),
              enabled: RunHistory.instance.runs.isNotEmpty,
              onTap: () async {
                if (await confirm(context, 'Очистить историю?', 'Сохранённые результаты будут удалены.',
                    ok: 'Очистить', danger: true)) {
                  RunHistory.instance.clear();
                }
              },
            ),
            const _Header('О приложении'),
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) => ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('SQL Snap'),
                subtitle: Text(snap.hasData ? 'Версия ${snap.data!.version} (${snap.data!.buildNumber})' : ''),
              ),
            ),
          ]),
        );
      },
    );
  }
}

// ---------- lock settings actions ----------

Future<bool> _createPin(BuildContext context) async {
  final pin = await createPinFlow(context);
  if (pin == null) return false;
  await PinCode.instance.set(pin);
  return true;
}

/// Turns the lock on, making sure there is a working way to unlock first.
Future<void> _enableLock(BuildContext context) async {
  final store = AppStore.instance;
  if (!PinCode.instance.isSet) {
    if (store.settings.useBiometrics) {
      String? error;
      final ok = await authenticateUser(error: (m) => error = m);
      if (!context.mounted) return;
      if (!ok) {
        if (error == null) return; // user cancelled the prompt
        final wantPin = await confirm(
          context,
          'Отпечаток недоступен',
          '$error\n\nМожно защитить приложение кодом-паролем из цифр.',
          ok: 'Задать код',
        );
        if (!wantPin || !context.mounted || !await _createPin(context)) return;
      }
    } else if (!await _createPin(context)) {
      return;
    }
  }
  store.updateSettings((x) => x.lockEnabled = true);
}

Future<void> _disableLock(BuildContext context) async {
  if (PinCode.instance.isSet && !await verifyPinFlow(context)) return;
  AppStore.instance.updateSettings((x) => x.lockEnabled = false);
}

/// Creates the first code; turns the lock on with it.
Future<void> _setupPin(BuildContext context) async {
  if (!await _createPin(context)) return;
  AppStore.instance.updateSettings((x) => x.lockEnabled = true);
  if (context.mounted) toast(context, 'Код-пароль задан, блокировка включена');
}

void _pinMenu(BuildContext context) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Изменить код'),
          onTap: () async {
            Navigator.pop(ctx);
            if (!await verifyPinFlow(context) || !context.mounted) return;
            if (await _createPin(context) && context.mounted) toast(context, 'Код-пароль изменён');
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Удалить код'),
          onTap: () async {
            Navigator.pop(ctx);
            if (!await verifyPinFlow(context)) return;
            await PinCode.instance.remove();
            final store = AppStore.instance;
            // Without a code and without biometrics there is no way to unlock.
            final lockOff = store.settings.lockEnabled && !store.settings.useBiometrics;
            if (lockOff) store.updateSettings((x) => x.lockEnabled = false);
            if (context.mounted) {
              toast(context, lockOff ? 'Код удалён, блокировка выключена' : 'Код удалён');
            }
          },
        ),
      ]),
    ),
  );
}

Future<void> _setBiometrics(BuildContext context, bool on) async {
  final store = AppStore.instance;
  if (on) {
    final ok = await authenticateUser(error: (m) => toast(context, m, error: true));
    if (!ok) return;
  } else if (store.settings.lockEnabled && !PinCode.instance.isSet) {
    toast(context, 'Сначала задайте код-пароль — иначе войти будет нечем', error: true);
    return;
  }
  store.updateSettings((x) => x.useBiometrics = on);
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
