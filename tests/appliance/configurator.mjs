// Acceptance test of a booted SBD configurator appliance, through its dashboard (http://HOST:PORT, the forwarded
// system-mgmt port): login and cookie, the manifest proxy limits (photo upload over 1 MB, default 1 MB elsewhere),
// a profile clone / PUT / render / export, "My data" download and load, the "Library…" dialog (on by default since
// configurator-0.16.0; with --package=<zip> --part=<id> it runs once: check, install, app restart, record live,
// remove, restart; --overlay=0 for an older release where it is off), a dead session reloading the page to the
// login (0.16.0), and 7 open tabs with a further tab still loading.
//
//   node tests/appliance/configurator.mjs --host=127.0.0.1 --port=8000 --password=… [--out=result.txt]
//   (or: make appliance-test APP=configurator HOST=… PORT=… APPLIANCE_PASSWORD=…)
import { readFileSync } from "node:fs";
import { args, reporter, Http, Browser, browserLogin, tabsTest, inflateJpeg } from "./lib.mjs";

const a = args();
const base = `http://${a.host}:${a.port}`;
const APP = "/app/sbd-configurator";
const SEED = a.seed || "honda-nq3-15-6";
const COOKIE = a.cookie || "session-sbd-configurator";
const r = reporter(a.out);
const id = `zz-acc-${Date.now().toString(36)}`;

const http = new Http(base);
const li = await http.login(a.user, a.password);
r.check(`login through the dashboard form (302)`, li.status === 302, li.status);
r.check(`session cookie is named ${COOKIE}`, http.setCookies.some(c => c.startsWith(COOKIE + "=")), http.setCookies);

const h = await http.req("GET", `${APP}/health`);
r.check("app health through the proxy", h.status === 200 && h.json?.status === "ok", h.json || h.status);
r.info(`app version ${h.json?.version}, library_format ${h.json?.library_format}, parts ${h.json?.parts}`);

// photo upload over the 1 MB default: the manifest's proxy.limits allow 512 MB on /api/photos/
const ph = await http.req("GET", `${APP}/api/photos/nq1-v11`);
const thumb = ph.json?.photos?.[0]?.thumb;
const small = thumb ? (await http.req("GET", APP + thumb)).buf : null;
if (r.check("a repository photo thumbnail is served", small && small[0] === 0xff && small[1] === 0xd8, ph.status)) {
    const big = inflateJpeg(small, 1.5 * 1024 * 1024);
    const up = await http.req("POST", `${APP}/api/photos/${id}?subject=board&side=front`, { body: big, type: "image/jpeg" });
    r.check(`photo upload of ${(big.length / 1048576).toFixed(1)} MB through the proxy (manifest limit 512 MB)`,
            up.status === 201, up.json || up.status);
    if (up.json?.file) {
        const del = await http.req("DELETE", `${APP}/api/photos/${id}/${up.json.file}`);
        r.check("uploaded photo deleted", del.status === 200, del.status);
    }
    const comp = await http.req("POST", `${APP}/api/compose`, { body: big, type: "application/json" });
    r.check("a 1.5 MB body on a path without a manifest limit is refused by the proxy (413, default 1 MB)",
            comp.status === 413, comp.status);
}

// profile: clone, get, PUT, render, export
const cl = await http.req("POST", `${APP}/api/profiles/${SEED}/clone`, { body: JSON.stringify({ new_id: id }), type: "application/json" });
r.check(`clone ${SEED} -> ${id}`, cl.status === 201, cl.json || cl.status);
const g = await http.req("GET", `${APP}/api/profiles/${id}`);
const put = await http.req("PUT", `${APP}/api/profiles/${id}`, { body: JSON.stringify(g.json?.profile), type: "application/json" });
r.check("PUT the profile", put.status === 200, put.json || put.status);
const png = await http.req("GET", `${APP}/api/profiles/${id}/render.png`);
r.check("render.png (resvg)", png.status === 200 && png.buf.subarray(1, 4).toString() === "PNG", png.status);
const ex = await http.req("GET", `${APP}/api/profiles/${id}/export.zip`);
r.check("export.zip", ex.status === 200 && ex.buf.subarray(0, 2).toString() === "PK", ex.status);

// My data: download (holds the profile), delete the profile, load the pack -> the profile is back
const md = await http.req("GET", `${APP}/api/user-data`);
r.check(`"My data" download (${(md.buf.length / 1024).toFixed(0)} kB)`, md.status === 200 && md.buf.subarray(0, 2).toString() === "PK", md.status);
await http.req("DELETE", `${APP}/api/profiles/${id}`);
const ld = await http.req("POST", `${APP}/api/user-data`, { body: md.buf, type: "application/zip" });
r.check(`"My data" load: the deleted profile is imported again`,
        ld.status === 200 && (ld.json?.imported || []).some(x => x.name === id), ld.json || ld.status);
const dl = await http.req("DELETE", `${APP}/api/profiles/${id}`);
r.check("test profile removed", dl.status === 200, dl.status);

// library package: off without the flag; with --overlay=1 the dialog runs once
const lp = await http.req("GET", `${APP}/api/library-package`);
const overlay = a.overlay !== "0";
r.check(`library-package endpoint ${overlay ? "enabled" : "off (404)"}`, overlay ? lp.status === 200 : lp.status === 404, lp.status);

