const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmt = n => Number(n || 0).toLocaleString('en-US');
const dt = t => t ? new Date(t * 1000).toLocaleString() : '-';
const post = (n, d = {}) => fetch(`https://${GetParentResourceName()}/${n}`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(d)
}).then(r => r.json()).catch(() => ({ error: 'No response from the server' }));
const api = async (action, data) => { try { const r=await post('call',{action,data}); return r&&typeof r==='object'?r:{error:'Invalid server response'}; } catch { return {error:'Connection failed. Check the result before retrying.'}; } };
const S = { t: null, p: null, page: 'dash', admin: 'Admin', acc: 'bank', mode: 'set', vault: 'full', vq: { full: '', other: '' }, mAcc: 'cash', mAct: 'reduce' };
const TITLES = { dash: 'Dashboard', target: 'Target Profile', wipe: 'Wipe Console', veh: 'Vehicle Control', money: 'Money Overview', econ: 'Economy Tools', mwipe: 'Money Wipe', vault: 'Restore Vault' };
const KINDS = {
  money: ['Wipe Money', 'Sets cash, bank and crypto to 0.'],
  inventory: ['Wipe Inventory', 'Removes every item from the inventory.'],
  vehicles: ['Wipe Vehicles', 'Deletes every vehicle the player owns.'],
  full: ['Wipe Full Character', 'Deletes the whole character: money, items, vehicles, looks and houses.']
};
const KL = { money: 'MONEY', inventory: 'INVENTORY', vehicles: 'ALL VEHICLES', vehicle: 'SINGLE VEHICLE' };
const av = (o, c = '') => `<div class="av ${c}">${ini(o)}</div>`;
const ini = p => esc(((p?.firstname || p?.name || '?')[0] + (p?.lastname || (p?.name || '').split(' ')[1] || '?')[0]).toUpperCase());

function amt(v) { // "100k", "1.5m", "-20000"
  const m = String(v ?? '').trim().replace(/,/g, '').match(/^(-?\d+(?:\.\d+)?)\s*([kKmM]?)$/);
  return m ? Math.round(parseFloat(m[1]) * ({ k: 1e3, m: 1e6 }[m[2].toLowerCase()] || 1)) : null;
}
function toast(msg, err) {
  const t = $('#toast'); t.textContent = msg; t.className = (err ? 'err ' : '') + 'show';
  clearTimeout(t._t); t._t = setTimeout(() => t.className = '', 4000);
}
const page = h => $('#page').innerHTML = h;
const closeModal = () => { $('#modal').classList.add('hidden'); $('#modal').innerHTML = ''; };
function modal(title, body, ok, fn, danger) {
  const m = $('#modal'); m.classList.remove('hidden');
  m.innerHTML = `<div class="box"><h3>${title}</h3>${body}<div class="mbtn"><button class="btn" id="mNo">Cancel</button><button class="btn ${danger ? 'dng' : 'pri'}" id="mOk">${ok}</button></div></div>`;
  $('#mNo').onclick = closeModal;
  $('#mOk').onclick = async () => { const b = $('#mOk'); b.disabled = true; try { await fn(); } catch { toast('Request failed. Check the result before retrying.', true); } finally { if(b.isConnected)b.disabled=false; } };
}
async function run(action, data, after) {
  const r = await api(action, data);
  if (r.error) { toast(r.error, true); return false; }
  toast(r.msg || 'Done'); closeModal(); if (after) after(r); return true;
}
const reasonField = `<label class="lab">Reason <em>OPTIONAL - SAVED IN ACTION LOGS</em></label><input id="f_reason" placeholder="Reason (optional)">`;
const tile = (g, ic, a, b) => `<button class="tile" data-go="${g}"><i>${ic}</i><b>${a}</b><span>${b}</span></button>`;

