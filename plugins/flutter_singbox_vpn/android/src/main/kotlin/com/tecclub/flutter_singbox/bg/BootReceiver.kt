package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.tecclub.flutter_singbox.config.SimpleConfigManager

class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.d(TAG, "Received boot/update intent: ${intent.action}")
                
                try {
                    // Check if we should auto-start the VPN
                    // Use context-based method since Application may not be initialized yet
                    val autoStart = SimpleConfigManager.getAutoStart(context.applicationContext)
                    if (autoStart) {
                        Log.d(TAG, "Auto-starting VPN service")
                        // Initialize Application context if needed
                        com.tecclub.flutter_singbox.Application.initializeIfNeeded(context.applicationContext)
                        SimpleConfigManager.setStartedByUser(true)
                        BoxService.start()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error in BootReceiver", e)
                }
            }
        }
    }
}
