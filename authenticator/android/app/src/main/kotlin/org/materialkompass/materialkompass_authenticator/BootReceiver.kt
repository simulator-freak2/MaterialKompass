package org.materialkompass.materialkompass_authenticator

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val accounts = SecureStore(context).get()
        if (accounts.isNullOrBlank() || accounts == "[]") return
        val service = Intent(context, PushPollingService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service) else context.startService(service)
    }
}
