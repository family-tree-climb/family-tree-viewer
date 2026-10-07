/* Family Tree Viewer tests: drives the page in headless Chrome (used by tests/Run-Tests.ps1).
   Loaded by the test copy of index.html AFTER the program's scripts (capture.js comes first).

   index-test.html?mode=routes  opens every page of the viewer one after the other (home, both trees,
                                every person with every tab and its tree, every document, people,
                                stories, notes, help, searches, pages that do not exist), clicks the
                                controls (people filters and sorting, tree generations, the picture
                                viewer, Copy the report, the search box) and reports what happened.
   index-test.html?mode=idle    only reports, every half second, what the page shows (for the
                                missing-settings and new-version tests).
   The report is JSON in <pre id="__out">. Nothing here changes any file. */
(function () {
  'use strict';
  var T = window.__T || { errors: [], resources: [], loads: 0 };
  var mode = (/[?&]mode=(\w+)/.exec(location.search) || [])[1] || 'idle';
  var out = document.createElement('pre');
  out.id = '__out'; out.hidden = true;
  document.body.appendChild(out);
  function report(o) { out.textContent = JSON.stringify(o); }
  function ss(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
  function $(id) { return document.getElementById(id); }
  function mainText() { var m = $('main'); return m ? m.innerText : ''; }
  function barText() { var b = $('statusbar'); return b && !b.hidden ? b.innerText : ''; }
  function state() {
    return {
      loads: T.loads, reloadedFor: ss('ft.reloadedForVersion'),
      version: typeof window.FAMILY_VERSION === 'string' ? window.FAMILY_VERSION : '',
      statusVersion: window.FAMILY_STATUS ? (window.FAMILY_STATUS.version || '') : '(no status)',
      settingsProblem: window.FAMILY_CONFIG ? window.FAMILY_CONFIG.settingsProblem : '(no config)',
      settingsCard: !!$('settings-problem'),
      errors: T.errors.slice(), resources: T.resources.slice(),
      bar: barText(), main: mainText().slice(0, 600), title: document.title
    };
  }

  if (mode !== 'routes') {
    report(state());
    setInterval(function () { report(state()); }, 500);
    return;
  }

  var FA = window.FamilyApp, M = FA && FA.model, G = window.Genealogy, C = window.FAMILY_CONFIG;
  if (!M) { report({ fatal: 'the family model was not built', state: state() }); return; }
  var enc = encodeURIComponent;
  var steps = [];
  function go(route, act) { steps.push({ route: route, act: act }); }
  function fire(el, type) { if (el) el.dispatchEvent(new Event(type, { bubbles: true })); }
  function count() { var p = document.querySelector('#plist p'); return p ? p.innerText : ''; }

  // ---- the pages
  go('#/');
  go('#/tree', function (res, next) {
    // 3, 5 and 6 generations, then back to 4
    res.generations = [3, 5, 6, 4].map(function (g) {
      var b = document.querySelector('[data-gens="' + g + '"]');
      if (!b) return g + ': no button';
      b.click();
      return g + ': ' + document.querySelectorAll('#pedigree .pcard').length + ' cards';
    });
    next();
  });
  C.roots.forEach(function (r) { go('#/tree/' + enc(r.key)); });
  go('#/people', function (res, next) {
    var r = [];
    ['born', 'gen', 'changed', 'name'].forEach(function (v) { var s = $('psort'); s.value = v; fire(s, 'change'); r.push('sort ' + v + ': ' + count()); });
    var pl = $('pline'); pl.value = Object.keys(C.lines)[2] || ''; fire(pl, 'change'); r.push('line ' + pl.value + ': ' + count());
    pl.value = ''; fire(pl, 'change');
    var pq = $('pq');
    ['ash', Object.keys(C.lines)[0] + '3', ''].forEach(function (q) { pq.value = q; fire(pq, 'input'); r.push('filter "' + q + '": ' + count()); });
    var pd = $('pdocs'); pd.checked = true; fire(pd, 'change'); r.push('only with a life history: ' + count());
    pd.checked = false; fire(pd, 'change');
    var lb = document.querySelector('#pletters button:not([disabled])[data-l]:not([data-l=""])');
    if (lb) { lb.click(); r.push('letter ' + lb.getAttribute('data-l') + ': ' + count()); }
    var all = document.querySelector('#pletters button[data-l=""]'); if (all) all.click();
    res.people = r;
    next();
  });
  go('#/stories');
  go('#/notes', function (res, next) {
    var a = document.querySelector('#notes-report a');
    res.notesReport = a ? a.getAttribute('href').slice(0, 40) : null;
    next();
  });
  go('#/help', function (res, next) {
    var pv = $('program-version'), btn = $('reportbtn'), copy = $('copyreport');
    res.programVersion = pv ? pv.innerText : null;
    res.mailto = btn ? { length: btn.getAttribute('href').length, start: btn.getAttribute('href').slice(0, 60) } : null;
    if (!copy) { next(); return; }
    copy.click();
    setTimeout(function () {
      var ta = $('reporttext');
      res.copy = { button: copy.innerText, textShown: !!ta && !ta.hidden, hasVersion: !!ta && /Program version: /.test(ta.value) };
      next();
    }, 300);
  });
  go('#/help/report');
  ['mill', 'Ashworth', "Rose's", 'church bread', 'zzzz-nothing'].forEach(function (q) { go('#/search/' + enc(q)); });
  go('#/search/' + enc(Object.keys(M.people).filter(function (k) { return /,/.test(k); }).sort()[0] || 'A1,1'), function (res, next) {
    // a number typed into the search box goes straight to that person
    setTimeout(function () { res.landedOn = location.hash; next(); }, 100);
  });
  go('#/', function (res, next) {
    var input = $('searchinput'), form = $('searchform');
    input.value = 'mill';
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    setTimeout(function () { res.searchBox = location.hash; next(); }, 100);
  });
  Object.keys(M.people).sort().forEach(function (k) {
    go('#/p/' + enc(k));
    ['facts', 'pictures', 'mentions'].forEach(function (t) { go('#/p/' + enc(k) + '/' + t); });
    go('#/tree/' + enc(k));
  });
  var withPhoto = Object.keys(M.people).sort().filter(function (k) { return M.people[k].photo && G.resolve(k) === k; })[0];
  if (withPhoto) {
    go('#/p/' + enc(withPhoto), function (res, next) {
      var img = document.querySelector('#main img.dimg'), lb = $('lightbox');
      if (!img) { res.lightbox = 'no picture in the story'; next(); return; }
      img.click();
      var opened = !lb.hidden;
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
      res.lightbox = (opened ? 'opened' : 'did not open') + ', ' + (lb.hidden ? 'closed' : 'did not close');
      next();
    });
  }
  Object.keys(M.docs).sort().forEach(function (id) { go('#/doc/' + id); });
  go('#/p/Z9%2C9');
  go('#/tree/Z9%2C9');
  go('#/doc/d000000000000');
  go('#/no-such-page');
  go('#/search/');

  // ---- run them one after the other
  var results = [], i = 0;
  function step() {
    if (i >= steps.length) { report({ state: state(), results: results }); return; }
    var s = steps[i++], before = T.errors.length, beforeRes = T.resources.length;
    if (location.hash === s.route) FA.route(); else location.hash = s.route;
    setTimeout(function () {
      var text = mainText();
      var res = { route: s.route, title: document.title, chars: text.length, start: text.slice(0, 80).replace(/\s+/g, ' ') };
      var finish = function () {
        res.errors = T.errors.slice(before);
        res.resources = T.resources.slice(beforeRes);
        res.broke = /Something went wrong showing this page/.test(mainText());
        results.push(res);
        setTimeout(step, 0);
      };
      if (!s.act) { finish(); return; }
      try { s.act(res, finish); } catch (e) { T.errors.push('test driver: ' + s.route + ': ' + (e && e.stack || e)); finish(); }
    }, 80);
  }
  setTimeout(step, 200);
})();
