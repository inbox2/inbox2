package com.inbox2.app.car

import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Template
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.inbox2.app.audio.BargeInListener
import com.inbox2.app.audio.Speaker
import com.inbox2.app.cloud.WeatherService
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.VoicePrefs
import com.inbox2.app.engine.bridgeReplyText
import com.inbox2.app.engine.nluBridgeConfig
import kotlinx.coroutines.launch
import uniffi.inbox2_core.FfiBridgeReply

/**
 * The Bridge car screen: a driving-safe list of the three briefs. Tapping a row reads it
 * aloud through the shared Speaker. CarPlay's counterpart is CarPlaySceneDelegate. A car
 * is a hands-free context, so briefs are always the FULL form (concise = false).
 */
class BridgeCarScreen(carContext: CarContext) : Screen(carContext) {
    // Same process-wide engine the phone UI/SyncWorker use (one writer on inbox2.db).
    private val engine by lazy { EngineModel.get(carContext.applicationContext) }
    private val prefs by lazy { VoicePrefs(carContext) }
    private val speaker by lazy { Speaker(carContext, engine, prefs) }
    // Break-in is mandatory wherever the Bridge speaks: "stop / cancel / ok" halts a brief
    // without a reach for the screen. Armed before each speak (mic before voice), as on the phone.
    private val bargeIn by lazy { BargeInListener(carContext).also { it.onStopWord = { speaker.stop() } } }

    private enum class Brief(val label: String, val detail: String) {
        DAILY("Daily brief", "Your inbox at a glance"),
        TOMORROW("Tomorrow", "Tomorrow's calendar"),
        WEEK("Weekly highlights", "Highlights of the week"),
    }

    init {
        // Preload TTS so the first tap speaks without the init pause.
        lifecycleScope.launch { runCatching { speaker.warmUp() } }
        // The mic closes the moment speech ends, and with the screen.
        lifecycleScope.launch { speaker.speaking.collect { speaking -> if (!speaking) bargeIn.stop() } }
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) { bargeIn.stop() }
        })
    }

    override fun onGetTemplate(): Template {
        val list = ItemList.Builder()
        Brief.entries.forEach { brief ->
            list.addItem(
                Row.Builder()
                    .setTitle(brief.label)
                    .addText(brief.detail)
                    .setOnClickListener { run(brief) }
                    .build()
            )
        }
        return ListTemplate.Builder()
            .setTitle("Bridge")
            .setSingleList(list.build())
            .build()
    }

    private fun run(brief: Brief) {
        CarToast.makeText(carContext, "Reading your ${brief.label.lowercase()}…", CarToast.LENGTH_SHORT).show()
        lifecycleScope.launch {
            speaker.stop(); bargeIn.stop()
            // Mornings still get the weather line on the daily brief.
            val weather = if (brief == Brief.DAILY) WeatherService.morningLine() else null
            val config = nluBridgeConfig(engine, prefs, concise = false, weather = weather)
            val reply: FfiBridgeReply? = when (brief) {
                Brief.DAILY -> engine.bridgeBrief(config)
                Brief.TOMORROW -> engine.bridgeTomorrow(config)
                Brief.WEEK -> engine.bridgeWeekHighlights(config)
            }
            val text = reply?.let { bridgeReplyText(it) }
            if (text.isNullOrBlank()) {
                CarToast.makeText(carContext, "Still starting up. Try again in a moment.", CarToast.LENGTH_LONG).show()
            } else {
                bargeIn.start()
                speaker.speak(text)
            }
        }
    }
}
