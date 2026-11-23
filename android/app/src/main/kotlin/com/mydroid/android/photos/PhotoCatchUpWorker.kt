package com.mydroid.android.photos

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.WorkManager
import com.mydroid.android.manager
import com.mydroid.android.net.ConnectionService
import java.util.concurrent.TimeUnit

/**
 * Safety net in case the ContentObserver missed something (process was dead, etc.). Runs every ~6 hours,
 * only on an unmetered network with a healthy battery; the observer handles the live case.
 */
class PhotoCatchUpWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val m = applicationContext.manager()
        if (!m.store.isPaired || !m.store.settings.photos) return Result.success()
        if (m.photos.scan() > 0 || !m.photos.queue.isEmpty()) {
            ConnectionService.start(applicationContext)
            m.start()
            m.wakeUp("photo catch-up") // we're on unmetered Wi-Fi here, so one fresh attempt is fair
            m.kickPhotoUpload()
        }
        return Result.success()
    }

    companion object {
        fun schedule(c: Context) {
            val req = PeriodicWorkRequestBuilder<PhotoCatchUpWorker>(6, TimeUnit.HOURS, 1, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).setRequiresBatteryNotLow(true).build())
                .build()
            // UPDATE replaces the old 15-minute request left by earlier builds.
            WorkManager.getInstance(c).enqueueUniquePeriodicWork("photo-catch-up", ExistingPeriodicWorkPolicy.UPDATE, req)
        }

        fun cancel(c: Context) = WorkManager.getInstance(c).cancelUniqueWork("photo-catch-up")
    }
}
