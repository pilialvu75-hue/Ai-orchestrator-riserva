package com.aiorchestrator

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import androidx.core.content.ContextCompat

/**
 * Transparent, short-lived Activity used only to obtain explicit user consent
 * for MediaProjection. No projection token is cached across sessions.
 */
class ScreenVisionPermissionActivity : Activity() {
    companion object {
        private const val REQUEST_MEDIA_PROJECTION = 5891
    }

    private var consentLaunched = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consentLaunched = savedInstanceState?.getBoolean("consentLaunched") ?: false
        if (!consentLaunched) {
            consentLaunched = true
            val manager =
                getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            startActivityForResult(
                manager.createScreenCaptureIntent(),
                REQUEST_MEDIA_PROJECTION,
            )
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("consentLaunched", consentLaunched)
        super.onSaveInstanceState(outState)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_MEDIA_PROJECTION) return

        if (resultCode != RESULT_OK || data == null) {
            ScreenVisionBridge.completeDenied()
            finish()
            return
        }

        try {
            val startIntent = ScreenVisionForegroundService.startIntent(
                this,
                resultCode,
                data,
            )
            ContextCompat.startForegroundService(this, startIntent)
        } catch (error: Throwable) {
            ScreenVisionBridge.completeStartError(
                error.message ?: "Unable to start Screen Vision foreground service.",
            )
        } finally {
            finish()
        }
    }
}
