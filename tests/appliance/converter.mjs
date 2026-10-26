// Acceptance test of a booted partkb converter appliance, through its dashboard (http://HOST:PORT): web plan §13
// tests 1 (Settings), 3 (same PDF again: no upload request), 8 (Data tab: bundle download of the VM and its restore,
// on an empty VM), 9 (factory reset, with --factory-reset=1) and 10 (stale / foreign cookie, 7 tabs), the baseline
// upload as a job (--package=<layout-2 zip>: check job, install, header shows its version), plus login / cookie, the
// header, the PDF upload through the proxy (manifest limit 200 MB), start without Azure settings (409 "Azure: not
// set", partkb-0.7.0), and the empty Cost page. Needs no Azure key and never stores a real one (a dummy endpoint /
// key, removed again).
//
//   node tests/appliance/converter.mjs --host=127.0.0.1 --port=8010 --password=… --pdf=<public datasheet.pdf>
//        [--package=<layout-2 library package>] [--factory-reset=1] [--parts=0 before partkb-0.8.0] [--out=result.txt]
//   node tests/appliance/converter.mjs … --bundle=<data bundle .tar>   (only the restore rehearsal, twice; the verify must
//        report no warnings, i.e. content-hash checked, unless --allow-warnings=1)
//   (or: make appliance-test APP=converter HOST=… PORT=… APPLIANCE_PASSWORD=… PDF=…)
// Run against 127.0.0.1 / localhost (or https): the page hashes a dropped file only in a secure context.
import { basename } from "node:path";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
import { args, reporter, Http, Browser, browserLogin, tabsTest, isSessionCookie } from "./lib.mjs";

const a = args();
const base = `http://${a.host}:${a.port}`;
const APP = "/app/partkb-converter";
const COOKIE = a.cookie || "session-partkb-converter";
const r = reporter(a.out);
const DUMMY = { endpoint: "https://acceptance-test.example.invalid", deployment: "model-router", key: "acceptance-dummy-key-0000" };

const http = new Http(base);
const li = await http.login(a.user, a.password);
r.check("login through the dashboard form (302)", li.status === 302, li.status);
r.check(`session cookie is named ${COOKIE}[-<version>] (${(http.setCookies[0] || "").split("=")[0]})`, http.setCookies.some(c => isSessionCookie(c.split("=")[0], COOKIE)), http.setCookies);
const h = await http.req("GET", `${APP}/health`);
r.check("app health through the proxy", h.status === 200 && h.json?.status === "ok", h.json || h.status);
const st = (await http.req("GET", `${APP}/api/status`)).json || {};
r.info(`app ${h.json?.version}; library "${st.library?.version}" (${st.library?.parts} parts); azure "${st.azure?.label}"`);
r.check('header state: "Azure: not set"', st.azure?.state === "not-set", st.azure);
r.check("header names the installed library version", /configurator-/.test(st.library?.version || ""), st.library);
const docs0 = (await http.req("GET", `${APP}/api/documents`)).json?.documents || [];
r.info(`${docs0.length} document(s) on the VM at start`);

