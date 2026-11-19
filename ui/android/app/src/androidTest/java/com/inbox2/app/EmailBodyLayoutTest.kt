package com.inbox2.app

import android.annotation.SuppressLint
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.inbox2.app.ui.components.EmailReaderCss
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Android layout harness — the counterpart of iOS [EmailBodyLayoutTest]. Renders the
 * fixtures flagged `noOverflow` through the app's real [EmailReaderCss] + the shipped
 * bundle in a WebView forced to a phone width, and asserts nothing spills past the
 * viewport. Catches the fixed/min-width desktop-email overflow (Temu) on Android, the
 * same bug fixed on iOS.
 *
 * Run on a booted emulator/device:  ./gradlew :app:connectedDebugAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class EmailBodyLayoutTest {

    private val targetAssets = InstrumentationRegistry.getInstrumentation().targetContext.assets
    private val testAssets = InstrumentationRegistry.getInstrumentation().context.assets

    // Force the WebView to a phone-class width so layout happens at that width.
    private val widthPx = 1080
    private val heightPx = 2400

    private fun asset(assets: android.content.res.AssetManager, name: String): String =
        assets.open(name).bufferedReader().use { it.readText() }

    @SuppressLint("SetJavaScriptEnabled")
    private fun measure(bundleJs: String, html: String): JSONObject {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val latch = CountDownLatch(1)
        val payload = java.util.concurrent.atomic.AtomicReference<String>()

        val sample = org.json.JSONArray().put(html).toString()
        val page = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="img-src data: blob:;">
            <style>${EmailReaderCss.CSS}</style></head>
            <body><div id="body"></div>
            <script>$bundleJs</script>
            <script>
              try {
                var SAMPLE = ($sample)[0];
                // Mirror the REAL reader host (ReaderWebView/MessageBodyWebView): re-inject
                // the email's own <style> blocks — responsive media queries live in <head>,
                // which processBody() drops. Without them a responsive email renders
                // differently than on device, so the harness would silently pass real bugs.
                // @import + remote url() stripped (privacy / CSP parity).
                try {
                  var srcDoc = new DOMParser().parseFromString(SAMPLE, 'text/html');
                  srcDoc.querySelectorAll('style').forEach(function (s) {
                    var css = (s.textContent || '')
                      .replace(/@import[^;]+;/gi, '')
                      .replace(/url\(\s*(['"]?)(https?:)?\/\/[^'")]+\1\s*\)/gi, 'none');
                    var e = document.createElement('style');
                    e.textContent = css;
                    document.head.appendChild(e);
                  });
                } catch (e) {}
                var root = document.getElementById('body');
                var r = Inbox2EmailBody.processBody(SAMPLE);
                root.innerHTML = r.html;
                ${EmailReaderCss.FIT_JS}
                var scale = window.__fitEmail();
                void document.body.offsetHeight; // force a synchronous reflow
                var maxRight = 0;
                root.querySelectorAll('*').forEach(function (el) {
                  var rect = el.getBoundingClientRect();
                  if (rect.width > 0 && rect.right > maxRight) maxRight = rect.right;
                });
                Bridge.metrics(JSON.stringify({ viewport: document.documentElement.clientWidth, maxRight: maxRight, scale: scale }));
              } catch (e) { Bridge.metrics(JSON.stringify({ error: String(e) })); }
            </script></body></html>
        """.trimIndent()

        instrumentation.runOnMainSync {
            val web = WebView(instrumentation.targetContext)
            web.settings.javaScriptEnabled = true
            web.addJavascriptInterface(object {
                @JavascriptInterface fun metrics(json: String) { payload.set(json); latch.countDown() }
            }, "Bridge")
            // Give the WebView real bounds so JS layout runs at widthPx.
            web.measure(
                View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY),
            )
            web.layout(0, 0, widthPx, heightPx)
            web.loadDataWithBaseURL(null, page, "text/html", "utf-8", null)
        }

        assertTrue("WebView did not return metrics in time", latch.await(15, TimeUnit.SECONDS))
        return JSONObject(payload.get()!!)
    }

    @Test
    fun reflowableFixturesDoNotOverflowThePhoneViewport() {
        val bundleJs = asset(targetAssets, "email-body.js")
        val corpus = JSONObject(asset(testAssets, "fixtures.gen.json")).getJSONArray("cases")

        val failures = mutableListOf<String>()
        var checked = 0
        for (i in 0 until corpus.length()) {
            val c = corpus.getJSONObject(i)
            val expect = c.optJSONObject("expect") ?: JSONObject()
            if (!expect.optBoolean("noOverflow")) continue
            checked++
            val name = c.getString("name")
            val m = measure(bundleJs, c.getString("html"))
            if (m.has("error")) { failures += "[$name] render threw: ${m.optString("error")}"; continue }
            val viewport = m.optDouble("viewport")
            val maxRight = m.optDouble("maxRight")
            if (maxRight > viewport + 1) {
                failures += "[$name] overflowed: content reaches ${maxRight}px on a ${viewport}px viewport"
            }
        }

        assertTrue("no fixtures flagged noOverflow — check the manifest", checked > 0)
        assertTrue("layout overflow:\n" + failures.joinToString("\n"), failures.isEmpty())
    }

    /**
     * Regression guard for the prose scale-down bug (parity with iOS
     * `testProseFixturesAreNotScaledDown`): an ordinary text email — flowing prose, or a
     * plain-text body in `white-space:pre-wrap` — must render at full width, NOT be shrunk
     * to a tiny strip. The old fit pass measured `width:max-content`, unwrapping every
     * paragraph onto one line and scaling the whole body down to a thumbnail. `noShrink`
     * fixtures assert the fit pass leaves them at scale ≈ 1.
     */
    @Test
    fun proseFixturesAreNotScaledDown() {
        val bundleJs = asset(targetAssets, "email-body.js")
        val corpus = JSONObject(asset(testAssets, "fixtures.gen.json")).getJSONArray("cases")

        val failures = mutableListOf<String>()
        var checked = 0
        for (i in 0 until corpus.length()) {
            val c = corpus.getJSONObject(i)
            val expect = c.optJSONObject("expect") ?: JSONObject()
            if (!expect.optBoolean("noShrink")) continue
            checked++
            val name = c.getString("name")
            val m = measure(bundleJs, c.getString("html"))
            if (m.has("error")) { failures += "[$name] render threw: ${m.optString("error")}"; continue }
            val scale = m.optDouble("scale")
            if (kotlin.math.abs(scale - 1.0) > 0.01) {
                failures += "[$name] was scaled to $scale — flowing text should wrap and render full width, not shrink"
            }
        }

        assertTrue("no fixtures flagged noShrink — check the manifest", checked > 0)
        assertTrue("prose scaled down:\n" + failures.joinToString("\n"), failures.isEmpty())
    }
}