function sideChip() {
  $('#chip').innerHTML = S.p ? `<div class="pc"><small>CHOSEN TARGET</small><div class="pr">${av(S.p, 'sm')}<b>${esc(S.p.name)}</b></div><button class="btn sm wide" data-act="change">Change target</button></div>` : '';
}
function go(p) {
  S.page = p; $('#title').textContent = TITLES[p];
  document.querySelectorAll('.nav').forEach(n => n.classList.toggle('on', n.dataset.go === p));
  ({ dash: pDash, target: pTarget, wipe: pWipe, mwipe: pMWipe, veh: pVeh, money: pMoney, econ: pEcon, vault: pVault })[p]();
}

// ───────── target helpers ─────────
async function ensureP() {
  if (!S.t) return null;
  const p = await api('profile', { cid: S.t });
  if (p.error) { S.t = null; S.p = null; sideChip(); toast(p.error, true); return null; }
  S.p = p; sideChip(); return p;
}
function gate(title, text) {
  page(`<div class="card"><div class="ch"><div><small class="eyebrow">STEP 1</small><h3 style="margin-top:6px">${title}</h3></div></div><p class="mute">${text}</p>
   <div class="srch"><input id="q" placeholder="Server ID, citizen ID, name, last name" autocomplete="off"><button class="btn pri" data-act="search">Search</button></div><div id="res" class="list"></div></div>`);
  $('#q').focus(); $('#q').onkeydown = e => { if (e.key === 'Enter') doSearch(); };
}
const tHead = p => `<div class="card prof">${av(p)}<div style="flex:1"><small class="eyebrow">TARGET PROFILE</small><h2>${esc(p.name)}</h2><span class="mute">${esc(p.citizenid)}</span></div>
  <span class="tag ${p.online ? 'ok' : ''}">${p.online ? 'ONLINE - ID ' + p.source : 'OFFLINE'}</span><button class="btn" data-act="change">Change target</button></div>`;
let searchRequest=0;
async function doSearch() {
  const input=$('#q'), results=$('#res');
  if(!input||!results)return;
  const request=++searchRequest;
  results.innerHTML='<div class="empty">Searching players...</div>';
  const r = await api('search', { q: input.value });
  if(request!==searchRequest||$('#res')!==results)return;
  if(r.error){results.innerHTML=`<div class="alert red">${esc(r.error)}</div>`;toast(r.error,true);return;}
  results.innerHTML = (r.list || []).map(c => `<div class="item"><div class="l">${av(c)}<div><b>${esc(c.name)}</b><small>${esc(c.citizenid)}${c.phone ? ' / ' + esc(c.phone) : ''}</small></div></div>
   <div class="ir"><span class="tag ${c.online ? 'ok' : ''}">${c.online ? 'ONLINE - ID ' + c.source : 'OFFLINE'}</span><button class="btn pri sm" data-act="pick" data-cid="${esc(c.citizenid)}">Select</button></div></div>`).join('') || '<div class="empty">No matching character. Server IDs only work for online players; try a character name or citizen ID.</div>';
}

// ───────── pages ─────────
async function pDash() {
  const d = await api('dashboard');
  const st = (n, a, b) => `<div class="stat"><b>${fmt(n)}</b><span>${a}</span><small>${b}</small></div>`;
  page(`<div class="hero"><div><small class="eyebrow">UltimateX WIPE CONTROL • DATA ADMIN TERMINAL</small><h2>Dashboard</h2><p class="mute">Fast access to player edit, wipe, restore, vehicles and economy tools.</p></div>
    <div class="hb"><button class="btn pri" data-go="target">Open Target</button><button class="btn" data-go="wipe">Wipe Console</button></div></div>
   <div class="stats">${st(d.online, 'PLAYERS ONLINE', 'CONNECTED NOW')}${st(d.chars, 'CHARACTERS', 'IN THE DATABASE')}${st(d.fullWipes, 'FULL WIPES', 'LAST 24 HOURS')}${st(d.otherWipes, 'OTHER WIPES', 'LAST 24 HOURS')}</div>
   <div class="grid2"><div class="card"><div class="ch"><h3>Quick Actions</h3><small>COMMON TASKS</small></div><div class="tiles">
     ${tile('target', '◎', 'Target Profile', 'Search and inspect data')}${tile('wipe', '⌫', 'Wipe Console', 'Backup and wipe')}${tile('vault', '↺', 'Restore Vault', 'Restore backups')}
     ${tile('veh', '⛟', 'Vehicle Control', 'View or remove vehicles')}${tile('money', '¤', 'Money Overview', 'Richest to poorest')}${tile('econ', '%', 'Economy Tools', 'Range economy tax')}</div></div>
    <div class="card"><div class="ch"><h3>Last 24h Summary</h3><small>ACTIVITY</small></div><div class="mini">
     <div><b>${fmt(d.fullWipes)}</b><span>Full wipes</span></div><div><b>${fmt(d.otherWipes)}</b><span>Other wipes</span></div>
     <div><b>${fmt(d.restores)}</b><span>Restores</span></div><div><b>${fmt(d.backups)}</b><span>Backups in vault</span></div></div></div></div>`);
}

