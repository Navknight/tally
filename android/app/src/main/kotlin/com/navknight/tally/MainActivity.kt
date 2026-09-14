package com.navknight.tally

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Telephony
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var smsResult: MethodChannel.Result? = null
    private var fileResult: MethodChannel.Result? = null
    private var saveResult: MethodChannel.Result? = null
    private var pendingSaveBytes: ByteArray? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.navknight.tally/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "requestSmsPermission" -> if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED) result.success(true) else { smsResult = result; ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECEIVE_SMS, Manifest.permission.READ_SMS), 41) }
                "takePendingSms" -> { val p = getSharedPreferences("tally_sms", MODE_PRIVATE); val raw = p.getString("pending", "") ?: ""; p.edit().remove("pending").apply(); result.success(decodeMessages(raw)) }
                "readHistoricSms" -> result.success(readHistoricSms())
                "pickStatement" -> { fileResult = result; startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"; putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/csv", "text/comma-separated-values", "text/plain", "application/pdf")) }, 42) }
                "saveFile" -> {
                    val name = call.argument<String>("name") ?: "export.csv"
                    val mimeType = call.argument<String>("mimeType") ?: "text/csv"
                    saveResult = result
                    pendingSaveBytes = call.argument<ByteArray>("bytes")
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply { addCategory(Intent.CATEGORY_OPENABLE); type = mimeType; putExtra(Intent.EXTRA_TITLE, name) }, 43)
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun decodeMessages(raw: String): List<Map<String, Any>> = raw.split("\u0000").filter { it.isNotBlank() }.mapNotNull { row ->
        val fields = row.split("\u0001", limit = 3)
        if (fields.size == 3) mapOf("sender" to fields[0], "timestamp" to (fields[1].toLongOrNull() ?: 0L), "body" to fields[2]) else null
    }
    private fun readHistoricSms(): List<Map<String, Any>> {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED) return emptyList()
        val messages = ArrayList<Map<String, Any>>()
        contentResolver.query(Telephony.Sms.Inbox.CONTENT_URI, arrayOf(Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE), null, null, "date DESC LIMIT 5000")?.use { cursor ->
            val senderIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE)
            while (cursor.moveToNext()) messages.add(mapOf("sender" to (cursor.getString(senderIndex) ?: ""), "body" to (cursor.getString(bodyIndex) ?: ""), "timestamp" to cursor.getLong(dateIndex)))
        }
        return messages
    }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) { super.onRequestPermissionsResult(code, permissions, grants); if (code == 41) { smsResult?.success(grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED); smsResult = null } }
    override fun onActivityResult(code: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(code, resultCode, data)
        if (code == 42) {
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            val picked = uri?.let { u ->
                val bytes = contentResolver.openInputStream(u)?.use { it.readBytes() }
                val name = contentResolver.query(u, null, null, null, null)?.use { c ->
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
                } ?: u.lastPathSegment ?: "statement"
                bytes?.let { mapOf("name" to name, "bytes" to it) }
            }
            fileResult?.success(picked)
            fileResult = null
        }
        if (code == 43) {
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            val bytes = pendingSaveBytes
            val saved = if (uri != null && bytes != null) {
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                true
            } else false
            pendingSaveBytes = null
            saveResult?.success(saved)
            saveResult = null
        }
    }
}
