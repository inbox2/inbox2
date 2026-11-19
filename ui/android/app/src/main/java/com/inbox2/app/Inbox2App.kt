package com.inbox2.app

import android.app.Application
import android.content.ComponentCallbacks2
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.AppConfig

/** Process-wide singletons live here (the engine model is created lazily by the UI). */
class Inbox2App : Application() {
    override fun onCreate() {
        super.onCreate()
        // The Server URL override (sign-in › Advanced) must be in place before the
        // engine is constructed with it.
        AppConfig.load(this)
        AppActivity.install(this)
    }

    /**
     * Release the resident on-device LLM under memory pressure or once the UI is
     * hidden, so a suspended process isn't OOM-killed holding the ~1.6 GB-class LiteRT
     * engine (the iOS jetsam condition; see EngineModel.unloadOnDeviceModel). We never
     * force the engine open — only unload if it already exists. `RUNNING_CRITICAL`
     * (15) ≤ `UI_HIDDEN` (20) ≤ the background levels, so one threshold covers
     * "backgrounded" and "foreground under severe pressure" without thrashing on mild
     * foreground trims.
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) {
            EngineModel.peek()?.unloadOnDeviceModel()
        }
    }
}
