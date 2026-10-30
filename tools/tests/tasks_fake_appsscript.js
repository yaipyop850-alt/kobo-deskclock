// usage: node fake.js <store.json> <GET|POST|PHONE> <querystring|bodyfile|json-op>
const fs = require('fs');
const [storeF, mode, arg] = process.argv.slice(2);
let st = fs.existsSync(storeF) ? JSON.parse(fs.readFileSync(storeF)) : { seq: 0, tasks: [], tasksOn: true };
const save = () => fs.writeFileSync(storeF, JSON.stringify(st));
const find = id => st.tasks.find(t => t.id === id);
const Tasks = {
  Tasklists: { list: () => ({ items: [{ id: 'L1' }] }) },
  Tasks: {
    get: (l, id) => { const t = find(id); if (!t) throw new Error('404'); return Object.assign({}, t); },
    patch: (b, l, id) => { const t = find(id); if (!t) throw new Error('404'); Object.assign(t, b); return t; },
    insert: (b, l) => { const t = Object.assign({ id: 'T' + (++st.seq) }, b); st.tasks.push(t); return t; },
    remove: (l, id) => { const t = find(id); if (!t) throw new Error('404'); t.deleted = true; },
    list: (l, o) => {
      const all = st.tasks.filter(t => !t.deleted);
      const start = o.pageToken ? Number(o.pageToken) : 0;
      const page = all.slice(start, start + 2); // tiny pages to test paging
      return { items: page, nextPageToken: start + 2 < all.length ? String(start + 2) : undefined };
    },
  },
};
if (mode === 'PHONE') { // simulate edits made on the phone
  const op = JSON.parse(arg);
  if (op.add) Tasks.Tasks.insert({ title: op.add, notes: op.notes || '', status: 'needsAction' });
  if (op.done) find(op.done).status = 'completed';
  if (op.rename) find(op.rename[0]).title = op.rename[1];
  if (op.del) find(op.del).deleted = true;
  if (op.off !== undefined) st.tasksOn = !op.off;
  save(); console.log(JSON.stringify(st.tasks)); process.exit(0);
}
const ctx = {
  Tasks: st.tasksOn ? Tasks : undefined,
  ContentService: { MimeType: { TEXT: 1 }, createTextOutput: t => ({ t, setMimeType() { return this; } }) },
  LockService: { getScriptLock: () => ({ waitLock() {}, releaseLock() {} }) },
  CalendarApp: { getDefaultCalendar: () => ({ getName: () => '내 캘린더' }) },
  Session: { getScriptTimeZone: () => 'Asia/Seoul' },
  Utilities: {},
};
let src = fs.readFileSync(require('path').join(__dirname, '..', '..', 'apps-script', 'Code.gs'), 'utf8').replace("'여기에-긴-비밀-문자열을-넣으세요'", "'abc@@'");
const fn = new Function(...Object.keys(ctx), src + '\nreturn {doGet, doPost};');
const api = fn(...Object.values(ctx));
const parse = q => Object.fromEntries(q.split('&').filter(Boolean).map(kv => kv.split('=').map(x => decodeURIComponent(x.replace(/\+/g, ' ')))));
let r;
if (mode === 'GET') r = api.doGet({ parameter: parse(arg) });
else { const [q, body] = fs.readFileSync(arg, 'utf8').split('\n\n'); r = api.doPost({ parameter: Object.assign(parse(q), parse(body)) }); }
save();
process.stdout.write(r.t);
