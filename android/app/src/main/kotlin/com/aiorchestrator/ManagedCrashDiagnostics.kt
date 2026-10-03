package com.aiorchestrator

import android.content.Context

/** One closed diagnostic category, never exception messages, stacks or user data.
 * The existing Android crash handler always retains ownership of termination.
 */
object ManagedCrashDiagnostics {
    private const val PREFS = "managed_crash_diagnostics"
    private var installed = false

    @Synchronized
    fun install(context: Context) {
        if (installed) return
        val previous = Thread.getDefaultUncaughtExceptionHandler() ?: return
        val preferences = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                preferences.edit()
                    .putLong("timestamp_ms", System.currentTimeMillis())
                    .putString("category", classify(error))
                    .commit()
            } catch (_: Exception) {
                // Diagnostics must never replace or prevent the real crash handler.
            } finally {
                previous.uncaughtException(thread, error)
            }
        }
        installed = true
    }

    fun categoryForExit(context: Context, timestampMs: Long): String? {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val recorded = preferences.getLong("timestamp_ms", 0)
        if (recorded <= 0 || kotlin.math.abs(timestampMs - recorded) > 60_000) return null
        return preferences.getString("category", null)
    }

    private fun classify(error: Throwable): String {
        var cause: Throwable? = error
        var security = false
        repeat(8) {
            val current = cause ?: return@repeat
            val name = current.javaClass.name
            when {
                name.endsWith("ForegroundServiceDidNotStartInTimeException") ->
                    return "foreground_start_timeout"
                name.endsWith("ForegroundServiceStartNotAllowedException") ->
                    return "foreground_start_disallowed"
                name.endsWith("CannotPostForegroundServiceNotificationException") ->
                    return "foreground_bad_notification"
            }
            if (current is SecurityException) security = true
            cause = current.cause
        }
        return if (security) "security_exception" else "managed_other"
    }
}
