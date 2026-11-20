package com.aiorchestrator

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.os.Bundle

/**
 * Owner-enabled, bounded QA gesture bridge. No autonomous model invocation.
 * Gestures are bound to an external foreground app explicitly selected by the owner.
 * The user must explicitly enable this service in Android accessibility settings.
 */
class ComputerUseAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile private var active: ComputerUseAccessibilityService? = null
        private var targetPackage: String? = null
        private var targetSinceMs: Long = 0L
        private const val TARGET_TTL_MS = 60000L
        private val excludedPackages = setOf(
            "com.android.systemui", "com.android.settings",
            "com.google.android.permissioncontroller",
            "com.android.permissioncontroller",
            "com.google.android.packageinstaller",
            "com.android.packageinstaller",
            "com.google.android.apps.walletnfcrel",
            "com.samsung.android.spay",
        )

        fun isReady(): Boolean = active != null

        fun clearTarget() {
            targetPackage = null
            targetSinceMs = 0L
        }

        fun selectForegroundTarget(callback: (Boolean, String) -> Unit) {
            Handler(Looper.getMainLooper()).post {
                val service = active
                val selected = service?.rootInActiveWindow?.packageName?.toString()
                if (service == null || selected.isNullOrBlank() ||
                    selected == service.packageName || selected in excludedPackages ||
                    selected.startsWith("com.android.") ||
                    selected.startsWith("com.google.android.permission")
                ) {
                    clearTarget()
                    callback(false, "TARGET_NOT_ALLOWED")
                    return@post
                }
                targetPackage = selected
                targetSinceMs = android.os.SystemClock.elapsedRealtime()
                callback(true, selected)
            }
        }

        fun typeInSelectedEditable(text: String, callback: (Boolean, String) -> Unit) {
            Handler(Looper.getMainLooper()).post {
                val service = active
                val selected = targetPackage
                val fresh = android.os.SystemClock.elapsedRealtime() - targetSinceMs <= TARGET_TTL_MS
                val root = service?.rootInActiveWindow
                if (service == null || !fresh || selected.isNullOrEmpty() ||
                    root?.packageName?.toString() != selected) {
                    clearTarget()
                    callback(false, "TARGET_CHANGED_OR_EXPIRED")
                    return@post
                }
                // Never type into password fields or a non-editable target.
                // The owner must first place focus in an ordinary text field.
                val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                if (focused == null || !focused.isEditable || focused.isPassword ||
                    text.isEmpty() || text.length > 512) {
                    clearTarget()
                    callback(false, "EDITABLE_FIELD_REQUIRED")
                    return@post
                }
                clearTarget()
                val args = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                }
                val ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                focused.recycle()
                callback(ok, if (ok) "TEXT_ACTION_SENT" else "TEXT_ACTION_REJECTED")
            }
        }

        fun gestureTarget(
            x: Int, y: Int, endX: Int, endY: Int,
            callback: (Boolean, String) -> Unit,
        ) {
            Handler(Looper.getMainLooper()).post {
                val service = active
                if (service == null) {
                    callback(false, "ACCESSIBILITY_DISABLED")
                    return@post
                }
                val selected = targetPackage
                val fresh = android.os.SystemClock.elapsedRealtime() - targetSinceMs <= TARGET_TTL_MS
                val currentPackage = service.rootInActiveWindow?.packageName?.toString()
                if (!fresh || selected.isNullOrEmpty() || currentPackage != selected) {
                    clearTarget()
                    callback(false, "TARGET_CHANGED_OR_EXPIRED")
                    return@post
                }
                // Every selected target authorizes just ONE gesture. A second
                // action needs a new screenshot/selection and fresh consent.
                clearTarget()
                val metrics = service.resources.displayMetrics
                val valid = x in 0 until metrics.widthPixels &&
                    y in 0 until metrics.heightPixels &&
                    endX in 0 until metrics.widthPixels &&
                    endY in 0 until metrics.heightPixels
                if (!valid) {
                    callback(false, "INVALID_COORDINATES")
                    return@post
                }
                val distance = kotlin.math.hypot(
                    (endX - x).toDouble(), (endY - y).toDouble(),
                )
                if (distance > maxOf(metrics.widthPixels, metrics.heightPixels) * 0.65) {
                    callback(false, "GESTURE_TOO_LONG")
                    return@post
                }
                val path = Path().apply {
                    moveTo(x.toFloat(), y.toFloat())
                    if (endX != x || endY != y) lineTo(endX.toFloat(), endY.toFloat())
                }
                val duration = if (endX == x && endY == y) 80L else 260L
                val gesture = GestureDescription.Builder()
                    .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
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
        clearTarget()
        active = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // No accessibility content, text, password, or account data is collected.
    }

    override fun onInterrupt() {
        // Fail closed on service interrupt.
        if (active === this) active = null
        clearTarget()
    }

    override fun onDestroy() {
        if (active === this) active = null
        super.onDestroy()
    }
}
