import { index, route } from "@react-router/dev/routes";

/** Route table. Mirrors the internal links in app/lib/nav.js. */
export default [
  index("routes/home.jsx"),
  route("mx", "routes/mx.jsx"),
  route("topologies", "routes/topologies.jsx"),
  route("download", "routes/download.jsx"),
  route("privacy", "routes/privacy.jsx"),
  route("terms", "routes/terms.jsx"),
];