// the Parts tab's API (partkb-0.8.0 and later; --parts=0 for older images): one row per working-library record,
// the CSV with a header line, a record by id
if (a.parts !== "0" && !a.bundle) {
    const pj = await http.req("GET", `${APP}/api/parts`);
    const pd = pj.json || {};
    r.check(`Parts: api/parts count ${pd.count} = the header's parts count ${st.library?.parts}, one row each`,
            pj.status === 200 && pd.count === st.library?.parts && (pd.parts || []).length === pd.count, [pj.status, pd.count, st.library]);
    const csv = await http.req("GET", `${APP}/api/parts?format=csv`);
    const rows = parseCsv(csv.buf.toString("utf8"));
    r.check(`Parts: CSV (${csv.headers.get("content-type")}) has count + 1 lines (${rows.length})`,
            csv.status === 200 && /text\/csv/.test(csv.headers.get("content-type") || "") && rows.length === pd.count + 1, [csv.status, rows.length]);
    const id = (pd.parts || [])[0]?.id;
    const one = await http.req("GET", `${APP}/api/parts/${encodeURIComponent(id)}`);
    const none = await http.req("GET", `${APP}/api/parts/zz-no-such-part-acceptance`);
    r.check(`Parts: api/parts/${id} answers the record, an unknown id 404`, one.status === 200 && none.status === 404, [one.status, none.status]);
    if (!docs0.length) {
        const s = pd.summary || {};
        const changed = (pd.parts || []).filter(p => p.baseline !== "unchanged").map(p => `${p.id}:${p.baseline}`);
        r.check(`Parts on an empty converter: 0 datasheets on this appliance (${s.datasheet_on_appliance}), every row unchanged against the baseline`,
                s.datasheet_on_appliance === 0 && s.baseline && !changed.length, { summary: s, changed: changed.slice(0, 5) });
    }
}

// --bundle=<tar>: the restore rehearsal only (Fable v5 W-2): upload in 64 MB chunks (each its own request with
// Content-Length and X-Chunk-SHA256, under the manifest's 128 MB / 600 s), verify, confirm; twice (the second
// restore replaces the previous generation); the document list and the Cost tab show the bundle's counts.
if (a.bundle) {
    const buf = readFileSync(a.bundle);
    const CH = 64 * 1024 * 1024;
    for (const round of [1, 2]) {
        const t0 = Date.now(), times = [];
        let n = 0, okc = true;
        for (let off = 0; off < buf.length; off += CH, n++) {
            const part = buf.subarray(off, off + CH), t = Date.now();
            const up = await http.req("PUT", `${APP}/api/bundle/upload/${n}`, { body: part, type: "application/octet-stream",
                headers: { "X-Chunk-SHA256": createHash("sha256").update(part).digest("hex") } });
            times.push(((Date.now() - t) / 1000).toFixed(1));
            okc &&= up.status === 200 && up.json?.bytes === part.length;
            if (up.status !== 200) r.info(`chunk ${n}: ${up.status} ${JSON.stringify(up.json).slice(0, 200)}`);
        }
        r.check(`restore ${round}: ${(buf.length / 1048576).toFixed(0)} MB in ${n} chunks of <= 64 MB through the proxy (s per chunk: ${times.join(", ")})`, okc);
        let t = Date.now();
        const ver = await http.req("POST", `${APP}/api/bundle/verify`, { body: JSON.stringify({ chunks: n }), type: "application/json" });
        const vs = ((Date.now() - t) / 1000).toFixed(1);
        r.check(`restore ${round}: verified in ${vs} s (${JSON.stringify(ver.json?.bundle?.counts || {})})`, ver.status === 200 && ver.json?.bundle, ver.json || ver.status);
        // partkb-0.7.2: a bundle with per-file content hashes (file_sha256) verifies without warnings; a size-only
        // check (an older bundle, or an image before 0.7.2) answers with a warning
        if (a["allow-warnings"] !== "1")
            r.check(`restore ${round}: verified with content hashes (no warnings)`, ver.status === 200 && !(ver.json?.bundle?.warnings || []).length,
                    ver.json?.bundle?.warnings);
        t = Date.now();
        const res = await http.req("POST", `${APP}/api/bundle/restore`, { body: JSON.stringify({ confirm: true }), type: "application/json" });
        const rs = ((Date.now() - t) / 1000).toFixed(1);
        r.check(`restore ${round}: confirmed in ${rs} s, ${(res.json?.restored || []).length} parts swapped in, previous generation ${res.json?.kept_generation}`,
                res.status === 200 && (res.json?.restored || []).length > 0, res.json || res.status);
        const want = ver.json?.bundle?.counts || {};
        const docs = (await http.req("GET", `${APP}/api/documents`)).json || {};
        const cost = (await http.req("GET", `${APP}/api/cost`)).json || {};
        const ndocs = docs.total ?? (docs.documents || []).length;
        r.check(`restore ${round}: document list shows the bundle's ${want.documents} documents (${ndocs})`, ndocs === want.documents, { docs: ndocs, want });
        r.check(`restore ${round}: Cost tab shows the bundle's ${want.calls} calls / USD ${want.cost_usd} (${cost.calls} / ${cost.total_usd})`,
                cost.calls === want.calls && Math.abs((cost.total_usd || 0) - (want.cost_usd || 0)) < 0.01, { cost: [cost.calls, cost.total_usd], want });
        r.info(`restore ${round} total ${((Date.now() - t0) / 1000).toFixed(0)} s`);
    }
    process.exit(r.done() ? 1 : 0);
}

