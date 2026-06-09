package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.database.Settings

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Application.initializeIfNeeded(context.applicationContext)

        val autoStart = SimpleConfigManager.getAutoStart(context)
        val shouldRestore = autoStart || SimpleConfigManager.getStartedByUser(context)
        if (!shouldRestore || !SimpleConfigManager.hasValidConfig(context)) {
            return
        }
        if (autoStart) {
            SimpleConfigManager.setStartedByUser(true)
        }

        val serviceIntent = Intent(context, Settings.serviceClass()).apply {
            action = BoxService.ACTION_START
        }
        ContextCompat.startForegroundService(context, serviceIntent)
    }
}
