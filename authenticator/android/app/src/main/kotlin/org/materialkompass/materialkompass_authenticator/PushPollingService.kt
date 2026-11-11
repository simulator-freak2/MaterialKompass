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
            val responseCode = connection.responseCode
            if (responseCode != 200) {
                val retrySeconds = if (responseCode == 429) {
                    connection.getHeaderField("Retry-After")?.toLongOrNull()?.coerceIn(1, 300) ?: 30
                } else {
                    5
                }
                Thread.sleep(retrySeconds * 1_000)
                return
            }
            val response = BufferedReader(connection.inputStream.reader()).use { it.readText() }
            val approval = JSONObject(response)
            val id = approval.getString("approvalId")
            if (notified.add(id) && !MainActivity.isVisible) showApproval(account, approval)
            if (notified.size > 100) notified.clear()
            Thread.sleep(5_000)
        } finally {
            connection.disconnect()
        }
    }

    private fun showApproval(account: JSONObject, approval: JSONObject) {
        val approvalId = approval.getString("approvalId")
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_APPROVAL_ID, approvalId)
        } ?: return
        val pendingIntent = PendingIntent.getActivity(
            this,
            approvalId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val publicNotification = NotificationCompat.Builder(this, CHANNEL_APPROVALS)
            .setSmallIcon(R.drawable.ic_stat_mk_auth)
            .setContentTitle("Neue Anmeldeanfrage")
            .setContentText("Öffne den Authenticator, um sie zu prüfen.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()
        val notification = NotificationCompat.Builder(this, CHANNEL_APPROVALS)
            .setSmallIcon(R.drawable.ic_stat_mk_auth)
            .setContentTitle("Anmeldung für ${account.optString("account", "MaterialKompass")}")
            .setContentText("Öffnen, Gerät und Herkunft prüfen und entscheiden")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicNotification)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        getSystemService(NotificationManager::class.java)
            .notify(approvalId.hashCode(), notification)
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
        ).apply {
            description = "Sicherheitsabfragen für MaterialKompass-Anmeldungen"
            lockscreenVisibility = NotificationCompat.VISIBILITY_PRIVATE
            enableVibration(true)
        })
    }

    companion object {
        private const val CHANNEL_SERVICE = "secure_connection"
        private const val CHANNEL_APPROVALS = "login_approvals_v2"
    }
}
