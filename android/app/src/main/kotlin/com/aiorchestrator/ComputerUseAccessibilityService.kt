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
        private const val TARGET_TTL_MS = 180000L
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

        /**
         * Resolve a text field without relying exclusively on FOCUS_INPUT.
         * Samsung Notes and some Compose/WebView editors expose accessibility
         * focus while a cursor is visible but report no input-focused node.
         * Never type into password fields, off-package nodes or an ambiguous
         * selection of multiple editables.
         */
        private fun eligibleEditable(node: AccessibilityNodeInfo?, pkg: String): Boolean =
            node != null && node.packageName?.toString() == pkg &&
                node.isVisibleToUser && node.isEnabled && node.isEditable &&
                !node.isPassword &&
                (node.actionList.any {
                    it.id == AccessibilityNodeInfo.ACTION_SET_TEXT
                })

        private fun resolveEditable(
            root: AccessibilityNodeInfo,
            pkg: String,
        ): AccessibilityNodeInfo? {
            val input = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            if (eligibleEditable(input, pkg)) return input
            val a11y = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
            if (eligibleEditable(a11y, pkg)) return a11y

            // Fallback only if exactly ONE visible editable node exists.
            // Do not guess when e.g. title and note body are both editable.
            val pending = java.util.ArrayDeque<AccessibilityNodeInfo>()
            pending.add(root)
            var found: AccessibilityNodeInfo? = null
            var scanned = 0
            while (pending.isNotEmpty() && scanned < 256) {
                val node = pending.removeFirst()
                scanned++
                if (eligibleEditable(node, pkg)) {
                    if (found != null) return null
                    found = node
                }
                for (i in 0 until node.childCount) {
                    node.getChild(i)?.let { pending.add(it) }
                }
            }
            return if (pending.isEmpty()) found else null
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
                if (text.isEmpty() || text.length > 512) {
                    callback(false, "INVALID_TEXT")
                    return@post
                }
                val editable = resolveEditable(root, selected)
                if (editable == null) {
                    callback(false, "EDITABLE_FIELD_REQUIRED")
                    return@post
                }
                val args = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                }
                val ok = editable.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                if (!ok) {
                    callback(false, "TEXT_ACTION_REJECTED")
                    return@post
                }
                // The accessibility tree may lag behind an accepted action.
                // Verify after a short UI update, without returning note text.
                Handler(Looper.getMainLooper()).postDelayed({
                    val after = service.rootInActiveWindow
                    if (after?.packageName?.toString() != selected) {
                        callback(false, "TEXT_VERIFICATION_UNAVAILABLE")
                        return@postDelayed
                    }
                    val verifiedNode = resolveEditable(after, selected)
                    val verified = verifiedNode?.text?.toString() == text
                    if (verified) {
                        clearTarget()
                        callback(true, "TEXT_VERIFIED")
                    } else {
                        callback(false, "TEXT_NOT_VERIFIED")
                    }
                }, 350L)
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
