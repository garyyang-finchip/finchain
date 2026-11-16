#!/usr/bin/env python3
"""A JSON-RPC shim that adds debug_getRawHeader and debug_getRawReceipts to an L1 endpoint that lacks them.

kona-host reads the L1 as raw RLP: debug_getRawHeader (the RLP-encoded header) and debug_getRawReceipts (the
RLP-encoded receipts of a block). Public endpoints usually do not serve the debug namespace. This shim sits in
front of such an endpoint, forwards every other method untouched, and synthesises the two raw methods from the
standard ones:

  debug_getRawHeader   <- eth_getBlockByHash / eth_getBlockByNumber, encoded as the Ethereum header (every fork
                          up to Amsterdam: baseFeePerGas, withdrawalsRoot, blobGasUsed, excessBlobGas,
                          parentBeaconBlockRoot, requestsHash, blockAccessListHash, slotNumber);
  debug_getRawReceipts <- eth_getBlockReceipts, each receipt encoded with its EIP-2718 type prefix.

Both answers are verified before they leave the shim: the header's keccak256 must equal the block hash the node
reported, and the receipts' ordered Merkle-Patricia root must equal the header's receiptsRoot. An answer that
fails either check is replaced by a JSON-RPC error, so the shim can never hand the prover a preimage the chain
does not vouch for; the proof client verifies the same hashes again on its side. The shim is a drill
convenience for `run-trace` (drill/README.md, K2b) and nothing more: a resident challenger needs an endpoint
that serves the methods itself (docs/mainnet.md, decision 3).

Usage:
  drill/l1-raw-shim.py --upstream https://<l1 endpoint> [--listen 127.0.0.1:8550] [--log FILE]
  drill/l1-raw-shim.py --self-test <eth_getBlockByHash answer.json> [--trie-tests <ethereum/tests TrieTests dir>]
No dependencies beyond the Python 3 standard library (keccak-256 is implemented here).
"""

import argparse
import json
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ----------------------------------------------------------------------------------------------- keccak-256
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
    0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
    0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_MASK = (1 << 64) - 1


def _rol(x, n):
    n %= 64
    return ((x << n) | (x >> (64 - n))) & _MASK if n else x