const b = await Browser.launch();
try {
    const p = await b.page();
    await browserLogin(p, base, a.user, a.password);
    const names = (await p.cookies()).map(c => c.name);
    r.check(`browser login keeps the ${COOKIE} cookie`, names.includes(COOKIE), names);
    await p.goto(base + APP + "/");
    await p.wait("document.querySelectorAll('#plist li').length > 0 && typeof document.querySelector('#btn-mydata').onclick === 'function'",
                 60000, "profile list");
    // the button's own probe (GET /api/library-package) settles within a second; wait on the expected state
    const want = overlay ? "!document.querySelector('#btn-libpkg').classList.contains('hidden')"
                         : "fetch('api/library-package').then(r => r.status === 404 && document.querySelector('#btn-libpkg').classList.contains('hidden'))";
    let shown;
    try { shown = await p.wait(want, 15000, "Library button state"); } catch { shown = false; }
    r.check(`"Library…" button ${overlay ? "shown" : "absent"} in the page`, !!shown);

    if (overlay && a.package) {
        await p.eval("document.querySelector('#btn-libpkg').click(), true");
        await p.wait("document.querySelector('#lp-file')", 15000, "library dialog");
        const doc = await p.send("DOM.getDocument", {});
        const { nodeId } = await p.send("DOM.querySelector", { nodeId: doc.root.nodeId, selector: "#lp-file" });
        await p.send("DOM.setFileInputFiles", { nodeId, files: [a.package] });
        await p.eval("document.querySelector('#lp-check').click(), true");
        const res = await p.wait("document.querySelector('#lp-apply') ? 'ok' : (document.querySelector('#lp-report h3') ? document.querySelector('#lp-report').innerText : '')",
                                 180000, "package check");
        r.check("dialog: the package checks clean", res === "ok", res);
        if (res === "ok") {
            await p.eval("document.querySelector('#lp-apply').click(), true");
            const msg = await p.wait("[...document.querySelectorAll('#lp-report .status-success')].map(e => e.innerText).find(t => /after a restart/.test(t)) || (document.querySelector('#lp-msg') || {}).innerText",
                                     60000, "install message");
            r.check("dialog: installed (takes effect after restart)", /after a restart/.test(msg), msg);
            const restart = async () => {
                const rs = await http.req("POST", `/api/apps/sbd-configurator/restart`, { type: "application/json", body: "{}" });
                for (let i = 0; i < 120; i++) {
                    await new Promise(z => setTimeout(z, 1000));
                    const hh = await http.req("GET", `${APP}/health`).catch(() => ({}));
                    if (hh.status === 200) return rs.status;
                }
                return -1;
            };
            r.check("app restarted from the dashboard API", (await restart()) === 200);
            const parts = await http.req("GET", `${APP}/api/library/parts`);
            const st = await http.req("GET", `${APP}/api/library-package`);
            r.check(`after the restart the overlay is the library (${a.part || "?"} listed, active)`,
                    st.json?.active && (!a.part || (parts.json || []).some(x => x.id === a.part)), st.json);
            await p.goto(base + APP + "/");
            await p.wait("!document.querySelector('#btn-libpkg').classList.contains('hidden')", 30000, "Library button");
            await p.eval("document.querySelector('#btn-libpkg').click(), true");
            await p.wait("document.querySelector('#lp-remove')", 15000, "remove button");
            await p.eval("document.querySelector('#lp-remove').click(), true");      // confirm() auto-accepted
            const rm = await p.wait("[...document.querySelectorAll('#lp-report .status-success')].map(e => e.innerText).find(t => /removed/.test(t)) || (document.querySelector('#lp-msg') || {}).innerText",
                                    60000, "remove message");
            r.check("dialog: removed", /removed/.test(rm), rm);
            r.check("app restarted again", (await restart()) === 200);
            const parts2 = await http.req("GET", `${APP}/api/library/parts`);
            const st2 = await http.req("GET", `${APP}/api/library-package`);
            r.check("after the restart the release's library is back", !st2.json?.active && !st2.json?.installed
                    && (!a.part || !(parts2.json || []).some(x => x.id === a.part)), st2.json);
        }
    }
    // a dead dashboard session: the next API call answers 401 (vmbox) and the page reloads to the login (0.16.0)
    if (a.reload401 !== "0") {
        await p.goto(base + APP + "/");
        await p.wait("document.querySelectorAll('#plist li').length > 0", 60000, "profile list");
        await p.send("Network.deleteCookies", { name: COOKIE, url: base + "/" });
        await p.eval("api('GET', '/api/profiles').catch(() => {}), true");
        let loc;
        try { loc = await p.wait("location.pathname === '/login' && location.pathname", 20000, "login page"); } catch { loc = await p.eval("location.pathname"); }
        r.check("dead session: an API call answers 401 and the page reloads to the dashboard login", loc === "/login", loc);
        await browserLogin(p, base, a.user, a.password);
    }
    await p.close();
    const ready = "document.readyState === 'complete' && document.body && document.body.innerText.length > 20";
    const took = await tabsTest(b, [base + "/", ...Array(6).fill(base + APP + "/")], ready, 60000);
    r.check(`7 tabs open (dashboard + 6 app tabs), an 8th tab loads (${took} ms)`, took < 30000, took);
} catch (e) {
    r.check("browser steps", false, e.message);
} finally {
    await b.close();
}
process.exit(r.done() ? 1 : 0);
