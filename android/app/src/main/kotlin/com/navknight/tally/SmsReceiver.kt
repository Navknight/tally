package com.navknight.tally

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/** Keeps received messages locally until the UI parses them. */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent).map { "${it.originatingAddress ?: ""}\u0001${it.timestampMillis}\u0001${it.messageBody}" }.filter { it.isNotBlank() }
        if (messages.isEmpty()) return
        val prefs = context.getSharedPreferences("tally_sms", Context.MODE_PRIVATE)
        val current = prefs.getString("pending", "") ?: ""
        prefs.edit().putString("pending", (listOf(current).filter { it.isNotBlank() } + messages).joinToString("\u0000")).apply()
    }
}