const sleep = ms => new Promise(z => setTimeout(z, ms));
async function waitJob(id, ms = 600000) {
    const t0 = Date.now();
    for (;;) {
        const j = (await http.req("GET", `${APP}/api/jobs/${id}`)).json || {};
        if (["done", "failed", "error", "skipped", "cancelled"].includes(j.state) || Date.now() - t0 > ms) return j;
        await sleep(1000);
    }
}

// web plan §13 test 8 on the VM as it is (empty before the first upload): download the data bundle through the
// proxy, upload it again in bounded chunks (each with Content-Length and its SHA-256), verify, restore
const data0 = (await http.req("GET", `${APP}/api/data`)).json || {};
r.info(`Data tab: ${JSON.stringify(data0.counts || {})}, restorable ${data0.restorable}`);
const bun = await http.req("GET", `${APP}/api/bundle`);
r.check(`Data: bundle download (${(bun.buf.length / 1024).toFixed(0)} kB tar)`, bun.status === 200 && bun.buf.length > 1024
        && bun.buf.subarray(257, 262).toString() === "ustar", bun.status);
if (bun.status === 200) {
    const CH = 8 * 1024 * 1024;
    let n = 0, okc = true;
    for (let off = 0; off < bun.buf.length; off += CH, n++) {
        const part = bun.buf.subarray(off, off + CH);
        const up = await http.req("PUT", `${APP}/api/bundle/upload/${n}`, { body: part, type: "application/octet-stream",
            headers: { "X-Chunk-SHA256": createHash("sha256").update(part).digest("hex") } });
        okc &&= up.status === 200;
    }
    r.check(`Data: bundle uploaded again in ${n} chunk(s)`, okc);
    const ver = await http.req("POST", `${APP}/api/bundle/verify`, { body: JSON.stringify({ chunks: n }), type: "application/json" });
    r.check("Data: bundle verified", ver.status === 200 && ver.json?.bundle, ver.json || ver.status);
    const res = await http.req("POST", `${APP}/api/bundle/restore`, { body: JSON.stringify({ confirm: true }), type: "application/json" });
    r.check(`Data: bundle restored (${(res.json?.restored || []).join(", ")}), same counts`,
            res.status === 200 && JSON.stringify(res.json?.counts) === JSON.stringify(data0.counts), res.json || res.status);
}

// the baseline upload as a job: package -> baseline-check job -> install -> the header names its version
if (a.package) {
    const zbuf = readFileSync(a.package);
    const man = JSON.parse(execZipManifest(zbuf));
    const up = await http.req("POST", `${APP}/api/library-package`, { body: zbuf, type: "application/zip" });
    r.check(`baseline: package ${basename(a.package)} accepted, check job queued`, up.status === 200 && up.json?.id, up.json || up.status);
    if (up.json?.id) {
        const j = await waitJob(up.json.id);
        r.check(`baseline: check job ${j.state} (${(j.row?.check || []).slice(-1)[0] || j.error || ""})`, j.state === "done" && j.row?.ok, { state: j.state, row: j.row, error: j.error });
        if (j.row?.ok) {
            const ins = await http.req("POST", `${APP}/api/library-package/install`, { body: JSON.stringify({ job: j.id }), type: "application/json" });
            r.check("baseline: installed", ins.status === 200, ins.json || ins.status);
            const st2 = (await http.req("GET", `${APP}/api/status`)).json || {};
            r.check(`baseline: header shows ${man.library_version} ("${st2.library?.version}")`,
                    (st2.library?.version || "").includes(man.library_version), st2.library);
        }
    }
}

