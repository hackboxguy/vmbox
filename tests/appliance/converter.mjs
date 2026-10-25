// Acceptance test of a booted partkb converter appliance, through its dashboard (http://HOST:PORT): web plan §13
// tests 1 (Settings), 3 (same PDF again: no upload request), 9 (factory reset, with --factory-reset=1) and 10 (stale /
// foreign cookie, 7 tabs), plus login / cookie, the header (Azure not set, library version), the PDF upload through
// the proxy (manifest limit 200 MB), the job without Azure settings, and the empty Cost page. Needs no Azure key and
// never stores a real one (a dummy endpoint / key, removed again).
//
//   node tests/appliance/converter.mjs --host=127.0.0.1 --port=8000 --password=… --pdf=<public datasheet.pdf>
//        [--factory-reset=1] [--out=result.txt]
//   (or: make appliance-test APP=converter HOST=… PORT=… APPLIANCE_PASSWORD=… PDF=…)
// Run against 127.0.0.1 / localhost (or https): the page hashes a dropped file only in a secure context.
import { basename } from "node:path";
import { args, reporter, Http, Browser, browserLogin, tabsTest } from "./lib.mjs";

const a = args();
const base = `http://${a.host}:${a.port}`;
const APP = "/app/partkb-converter";
const COOKIE = a.cookie || "session-partkb-converter";
const r = reporter(a.out);
const DUMMY = { endpoint: "https://acceptance-test.example.invalid", deployment: "model-router", key: "acceptance-dummy-key-0000" };

const http = new Http(base);
const li = await http.login(a.user, a.password);
r.check("login through the dashboard form (302)", li.status === 302, li.status);
r.check(`session cookie is named ${COOKIE}`, http.setCookies.some(c => c.startsWith(COOKIE + "=")), http.setCookies);
const h = await http.req("GET", `${APP}/health`);
r.check("app health through the proxy", h.status === 200 && h.json?.status === "ok", h.json || h.status);
const st = (await http.req("GET", `${APP}/api/status`)).json || {};
r.info(`app ${h.json?.version}; library "${st.library?.version}" (${st.library?.parts} parts); azure "${st.azure?.label}"`);
r.check('header state: "Azure: not set"', st.azure?.state === "not-set", st.azure);
r.check("header names the installed library version", /configurator-/.test(st.library?.version || ""), st.library);
const docs0 = (await http.req("GET", `${APP}/api/documents`)).json?.documents || [];
r.info(`${docs0.length} document(s) on the VM at start`);

// web plan §13 test 10 (first half): a stale or foreign cookie leads to the login page, then the app works
const stale = new Http(base);
stale.jar = { [COOKIE]: "stale-from-a-previous-vm", "session-sbd-configurator": "foreign-cookie" };
const sp = await stale.req("GET", `${APP}/`);
const sa = await stale.req("GET", `${APP}/api/status`);
r.check("stale / foreign cookies: the page redirects to the login (302 /login)",
        sp.status === 302 && /\/login/.test(sp.headers.get("location") || ""), sp.status);
r.info(`stale cookie on ${APP}/api/status: ${sa.status} (the proxy redirects app API paths too; 401 only on the dashboard's own /api/)`);
await stale.login(a.user, a.password);
r.check("after logging in again the app works", (await stale.req("GET", `${APP}/api/status`)).status === 200);

const b = await Browser.launch();
try {
    const p = await b.page();
    await browserLogin(p, base, a.user, a.password);
    const names = (await p.cookies()).map(c => c.name);
    r.check(`browser login keeps the ${COOKIE} cookie`, names.includes(COOKIE), names);
    const posts = [];
    b.handlers.push(m => {
        if (m.method === "Network.requestWillBeSent" && m.params.request.method === "POST" && /\/api\/documents\?/.test(m.params.request.url))
            posts.push(m.params.request.url);
    });
    await p.goto(base + APP + "/");
    const head = await p.wait("(() => { const t = document.querySelector('#h-azure')?.innerText || ''; return /Azure/.test(t) && !/…/.test(t) && t; })()",
                              60000, "header");
    r.check(`page header shows "${head}"`, /not set/.test(head), head);
    const lib = await p.eval("document.querySelector('#h-lib').innerText");
    r.check(`page header shows the library (${lib})`, /configurator-/.test(lib), lib);

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
            const j = (await http.req("POST", `${APP}/api/documents/${d.sha}/start`, { body: "{}", type: "application/json" })).json || {};
            let job = j;
            for (let i = 0; i < 120 && j.id && !["done", "failed", "error", "cancelled"].includes(job.state); i++) {
                await new Promise(z => setTimeout(z, 1000));
                job = (await http.req("GET", `${APP}/api/jobs/${j.id}`)).json || {};
            }
            const text = JSON.stringify({ state: job.state, error: job.error, row: job.row, log: (job.log || []).slice(-3) });
            r.info(`job without Azure settings: ${text.slice(0, 300)}`);
            r.check('the job without Azure settings fails with the clear "Azure: not set" message',
                    job.state !== "done" && /azure/i.test(String(job.error || "") + JSON.stringify(job.log || [])) && /not set/i.test(text), text);
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
