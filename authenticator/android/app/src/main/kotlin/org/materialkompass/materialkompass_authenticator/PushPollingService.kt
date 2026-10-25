package org.materialkompass.materialkompass_authenticator

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class PushPollingService : Service() {
    private val running = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor()
    private val notified = mutableSetOf<String>()

    override fun onCreate() {
        super.onCreate()
        createChannels()
        startForeground(1, NotificationCompat.Builder(this, CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_mk_auth)
            .setContentTitle("MaterialKompass Authenticator")
            .setContentText("Wartet sicher auf Anmeldeanfragen")
            .setOngoing(true)
            .setSilent(true)
            .build())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (running.compareAndSet(false, true)) executor.execute(::pollLoop)
        return START_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun pollLoop() {
        while (running.get()) {
            val raw = SecureStore(this).get()
            if (raw.isNullOrBlank() || raw == "[]") {
                stopSelf()
                return
            }
            try {
                val accounts = JSONArray(raw)
                for (index in 0 until accounts.length()) {
                    if (!running.get()) return
                    pollAccount(accounts.getJSONObject(index))
                }
            } catch (_: Exception) {
                Thread.sleep(5_000)
            }
        }
    }

    private fun pollAccount(account: JSONObject) {
        val server = account.getString("serverUrl").trimEnd('/')
        if (!server.startsWith("https://")) return
        val request = JSONObject()
            .put("deviceId", account.getString("deviceId"))
            .put("deviceSecret", account.getString("deviceSecret"))
        val connection = URL("$server/api/auth/mfa/push/pending").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 10_000
            connection.readTimeout = 35_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(request.toString().toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode != 200) return
            val response = BufferedReader(connection.inputStream.reader()).use { it.readText() }
            val approval = JSONObject(response)
            val id = approval.getString("approvalId")
            if (notified.add(id)) showApproval(account, approval)
            if (notified.size > 100) notified.clear()
        } finally {
            connection.disconnect()
        }
    }

    private fun showApproval(account: JSONObject, approval: JSONObject) {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        } ?: return
        val pendingIntent = PendingIntent.getActivity(
            this,
            approval.getString("approvalId").hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_APPROVALS)
            .setSmallIcon(R.drawable.ic_stat_mk_auth)
            .setContentTitle("Anmeldung für ${account.optString("account", "MaterialKompass")}")
            .setContentText("Öffnen, Code vergleichen und sicher freigeben")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        getSystemService(NotificationManager::class.java)
            .notify(approval.getString("approvalId").hashCode(), notification)
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL_SERVICE,
            "Sichere Verbindung",
            NotificationManager.IMPORTANCE_LOW,
        ))
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL_APPROVALS,
            "Anmeldeanfragen",
            NotificationManager.IMPORTANCE_HIGH,
        ))
    }

    companion object {
        private const val CHANNEL_SERVICE = "secure_connection"
        private const val CHANNEL_APPROVALS = "login_approvals"
    }
}
