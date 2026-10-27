// Acceptance test of a booted HDR processor appliance, through its dashboard (http://HOST:PORT, the forwarded
// system-mgmt port; sdr-hdr-shootout-demo web-app/docs/acceptance-0.1.md):
//   - login, the session-hdr-processor cookie, the app's health through the proxy, a master on the VM;
//   - in the browser: an OLED profile with "local dimming" selected is refused with the mismatch message, with OLED it
//     shows the card (type, resolution, peak, black, ABL table); Pi player, 2-minute excerpt, Prepare -> the progress
//     card moves through the stages -> Download clip / report work; the report's LUT hashes are written to
//     --report-out (compare them with a PC render of the same command);
//   - --master-upload=FILE: the file uploaded in the browser through the proxy (Masters tab, up to 4 GB), its probe
//     card, deleted again; deleting the only master refused (409);
//   - --queue=1: two jobs, the queued one deleted, the running one cancelled (state cancelled, no clip).
//
//   node tests/appliance/hdr-processor.mjs --host=127.0.0.1 --port=38000 --password=… --oled-profile=P.json
//        [--master-upload=peru-hdr10+.mp4] [--queue=1] [--skip-render=1] [--report-out=r.json] [--out=result.txt]
//        [--mode=hdr10plus|hdr10-static|sdr-today|sdr-managed|pair] (web app 0.2: the Mode select; default hdr10plus)
//        [--timeout-min=180]
import { resolve } from "node:path";
import { readFileSync, writeFileSync, statSync } from "node:fs";
import { args, reporter, Http, Browser, browserLogin, isSessionCookie } from "./lib.mjs";

const a = args();
const base = `http://${a.host}:${a.port}`;
const APP = "/app/hdr-processor";
const COOKIE = a.cookie || "session-hdr-processor";
const r = reporter(a.out);

const http = new Http(base);
const li = await http.login(a.user, a.password);
r.check("login through the dashboard form (302)", li.status === 302, li.status);
r.check(`session cookie is named ${COOKIE}[-<version>]`, http.setCookies.some(c => isSessionCookie(c.split("=")[0], COOKIE)), http.setCookies);
const h = await http.req("GET", `${APP}/health`);
r.check("app health through the proxy", h.status === 200 && h.json?.status === "ok", h.json || h.status);
const st = await http.req("GET", `${APP}/api/state`);
const masters = st.json?.masters || [];
r.check("at least one master on the VM", masters.length >= 1, st.json);
r.info(`masters: ${masters.map(m => `${m.name} ${m.width}x${m.height} ${m.frames} frames HDR10+ ${m.hdr10plus}`).join("; ")}`);
r.info(`versions: ${JSON.stringify(st.json?.versions)}`);
const unauth = await new Http(base).req("GET", `${APP}/api/state`);
r.check("app API without login answers 401", unauth.status === 401, unauth.status);