// web plan §13 test 10 (first half): a stale or foreign cookie leads to the login page, then the app works
const stale = new Http(base);
stale.jar = { [(http.setCookies[0] || COOKIE).split("=")[0]]: "stale-from-a-previous-vm", "session-sbd-configurator": "foreign-cookie" };
const sp = await stale.req("GET", `${APP}/`);
const sa = await stale.req("GET", `${APP}/api/status`);
r.check("stale / foreign cookies: the page redirects to the login (302 /login)",
        sp.status === 302 && /\/login/.test(sp.headers.get("location") || ""), sp.status);
r.check("stale / foreign cookies: an app API path answers 401 (JSON), not the login page (vmbox Y-1)", sa.status === 401 && sa.json?.error, [sa.status, sa.json]);
await stale.login(a.user, a.password);
r.check("after logging in again the app works", (await stale.req("GET", `${APP}/api/status`)).status === 200);

const b = await Browser.launch();
try {
    const p = await b.page();
    await browserLogin(p, base, a.user, a.password);
    const names = (await p.cookies()).map(c => c.name);
    r.check(`browser login keeps the ${COOKIE} cookie`, names.some(n => isSessionCookie(n, COOKIE)), names);
    const posts = [];
    b.handlers.push(m => {
        if (m.method === "Network.requestWillBeSent" && m.params.request.method === "POST" && /\/api\/documents\?/.test(m.params.request.url))
            posts.push(m.params.request.url);
    });
    await p.goto(base + APP + "/");
    const head = await p.wait("(() => { const t = document.querySelector('#h-azure')?.innerText || ''; return /Azure/.test(t) && !/…/.test(t) && t; })()",
                              60000, "header");
    r.check(`page header shows "${head}"`, /not set/.test(head), head);
    if (a.parts !== "0") {
        await p.eval("document.querySelector('[data-tab=parts]').click()");
        const line = await p.wait("(() => { const t = document.querySelector('#pt-summary')?.innerText || ''; return /parts ·/.test(t) && t; })()",
                                  60000, "Parts summary");
        r.check(`Parts tab: summary line "${line.split("·").slice(0, 2).join("·").trim()} …"`,
                line.startsWith(`${st.library?.parts} parts ·`) && /on this appliance/.test(line), line);
        await p.eval("document.querySelector('[data-tab=datasheets]').click()");
    }
    const lib = await p.eval("document.querySelector('#h-lib').innerText");
    const libNow = ((await http.req("GET", `${APP}/api/status`)).json || {}).library?.version || "?";
    r.check(`page header shows the working library (${lib})`, lib.includes(libNow), { header: lib, api: libNow });

    // web plan §13 test 1: Settings save -> reload shows only the hint -> remove
    await p.eval(`(() => { document.querySelector('[data-tab=settings]').click();
        document.querySelector('#az-endpoint').value = ${JSON.stringify(DUMMY.endpoint)};
        document.querySelector('#az-deployment').value = ${JSON.stringify(DUMMY.deployment)};
        document.querySelector('#az-key').value = ${JSON.stringify(DUMMY.key)};
        document.querySelector('#az-save').click(); return true; })()`);
    const saved = await http.req("GET", `${APP}/api/settings/azure`);
    let ok = false;
    for (let i = 0; i < 40 && !ok; i++) {
        const s = (await http.req("GET", `${APP}/api/settings/azure`)).json;
        ok = s?.key_set && s.endpoint === DUMMY.endpoint;
        if (!ok) await new Promise(z => setTimeout(z, 250));
    }
    r.check("Settings: endpoint and key saved", ok, saved.json);
    await p.goto(base + APP + "/");
    await p.wait("document.querySelector('#az-hint') && /…/.test(document.querySelector('#az-hint').innerText)", 30000, "key hint");
    const field = await p.eval("({ key: document.querySelector('#az-key').value, hint: document.querySelector('#az-hint').innerText, endpoint: document.querySelector('#az-endpoint').value })");
    r.check(`Settings after reload: key field empty, only the hint (${field.hint})`,
            field.key === "" && field.hint.includes(DUMMY.key.slice(-4)) && !JSON.stringify(field).includes(DUMMY.key.slice(0, 12)), field);
    await p.eval("document.querySelector('[data-tab=settings]').click(), document.querySelector('#az-remove').click(), true");   // confirm() accepted
    let gone = false;
    for (let i = 0; i < 40 && !gone; i++) {
        gone = (await http.req("GET", `${APP}/api/settings/azure`)).json?.key_set === false;
        if (!gone) await new Promise(z => setTimeout(z, 250));
    }
    r.check("Settings: Remove deletes key and endpoint", gone);

    // PDF drop: upload through the proxy; the same file again -> notice, no second upload (web plan §13 test 3)
    if (a.pdf) {
        await p.goto(base + APP + "/");
        await p.wait("document.querySelector('#files') && document.querySelector('#h-azure') && !/…/.test(document.querySelector('#h-azure').innerText)", 30000, "datasheets tab");
        const drop = async () => {
            const doc = await p.send("DOM.getDocument", {});
            const { nodeId } = await p.send("DOM.querySelector", { nodeId: doc.root.nodeId, selector: "#files" });
            await p.eval("document.querySelector('#notices').innerHTML = '', true");
            await p.send("DOM.setFileInputFiles", { nodeId, files: [a.pdf] });
            // the final notice, not the "uploading…" / "checking…" progress line
            return p.wait("(() => { const t = (document.querySelector('#notices') || {}).innerText || ''; return t && !/uploading|checking|hashing/i.test(t) && t; })()",
                          300000, "upload answer");
        };
        const before = posts.length;
        const n1 = await drop();
        const known = /already/.test(n1);
        r.info(`first drop of ${basename(a.pdf)}: "${n1.replace(/\s+/g, " ").slice(0, 160)}"`);
        r.check(known ? "first drop: the file was already on the VM (no upload needed)"
                      : `first drop: uploaded through the proxy (${posts.length - before} upload request, manifest limit 200 MB)`,
                known ? posts.length === before : posts.length - before === 1 && !/error|failed|413/i.test(n1), n1);
        const mid = posts.length;
        const n2 = await drop();
        r.check("same file again: \"already uploaded\" notice, no upload request (hash checked first)",
                /already/.test(n2) && posts.length === mid, { notice: n2.slice(0, 160), uploads: posts.length - mid });
        const list = (await http.req("GET", `${APP}/api/documents`)).json?.documents || [];
        const d = list.find(x => n1.includes(x.short) || n2.includes(x.short)) || list[list.length - 1];
        r.check(`the document is listed (${d?.short}, state ${d?.state_label})`, !!d, list.length);
        if (d) {
            const doc = JSON.stringify((await http.req("GET", `${APP}/api/documents/${d.sha}`)).json || {});
            r.check('the document shows "classified without a model"', /classified without a model/i.test(doc + n1), doc.slice(0, 200));
            const sj = await http.req("POST", `${APP}/api/documents/${d.sha}/start`, { body: "{}", type: "application/json" });
            r.info(`start without Azure settings: ${sj.status} ${JSON.stringify(sj.json).slice(0, 200)}`);
            r.check('start without Azure settings answers 409 "Azure: not set" (no job)',
                    sj.status === 409 && /Azure: not set/.test(sj.json?.error || ""), [sj.status, sj.json]);
        }
    }

    const cost = (await http.req("GET", `${APP}/api/cost`)).json || {};
    r.check("Cost page: no calls, total 0 (no key on the VM)", (cost.rows || []).length === 0 && cost.total_usd === 0, cost);
    await p.close();

    // web plan §13 test 10 (second half): 7 tabs (dashboard + converter), a new tab still loads
    const ready = "document.readyState === 'complete' && document.body && document.body.innerText.length > 20";
    const took = await tabsTest(b, [base + "/", ...Array(6).fill(base + APP + "/")], ready, 60000);
    r.check(`7 tabs open (dashboard + 6 converter tabs), an 8th tab loads (${took} ms)`, took < 30000, took);
} catch (e) {
    r.check("browser steps", false, e.message);
} finally {
    await b.close();
}

