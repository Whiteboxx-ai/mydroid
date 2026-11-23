package com.mydroid.android.find

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import com.mydroid.android.Channels
import com.mydroid.android.Perms
import com.mydroid.android.R

/** `find.ring`: full-volume alarm-stream ringtone (works on silent) until Stop. */
object FindMyPhone {
    private const val NOTIF_ID = 4300
    private var ringtone: Ringtone? = null
    private var savedVolume = -1
    @Volatile var ringing = false
        private set

    @Synchronized
    @SuppressLint("MissingPermission")
    fun start(c: Context) {
        val ctx = c.applicationContext
        if (ringing) return
        ringing = true
        val audio = ctx.getSystemService(AudioManager::class.java)
        savedVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        ringtone = RingtoneManager.getRingtone(ctx, uri)?.apply {
            audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            isLooping = true
            play()
        }
        vibrate(ctx, true)

        val open = Intent(ctx, FindActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val full = PendingIntent.getActivity(ctx, 1, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getBroadcast(ctx, 2, Intent(ctx, StopFindReceiver::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(ctx, Channels.FIND)
            .setSmallIcon(R.drawable.ic_stat_mydroid)
            .setContentTitle("Your Mac is finding this phone")
            .setContentText("Tap Stop to silence")
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setContentIntent(full)
            .setFullScreenIntent(full, true)
            .addAction(0, "Stop", stop)
            .build()
        if (Perms.canPostNotifications(ctx)) ctx.getSystemService(NotificationManager::class.java).notify(NOTIF_ID, n)
        // Also try to show the screen directly (works if the app is foregrounded or has the overlay exemption).
        runCatching { ctx.startActivity(open) }
    }

    @Synchronized
    fun stop(c: Context) {
        val ctx = c.applicationContext
        if (!ringing) return
        ringing = false
        runCatching { ringtone?.stop() }
        ringtone = null
        if (savedVolume >= 0) runCatching { ctx.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0) }
        vibrate(ctx, false)
        ctx.getSystemService(NotificationManager::class.java).cancel(NOTIF_ID)
        ctx.sendBroadcast(Intent(FindActivity.ACTION_FINISH).setPackage(ctx.packageName))
    }

    @Suppress("DEPRECATION")
    private fun vibrate(ctx: Context, on: Boolean) {
        val v: Vibrator = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(VibratorManager::class.java).defaultVibrator
        else ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (on) v.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 600, 400), 0)) else v.cancel()
    }
}

class StopFindReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        FindMyPhone.stop(context)
    }
}
