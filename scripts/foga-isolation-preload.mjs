// Preloaded into every Node process of the FOGA isolation check (NODE_OPTIONS=--import): records every host name the
// process resolves or connects to, and makes any name under finchain.one fail as if it did not exist. The log is the
// evidence that a FOGA package never reaches for Finchain unless a world file names it (docs/world.md, "FOGA on its own").
import dns from "node:dns";
import fs from "node:fs";
import net from "node:net";

const LOG = process.env.FOGA_ISOLATION_LOG;
const BLOCK = /(^|\.)finchain\.one$/i;

function record(kind, host) {
  if (!LOG || !host) return;
  try {
    fs.appendFileSync(LOG, JSON.stringify({ t: new Date().toISOString(), pid: process.pid, kind, host: String(host) }) + "\n");
  } catch {
    /* the log must never break the program under test */
  }
}
function blocked(host) {
  return Object.assign(new Error(`getaddrinfo ENOTFOUND ${host} (blocked by the Finchain isolation check)`), { code: "ENOTFOUND", errno: -3008, syscall: "getaddrinfo", hostname: host });
}

const lookup = dns.lookup;
dns.lookup = function (host, ...rest) {
  record("dns.lookup", host);
  if (BLOCK.test(String(host))) {
    const cb = rest[rest.length - 1];
    if (typeof cb === "function") {
      process.nextTick(() => cb(blocked(host)));
      return;
    }
    throw blocked(host);
  }
  return lookup.call(this, host, ...rest);
};
const plookup = dns.promises.lookup;
dns.promises.lookup = async function (host, ...rest) {
  record("dns.promises.lookup", host);
  if (BLOCK.test(String(host))) throw blocked(host);
  return plookup.call(this, host, ...rest);
};
const connect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
  // net.connect() and tls.connect() reach this method with their arguments already normalized into an array
  // ([options, callback]); a direct socket.connect(options) or socket.connect(port, host) does not.
  const first = Array.isArray(args[0]) ? args[0][0] : args[0];
  const opts = first && typeof first === "object" ? first : null;
  const host = opts?.host ?? opts?.hostname ?? (typeof args[1] === "string" ? args[1] : null) ?? (opts && !opts.path && opts.port !== undefined ? "localhost" : null);
  if (host) record("socket.connect", host);
  if (host && BLOCK.test(String(host))) {
    process.nextTick(() => this.destroy(blocked(host)));
    return this;
  }
  return connect.apply(this, args);
};
