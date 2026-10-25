// Shared helpers of the appliance acceptance tests (run against a booted VM through its dashboard; not part of
// `make check`). Node >= 22 (built-in fetch / WebSocket), chromium on PATH (or $CHROMIUM).
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export function args() {
    const a = Object.fromEntries(process.argv.slice(2).map(x => x.replace(/^--/, "").split("=")).map(([k, ...v]) => [k, v.join("=") || "1"]));
    return {
        host: a.host || process.env.HOST || "127.0.0.1",
        port: a.port || process.env.PORT || "8000",
        user: a.user || process.env.APPLIANCE_USER || "admin",
        password: a.password || process.env.APPLIANCE_PASSWORD || "",
        out: a.out || process.env.OUT || "",
        ...a,
    };
}

// ok / FAIL lines, to stdout and (with --out) to a file; exit code = number of failures
export function reporter(out) {
    let bad = 0;
    if (out) writeFileSync(out, "");
    const line = s => { console.log(s); if (out) appendFileSync(out, s + "\n"); };
    return {
        check(name, ok, detail = "") {
            line(`${ok ? "ok  " : "FAIL"} ${name}${ok || !detail ? "" : `  (${typeof detail === "string" ? detail : JSON.stringify(detail).slice(0, 400)})`}`);
            bad += !ok;
            return ok;
        },
        info: s => line(`info ${s}`),
        done() { line(bad ? `${bad} FAILED` : "OK"); return bad; },
    };
}

// fetch with a cookie jar: the dashboard login cookie, as a browser would keep it
export class Http {
    constructor(base) { this.base = base; this.jar = {}; this.setCookies = []; }
    cookie() { return Object.entries(this.jar).map(([k, v]) => `${k}=${v}`).join("; "); }
    async req(method, path, { body, type, headers = {}, redirect = "manual" } = {}) {
        const h = { ...headers };
        if (Object.keys(this.jar).length) h.Cookie = this.cookie();
        if (type) h["Content-Type"] = type;
        const r = await fetch(this.base + path, { method, body, headers: h, redirect });
        for (const c of r.headers.getSetCookie()) {
            this.setCookies.push(c);
            const [kv] = c.split(";");
            const i = kv.indexOf("=");
            this.jar[kv.slice(0, i)] = kv.slice(i + 1);
        }
        const buf = Buffer.from(await r.arrayBuffer());
        let json = null;
        try { json = JSON.parse(buf.toString("utf8")); } catch { /* not JSON */ }
        return { status: r.status, headers: r.headers, buf, json };
    }
    async login(user, password) {
        return this.req("POST", "/login", { body: new URLSearchParams({ username: user, password, next: "" }).toString(),
                                            type: "application/x-www-form-urlencoded" });
    }
}

// A minimal Chrome DevTools Protocol driver: one headless chromium on a temp profile dir, pages as flat sessions.
export class Browser {
    static async launch() {
        const b = new Browser();
        b.dir = mkdtempSync(join(tmpdir(), "appliance-test-chromium-"));
        b.proc = spawn(process.env.CHROMIUM || "chromium", ["--headless=new", "--disable-gpu", "--no-sandbox",
            "--no-first-run", "--remote-debugging-port=0", `--user-data-dir=${b.dir}`, "about:blank"],
            { stdio: ["ignore", "ignore", "pipe"] });
        const url = await new Promise((res, rej) => {
            let err = "";
            const t = setTimeout(() => rej(new Error("chromium did not start: " + err.slice(-300))), 30000);
            b.proc.stderr.on("data", d => {
                err += d;
                const m = err.match(/DevTools listening on (ws:\/\/\S+)/);
                if (m) { clearTimeout(t); res(m[1]); }
            });
        });
        b.ws = new WebSocket(url);
        await new Promise((res, rej) => { b.ws.onopen = res; b.ws.onerror = rej; });
        b.id = 0; b.pending = new Map(); b.handlers = [];
        b.ws.onmessage = e => {
            const m = JSON.parse(e.data);
            if (m.id && b.pending.has(m.id)) {
                const { res, rej } = b.pending.get(m.id);
                b.pending.delete(m.id);
                m.error ? rej(new Error(m.error.message)) : res(m.result);
            } else if (m.method) b.handlers.forEach(h => h(m));
        };
        return b;
    }
    send(method, params = {}, sessionId) {
        const id = ++this.id;
        this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
        return new Promise((res, rej) => this.pending.set(id, { res, rej }));
    }
    async page(url = "about:blank") {
        const { targetId } = await this.send("Target.createTarget", { url: "about:blank" });
        const { sessionId } = await this.send("Target.attachToTarget", { targetId, flatten: true });
        const p = new Page(this, sessionId, targetId);
        await p.send("Page.enable");
        await p.send("Runtime.enable");
        await p.send("Network.enable");
        // auto-accept confirm() / alert() (switching away from an unsaved profile, remove dialogs)
        this.handlers.push(m => {
            if (m.sessionId === sessionId && m.method === "Page.javascriptDialogOpening")
                p.send("Page.handleJavaScriptDialog", { accept: true }).catch(() => {});
        });
        if (url !== "about:blank") await p.goto(url);
        return p;
    }
    async close() {
        try { await this.send("Browser.close"); } catch { /* gone */ }
        this.proc.kill();
        rmSync(this.dir, { recursive: true, force: true });
    }
}

