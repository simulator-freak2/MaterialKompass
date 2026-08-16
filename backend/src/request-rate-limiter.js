'use strict';

const DEFAULT_MAX_CLIENTS = 10_000;
const DEFAULT_ERROR_MESSAGE = 'Zu viele Anfragen. Bitte später erneut versuchen.';

/**
 * Creates an in-memory fixed-window rate limiter for one kind of request.
 *
 * The state belongs to the returned middleware. This keeps independent app
 * instances and test runs isolated from each other.
 */
function createRateLimiter({
  windowMs,
  maxRequests,
  keyFor = (req) => req.ip,
  appliesTo = () => true,
  errorMessage = DEFAULT_ERROR_MESSAGE,
  exposePolicyHeaders = false,
  maxClients = DEFAULT_MAX_CLIENTS,
  now = Date.now,
}) {
  if (!Number.isFinite(windowMs) || windowMs <= 0) {
    throw new TypeError('windowMs must be a positive number.');
  }
  if (!Number.isInteger(maxRequests) || maxRequests <= 0) {
    throw new TypeError('maxRequests must be a positive integer.');
  }

  const requestsByClient = new Map();

  function removeExpiredEntries(timestamp) {
    for (const [key, entry] of requestsByClient) {
      if (entry.resetAt <= timestamp) requestsByClient.delete(key);
    }
  }

  return function rateLimit(req, res, next) {
    if (!appliesTo(req)) return next();

    const timestamp = now();
    const key = String(keyFor(req));
    let entry = requestsByClient.get(key);

    if (!entry && requestsByClient.size >= maxClients) {
      removeExpiredEntries(timestamp);
      if (requestsByClient.size >= maxClients) {
        return res.status(429).json({ error: errorMessage });
      }
    }

    if (!entry || entry.resetAt <= timestamp) {
      entry = { count: 0, resetAt: timestamp + windowMs };
    }
    entry.count += 1;
    requestsByClient.set(key, entry);

    const secondsUntilReset = Math.ceil((entry.resetAt - timestamp) / 1000);
    if (exposePolicyHeaders) {
      res.set('RateLimit-Policy', `${maxRequests};w=${windowMs / 1000}`);
      res.set('RateLimit-Remaining', String(Math.max(0, maxRequests - entry.count)));
      res.set('RateLimit-Reset', String(secondsUntilReset));
    }

    if (entry.count > maxRequests) {
      res.set('Retry-After', String(secondsUntilReset));
      return res.status(429).json({ error: errorMessage });
    }
    return next();
  };
}

module.exports = { createRateLimiter };
