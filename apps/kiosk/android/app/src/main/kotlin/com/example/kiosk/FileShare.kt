package com.example.kiosk

import android.app.Activity
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Comparte un archivo generado en la tablet con otras apps (WhatsApp, correo, Drive…). */
class FileShare(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "accesos/compartir")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "share") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val name = call.argument<String>("name")!!
                val bytes = call.argument<ByteArray>("bytes")!!
                val mimeType = call.argument<String>("mimeType")!!
                val title = call.argument<String>("title") ?: "Compartir"
                // Solo se conserva el último archivo compartido.
                val folder = File(activity.cacheDir, "compartidos").apply {
                    deleteRecursively()
                    mkdirs()
                }
                val file = File(folder, File(name).name).apply { writeBytes(bytes) }
                val uri = FileProvider.getUriForFile(
                    activity,
                    "${activity.packageName}.archivos",
                    file,
                )
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = mimeType
                    putExtra(Intent.EXTRA_STREAM, uri)
                    putExtra(Intent.EXTRA_SUBJECT, File(name).nameWithoutExtension)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                activity.startActivity(Intent.createChooser(send, title))
                result.success(null)
            } catch (error: Exception) {
                result.error("share_failed", error.message, null)
            }
        }
    }
}
