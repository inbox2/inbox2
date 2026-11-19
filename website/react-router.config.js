/** @type {import('@react-router/dev/config').Config} */
export default {
  // Static marketing site — no server runtime. Every route is param-free, so
  // prerender them all to HTML at build time; the browser hydrates for the
  // interactive bits. Build output is plain assets in build/client, deployed
  // to Cloudflare Pages (no Worker).
  ssr: false,
  prerender: true,
};
