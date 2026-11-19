// react-grab: dev-only overlay for grabbing component/DOM context (matches
// ui/web). Dead-code-eliminated from the production build (DEV === false).
if (import.meta.env.DEV) {
  import("react-grab");
}

import { HydratedRouter } from "react-router/dom";
import { startTransition, StrictMode } from "react";
import { hydrateRoot } from "react-dom/client";

startTransition(() => {
  hydrateRoot(
    document,
    <StrictMode>
      <HydratedRouter />
    </StrictMode>,
  );
});
