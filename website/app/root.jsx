import {
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
  isRouteErrorResponse,
} from "react-router";

import Nav from "./components/Nav/Nav.jsx";
import Footer from "./components/Footer/Footer.jsx";
import CookieBanner from "./components/CookieBanner/CookieBanner.jsx";
import ShotThemeSwitch from "./components/ShotThemeSwitch/ShotThemeSwitch.jsx";
import { ShotThemeProvider } from "./lib/shotTheme.jsx";

import "./styles/tokens.css";
import "./styles/global.css";

/** @type {import('react-router').LinksFunction} */
export const links = () => [
  { rel: "icon", type: "image/png", sizes: "32x32", href: "/assets/favicon-32.png" },
  { rel: "icon", type: "image/png", sizes: "128x128", href: "/assets/favicon-128.png" },
  { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
  { rel: "preconnect", href: "https://fonts.googleapis.com" },
  { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
  {
    rel: "stylesheet",
    href: "https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@62..125,400..900&family=Inter:wght@400;500;600&family=Fraunces:opsz,wght@9..144,500..700&display=swap",
  },
];

export function Layout({ children }) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="theme-color" content="#111111" />
        <Meta />
        <Links />
      </head>
      <body>
        {children}
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  );
}

export default function App() {
  return (
    <ShotThemeProvider>
      <Nav />
      <main>
        <Outlet />
      </main>
      <Footer />
      <ShotThemeSwitch />
      <CookieBanner />
    </ShotThemeProvider>
  );
}

export function ErrorBoundary({ error }) {
  const title = isRouteErrorResponse(error)
    ? `${error.status} ${error.statusText}`
    : "Something went wrong";
  const detail = isRouteErrorResponse(error)
    ? error.data
    : error instanceof Error
      ? error.message
      : "Unknown error";
  return (
    <main className="wrap errorPage">
      <h1>{title}</h1>
      <p className="lede">{String(detail)}</p>
    </main>
  );
}