async function pTarget() {
  if (!S.t) return gate('Find a player', 'Search by server ID, citizen ID, character name, last name.');
  const p = await ensureP(); if (!p) return pTarget();
  const rows = [['CITIZEN ID', p.citizenid], ['NAME', p.name], ['BIRTHDATE', p.birthdate], ['PHONE', p.phone], ['NATIONALITY', p.nationality], ['VEHICLES', p.vehicles], ['CASH', fmt(p.cash)], ['BANK', fmt(p.bank)], ['STATUS', p.online ? 'Online' : 'Offline']]
    .map(([a, b]) => `<div class="row"><span>${a}</span><b>${esc(b ?? '-')}</b></div>`).join('');
  page(`${tHead(p)}<div class="grid2"><div class="card"><div class="ch"><h3>Identity</h3><button class="btn pri sm" data-act="editId">Edit Identity</button></div>${rows}</div>
   <div class="card"><div class="ch"><h3>Control Shortcuts</h3><small>OPEN A SECTION</small></div><div class="tiles t2">
    ${tile('veh', '⛟', 'Vehicle Control', 'View or remove vehicles')}${tile('wipe', '⌫', 'Wipe Console', 'Money, items, vehicles, character')}
    ${tile('mwipe', '⊖', 'Money Wipe', 'Reduce or add cash and bank')}${tile('vault', '↺', 'Restore Vault', 'Restore backups')}</div></div></div>`);
}

async function pWipe() {
  if (!S.t) { gate('Choose who to wipe', 'Select a player first. Every wipe saves a backup in the Restore Vault.'); showCitizenSwitch(); return; }
  const p = await ensureP(); if (!p) return pWipe();
  page(`${tHead(p)}<div class="wc">${Object.entries(KINDS).map(([k, v]) => `<div class="card ${k === 'full' ? 'danger' : ''}"><span class="tag ${k === 'full' ? 'red' : ''}">${k === 'full' ? 'FULL WIPE' : 'PARTIAL WIPE'}</span><h3>${v[0]}</h3><p class="mute">${v[1]}</p>
    <button class="btn ${k === 'full' ? 'dng' : 'pri'}" data-act="wipe" data-kind="${k}">${v[0]}</button></div>`).join('')}</div>`);
  showCitizenSwitch();
}

