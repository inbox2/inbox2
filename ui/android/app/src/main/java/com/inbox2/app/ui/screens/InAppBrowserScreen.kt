package com.inbox2.app.ui.screens

import android.annotation.SuppressLint
import android.content.Intent
import android.webkit.WebView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.noRippleClickable

/**
 * The in-app browser a tapped email link opens in (iOS InAppBrowser / desktop
 * BrowserChrome): the reader stays inside inbox2 instead of leaving for Chrome. Same
 * toolbar set — back / forward / reload-stop / address (lock + host) / share / open in
 * system / close — with a thin ring-gradient load-progress bar. System back walks the
 * page history first (RootTabs).
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun InAppBrowserScreen(url: String, onClose: () -> Unit) {
    val p = theme
    val ctx = LocalContext.current
    var web by remember { mutableStateOf<WebView?>(null) }
    var current by remember { mutableStateOf(url) }
    var loading by remember { mutableStateOf(true) }
    var progress by remember { mutableFloatStateOf(0f) }
    var canBack by remember { mutableStateOf(false) }
    var canForward by remember { mutableStateOf(false) }
    val host = remember(current) { runCatching { android.net.Uri.parse(current).host }.getOrNull() ?: current }
    val secure = current.startsWith("https://")

    Column(Modifier.fillMaxSize().background(p.bgBase)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Space.s3, vertical = Space.s2),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ToolIcon("chevron.left", enabled = canBack) { web?.goBack() }
            ToolIcon("chevron.right", enabled = canForward) { web?.goForward() }
            ToolIcon(if (loading) "xmark" else "arrow.clockwise") { if (loading) web?.stopLoading() else web?.reload() }
            Spacer(Modifier.width(Space.s1))
            Row(
                Modifier.weight(1f).clip(RoundedCornerShape(Radius.full)).background(p.bgInput)
                    .padding(horizontal = Space.s3, vertical = Space.s2),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(SfIcon.vector(if (secure) "lock.fill" else "lock.open"), null, tint = p.textTertiary, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(Space.s1))
                Text(host, color = p.textPrimary, style = AppFont.sm, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.width(Space.s1))
            ToolIcon("square.and.arrow.up") {
                ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"; putExtra(Intent.EXTRA_TEXT, current)
                }, null))
            }
            ToolIcon("safari") { runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(current))) } }
            ToolIcon("xmark.circle.fill", tint = p.textSecondary) { onClose() }
        }
        Box(Modifier.fillMaxWidth().height(2.dp)) {
            if (loading) Box(
                Modifier.fillMaxWidth(fraction = progress.coerceIn(0.04f, 1f)).height(2.dp)
                    .background(p.ringGradient)
            )
        }
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { c ->
                WebView(c).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.loadWithOverviewMode = true
                    settings.useWideViewPort = true
                    settings.builtInZoomControls = true
                    settings.displayZoomControls = false
                    webViewClient = object : android.webkit.WebViewClient() {
                        override fun onPageStarted(view: WebView, u: String?, favicon: android.graphics.Bitmap?) {
                            u?.let { current = it }; loading = true
                            canBack = view.canGoBack(); canForward = view.canGoForward()
                        }
                        override fun onPageFinished(view: WebView, u: String?) {
                            u?.let { current = it }; loading = false
                            canBack = view.canGoBack(); canForward = view.canGoForward()
                        }
                        // Non-web schemes (mailto/tel/intent) go to the system; everything
                        // else stays here.
                        override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest): Boolean {
                            val scheme = request.url.scheme?.lowercase() ?: return false
                            if (scheme == "http" || scheme == "https") return false
                            runCatching { c.startActivity(Intent(Intent.ACTION_VIEW, request.url)) }
                            return true
                        }
                    }
                    webChromeClient = object : android.webkit.WebChromeClient() {
                        override fun onProgressChanged(view: WebView, newProgress: Int) { progress = newProgress / 100f }
                    }
                    loadUrl(url)
                    web = this
                }
            },
        )
    }
}

@Composable
private fun ToolIcon(icon: String, enabled: Boolean = true, tint: androidx.compose.ui.graphics.Color? = null, onClick: () -> Unit) {
    val p = theme
    Icon(
        SfIcon.vector(icon), null,
        tint = if (!enabled) p.textMuted else tint ?: p.textPrimary,
        modifier = Modifier.padding(Space.s2).size(20.dp).let { if (enabled) it.noRippleClickable { onClick() } else it },
    )
}