export class Page {
    constructor(b, sessionId, targetId) { this.b = b; this.sessionId = sessionId; this.targetId = targetId; }
    send(method, params) { return this.b.send(method, params, this.sessionId); }
    async eval(expr) {
        const r = await this.send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
        if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
        return r.result.value;
    }
    async goto(url) { await this.send("Page.navigate", { url }); }
    // poll a JS condition until it is truthy (never a fixed sleep); returns its value or throws on timeout
    async wait(expr, ms = 30000, what = expr) {
        const t0 = Date.now();
        for (;;) {
            let v;
            try { v = await this.eval(expr); } catch { v = undefined; }
            if (v) return v;
            if (Date.now() - t0 > ms) throw new Error(`timeout (${ms} ms) waiting for ${what}`);
            await new Promise(r => setTimeout(r, 250));
        }
    }
    async cookies() { return (await this.send("Network.getCookies")).cookies; }
    async close() { await this.b.send("Target.closeTarget", { targetId: this.targetId }); }
}

// log into the dashboard in the browser through its own form
export async function browserLogin(page, base, user, password) {
    await page.goto(base + "/login");
    await page.wait("document.querySelector('#username') && document.readyState === 'complete'", 30000, "login form");
    await page.eval(`(() => { document.querySelector('#username').value = ${JSON.stringify(user)};
        document.querySelector('#password').value = ${JSON.stringify(password)};
        document.querySelector('form').submit(); return true; })()`);
    await page.wait("location.pathname !== '/login' && document.readyState === 'complete'", 30000, "login redirect");
}

// open n tabs (the dashboard and app pages), then check a further tab still loads: the dashboard's live stream once
// held the browser's per-host connection limit (6) and blocked every new page
export async function tabsTest(b, urls, readyExpr, ms = 30000) {
    const pages = [];
    for (const u of urls) pages.push(await b.page(u));
    for (const p of pages) await p.wait(readyExpr, ms, "tab ready");
    const extra = await b.page(urls[0]);
    const t0 = Date.now();
    await extra.wait(readyExpr, ms, "the extra tab");
    const took = Date.now() - t0;
    for (const p of [...pages, extra]) await p.close().catch(() => {});
    return took;
}

// a valid small JPEG grown past `size` bytes with APP15 segments the decoder skips (not COM: Pillow copies a comment
// into the re-saved picture, and a 64 kB one cannot be written back)
export function inflateJpeg(jpeg, size) {
    const segs = [];
    let total = jpeg.length;
    while (total <= size) {
        const n = 65533;
        const seg = Buffer.alloc(n + 4, 0x41);
        seg[0] = 0xff; seg[1] = 0xef; seg.writeUInt16BE(n + 2, 2);
        segs.push(seg);
        total += seg.length;
    }
    return Buffer.concat([jpeg.subarray(0, 2), ...segs, jpeg.subarray(2)]);
}

// the dashboard's session cookie of an appliance: session-<appliance> or (vmbox W-1) session-<appliance>-<version>
export const isSessionCookie = (name, appliance) => name === appliance || name.startsWith(appliance + "-");
