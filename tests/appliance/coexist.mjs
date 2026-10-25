// Two appliances on one host, one browser profile: log into the configurator dashboard and the converter dashboard;
// neither logs the other out (cookies are per host, not per port: the names session-sbd-configurator and
// session-partkb-converter keep them apart).
//
//   node tests/appliance/coexist.mjs --host=127.0.0.1 --config-port=8000 --converter-port=8100 --password=…
import { args, reporter, Browser, browserLogin } from "./lib.mjs";

const a = args();
const r = reporter(a.out);
const cfg = `http://${a.host}:${a["config-port"]}`, conv = `http://${a.host}:${a["converter-port"]}`;
// --second-app=sbd-configurator: two configurator releases side by side (both use session-sbd-configurator)
const second = a["second-app"] || "partkb-converter";
const apps = [[cfg, "/app/sbd-configurator/", "session-sbd-configurator"], [conv, `/app/${second}/`, `session-${second}`]];
const b = await Browser.launch();
try {
    const p = await b.page();
    for (const [base] of apps) await browserLogin(p, base, a.user, a.password);
    const names = (await p.cookies()).map(c => c.name);
    r.check("both session cookies held side by side in one profile", new Set(apps.map(x => x[2])).size === 2 && apps.every(([, , c]) => names.includes(c)), names);
    for (let round = 1; round <= 2; round++) {
        for (const [base, path] of apps) {
            await p.goto(base + path);
            await p.wait("document.readyState === 'complete' && document.body && document.body.innerText.length > 20", 60000, path);
            const loc = await p.eval("location.pathname");
            r.check(`round ${round}: ${base}${path} opens without a login (still logged in)`, loc === path, loc);
        }
    }
} catch (e) {
    r.check("browser steps", false, e.message);
} finally {
    await b.close();
}
process.exit(r.done() ? 1 : 0);
