package com.inbox2.app.car

import android.content.Intent
import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/**
 * Android Auto entry point — the head-unit counterpart to the phone BridgeScreen. Reuses
 * the SAME process-wide Rust engine (`EngineModel.get`), so briefs read on the car are
 * the same the phone produces. Driven entirely by templates (no custom views), as Auto
 * requires.
 *
 * Distribution note: Google restricts which app categories may ship on Auto. This targets
 * dev/DHU (Desktop Head Unit) testing; production listing needs an approved category +
 * review (see docs/Android-App.md).
 */
class BridgeCarAppService : CarAppService() {
    /** Debug builds trust any host (DHU/emulator); release uses the library's allow-list
     *  of Google-signed hosts so a rogue app can't drive our car surface. */
    override fun createHostValidator(): HostValidator =
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            HostValidator.Builder(applicationContext)
                .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
                .build()
        }

    override fun onCreateSession(): Session = BridgeCarSession()
}

/** One car connection. Hands back the Bridge list screen as the root. */
class BridgeCarSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen = BridgeCarScreen(carContext)
}
