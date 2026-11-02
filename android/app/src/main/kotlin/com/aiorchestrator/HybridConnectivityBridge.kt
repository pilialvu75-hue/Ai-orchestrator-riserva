package com.aiorchestrator

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Read-only network capability check for the opt-in HYBRID checkpoint relay.
 *
 * ACCESS_NETWORK_STATE is already declared by the app. This does not register
 * network callbacks, schedule polling, probe endpoints, or send private data.
 * A validated default network is not proof that a particular Cloud API works.
 */
internal object HybridConnectivityBridge {
    private const val CHANNEL = "com.aiorchestrator/hybrid_connectivity"

    fun register(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasValidatedInternet" -> result.success(hasValidatedInternet(context))
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasValidatedInternet(context: Context): Boolean {
        // NET_CAPABILITY_VALIDATED and activeNetwork require Android 6 (API 23).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager ?: return false
            val active = manager.activeNetwork ?: return false
            val capabilities = manager.getNetworkCapabilities(active)
                ?: return false
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        } catch (_: SecurityException) {
            false
        } catch (_: IllegalStateException) {
            false
        }
    }
}
