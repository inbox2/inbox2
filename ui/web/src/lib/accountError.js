// What an account row says when its last sync failed. A rate limit (Gmail sends
// it as a 403 with a JSON body) clears by itself, so it gets one plain line
// instead of the JSON; the stored error keeps the provider's retry time.
const RATE_LIMIT = ['quota exceeded', 'quotaexceeded', 'ratelimitexceeded', 'rate limit', 'http 429'];

export function accountErrorText(message) {
  if (!message) return "Couldn't get new mail. We'll try again.";
  const m = message.toLowerCase();
  if (RATE_LIMIT.some((x) => m.includes(x))) return "The mail provider asked us to slow down. We'll try again when it lets us.";
  return message;
}
