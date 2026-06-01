package com.tecclub.flutter_singbox.bg

import android.net.Network
import android.os.Build
import io.nekohasekai.libbox.InterfaceUpdateListener
import com.tecclub.flutter_singbox.Application
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import java.net.NetworkInterface

object DefaultNetworkMonitor {

    var defaultNetwork: Network? = null
    private var listener: InterfaceUpdateListener? = null

    suspend fun start() {
        android.util.Log.d("DefaultNetworkMonitor", "Starting network monitor")
        
        // First, get the active network BEFORE starting the listener
        // This ensures we have a network ready when setListener is called
        defaultNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Application.connectivity.activeNetwork.also {
                android.util.Log.d("DefaultNetworkMonitor", "Pre-start active network: $it")
            }
        } else {
            null
        }
        
        // Now start the listener for future changes
        DefaultNetworkListener.start(this) {
            android.util.Log.d("DefaultNetworkMonitor", "Network changed callback: $it")
            defaultNetwork = it
            checkDefaultInterfaceUpdate(it)
        }
        
        // If we didn't get network above, try to get it from listener
        if (defaultNetwork == null && Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            defaultNetwork = DefaultNetworkListener.get().also {
                android.util.Log.d("DefaultNetworkMonitor", "Got network from listener: $it")
            }
        }
        
        android.util.Log.d("DefaultNetworkMonitor", "Network monitor started, defaultNetwork=$defaultNetwork")
    }

    suspend fun stop() {
        android.util.Log.d("DefaultNetworkMonitor", "Stopping network monitor")
        listener = null
        defaultNetwork = null
        DefaultNetworkListener.stop(this)
    }

    suspend fun require(): Network {
        val network = defaultNetwork
        if (network != null) {
            return network
        }
        return DefaultNetworkListener.get()
    }

    fun setListener(listener: InterfaceUpdateListener?) {
        android.util.Log.d("DefaultNetworkMonitor", "setListener called, listener=${listener != null}, defaultNetwork=$defaultNetwork")
        this.listener = listener
        
        if (listener != null) {
            // When setting listener, call synchronously first to ensure libbox gets the interface immediately
            checkDefaultInterfaceUpdateSync(defaultNetwork, listener)
        }
    }
    
    // Synchronous version for initial setup
    private fun checkDefaultInterfaceUpdateSync(newNetwork: Network?, listener: InterfaceUpdateListener) {
        android.util.Log.d("DefaultNetworkMonitor", "checkDefaultInterfaceUpdateSync: network=$newNetwork")
        
        if (newNetwork != null) {
            val linkProperties = Application.connectivity.getLinkProperties(newNetwork)
            if (linkProperties == null) {
                android.util.Log.w("DefaultNetworkMonitor", "getLinkProperties returned null")
                listener.updateDefaultInterface("", -1, false, false)
                return
            }
            val interfaceName = linkProperties.interfaceName
            android.util.Log.d("DefaultNetworkMonitor", "Interface name: $interfaceName")
            
            for (times in 0 until 10) {
                try {
                    val networkInterface = NetworkInterface.getByName(interfaceName)
                    if (networkInterface == null) {
                        android.util.Log.w("DefaultNetworkMonitor", "NetworkInterface.getByName returned null, attempt $times")
                        Thread.sleep(50)
                        continue
                    }
                    val interfaceIndex = networkInterface.index
                    android.util.Log.d("DefaultNetworkMonitor", "SYNC: Calling updateDefaultInterface($interfaceName, $interfaceIndex)")
                    listener.updateDefaultInterface(interfaceName, interfaceIndex, false, false)
                    android.util.Log.d("DefaultNetworkMonitor", "SYNC: updateDefaultInterface completed successfully")
                    return
                } catch (e: Exception) {
                    android.util.Log.w("DefaultNetworkMonitor", "Error getting interface, attempt $times: ${e.message}")
                    Thread.sleep(50)
                }
            }
            android.util.Log.e("DefaultNetworkMonitor", "SYNC: Failed to get interface after 10 attempts, sending empty")
            listener.updateDefaultInterface("", -1, false, false)
        } else {
            android.util.Log.d("DefaultNetworkMonitor", "SYNC: Network is null, calling updateDefaultInterface with empty values")
            listener.updateDefaultInterface("", -1, false, false)
        }
    }

    private fun checkDefaultInterfaceUpdate(newNetwork: Network?) {
        val listener = listener ?: return
        android.util.Log.d("DefaultNetworkMonitor", "checkDefaultInterfaceUpdate: network=$newNetwork")
        
        if (newNetwork != null) {
            val linkProperties = Application.connectivity.getLinkProperties(newNetwork)
            if (linkProperties == null) {
                android.util.Log.w("DefaultNetworkMonitor", "getLinkProperties returned null")
                return
            }
            val interfaceName = linkProperties.interfaceName
            android.util.Log.d("DefaultNetworkMonitor", "Interface name from LinkProperties: $interfaceName")
            
            for (times in 0 until 10) {
                var interfaceIndex: Int
                try {
                    val networkInterface = NetworkInterface.getByName(interfaceName)
                    if (networkInterface == null) {
                        android.util.Log.w("DefaultNetworkMonitor", "NetworkInterface.getByName returned null, attempt $times")
                        Thread.sleep(100)
                        continue
                    }
                    interfaceIndex = networkInterface.index
                    android.util.Log.d("DefaultNetworkMonitor", "Got interface index: $interfaceIndex for $interfaceName (attempt $times)")
                } catch (e: Exception) {
                    android.util.Log.w("DefaultNetworkMonitor", "Error getting interface, attempt $times: ${e.message}")
                    Thread.sleep(100)
                    continue
                }
                
                // Match official implementation: always use GlobalScope.launch for Android P+
                // and call updateDefaultInterface. Do NOT return early!
                GlobalScope.launch(Dispatchers.IO) {
                    try {
                        android.util.Log.d("DefaultNetworkMonitor", "Calling updateDefaultInterface($interfaceName, $interfaceIndex)")
                        listener.updateDefaultInterface(interfaceName, interfaceIndex, false, false)
                        android.util.Log.d("DefaultNetworkMonitor", "updateDefaultInterface completed")
                    } catch (e: Exception) {
                        android.util.Log.e("DefaultNetworkMonitor", "Error in updateDefaultInterface: ${e.message}", e)
                    }
                }
                // Official code does NOT return here - it loops all 10 times
                // But we should return after successful call to avoid spamming
                return
            }
            android.util.Log.e("DefaultNetworkMonitor", "Failed to get interface after 10 attempts")
        } else {
            android.util.Log.d("DefaultNetworkMonitor", "Network is null, calling updateDefaultInterface with empty values")
            GlobalScope.launch(Dispatchers.IO) {
                try {
                    listener.updateDefaultInterface("", -1, false, false)
                } catch (e: Exception) {
                    android.util.Log.e("DefaultNetworkMonitor", "Error in updateDefaultInterface (null network): ${e.message}", e)
                }
            }
        }
    }
}