// web plan §13 test 9: factory reset -> Settings "not set", document list empty (the VM reboots)
if (a["factory-reset"] === "1") {
    const fr = await http.req("POST", "/api/factory-reset", { body: "{}", type: "application/json" });
    r.check("factory reset accepted (the VM reboots)", fr.status === 200, fr.json || fr.status);
    await new Promise(z => setTimeout(z, 15000));
    const back = new Http(base);
    let up = false;
    for (let i = 0; i < 180 && !up; i++) {
        try { up = (await back.req("GET", "/login")).status === 200; } catch { up = false; }
        if (!up) await new Promise(z => setTimeout(z, 1000));
    }
    await back.login(a.user, a.password);
    let s2 = null;
    for (let i = 0; i < 120 && !s2; i++) {
        const x = await back.req("GET", `${APP}/api/status`).catch(() => ({}));
        if (x.status === 200) s2 = x.json; else await new Promise(z => setTimeout(z, 1000));
    }
    const az = (await back.req("GET", `${APP}/api/settings/azure`)).json || {};
    const docs = (await back.req("GET", `${APP}/api/documents`)).json?.documents || [];
    r.check('after the factory reset: "Azure: not set", no key or endpoint, 0 documents',
            up && s2?.azure?.state === "not-set" && !az.key_set && !az.endpoint && docs.length === 0, { up, azure: s2?.azure, az, docs: docs.length });
}
process.exit(r.done() ? 1 : 0);

