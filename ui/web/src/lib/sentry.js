// Errors and page timings to Pushleft's Errors page, through the Sentry SDK.
// Only the Pages build has a DSN (.env.pages), so dev and desktop builds send
// nothing and never load the SDK. The release is the commit (deploy.yml).
const dsn = import.meta.env.VITE_SENTRY_DSN;
let sdk = null;

// Tokens and ids in paths (share links, meet links, conversations): any segment
// of 16+ URL-safe characters, as api/config/initializers/sentry.rb does. Query
// strings and fragments go entirely.
const scrub = (s) => s?.replace(/[?#].*$/, '').replace(/\/[A-Za-z0-9_-]{16,}(?=[/.]|$)/g, '/:token');
const scrubData = (data) => {
  for (const k of Object.keys(data || {})) {
    if (/query|refer|header/i.test(k)) delete data[k];
    else if (/url|path|target/i.test(k) && typeof data[k] === 'string') data[k] = scrub(data[k]);
  }
};
// Exception messages are kept on purpose: they are what an error report is for.
// The Errors page is Pushleft's (our own platform, members of the org only,
// 14-30 days), the same store and reach as the service logs that already hold
// these messages; it is not a third party.
const scrubEvent = (event) => {
  if (event.request?.url) event.request.url = scrub(event.request.url);
  // Only the browser; Referer can hold a share-link token.
  if (event.request?.headers) event.request.headers = { 'User-Agent': event.request.headers['User-Agent'] };
  if (event.transaction) event.transaction = scrub(event.transaction);
  scrubData(event.contexts?.trace?.data);
  for (const span of event.spans || []) {
    if (span.description) span.description = scrub(span.description);
    scrubData(span.data);
  }
  return event;
};

export function initSentry() {
  if (!dsn) return;
  sdk = import('@sentry/react').then((Sentry) => {
    Sentry.init({
      dsn,
      release: import.meta.env.VITE_SENTRY_RELEASE,
      environment: 'production',
      tracesSampleRate: 0.1,
      // Whole transactions, not v11's default streamed spans: Pushleft stores
      // transaction items (and drops span items), and beforeSendTransaction runs.
      traceLifecycle: 'static',
      integrations: [Sentry.browserTracingIntegration()],
      beforeSend: scrubEvent,
      beforeSendTransaction: scrubEvent,
      // No breadcrumbs: console lines, clicked labels and URLs carry addresses,
      // subjects and file names. The stack trace and the page path are enough.
      beforeBreadcrumb: () => null,
    });
    return Sentry;
  });
}

// A render error the ErrorBoundary caught (React does not rethrow it).
export function reportError(error, componentStack) {
  sdk?.then((Sentry) => Sentry.captureException(error, { contexts: { react: { componentStack } } }));
}
