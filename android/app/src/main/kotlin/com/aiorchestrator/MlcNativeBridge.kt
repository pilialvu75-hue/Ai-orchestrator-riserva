package com.aiorchestrator

object MlcNativeBridge {
    private var loadError: String? = null

    init {
        try {
            System.loadLibrary("mlc_native_bridge")
        } catch (error: UnsatisfiedLinkError) {
            loadError = error.message ?: "Failed to load mlc_native_bridge"
        } catch (error: SecurityException) {
            loadError = error.message ?: "Security policy blocked mlc_native_bridge"
        }
    }

    external fun nativeIsAvailable(): Boolean
    external fun nativeBackendName(): String
    external fun nativeMaxKvCacheBytes(): Long

    fun isAvailable(): Boolean {
        if (loadError != null) return false
        return try {
            nativeIsAvailable()
        } catch (_: Exception) {
            false
        }
    }

    fun backendName(): String {
        if (loadError != null) return "unavailable"
        return try {
            nativeBackendName()
        } catch (_: Exception) {
            "unavailable"
        }
    }

    fun maxKvCacheBytes(): Long {
        if (loadError != null) return 0L
        return try {
            nativeMaxKvCacheBytes()
        } catch (_: Exception) {
            0L
        }
    }

    fun diagnostics(): Map<String, Any?> = mapOf(
        "loaded" to (loadError == null),
        "available" to isAvailable(),
        "backend" to backendName(),
        "maxKvCacheBytes" to maxKvCacheBytes(),
        "loadError" to loadError,
    )
}