async function pMWipe() {
  if (!S.t) return gate('Choose a player', 'Select the player whose money you want to reduce or add to.');
  const p = await ensureP(); if (!p) return pMWipe();
  const st = (a, b) => `<div class="stat"><small>${a}</small><b style="font-size:32px;margin-top:8px">${fmt(b)}</b></div>`;
  page(`${tHead(p)}<div class="stats" style="grid-template-columns:repeat(3,minmax(0,1fr))">${st('CASH', p.cash)}${st('BANK', p.bank)}${st('TOTAL', p.cash + p.bank)}</div>
   <div class="card"><div class="ch"><div><small class="eyebrow">MONEY WIPE</small><h3 style="margin-top:6px">Reduce or add money</h3></div></div>
   <p class="mute">Pick the account and the action, then type the amount. You can write 50000, 50k or 1.5m.</p>
   <div class="two"><div><label class="lab">Account</label><div class="seg" id="maseg">${[['cash', 'Cash'], ['bank', 'Bank']].map(([k, l]) => `<button data-macc="${k}" class="${S.mAcc === k ? 'on' : ''}">${l}</button>`).join('')}</div></div>
    <div><label class="lab">Action</label><div class="seg" id="mtseg">${[['reduce', 'Reduce'], ['add', 'Add']].map(([k, l]) => `<button data-mact="${k}" class="${S.mAct === k ? 'on' : ''}">${l}</button>`).join('')}</div></div></div>
   <label class="lab">Amount</label><input id="mw_amt" placeholder="Example: 50k" autocomplete="off">
   <div class="example" id="mw_ex"></div>${reasonField}
   <div style="margin-top:18px"><button class="btn pri" data-act="mwApply">Apply</button></div></div>`);
  $('#mw_amt').oninput = mwEx; mwEx();
}
function mwEx() {
  const el = $('#mw_ex'); if (!el) return;
  const a = amt($('#mw_amt').value), cur = S.p[S.mAcc] || 0, name = S.mAcc === 'cash' ? 'Cash' : 'Bank';
  el.innerHTML = a > 0 ? `${name}: <b>${fmt(cur)}</b> &rarr; <b>${fmt(S.mAct === 'add' ? cur + a : Math.max(0, cur - a))}</b>` : `${name} right now: <b>${fmt(cur)}</b>`;
}

async function pVeh() {
  if (!S.t) return gate('Choose a player', 'Select a player to see their vehicles.');
  const p = await ensureP(); if (!p) return pVeh();
  const r = await api('vehicles', { cid: S.t });
  const st = s => s == 0 ? ['OUT', ''] : s == 2 ? ['IMPOUND', 'red'] : ['STORED', 'ok'];
  page(`${tHead(p)}<div class="card"><div class="ch"><h3>Vehicles</h3><small>${(r.list || []).length} VEHICLE(S)</small></div>
   <table><tr><th>VEHICLE</th><th>PLATE</th><th>SPAWN NAME</th><th>GARAGE</th><th></th></tr>
   ${(r.list || []).map(v => `<tr><td><b>${esc(v.name)}</b></td><td>${esc(v.plate)}</td><td>${esc(v.model)}</td><td>${esc(v.garage || '-')} <span class="tag ${st(v.state)[1]}">${st(v.state)[0]}</span></td>
   <td><button class="btn dng sm" data-act="rmVeh" data-plate="${esc(v.plate)}">Remove</button></td></tr>`).join('') || '<tr><td colspan="5" class="empty">This player has no vehicles.</td></tr>'}</table></div>`);
}

async function pMoney() {
  const r = await api('money');
  const st = (a, b) => `<div class="stat"><small>${a}</small><b style="font-size:30px;margin-top:8px">${fmt(b)}</b></div>`;
  page(`<div class="stats" style="grid-template-columns:repeat(3,minmax(0,1fr))">${st('TOTAL CASH', r.cash)}${st('TOTAL BANK', r.bank)}${st('TOTAL ECONOMY', r.cash + r.bank)}</div>
   <div class="card"><div class="ch"><h3>Top 50 Money Holders</h3><small>HIGHEST TO LOWEST</small></div><div class="list">
   <div class="rank h"><span>#</span><span>PLAYER</span><span>CASH</span><span>BANK</span><span>TOTAL</span><span></span></div>
   ${(r.list || []).map((p, i) => `<div class="rank"><div class="n">${i + 1}</div><div><b>${esc(p.name)}</b><small>${esc(p.citizenid)}${p.online ? ' • ONLINE' : ''}</small></div><div>${fmt(p.cash)}</div><div>${fmt(p.bank)}</div><div><b>${fmt(p.cash + p.bank)}</b></div>
   <button class="btn pri sm" data-act="editMoney" data-cid="${esc(p.citizenid)}" data-name="${esc(p.name)}">Open Detail</button></div>`).join('')}</div></div>`);
}

