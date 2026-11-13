package tech.mpspace.sqlsnap

import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth for the biometric prompt.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sqlsnap/shortcuts")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pin" -> {
                        val id = call.argument<String>("id")
                        val label = call.argument<String>("label")
                        if (id == null || label == null) {
                            result.error("args", "id and label are required", null)
                        } else {
                            result.success(pinShortcut(id, label))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Asks the launcher to pin a home-screen shortcut that opens the app with [action]. */
    private fun pinShortcut(action: String, label: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = getSystemService(ShortcutManager::class.java) ?: return false
        if (!manager.isRequestPinShortcutSupported) return false
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?.setAction(Intent.ACTION_RUN)
            ?.putExtra(QUICK_ACTION_EXTRA, action)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            ?: return false
        val info = ShortcutInfo.Builder(this, "pin_$action")
            .setShortLabel(label.take(25))
            .setLongLabel(label)
            .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
            .setIntent(intent)
            .build()
        return manager.requestPinShortcut(info, null)
    }

    companion object {
        // The extra the quick_actions plugin reads on launch, so pinned shortcuts reuse its handling.
        private const val QUICK_ACTION_EXTRA = "some unique action key"
    }
}
