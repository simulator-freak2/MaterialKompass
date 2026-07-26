package org.materialkompass.materialkompass

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Parcel
import android.os.ResultReceiver
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "materialkompass/label_printer"
    private val printConnectPackage = "com.zebra.printconnect"
    private val passthroughService = "com.zebra.printconnect.print.PassthroughService"
    private val passthroughData = "com.zebra.printconnect.PrintService.PASSTHROUGH_DATA"
    private val resultReceiver = "com.zebra.printconnect.PrintService.RESULT_RECEIVER"
    private val errorMessage = "com.zebra.printconnect.PrintService.ERROR_MESSAGE"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPrintConnectInstalled" -> result.success(isPrintConnectInstalled())
                    "sendPrintConnect" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null || bytes.isEmpty()) {
                            result.error("invalid_arguments", "Druckdaten fehlen.", null)
                        } else {
                            sendToPrintConnect(bytes, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isPrintConnectInstalled(): Boolean =
        try {
            packageManager.getApplicationInfo(printConnectPackage, 0)
            true
        } catch (_: Exception) {
            false
        }

    private fun ipcSafeReceiver(receiver: ResultReceiver): ResultReceiver {
        val parcel = Parcel.obtain()
        return try {
            receiver.writeToParcel(parcel, 0)
            parcel.setDataPosition(0)
            ResultReceiver.CREATOR.createFromParcel(parcel)
        } finally {
            parcel.recycle()
        }
    }

    private fun sendToPrintConnect(bytes: ByteArray, channelResult: MethodChannel.Result) {
        if (!isPrintConnectInstalled()) {
            channelResult.error(
                "printconnect_missing",
                "Zebra PrintConnect ist auf diesem Android-Gerät nicht installiert.",
                null,
            )
            return
        }

        val handler = Handler(Looper.getMainLooper())
        var completed = false
        val receiver = object : ResultReceiver(handler) {
            override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                if (completed) return
                completed = true
                if (resultCode == 0) {
                    channelResult.success(null)
                } else {
                    channelResult.error(
                        "print_failed",
                        resultData?.getString(errorMessage)
                            ?: "Zebra PrintConnect konnte den Auftrag nicht drucken.",
                        resultCode,
                    )
                }
            }
        }
        val intent = Intent().apply {
            component = ComponentName(printConnectPackage, passthroughService)
            putExtra(passthroughData, bytes)
            putExtra(resultReceiver, ipcSafeReceiver(receiver))
        }
        try {
            if (startService(intent) == null) {
                completed = true
                channelResult.error(
                    "printconnect_unavailable",
                    "Der Zebra-PrintConnect-Dienst ist nicht verfügbar.",
                    null,
                )
                return
            }
            handler.postDelayed({
                if (!completed) {
                    completed = true
                    channelResult.error(
                        "print_timeout",
                        "Zebra PrintConnect hat nicht innerhalb von 15 Sekunden geantwortet.",
                        null,
                    )
                }
            }, 15_000)
        } catch (error: Exception) {
            completed = true
            channelResult.error("print_failed", error.message, null)
        }
    }
}
