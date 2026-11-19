package com.inbox2.app.notify

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.inbox2.app.engine.EngineModel
import java.util.concurrent.TimeUnit

/**
 * Background mail sync (iOS BGTaskScheduler app-refresh analog). Periodically wakes the
 * shared engine and syncs all accounts; the core's post-sync rule scan emits
 * `new-message`, which the engine's sink turns into a local notification — push-like
 * delivery with no server infra. WorkManager's minimum period is 15 minutes (iOS is
 * also best-effort); the system decides the actual cadence.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val engine = EngineModel.get(applicationContext)
        // The ingest/sync emits `new-message`, which the sink turns into a local
        // notification — push-like delivery with no server content.
        engine.setNewMessageSink { payload -> NotificationHelper.postNewMessage(applicationContext, payload) }
        // Meta webhook relay: a `meta_event` push fetches + verifies + applies one
        // buffered event rather than running a full mailbox sync.
        val metaKey = inputData.getString(KEY_META_EVENT)
        if (metaKey != null) {
            engine.ingestMetaEvent(metaKey)
            return Result.success()
        }
        engine.syncAllAndWait()
        // The MX mirror catches up on the same wake (docs/MX-Sync.md) — mobile has no
        // socket, so pushes and foregrounding are its live signals.
        engine.mxTick()
        afterSync(applicationContext, engine)
        return Result.success()
    }

    // Expedited work (the FCM-push path) runs as a foreground service before API 31,
    // which requires this. A silent, ongoing "Syncing" notification on the existing
    // mail channel; API 31+ ignores it for expedited jobs.
    override suspend fun getForegroundInfo(): androidx.work.ForegroundInfo {
        NotificationHelper.ensureChannel(applicationContext)
        val notification = androidx.core.app.NotificationCompat
            .Builder(applicationContext, NotificationHelper.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Checking for new mail")
            .setOngoing(true)
            .setSilent(true)
            .build()
        return androidx.work.ForegroundInfo(NOW_NOTIFICATION_ID, notification)
    }

    companion object {
        /**
         * Drop any tray notification whose conversation no longer warrants one — gone
         * (deleted/merged), left the inbox (trash/archive/spam), or already read. On
         * Android the launcher badge is driven by active notifications, so this is also
         * how the badge tracks the unread count: read/delete a thread anywhere and, on
         * the next sync or foreground, its notification (and badge contribution) clears.
         * Covers local channels (Rails can't push a removal for them) and is a harmless
         * backstop for MX mail. Reads the local SQLite the engine just refreshed.
         */
        fun reconcileNotifications(context: Context, engine: EngineModel) {
            val onScreen = NotificationHelper.deliveredConversationKeys(context)
            if (onScreen.isEmpty()) return
            val stale = onScreen.filter { key ->
                val c = engine.store.conversation(key)
                c == null || c.status in com.inbox2.app.model.ConvStatusValue.inboxHidden || !c.unread
            }
            NotificationHelper.removeDelivered(context, stale)
        }

        /** Post-sync: reconcile the tray, then move the ongoing card to the newest unread. */
        suspend fun afterSync(context: Context, engine: EngineModel) {
            reconcileNotifications(context, engine)
            NotificationHelper.refreshOngoing(context, engine, NotificationHelper.liveCloud)
            MeetingAlarms.reconcile(context, engine)
        }

        private const val NAME = "inbox2-sync"
        private const val NOW_NAME = "inbox2-sync-now"
        private const val NOW_NOTIFICATION_ID = 9_001
        private const val KEY_META_EVENT = "meta_event_key"

        fun schedule(context: Context) {
            val req = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, req)
        }

        /** Immediate one-shot sync — an FCM channel_sync push lands here. Expedited
         *  so it runs while the push's wake window is open; a full sync doesn't fit
         *  onMessageReceived's ~10s execution budget. */
        fun syncNow(context: Context) {
            val req = OneTimeWorkRequestBuilder<SyncWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork(NOW_NAME, ExistingWorkPolicy.REPLACE, req)
        }

        /** Ingest one buffered Meta webhook event — an FCM `meta_event` push lands
         *  here with the relay buffer key. Expedited so it runs in the push window. */
        fun ingestMetaEvent(context: Context, eventKey: String) {
            val req = OneTimeWorkRequestBuilder<SyncWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setInputData(androidx.work.workDataOf(KEY_META_EVENT to eventKey))
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork("inbox2-meta-$eventKey", ExistingWorkPolicy.KEEP, req)
        }
    }
}