function pEcon() {
  page(`<div class="card"><div class="ch"><div><small class="eyebrow">RANGE TAX</small><h3 style="margin-top:6px">Remove money from every player</h3></div><span class="tag red">AFFECTS ALL PLAYERS</span></div>
   <p class="mute">For each amount a player holds, remove a fixed amount. You can type 100k, 250k or 1.5m.</p>
   <div class="sentence">For each <input id="e_each" value="100k"> remove <input id="e_rem" value="20k"></div>
   <label class="lab">Take it from</label><div class="seg" id="accseg">${[['cash', 'Cash'], ['bank', 'Bank'], ['both', 'Cash + Bank']].map(([k, l]) => `<button data-acc="${k}" class="${S.acc === k ? 'on' : ''}">${l}</button>`).join('')}</div>
   <div class="example" id="e_ex"></div>${reasonField}
   <div style="display:flex;gap:12px;margin-top:18px"><button class="btn" data-act="econPrev">Preview</button><button class="btn dng" data-act="econApply">Apply to all players</button></div>
   <div id="e_res" class="res hidden"></div></div>`);
  const ex = () => { const e = amt($('#e_each').value), r = amt($('#e_rem').value);
    $('#e_ex').innerHTML = e > 0 && r > 0 ? `Example: a player holding <b>${fmt(e * 3.5)}</b> loses <b>${fmt(3 * r)}</b> (3 steps of ${fmt(e)}).` : 'Enter valid numbers.'; };
  $('#e_each').oninput = $('#e_rem').oninput = ex; ex();
}
const econData = () => ({ account: S.acc, each: amt($('#e_each').value), remove: amt($('#e_rem').value), reason: $('#f_reason').value });

// ───────── restore vault: two isolated sections ─────────
function pVault() {
  page(`<div class="vtabs"><button class="vt" data-vault="full"><em id="c_full">-</em><small>SECTION 1</small><b>Full Wipe Vault</b><span>Characters that were wiped completely</span></button>
   <button class="vt" data-vault="other"><em id="c_other">-</em><small>SECTION 2</small><b>Other Wipes Vault</b><span>Money, inventory and vehicle wipes</span></button></div><div id="vbody"></div>`);
  vaultBody();
}
async function vaultBody() {
  const v = S.vault, full = v === 'full';
  document.querySelectorAll('.vt').forEach(b => { const on = b.dataset.vault === v; b.classList.toggle('on', on); b.classList.toggle('rd', on && v === 'full'); });
  $('#vbody').innerHTML = `<div class="card ${full ? 'danger' : ''}"><div class="ch"><div><small class="eyebrow">${full ? 'FULL WIPE VAULT' : 'OTHER WIPES VAULT'}</small><h3 style="margin-top:6px">${full ? 'Deleted characters' : 'Money, inventory and vehicle backups'}</h3></div></div>
   <p class="mute">${full ? 'Restoring brings the whole character back: identity, money, items, vehicles and looks.' : 'Restoring brings back only the part that was wiped (money, items or vehicles).'}</p>
   <div class="srch"><input id="q" value="${esc(S.vq[v])}" placeholder="Search citizen ID, first name or last name..." autocomplete="off"><button class="btn pri" data-act="bsearch">Search</button></div><div id="bl" class="list"></div></div>`;
  $('#q').onkeydown = e => { if (e.key === 'Enter') loadBackups(); };
  loadBackups();
}
async function loadBackups() {
  const v = S.vault; S.vq[v] = $('#q').value;
  const r = await api('backups', { q: S.vq[v], scope: v });
  if (r.counts) { $('#c_full').textContent = r.counts.full; $('#c_other').textContent = r.counts.other; }
  if (S.vault !== v || !$('#bl')) return;
  $('#bl').innerHTML = `<small>${(r.list || []).length} BACKUP(S)</small>` + ((r.list || []).map(b => `<div class="item"><div class="l">${av(b)}<div><b>${esc(b.name)} ${v === 'other' ? `<span class="tag">${KL[b.kind] || esc(String(b.kind).toUpperCase())}</span>` : ''}</b>
   <small>${esc(b.citizenid)} • ${dt(b.created_at)} • by ${esc(b.admin)} • ${esc(b.reason || '')}</small></div></div>
   ${b.restored == 1 ? '<span class="tag ok">RESTORED</span>' : `<button class="btn pri sm" data-act="restore" data-id="${b.id}" data-name="${esc(b.name)}">${v === 'full' ? 'Restore character' : 'Restore'}</button>`}</div>`).join('') || '<div class="empty">No backups in this section.</div>');
}

