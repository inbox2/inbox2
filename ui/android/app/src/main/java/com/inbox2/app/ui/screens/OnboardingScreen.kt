package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.theme.theme

/** Fresh-install onboarding (iOS OnboardingView): connect a mailbox or sign in to the
 *  inbox2 mx team pool. Adding either swaps the shell to the tabs. */
@Composable
fun OnboardingScreen(engine: EngineModel, cloud: com.inbox2.app.cloud.CloudSession, onCloudSignIn: () -> Unit) {
    Box(Modifier.fillMaxSize().background(theme.bgBase)) {
        AddAccountScreen(
            engine, onClose = {},
            title = "Welcome to inbox2", showBack = false,
            onCloudSignIn = onCloudSignIn,
        )
    }
}