const b = await Browser.launch();
try {
    const p = await b.page();
    await browserLogin(p, base, a.user, a.password);
    await p.goto(base + APP + "/");
    await p.wait("document.querySelector('#dtype') && document.querySelector('#dtype').options.length > 0", 30000, "Prepare form");
    if (a["oled-profile"]) {
        const setFile = async (sel, file) => {
            const doc = await p.send("DOM.getDocument", {});
            const { nodeId } = await p.send("DOM.querySelector", { nodeId: doc.root.nodeId, selector: sel });
            await p.send("DOM.setFileInputFiles", { nodeId, files: [resolve(file)] });   // absolute path for CDP
        };
        await p.eval("document.querySelector('#dtype').value = 'localdimming', true");
        await setFile("#profile-file", a["oled-profile"]);
        const mis = await p.wait("!document.querySelector('#profile-error').classList.contains('hidden') && document.querySelector('#profile-error').innerText", 60000, "mismatch error");
        r.check("OLED profile with 'local dimming' selected: refused", mis === "profile is oled, you selected local dimming", mis);
        await p.eval("document.querySelector('#dtype').value = 'oled', true");
        await setFile("#profile-file", a["oled-profile"]);
        await p.wait("!document.querySelector('#profile-table').classList.contains('hidden')", 60000, "profile card");
        const card = await p.eval("document.querySelector('#profile-table').innerText");
        r.check("card: type OLED, 2560×1440, peaks, blacks, ABL table present",
                /OLED/.test(card) && /2560×1440/.test(card) && /peak 10 %/.test(card) && /black full screen/.test(card) && /ABL table\s+present/.test(card), card);
        r.check("display type read-only once the profile is loaded", await p.eval("document.querySelector('#dtype').disabled"));
        const modes = await p.eval("document.querySelector('#mode') ? [...document.querySelector('#mode').options].map(o => o.value) : []");
        r.info(`modes offered: ${modes.join(", ") || "(no Mode select: web app 0.1)"}`);
        if (modes.length) r.check("SDR modes offered (libplacebo renders here)", ["sdr-today", "sdr-managed", "pair"].every(m => modes.includes(m)), modes);
        const mode = a.mode || "hdr10plus";
        await p.eval(`document.querySelector('#player').value = 'pi'; document.querySelector('#length').value = 'excerpt'; ` +
                     `if (document.querySelector('#mode')) document.querySelector('#mode').value = '${mode}'; ` +
                     `document.querySelector('#length').dispatchEvent(new Event('change')); true`);
        const cmd = await p.wait("/--to=2:00/.test(document.querySelector('#command').innerText) && document.querySelector('#command').innerText", 20000, "command line");
        r.check("command line shown: h264, 1920x1080, crf 18, --to=2:00", /--codec=h264/.test(cmd) && /--display-res=1920x1080/.test(cmd) && /--crf=18/.test(cmd), cmd);
        r.info(`command: ${cmd.split("\n")[0]}`);
        if (!a["skip-render"]) {
            const t0 = Date.now();
            await p.eval("document.querySelector('#prepare').click(), true");
            const stages = new Set();
            let res = "";
            for (;;) {
                const s = await p.eval("(document.querySelector('#job-detail') || {}).innerText || ''");
                const m = s.match(/^(queued|probe|luts|render|verify|starting|done|failed|cancelled)/);
                if (m) stages.add(m[1]);
                if (/^(done|failed|cancelled)/.test(s)) { res = s; break; }
                if (Date.now() - t0 > (Number(a["timeout-min"]) || 180) * 60e3) { res = "timeout"; break; }
                await new Promise(z => setTimeout(z, 1000));
            }
            r.info(`job ${res} after ${((Date.now() - t0) / 60000).toFixed(1)} min; stages seen: ${[...stages].join(" -> ")}`);
            r.check("progress went through luts, render and verify", ["luts", "render", "verify"].every(x => stages.has(x)), [...stages]);
            r.check("job done", /^done/.test(res), res);
            // the card shows the progress file's "done" a moment before the job record has its clips: wait for the links
            let links = [];
            for (let i = 0; i < 30; i++) {
                links = await p.eval("[...document.querySelectorAll('#job-result a')].map(e => [e.innerText, e.getAttribute('href')])");
                if (links.length || !/^done/.test(res)) break;
                await new Promise(z => setTimeout(z, 1000));
            }
            const clips = links.filter(l => /clip/i.test(l[0])), reps = links.filter(l => /report/i.test(l[0]));
            r.check(`${mode === "pair" ? 2 : 1} Download clip / report pair(s)`, clips.length === (mode === "pair" ? 2 : 1) && reps.length === clips.length, links);
            for (const [clip, rep] of clips.map((c, i) => [c, reps[i]])) {
                const c = await http.req("GET", clip[1]);
                r.check(`clip downloads through the proxy (${(c.buf.length / 1e6).toFixed(1)} MB, ${c.headers.get("content-disposition")})`,
                        c.status === 200 && c.buf.length > 1e6 && c.buf.subarray(4, 8).toString() === "ftyp", c.status);
                const rj = await http.req("GET", rep[1]);
                r.check(`report downloads (${rj.json?.mode}: ok${rj.json?.mode === "sdr-today" ? "" : ", LUT hashes"})`,
                        rj.status === 200 && rj.json?.ok && (rj.json?.mode === "sdr-today" || rj.json?.luts?.length > 0), rj.status);
                if (a["report-out"] && rj.json)    // a pair: one file per mode
                    writeFileSync(clips.length > 1 ? a["report-out"].replace(/(\.json)?$/, `-${rj.json.mode}$1`) : a["report-out"],
                                  JSON.stringify(rj.json, null, 1));
                r.info(`report ${rj.json?.mode}: ${rj.json?.scenes?.length} segments, ${rj.json?.luts?.length} LUTs, timing ${JSON.stringify(rj.json?.timing_s)}` +
                       (rj.json?.checks?.set ? `, set: ${JSON.stringify(rj.json.checks.set)}` : ""));
            }
        }
    }

    if (a["master-upload"]) {
        const file = resolve(a["master-upload"]);
        const size = statSync(file).size;
        await p.eval("document.querySelector('.tab[data-tab=masters]').click(), true");
        const doc = await p.send("DOM.getDocument", {});
        const { nodeId } = await p.send("DOM.querySelector", { nodeId: doc.root.nodeId, selector: "#master-file" });
        await p.send("DOM.setFileInputFiles", { nodeId, files: [file] });
        const t0 = Date.now();
        await p.eval("document.querySelector('#master-upload').click(), true");
        const msg = await p.wait("/^(uploaded|upload failed)/.test(document.querySelector('#upload-msg').innerText) && document.querySelector('#upload-msg').innerText",
                                 1200000, "upload result");
        const s = (Date.now() - t0) / 1000;
        r.check(`master upload in the browser through the proxy (${(size / 2 ** 30).toFixed(2)} GB in ${s.toFixed(0)} s, ${(size / 2 ** 20 / s).toFixed(0)} MB/s)`,
                /^uploaded/.test(msg), msg);
        r.info(msg);
        const st2 = (await http.req("GET", `${APP}/api/state`)).json;
        const up = st2.masters.find(m => m.size === size && !masters.some(o => o.name === m.name));
        r.check("probe card of the upload: size, resolution, frames, HDR10+", up && up.width && up.frames > 0, up);
        if (up) {
            const del = await http.req("DELETE", `${APP}/api/masters/${encodeURIComponent(up.name)}`);
            r.check("the uploaded master deleted", del.status === 200, del.json || del.status);
        }
    }
    const only = (await http.req("GET", `${APP}/api/state`)).json.masters;
    if (only.length === 1) {
        const del = await http.req("DELETE", `${APP}/api/masters/${encodeURIComponent(only[0].name)}`);
        r.check("deleting the only master is refused (409)", del.status === 409, del.json || del.status);
    }

    if (a.queue && a["oled-profile"]) {
        const prof = readFileSync(a["oled-profile"], "utf8");
        const c = await http.req("POST", `${APP}/api/profile?type=oled`, { body: prof, type: "application/json" });
        const job = () => http.req("POST", `${APP}/api/jobs`, { type: "application/json", body: JSON.stringify(
            { master: only[0].name, token: c.json.token, type: "oled", player: "pi", length: "excerpt" }) });
        const j1 = (await job()).json, j2 = (await job()).json;
        const get = id => http.req("GET", `${APP}/api/jobs/${id}`).then(x => x.json);
        for (let i = 0; i < 120 && (await get(j1.id)).state !== "running"; i++) await new Promise(z => setTimeout(z, 1000));
        const q = await get(j2.id);
        r.check("second job queued behind the first (position 1)", q.state === "queued" && q.queue_position === 1, q);
        const d2 = await http.req("DELETE", `${APP}/api/jobs/${j2.id}`);
        r.check("queued job deleted", d2.json?.result === "deleted" && (await http.req("GET", `${APP}/api/jobs/${j2.id}`)).status === 404, d2.json);
        await new Promise(z => setTimeout(z, 20000));     // into the LUT build: the pool and ffmpeg children exist
        const d1 = await http.req("DELETE", `${APP}/api/jobs/${j1.id}`);
        r.check("running job: cancelling", d1.json?.result === "cancelling", d1.json);
        let s1;
        for (let i = 0; i < 60; i++) { s1 = await get(j1.id); if (s1.state !== "running") break; await new Promise(z => setTimeout(z, 1000)); }
        r.check("running job cancelled, no clip offered", s1.state === "cancelled" && !s1.clip, s1);
        r.info("check in the VM: pgrep ffmpeg prints nothing");
        await http.req("DELETE", `${APP}/api/jobs/${j1.id}`);
    }
} finally {
    await b.close();
}
process.exit(r.done());
