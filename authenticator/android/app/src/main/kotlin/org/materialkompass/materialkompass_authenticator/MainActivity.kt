package org.materialkompass.materialkompass_authenticator

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.materialkompass.authenticator/push",
        ).setMethodCallHandler { call, result ->
            if (call.method != "configure") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val accounts = call.argument<String>("accounts") ?: "[]"
            SecureStore(applicationContext).put(accounts)
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 31)
            }
            val intent = Intent(this, PushPollingService::class.java)
            if (accounts == "[]") stopService(intent) else startForegroundService(intent)
            result.success(null)
        }
    }
}
