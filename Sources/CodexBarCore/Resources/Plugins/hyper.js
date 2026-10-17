function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
defineProvider({
  id: "hyper",
  name: "Charm Hyper",
  endpoints: ["https://hyper.charm.land"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["hyper.charm.land"],
  settings: [
    { key: "HYPER_API_KEY", title: "API key", type: "secure" },
    { key: "SOURCE_MODE", title: "Source", type: "plain" },
  ],
  async fetchUsage(ctx) {
    const domain = "hyper.charm.land";
    const base = `https://${domain}`;
    const key = ctx.settings.getSecret("HYPER_API_KEY");
    const canUseKey = Boolean(key) && ctx.settings.get("SOURCE_MODE") !== "web";
    const cookiePolicy = ctx.browser.availability(domain);
    const missing = () => {
      throw ctx.fail.missingCredential("Sign in to hyper.charm.land or configure a Charm Hyper API key.");
    };
    const record = (value) =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? value : undefined;
    const number = (value) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
    const parse = (bodyText) => {
      try {
        return JSON.parse(bodyText);
      } catch (error) {
        void error;
        return undefined;
      }
    };
    // hyper.charm.land now serves a client-rendered app at "/", so the session probe is the
    // JSON endpoint the app itself calls. /v1/credits accepts bearer keys only.
    const authenticated = (body) =>
      _optionalChain([record, "call", (_) => _(body), "optionalAccess", (_2) => _2.authenticated]) === true;
    const teamIDs = (body) => {
      const teams = _optionalChain([record, "call", (_3) => _3(body), "optionalAccess", (_4) => _4.teams]);
      if (!Array.isArray(teams)) return [];
      return teams
        .map((team) => _optionalChain([record, "call", (_5) => _5(team), "optionalAccess", (_6) => _6.id]))
        .filter((id) => typeof id === "string" && id.length > 0);
    };
    // The dashboard headline "Hypercredits Available" is subscription remaining plus prepaid.
    const hypercredits = (body) => {
      const dashboard = record(body);
      if (!dashboard) return undefined;
      let total = 0;
      let present = false;
      for (const field of ["remaining", "prepaid"]) {
        const raw = dashboard[field];
        if (raw === undefined || raw === null) continue;
        const amount = number(raw);
        if (amount === undefined) return undefined;
        total += amount;
        present = true;
      }
      return present ? total : undefined;
    };
    let balance;
    let session = false;
    let rejected = false;
    let malformed = false;
    if (cookiePolicy !== "off") {
      try {
        // A stale session in an earlier browser must not shadow a live one in a later browser.
        for await (const candidate of ctx.browser.sessions(domain)) {
          const headers = {
            Cookie: _nullishCoalesce(candidate.header, () => ""),
            Accept: "application/json",
          };
          const probe = await ctx.http.get(`${base}/auth/me`, { headers, timeoutSeconds: 8 });
          const profile = probe.status === 200 ? parse(probe.bodyText) : undefined;
          if (!authenticated(profile)) {
            rejected = true;
            ctx.browser.rejectCookie(domain, candidate);
            if (cookiePolicy === "manual") break;
            continue;
          }
          let total;
          for (const teamID of teamIDs(profile)) {
            const dashboard = await ctx.http.get(`${base}/teams/${teamID}/dashboard`, {
              headers,
              timeoutSeconds: 8,
            });
            if (dashboard.status !== 200) continue;
            total = hypercredits(parse(dashboard.bodyText));
            if (total !== undefined) break;
          }
          if (total === undefined) {
            // The session authenticated but the dashboard did not report a balance: fail closed
            // rather than guess, and keep the cookie since authentication itself succeeded.
            malformed = true;
            break;
          }
          balance = total;
          session = true;
          break;
        }
      } catch (error) {
        const transportClass = error.transportClass;
        if (transportClass === "cancelled") throw error;
        if (transportClass !== undefined) {
          if (!canUseKey) throw ctx.fail.networkFailure("Charm Hyper session request failed.");
        } else if (!canUseKey) {
          return missing();
        }
      }
      if (malformed) {
        throw ctx.fail.parseFailure("Charm Hyper dashboard did not report a balance.");
      }
      if (!session && rejected && !canUseKey) {
        throw ctx.fail.authenticationExpired(
          cookiePolicy === "manual"
            ? "Charm Hyper session expired. Paste a fresh Cookie header in Settings."
            : "Charm Hyper session expired. Sign in again at hyper.charm.land.",
        );
      }
    }
    if (!session) {
      if (!canUseKey) return missing();
      const response = await ctx.http.get(`${base}/v1/credits`, {
        headers: { Authorization: `Bearer ${key}` },
        timeoutSeconds: 10,
      });
      if (response.status === 401) throw ctx.fail.authenticationExpired("Charm Hyper API key rejected (HTTP 401).");
      if (response.status === 403)
        throw ctx.fail.permissionDenied("Charm Hyper API key cannot access credits (HTTP 403).");
      if (response.status === 429) throw ctx.fail.rateLimited("Charm Hyper credits requests are rate limited.");
      if (response.status >= 500) throw ctx.fail.providerUnavailable(`Charm Hyper API error: HTTP ${response.status}`);
      if (response.status !== 200) throw ctx.fail.apiFailure(`Charm Hyper API error: HTTP ${response.status}`);
      const payload = record(parse(response.bodyText));
      const value = payload ? number(payload.balance) : undefined;
      if (value === undefined || value < 0) {
        throw ctx.fail.parseFailure("Charm Hyper balance must be a non-negative number.");
      }
      balance = value;
    }
    if (balance === undefined || !Number.isFinite(balance) || balance < 0) {
      throw ctx.fail.parseFailure("Charm Hyper balance must be a non-negative number.");
    }
    const row = {
      label: "Balance",
      value: `${ctx.format.number(balance, { maximumFractionDigits: 2 })} HC`,
      usageValue: balance,
    };
    return {
      usage: {
        details: [{ title: "Hypercredits", rows: [row] }],
        identity: { loginMethod: session ? "Browser session" : "API key" },
        dataConfidence: "exact",
      },
      sourceLabel: session ? "web" : "api",
    };
  },
});