// ───────── actions ─────────
const A = {
  search: doSearch, bsearch: loadBackups,
  pick: el => { S.t = el.dataset.cid; go(S.page === 'target' ? 'wipe' : S.page); },
  change: () => { S.t = null; S.p = null; sideChip(); go(S.page === 'dash' ? 'target' : S.page); },
  editId: () => {
    const p = S.p, f = (id, l, v) => `<div><label class="lab">${l}</label><input id="${id}" value="${esc(v || '')}"></div>`;
    modal('Edit Identity', `<div class="two">${f('i_fn', 'First name', p.firstname)}${f('i_ln', 'Last name', p.lastname)}${f('i_bd', 'Birthdate', p.birthdate)}${f('i_na', 'Nationality', p.nationality)}</div>${reasonField}`, 'Save changes',
      () => run('identity', { cid: S.t, firstname: $('#i_fn').value, lastname: $('#i_ln').value, birthdate: $('#i_bd').value, nationality: $('#i_na').value, reason: $('#f_reason').value }, () => go(S.page)));
  },
  wipe: el => {
    const k = el.dataset.kind, v = KINDS[k];
    modal(v[0], `<div class="alert ${k === 'full' ? 'red' : ''}">Target: <b>${esc(S.p.name)}</b> (${esc(S.t)})<br>${v[1]}</div><p class="mute">A backup is saved in the Restore Vault, so this can be undone.</p>${reasonField}
     ${k === 'full' ? '<label class="check"><input type="checkbox" id="f_ok"> I understand the whole character will be deleted</label>' : ''}`, 'Confirm wipe',
      async () => { if (k === 'full' && !$('#f_ok').checked) return toast('Tick the box to confirm', true);
        await run('wipe', { cid: S.t, kind: k, reason: $('#f_reason').value }, k === 'full' ? () => { S.t = null; S.p = null; sideChip(); go('wipe'); } : null); }, true);
  },
  mwApply: () => {
    const a = amt($('#mw_amt').value);
    if (!(a > 0)) return toast('Enter a valid amount', true);
    run('setMoney', { cid: S.t, mode: 'add', [S.mAcc]: S.mAct === 'add' ? a : -a, reason: $('#f_reason').value }, () => go('mwipe'));
  },
  rmVeh: el => modal('Remove vehicle', `<div class="alert red">Plate <b>${esc(el.dataset.plate)}</b> will be removed from the player.</div><p class="mute">A backup is saved in the Other Wipes Vault.</p>${reasonField}`, 'Remove vehicle',
    () => run('removeVehicle', { cid: S.t, plate: el.dataset.plate, reason: $('#f_reason').value }, pVeh), true),
  editMoney: el => {
    const cid = el?.dataset.cid || S.t, name = el?.dataset.name || S.p?.name; S.mode = 'set';
    modal('Edit Money Detail', `<p class="mute">${esc(name)} (${esc(cid)})</p><label class="lab">Mode</label>
     <div class="seg" id="modeseg"><button data-mode="set" class="on">Set amount<small>replace the current money</small></button><button data-mode="add">Add amount<small>use - to remove money</small></button></div>
     <div class="two"><div><label class="lab">Cash</label><input id="m_cash" placeholder="empty = no change"></div><div><label class="lab">Bank</label><input id="m_bank" placeholder="empty = no change"></div></div>${reasonField}`, 'Save amount',
      () => run('setMoney', { cid, mode: S.mode, cash: $('#m_cash').value === '' ? null : amt($('#m_cash').value), bank: $('#m_bank').value === '' ? null : amt($('#m_bank').value), reason: $('#f_reason').value }, () => go(S.page)));
  },
  econPrev: async () => {
    const r = await api('econPreview', econData()), b = $('#e_res'); b.classList.remove('hidden');
    b.innerHTML = r.error ? `<span style="color:#ff8a98">${esc(r.error)}</span>` : `Players affected: <b>${fmt(r.players)}</b> / ${fmt(r.all)}<br>Total removed: <b>${fmt(r.total)}</b>`;
  },
  econApply: () => modal('Apply economy tax', '<div class="alert red">This removes money from ALL players and cannot be undone.</div>', 'Apply',
    async () => { const r = await api('econApply', econData()); r.error ? toast(r.error, true) : toast(r.msg); closeModal(); }, true),
  restore: el => modal('Restore backup', `<div class="alert">Restore the backup of <b>${esc(el.dataset.name)}</b>.</div>${reasonField}`, 'Restore',
    () => run('restore', { id: Number(el.dataset.id), reason: $('#f_reason').value }, loadBackups)),
};

