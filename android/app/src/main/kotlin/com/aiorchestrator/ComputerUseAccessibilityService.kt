package com.aiorchestrator

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent

/**
 * Owner-enabled, bounded QA gesture bridge. No autonomous model invocation.
 * Only the already-installed Car Jam Solver test game may receive gestures.
 * The user must explicitly enable this service in Android accessibility settings.
 */
class ComputerUseAccessibilityService : AccessibilityService() {
    companion object {
        private const val GAME_PACKAGE = "car.parking.jam.solver.puzzle.games"
        @Volatile private var active: ComputerUseAccessibilityService? = null

        fun isReady(): Boolean = active != null

        fun tapGame(x: Int, y: Int, callback: (Boolean, String) -> Unit) {
            Handler(Looper.getMainLooper()).post {
                val service = active
                if (service == null) {
                    callback(false, "ACCESSIBILITY_DISABLED")
                    return@post
                }
                val currentPackage = service.rootInActiveWindow?.packageName?.toString()
                if (currentPackage != GAME_PACKAGE) {
                    callback(false, "GAME_NOT_FOREGROUND")
                    return@post
                }
                val metrics = service.resources.displayMetrics
                if (x < 0 || y < 0 || x >= metrics.widthPixels || y >= metrics.heightPixels) {
                    callback(false, "INVALID_COORDINATES")
                    return@post
                }
                val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
                val gesture = GestureDescription.Builder()
                    .addStroke(GestureDescription.StrokeDescription(path, 0, 80))
                    .build()
                val accepted = service.dispatchGesture(
                    gesture,
                    object : GestureResultCallback() {
                        override fun onCompleted(gestureDescription: GestureDescription?) {
                            callback(true, "TAP_COMPLETED")
                        }

                        override fun onCancelled(gestureDescription: GestureDescription?) {
                            callback(false, "GESTURE_CANCELLED")
                        }
                    },
                    Handler(Looper.getMainLooper())
                )
                if (!accepted) callback(false, "GESTURE_REJECTED")
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        active = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // No accessibility content, text, password, or account data is collected.
    }

    override fun onInterrupt() {
        // Fail closed on service interrupt.
        if (active === this) active = null
    }

    override fun onDestroy() {
        if (active === this) active = null
        super.onDestroy()
    }
}
