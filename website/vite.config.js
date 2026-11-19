import { reactRouter } from "@react-router/dev/vite";
import { defineConfig } from "vite";

// Static marketing build (React Router SPA + full prerender). No Cloudflare
// Workers runtime — output is plain assets in build/client for Cloudflare Pages.
export default defineConfig({
  server: { port: 8899, strictPort: true },
  // host pinned to IPv4: the prerender step boots this preview server (on a
  // random port) and fetches it back. In Docker/CI `localhost` resolves to ::1
  // first, so the server binds IPv6 while the fetch hits 127.0.0.1 -> ECONNREFUSED.
  preview: { host: "127.0.0.1", port: 8899, strictPort: true },
  plugins: [reactRouter()],
});
