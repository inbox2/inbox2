package com.inbox2.app

import android.annotation.SuppressLint
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * On-device rendering harness for the email body engine — the Android counterpart of
 * the iOS [EmailBodyRenderingTests]. The web/desktop app and the iOS/Android WebViews
 * all render through the same shipped `email-body.js`; this loads that exact bundle
 * into a real [WebView] and runs every fixture in `fixtures/email/` (flattened into
 * `fixtures.gen.json` by `bin/gen-email-fixtures`) through `processBody()`, asserting
 * the same outcomes the JS and iOS harnesses check. It proves the bundle behaves
 * correctly when executed by Android's WebView — catching a stale/broken embedded
 * bundle or an engine difference the Node/jsdom suite can't see.
 *
 * Run on a booted emulator/device:  ./gradlew :app:connectedDebugAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class EmailBodyRenderingTest {

    private val targetAssets = InstrumentationRegistry.getInstrumentation().targetContext.assets
    private val testAssets = InstrumentationRegistry.getInstrumentation().context.assets

    private fun asset(assets: android.content.res.AssetManager, name: String): String =
        assets.open(name).bufferedReader().use { it.readText() }

    /** Load the bundle + one fixture into a real WebView and return processBody's result. */
    @SuppressLint("SetJavaScriptEnabled")
    private fun process(bundleJs: String, html: String): JSONObject {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val latch = CountDownLatch(1)
        val payload = java.util.concurrent.atomic.AtomicReference<String>()

        val sample = JSONArray().put(html).toString() // ["<html>"] → safe JS literal source
        val page = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="img-src data: blob:;"></head>
            <body><script>$bundleJs</script><script>
              try {
                var r = Inbox2EmailBody.processBody(($sample)[0]);
                Bridge.result(JSON.stringify({
                  hasQuote: r.hasQuote, hasSignature: r.hasSignature,
                  blockedCount: r.blockedCount, html: r.html
                }));
              } catch (e) { Bridge.result(JSON.stringify({ error: String(e) })); }
            </script></body></html>
        """.trimIndent()

        instrumentation.runOnMainSync {
            val web = WebView(instrumentation.targetContext)
            web.settings.javaScriptEnabled = true
            web.addJavascriptInterface(object {
                @JavascriptInterface fun result(json: String) { payload.set(json); latch.countDown() }
            }, "Bridge")
            web.loadDataWithBaseURL(null, page, "text/html", "utf-8", null)
        }

        assertTrue("WebView did not return a result in time", latch.await(15, TimeUnit.SECONDS))
        return JSONObject(payload.get()!!)
    }

    @Test
    fun everyFixtureRendersThroughTheShippedBundle() {
        val bundleJs = asset(targetAssets, "email-body.js")
        val corpus = JSONObject(asset(testAssets, "fixtures.gen.json")).getJSONArray("cases")
        assertTrue("corpus is empty", corpus.length() > 0)

        val failures = mutableListOf<String>()
        fun check(cond: Boolean, msg: String) { if (!cond) failures += msg }

        for (i in 0 until corpus.length()) {
            val c = corpus.getJSONObject(i)
            val name = c.getString("name")
            val expect = c.optJSONObject("expect") ?: JSONObject()
            val r = process(bundleJs, c.getString("html"))

            check(!r.has("error"), "[$name] processBody threw: ${r.optString("error")}")
            val out = r.optString("html", "")

            check(r.optBoolean("hasQuote") == expect.optBoolean("hasQuote"), "[$name] hasQuote")
            check(r.optBoolean("hasSignature") == expect.optBoolean("hasSignature"), "[$name] hasSignature")

            if (expect.optBoolean("blocksRemote")) {
                check(r.optInt("blockedCount") > 0, "[$name] expected remote content blocked")
            } else {
                check(r.optInt("blockedCount") == 0, "[$name] expected no remote content blocked")
            }

            if (expect.optBoolean("unwrapsPre")) {
                check(!out.contains("<pre", ignoreCase = true), "[$name] expected <pre> wrapper unwrapped")
            }

            // Universal privacy invariant: no LIVE remote image src (leading space
            // distinguishes it from the stashed data-blocked-src that holds the original).
            check(!out.contains(" src=\"http", ignoreCase = true),
                "[$name] left a live remote image src in the rendered HTML")

            expect.optJSONArray("contains")?.let { arr ->
                for (j in 0 until arr.length()) {
                    val needle = arr.getString(j)
                    check(out.contains(needle), "[$name] output should contain: $needle")
                }
            }
            expect.optJSONArray("notContains")?.let { arr ->
                for (j in 0 until arr.length()) {
                    val needle = arr.getString(j)
                    check(!out.contains(needle), "[$name] output should NOT contain: $needle")
                }
            }
        }

        assertTrue("rendering fixtures failed:\n" + failures.joinToString("\n"), failures.isEmpty())
    }
}
