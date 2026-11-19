package com.inbox2.app

import android.app.Activity
import android.app.Application
import android.os.Bundle

/**
 * Is the UI on screen? (iOS `AppActivity.isForeground`, set from `scenePhase`.) Driven
 * by `Application.registerActivityLifecycleCallbacks` — a started-activity count, so
 * configuration changes (stop old → start new) never read as "backgrounded". Gates
 * cold on-device model loads: a WorkManager sync can drive the core's triage worker
 * into `BridgeLLM.generate` with no UI up, and loading ~1 GB there is the OOM-kill
 * condition (see `LiteRtEngine.engineFor`).
 */
object AppActivity : Application.ActivityLifecycleCallbacks {
    @Volatile var isForeground: Boolean = false
        private set
    private var started = 0

    fun install(app: Application) = app.registerActivityLifecycleCallbacks(this)

    override fun onActivityStarted(activity: Activity) { started += 1; isForeground = true }
    override fun onActivityStopped(activity: Activity) { started = (started - 1).coerceAtLeast(0); isForeground = started > 0 }
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityResumed(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}
}