document.addEventListener('click', e => {
  const t = e.target.closest('[data-go],[data-act],[data-acc],[data-mode],[data-vault],[data-macc],[data-mact]');
  if (!t) return;
  if (t.dataset.go) go(t.dataset.go);
  else if (t.dataset.act) A[t.dataset.act]?.(t);
  else if (t.dataset.vault) { S.vault = t.dataset.vault; vaultBody(); }
  else if (t.dataset.macc) { S.mAcc = t.dataset.macc; document.querySelectorAll('#maseg button').forEach(b => b.classList.toggle('on', b === t)); mwEx(); }
  else if (t.dataset.mact) { S.mAct = t.dataset.mact; document.querySelectorAll('#mtseg button').forEach(b => b.classList.toggle('on', b === t)); mwEx(); }
  else if (t.dataset.acc) { S.acc = t.dataset.acc; document.querySelectorAll('#accseg button').forEach(b => b.classList.toggle('on', b === t)); }
  else if (t.dataset.mode) { S.mode = t.dataset.mode; document.querySelectorAll('#modeseg button').forEach(b => b.classList.toggle('on', b === t)); }
});

function close() { $('#app').classList.add('hidden'); closeModal(); post('close'); }
$('#close').onclick = close;
$('#refresh').onclick = () => go(S.page);
document.addEventListener('keydown', e => { if (e.key === 'Escape') { $('#modal').classList.contains('hidden') ? close() : closeModal(); } });
window.addEventListener('message', e => {
  if (e.data.action !== 'open') return;
  S.admin = e.data.admin || 'Admin'; $('#app').classList.remove('hidden'); go('dash');
});

function showCitizenSwitch(){ $('#page').insertAdjacentHTML('beforeend',`<div class="card" style="margin-top:20px"><h3>Swap characters</h3><p class="mute">Exchange characters between two accounts after both disconnect. Citizen IDs, money and belongings stay with each character.</p><label>First character citizen ID<input id="cid-current" value="${esc(S.t||'')}" maxlength="50"></label><label>Second character citizen ID<input id="cid-new" maxlength="50"></label><button class="btn pri" id="cid-switch">Queue character swap</button></div>`);$('#cid-switch').onclick=()=>run('switchCitizenId',{current:$('#cid-current').value,new:$('#cid-new').value}); }
