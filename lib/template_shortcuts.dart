import 'package:flutter/services.dart';
import 'package:quick_actions/quick_actions.dart';

import 'models.dart';
import 'store.dart';

/// Android shortcuts to templates:
/// - long press on the app icon shows favorite templates (dynamic shortcuts, via quick_actions);
/// - a template can be pinned to the home screen (native code in MainActivity.kt).
/// Both use the same launch extra, so opening is handled in one place ([init]'s callback).
class TemplateShortcuts {
  TemplateShortcuts._();

  static const _prefix = 'tpl:';

  /// Android shows at most 4–5 shortcuts on long press.
  static const _maxDynamic = 4;

  static const _channel = MethodChannel('sqlsnap/shortcuts');
  static const _quickActions = QuickActions();
  static String? _lastSignature;

  /// [onOpen] gets a template id when the app is opened from a shortcut.
  static Future<void> init(void Function(String templateId) onOpen) async {
    await _quickActions.initialize((type) {
      if (type.startsWith(_prefix)) onOpen(type.substring(_prefix.length));
    });
    AppStore.instance.addListener(_syncFavorites);
    _syncFavorites();
  }

  /// Mirrors favorite templates into the long-press menu (only when they actually changed).
  static void _syncFavorites() {
    final favs = AppStore.instance.favoriteTemplates.take(_maxDynamic).toList();
    final signature = favs.map((t) => '${t.id}|${t.name}').join(';');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    _quickActions.setShortcutItems([
      for (final t in favs)
        ShortcutItem(type: '$_prefix${t.id}', localizedTitle: t.name, icon: 'ic_launcher'),
    ]);
  }

  /// Asks the launcher to put a shortcut to [t] on the home screen.
  /// Returns false if the launcher doesn't support pinned shortcuts.
  static Future<bool> pin(QueryTemplate t) async {
    try {
      return await _channel.invokeMethod<bool>('pin', {'id': '$_prefix${t.id}', 'label': t.name}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