// RFC 4180 rows: a quoted field may hold commas, newlines and doubled quotes; a trailing newline ends the last row
function parseCsv(text) {
    const rows = [];
    let row = [], f = "", q = false;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (q) {
            if (c === '"' && text[i + 1] === '"') { f += '"'; i++; }
            else if (c === '"') q = false;
            else f += c;
        } else if (c === '"') q = true;
        else if (c === ",") { row.push(f); f = ""; }
        else if (c === "\n" || c === "\r") {
            if (c === "\r" && text[i + 1] === "\n") i++;
            row.push(f); rows.push(row); row = []; f = "";
        } else f += c;
    }
    if (f || row.length) { row.push(f); rows.push(row); }
    return rows;
}

// manifest.json of a ZIP (stored or deflated), without a zip library: the central directory names its offset
function execZipManifest(buf) {
    const { inflateRawSync } = require("node:zlib");
    let eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
    let cd = buf.readUInt32LE(eocd + 16), count = buf.readUInt16LE(eocd + 10);
    for (let i = 0; i < count; i++) {
        const method = buf.readUInt16LE(cd + 10), csize = buf.readUInt32LE(cd + 20), nlen = buf.readUInt16LE(cd + 28);
        const xlen = buf.readUInt16LE(cd + 30), clen = buf.readUInt16LE(cd + 32), loc = buf.readUInt32LE(cd + 42);
        const name = buf.subarray(cd + 46, cd + 46 + nlen).toString();
        if (name === "manifest.json") {
            const start = loc + 30 + buf.readUInt16LE(loc + 26) + buf.readUInt16LE(loc + 28);
            const raw = buf.subarray(start, start + csize);
            return (method === 8 ? inflateRawSync(raw) : raw).toString();
        }
        cd += 46 + nlen + xlen + clen;
    }
    throw new Error("no manifest.json in the package");
}
