#!/usr/bin/env node
// inbox2 Android MCP — the Android analog of XcodeBuildMCP / the ios-simulator MCP.
// Exposes the bin/android driver (build the Rust core + Compose app, drive the
// emulator, automate + screenshot the UI) as MCP tools so an agent can build, run,
// and inspect the Android app the same way it drives the iOS simulator.
//
// Register (e.g. in .mcp.json or your client config):
//   { "mcpServers": { "inbox2-android": {
//       "command": "node",
//       "args": ["ui/android/tools/android-mcp/server.js"] } } }
//
// Run `npm install` in this dir first (pulls @modelcontextprotocol/sdk).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { readFileSync } from "node:fs";

const __dirname = dirname(fileURLToPath(import.meta.url));
// repo root is four levels up: tools/android-mcp → android → ui → repo
const REPO = resolve(__dirname, "..", "..", "..", "..");
const ANDROID = resolve(REPO, "bin", "android");

function run(args, { binary = false } = {}) {
  return new Promise((res) => {
    execFile(ANDROID, args, { cwd: REPO, maxBuffer: 64 * 1024 * 1024, encoding: binary ? "buffer" : "utf8" },
      (err, stdout, stderr) => {
        if (binary) return res({ ok: !err, stdout, stderr: stderr?.toString() ?? "" });
        res({ ok: !err, stdout: stdout ?? "", stderr: stderr ?? "" });
      });
  });
}

const text = (s) => ({ content: [{ type: "text", text: s || "(no output)" }] });
const result = (r) => text([r.stdout, r.stderr].filter(Boolean).join("\n").slice(-12000));

const server = new McpServer({ name: "inbox2-android", version: "0.1.0" });

server.tool("android_core", "Rebuild inbox2-core for Android (cargo-ndk .so + UniFFI Kotlin bindings). Run after any Rust change.", {}, async () => result(await run(["core"])));
server.tool("android_build", "Build the Compose app APK.", { variant: z.enum(["debug", "release"]).default("debug") }, async ({ variant }) => result(await run(["build", variant])));
server.tool("android_boot", "Boot the emulator (default AVD) and wait for it.", { avd: z.string().optional() }, async ({ avd }) => result(await run(avd ? ["boot", avd] : ["boot"])));
server.tool("android_install", "Install the APK on the running emulator.", { variant: z.enum(["debug", "release"]).default("debug") }, async ({ variant }) => result(await run(["install", variant])));
server.tool("android_run", "boot + build + install + launch in one step.", { variant: z.enum(["debug", "release"]).default("debug") }, async ({ variant }) => result(await run(["run", variant])));
server.tool("android_launch", "Launch the app's main activity.", {}, async () => result(await run(["launch"])));
server.tool("android_stop", "Force-stop the app.", {}, async () => result(await run(["stop"])));
server.tool("android_seed", "Seed the app sandbox with the desktop inbox2.db + credential key (real mail, no OAuth).", {}, async () => result(await run(["seed"])));
server.tool("android_ui", "Dump the current UI hierarchy (uiautomator XML).", {}, async () => result(await run(["ui"])));
server.tool("android_tap", "Tap at device pixel coordinates.", { x: z.number(), y: z.number() }, async ({ x, y }) => result(await run(["tap", String(x), String(y)])));
server.tool("android_swipe", "Swipe between two points.", { x1: z.number(), y1: z.number(), x2: z.number(), y2: z.number(), ms: z.number().default(300) }, async ({ x1, y1, x2, y2, ms }) => result(await run(["swipe", String(x1), String(y1), String(x2), String(y2), String(ms)])));
server.tool("android_text", "Type a string into the focused field.", { text: z.string() }, async ({ text: t }) => result(await run(["text", t])));
server.tool("android_key", "Send a keyevent (e.g. BACK=4, ENTER=66, HOME=3).", { keycode: z.string() }, async ({ keycode }) => result(await run(["key", keycode])));
server.tool("android_logcat", "Capture logcat (core + app tags) for N seconds.", { seconds: z.number().default(8) }, async ({ seconds }) => result(await run(["logcat", String(seconds)])));
server.tool("android_devices", "List attached devices/emulators.", {}, async () => result(await run(["devices"])));
server.tool("android_screenshot", "Capture a screenshot and return it as an image.", { path: z.string().default("/tmp/inbox2-android.png") }, async ({ path }) => {
  const r = await run(["screenshot", path]);
  try {
    const data = readFileSync(path.trim()).toString("base64");
    return { content: [{ type: "image", data, mimeType: "image/png" }] };
  } catch {
    return result(r);
  }
});

await server.connect(new StdioServerTransport());
