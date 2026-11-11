package org.materialkompass.materialkompass_authenticator

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var pushChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pushChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.materialkompass.authenticator/push",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "configure" -> {
                        val accounts = call.argument<String>("accounts") ?: "[]"
                        SecureStore(applicationContext).put(accounts)
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 31)
                        }
                        val serviceIntent = Intent(this, PushPollingService::class.java)
                        if (accounts == "[]") stopService(serviceIntent) else startForegroundService(serviceIntent)
                        result.success(null)
                    }
                    "consumeLaunchApproval" -> result.success(consumeLaunchApproval())
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val approvalId = consumeLaunchApproval() ?: return
        pushChannel?.invokeMethod("openApproval", mapOf("approvalId" to approvalId))
    }

    override fun onResume() {
        super.onResume()
        isVisible = true
    }

    override fun onPause() {
        isVisible = false
        super.onPause()
    }

    private fun consumeLaunchApproval(): String? {
        val approvalId = intent?.getStringExtra(EXTRA_APPROVAL_ID)?.takeIf { it.isNotBlank() }
        intent?.removeExtra(EXTRA_APPROVAL_ID)
        return approvalId
    }

    companion object {
        const val EXTRA_APPROVAL_ID = "approvalId"

        @Volatile
        var isVisible = false
    }
}