def _keccak_f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate:
        padded.append(0)
    padded[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(padded), rate):
        block = padded[off:off + rate]
        for i in range(rate // 8):
            lane = int.from_bytes(block[8 * i:8 * i + 8], "little")
            a[i % 5][i // 5] ^= lane
        a = _keccak_f(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out[:32]


# ----------------------------------------------------------------------------------------------- RLP
def rlp(item) -> bytes:
    if isinstance(item, (bytes, bytearray)):
        b = bytes(item)
        if len(b) == 1 and b[0] < 0x80:
            return b
        return _rlp_len(len(b), 0x80) + b
    if isinstance(item, (list, tuple)):
        body = b"".join(rlp(x) for x in item)
        return _rlp_len(len(body), 0xC0) + body
    raise TypeError("rlp: bytes or list expected, got %r" % type(item))


def _rlp_len(n, base):
    if n < 56:
        return bytes([base + n])
    nb = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([base + 55 + len(nb)]) + nb


def hx(s: str) -> bytes:
    s = s[2:] if s.startswith("0x") else s
    if len(s) % 2:
        s = "0" + s
    return bytes.fromhex(s)


def uint(s) -> bytes:
    n = int(s, 16) if isinstance(s, str) else int(s)
    return b"" if n == 0 else n.to_bytes((n.bit_length() + 7) // 8, "big")


# ----------------------------------------------------------------------------------------------- header
HEADER_OPTIONAL = [
    ("baseFeePerGas", uint), ("withdrawalsRoot", hx), ("blobGasUsed", uint), ("excessBlobGas", uint),
    ("parentBeaconBlockRoot", hx), ("requestsHash", hx), ("blockAccessListHash", hx), ("slotNumber", uint),
]


def encode_header(h: dict) -> bytes:
    fields = [
        hx(h["parentHash"]), hx(h["sha3Uncles"]), hx(h["miner"]), hx(h["stateRoot"]), hx(h["transactionsRoot"]),
        hx(h["receiptsRoot"]), hx(h["logsBloom"]), uint(h["difficulty"]), uint(h["number"]), uint(h["gasLimit"]),
        uint(h["gasUsed"]), uint(h["timestamp"]), hx(h["extraData"]), hx(h["mixHash"]), hx(h["nonce"]),
    ]
    # optional fields: present up to the last one the node reports (a later fork field implies the earlier ones)
    present = [i for i, (k, _) in enumerate(HEADER_OPTIONAL) if h.get(k) is not None]
    for i in range(max(present) + 1 if present else 0):
        k, f = HEADER_OPTIONAL[i]
        v = h.get(k)
        if v is None:
            raise ValueError("header %s lacks %s while a later fork field is present" % (h.get("number"), k))
        fields.append(f(v))
    return rlp(fields)


# ----------------------------------------------------------------------------------------------- receipts
def encode_receipt(r: dict) -> bytes:
    logs = [[hx(lg["address"]), [hx(t) for t in lg["topics"]], hx(lg["data"])] for lg in r.get("logs", [])]
    if "status" in r and r["status"] is not None:
        first = uint(r["status"])
    else:  # pre-Byzantium receipts carry the intermediate state root instead of a status
        first = hx(r["root"])
    body = rlp([first, uint(r["cumulativeGasUsed"]), hx(r["logsBloom"]), logs])
    typ = int(r.get("type", "0x0"), 16)
    return body if typ == 0 else bytes([typ]) + body


# ----------------------------------------------------------------------------------------------- Merkle-Patricia trie
def _nibbles(key: bytes):
    out = []
    for b in key:
        out.append(b >> 4)
        out.append(b & 0x0F)
    return out


def _hp(nibbles, terminal):
    flag = 2 if terminal else 0
    if len(nibbles) % 2:
        flag |= 1
        nibbles = [flag] + list(nibbles)
    else:
        nibbles = [flag, 0] + list(nibbles)
    return bytes(nibbles[i] * 16 + nibbles[i + 1] for i in range(0, len(nibbles), 2))


def _node(items):
    """items: list of (nibble list, value bytes) with distinct keys -> the node (list) or b'' when empty."""
    if not items:
        return b""
    if len(items) == 1:
        nib, val = items[0]
        return [_hp(nib, True), val]
    prefix = []
    first = items[0][0]
    for i in range(len(first)):
        if all(len(n) > i and n[i] == first[i] for n, _ in items):
            prefix.append(first[i])
        else:
            break
    if prefix:
        child = _node([(n[len(prefix):], v) for n, v in items])
        return [_hp(prefix, False), _ref(child)]
    branch = [b""] * 17
    for digit in range(16):
        sub = [(n[1:], v) for n, v in items if n and n[0] == digit]
        branch[digit] = _ref(_node(sub))
    for n, v in items:
        if not n:
            branch[16] = v
    return branch


def _ref(node):
    if node == b"":
        return b""
    enc = rlp(node)
    return node if len(enc) < 32 else keccak256(enc)


def trie_root(kv: dict) -> bytes:
    items = [(_nibbles(k), v) for k, v in kv.items() if v is not None and v != b""]
    node = _node(items)
    return keccak256(rlp(node)) if node != b"" else keccak256(rlp(b""))


def ordered_trie_root(values) -> bytes:
    return trie_root({rlp(uint(i)): v for i, v in enumerate(values)})


# ----------------------------------------------------------------------------------------------- the shim
class Upstream:
    def __init__(self, url, timeout=60):
        self.url = url
        self.timeout = timeout
        self._id = 0
        self._lock = threading.Lock()

    def raw(self, body: bytes) -> bytes:
        req = urllib.request.Request(self.url, data=body, headers={"content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return resp.read()

    def call(self, method, params):
        with self._lock:
            self._id += 1
            rid = self._id
        out = json.loads(self.raw(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}).encode()))
        if "error" in out and out["error"]:
            raise RuntimeError("%s: %s" % (method, out["error"]))
        return out.get("result")


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.counts = {"forwarded": 0, "headers": 0, "receipts": 0, "failed": 0}

    def bump(self, k):
        with self.lock:
            self.counts[k] += 1


def make_handler(upstream: Upstream, stats: Stats, logf):
    def log(msg):
        line = "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg)
        logf.write(line)
        logf.flush()

    def block_by(param):
        if isinstance(param, str) and len(param) == 66:
            return upstream.call("eth_getBlockByHash", [param, False])
        return upstream.call("eth_getBlockByNumber", [param, False])

    def raw_header(params):
        blk = block_by(params[0])
        if blk is None:
            raise RuntimeError("block %s not found" % params[0])
        enc = encode_header(blk)
        got = "0x" + keccak256(enc).hex()
        if got.lower() != blk["hash"].lower():
            raise RuntimeError("header %s: encoded hash %s differs from the node's %s" % (blk["number"], got, blk["hash"]))
        log("debug_getRawHeader %s (%d) ok, %d bytes" % (blk["hash"], int(blk["number"], 16), len(enc)))
        stats.bump("headers")
        return "0x" + enc.hex()

    def raw_receipts(params):
        blk = block_by(params[0])
        if blk is None:
            raise RuntimeError("block %s not found" % params[0])
        try:
            receipts = upstream.call("eth_getBlockReceipts", [blk["hash"]])
        except RuntimeError as e:  # endpoints without eth_getBlockReceipts: one receipt at a time
            log("eth_getBlockReceipts unavailable (%s); fetching %d receipts one by one" % (e, len(blk["transactions"])))
            receipts = [upstream.call("eth_getTransactionReceipt", [tx]) for tx in blk["transactions"]]
        if receipts is None or any(r is None for r in receipts):
            raise RuntimeError("no receipts for %s" % blk["hash"])
        if len(receipts) != len(blk["transactions"]):
            raise RuntimeError("block %s: %d receipts for %d transactions" % (blk["number"], len(receipts), len(blk["transactions"])))
        encs = [encode_receipt(r) for r in receipts]
        root = "0x" + ordered_trie_root(encs).hex()
        if root.lower() != blk["receiptsRoot"].lower():
            raise RuntimeError("receipts of %s: root %s differs from the header's %s" % (blk["number"], root, blk["receiptsRoot"]))
        log("debug_getRawReceipts %s (%d) ok, %d receipts, root %s" % (blk["hash"], int(blk["number"], 16), len(encs), root))
        stats.bump("receipts")
        return ["0x" + e.hex() for e in encs]

    synth = {"debug_getRawHeader": raw_header, "debug_getRawReceipts": raw_receipts}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quiet; the shim keeps its own log
            return

        def do_POST(self):
            n = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(n)
            try:
                req = json.loads(body)
            except ValueError:
                return self._send(400, b'{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}')
            reqs = req if isinstance(req, list) else [req]
            if not any(r.get("method") in synth for r in reqs if isinstance(r, dict)):
                try:
                    out = upstream.raw(body)
                except Exception as e:  # noqa: BLE001
                    stats.bump("failed")
                    log("forward failed: %s" % e)
                    return self._send(502, json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32000, "message": "shim: upstream %s" % e}}).encode())
                stats.bump("forwarded")
                return self._send(200, out)
            answers = []
            for r in reqs:
                m = r.get("method")
                if m in synth:
                    try:
                        answers.append({"jsonrpc": "2.0", "id": r.get("id"), "result": synth[m](r.get("params") or [])})
                    except Exception as e:  # noqa: BLE001
                        stats.bump("failed")
                        log("%s failed: %s" % (m, e))
                        answers.append({"jsonrpc": "2.0", "id": r.get("id"), "error": {"code": -32000, "message": "shim: %s" % e}})
                else:
                    try:
                        answers.append(json.loads(upstream.raw(json.dumps(r).encode())))
                        stats.bump("forwarded")
                    except Exception as e:  # noqa: BLE001
                        stats.bump("failed")
                        answers.append({"jsonrpc": "2.0", "id": r.get("id"), "error": {"code": -32000, "message": "shim: upstream %s" % e}})
            out = json.dumps(answers if isinstance(req, list) else answers[0]).encode()
            return self._send(200, out)

        def do_GET(self):
            if self.path == "/healthz":
                return self._send(200, json.dumps({"shim": "l1-raw", "upstream": upstream.url.split("/")[2], **stats.counts}).encode())
            return self._send(404, b"not found")

        def _send(self, code, payload: bytes):
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return Handler


# ----------------------------------------------------------------------------------------------- self-test
def self_test(block_file, trie_dir):
    ok = True
    vec = keccak256(b"").hex()
    want = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    print("keccak256('')          ", "PASS" if vec == want else "FAIL (%s)" % vec)
    ok &= vec == want
    empty = trie_root({}).hex()
    want = "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"
    print("empty trie root        ", "PASS" if empty == want else "FAIL (%s)" % empty)
    ok &= empty == want
    if block_file:
        with open(block_file) as f:
            doc = json.load(f)
        blk = doc.get("result", doc)
        enc = encode_header(blk)
        got = "0x" + keccak256(enc).hex()
        res = got.lower() == blk["hash"].lower()
        print("header %s encoded: %d bytes, keccak %s %s" % (int(blk["number"], 16), len(enc), got, "PASS" if res else "FAIL (node says %s)" % blk["hash"]))
        ok &= res
    if trie_dir:
        import os

        def val(v):
            if v is None:
                return None
            return hx(v) if isinstance(v, str) and v.startswith("0x") else v.encode()

        for name in ("trietest.json", "trieanyorder.json"):
            path = os.path.join(trie_dir, name)
            if not os.path.exists(path):
                continue
            with open(path) as f:
                tests = json.load(f)
            for tname, t in tests.items():
                kv = {}
                if isinstance(t["in"], dict):
                    for k, v in t["in"].items():
                        kv[val(k)] = val(v)
                else:
                    for k, v in t["in"]:
                        kv[val(k)] = val(v)
                root = "0x" + trie_root(kv).hex()
                res = root == t["root"]
                ok &= res
                print("%s/%s %s" % (name, tname, "PASS" if res else "FAIL (%s != %s)" % (root, t["root"])))
    print("self-test", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--upstream", help="the L1 JSON-RPC endpoint to forward to")
    ap.add_argument("--listen", default="127.0.0.1:8550", help="host:port to listen on (default 127.0.0.1:8550)")
    ap.add_argument("--log", default="-", help="log file (default stderr)")
    ap.add_argument("--self-test", metavar="BLOCK_JSON", help="encode the header of a saved eth_getBlockByHash answer and check its hash")
    ap.add_argument("--trie-tests", metavar="DIR", help="run the ethereum/tests TrieTests vectors found in DIR")
    args = ap.parse_args()
    if args.self_test or args.trie_tests:
        sys.exit(self_test(args.self_test, args.trie_tests))
    if not args.upstream:
        ap.error("--upstream is required")
    host, port = args.listen.rsplit(":", 1)
    logf = sys.stderr if args.log == "-" else open(args.log, "a")
    stats = Stats()
    server = ThreadingHTTPServer((host, int(port)), make_handler(Upstream(args.upstream), stats, logf))
    logf.write("%s l1-raw-shim listening on %s, upstream %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), args.listen, args.upstream.split("/")[2]))
    logf.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        logf.write("%s l1-raw-shim stopped: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), json.dumps(stats.counts)))
        logf.flush()


if __name__ == "__main__":
    main()
