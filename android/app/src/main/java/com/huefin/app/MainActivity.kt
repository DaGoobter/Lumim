package com.huefin.app

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import com.huefin.app.ui.AppRouter
import com.huefin.app.ui.HuefinRoot
import com.huefin.app.ui.HuefinTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) {
            registerForActivityResult(ActivityResultContracts.RequestPermission()) {}.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        handle(intent)
        setContent { HuefinTheme { HuefinRoot(); com.huefin.app.core.CrashReportDialog() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** Home-screen shortcuts and Google Assistant ("Resume watching", "Watch live TV", "Start Huefin DJ"). */
    private fun handle(intent: Intent?) {
        when (intent?.action) {
            "com.huefin.app.RESUME" -> AppRouter.pending = AppRouter.Action.Resume
            "com.huefin.app.LIVE" -> AppRouter.pending = AppRouter.Action.Live(intent.getStringExtra("channel"))
            "com.huefin.app.DJ" -> AppRouter.pending = AppRouter.Action.DJ
            "com.huefin.app.NOWPLAYING" -> com.huefin.app.playback.AudioPlayer.showNowPlaying = true
        }
    }
}
