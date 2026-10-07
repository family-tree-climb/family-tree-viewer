/* Family Tree Viewer — tree fingerprint, used by tests/Compare-Trees.ps1 (through compare-trees.html).

   It runs after one program's settings + config.js, a data.js, genealogy.js and render.js have been
   loaded. It builds the family model ONCE (exactly as the viewer does) and prints a complete,
   canonical description of it into <pre id="out">, one item per line:

       <KIND> TAB <id> TAB <json>

     CONFIG   the tree-relevant settings: title, subtitle, lines, spaces, roots, people,
              documentPeople, ignoreDocuments (help and report settings are left out on purpose)
     MODEL    the names of the model's top-level parts
     ORDER    the order of the people, of the model's documents, of data.docs and of the stories
     PERSON   every place in the model with ALL of its own fields (name, span, years, sex, facts,
              docs, doc, mentions, aliases seen as alsoAt, ...) plus the links the pages use
              (father/mother/child/spouse keys, raw and resolved, relationTo, sexOf)
     ALIAS    every place that resolves to another place (pedigree collapse), probed over every key
              that appears anywhere in the model
     DOC      every document: everything genealogy.js wrote onto it (kind, personKey, alsoKeys,
              title, info, fileKey, otherMarriages, ...); the big parts (the raw blocks "b", "text"
              and info.lines) as length + hash
     NOTE     every item of every Notes list (duplicates, codeMismatch, refMismatch, ...)
     STORIES  the list of stories

   Inside a json, another document is written "doc:<id>", a person "person:<key>", a line
   "line:<letter>" and a document's analysis "info:<doc id>", so every item stands on its own.
   Object keys keep their insertion order (that order is part of what is compared).
   Lines starting with "#" are information only (program version, timing) and are not compared.
   The last line is "#END <count>". Nothing here changes any file.
*/
(function () {
  'use strict';

  // a fast 64-bit string hash (cyrb53 twice), as 16 hex digits
  function hash(s) {
    var h1 = 0xdeadbeef, h2 = 0x41c6ce57, i, ch;
    for (i = 0; i < s.length; i++) {
      ch = s.charCodeAt(i);
      h1 = Math.imul(h1 ^ ch, 2654435761);
      h2 = Math.imul(h2 ^ ch, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return ('0000000' + (h2 >>> 0).toString(16)).slice(-8) + ('0000000' + (h1 >>> 0).toString(16)).slice(-8);
  }
  function blob(v) { var s = typeof v === 'string' ? v : JSON.stringify(v); s = s == null ? '' : s; return '[' + s.length + ' chars ' + hash(s) + ']'; }

  function run() {
    var G = window.Genealogy, CFG = window.FAMILY_CONFIG, D = window.FAMILY_DATA;
    var lines = [];
    function emit(kind, id, value) { lines.push(kind + '\t' + id + '\t' + JSON.stringify(value)); }
    function info(name, value) { lines.push('#' + name + '\t' + JSON.stringify(value)); }

    info('INFO', {
      version: typeof window.FAMILY_VERSION === 'string' ? window.FAMILY_VERSION : '',
      settingsProblem: CFG && CFG.settingsProblem != null ? CFG.settingsProblem : '(no settingsProblem field)',
      settingsMissing: !!window.FAMILY_SETTINGS_MISSING,
      dataBuilt: D && D.built, docs: D && D.docs ? D.docs.length : 0,
      userAgent: navigator.userAgent
    });
    if (!CFG) throw new Error('window.FAMILY_CONFIG is not defined (config.js did not load or failed)');
    if (!D) throw new Error('window.FAMILY_DATA is not defined (data.js did not load)');
    if (!G || !G.build) throw new Error('window.Genealogy is not defined (genealogy.js did not load or failed)');
    if (!window.Render) throw new Error('window.Render is not defined (render.js did not load or failed)');

    var t0 = performance.now();
    var M = G.build(D);
    var buildMs = Math.round(performance.now() - t0);

    // ---- references: documents, people, lines and analyses are written as short references
    var docRef = new Map(), personRef = new Map(), lineRef = new Map(), infoRef = new Map();
    Object.keys(M.docs).forEach(function (id) { docRef.set(M.docs[id], id); });
    (D.docs || []).forEach(function (d) { if (!docRef.has(d)) docRef.set(d, d.id); });
    Object.keys(M.people).forEach(function (k) { personRef.set(M.people[k], k); });
    Object.keys(CFG.lines || {}).forEach(function (l) { lineRef.set(CFG.lines[l], l); });
    docRef.forEach(function (id, d) { if (d.info && typeof d.info === 'object') infoRef.set(d.info, id); });

    // canonical copy: references for known objects (unless listed in "expand"), insertion order kept,
    // undefined / functions / NaN made visible instead of silently dropped
    function canon(v, expand, stack) {
      if (v === undefined) return '[undefined]';
      if (typeof v === 'function') return '[function]';
      if (typeof v === 'number' && !isFinite(v)) return '[' + String(v) + ']';
      if (v === null || typeof v !== 'object') return v;
      if (!expand || expand.indexOf(v) < 0) {
        if (docRef.has(v)) return 'doc:' + docRef.get(v);
        if (personRef.has(v)) return 'person:' + personRef.get(v);
        if (lineRef.has(v)) return 'line:' + lineRef.get(v);
        if (infoRef.has(v)) return 'info:' + infoRef.get(v);
      }
      stack = stack || [];
      if (stack.indexOf(v) >= 0) return '[cycle]';
      stack.push(v);
      var r;
      if (Array.isArray(v)) r = v.map(function (x) { return canon(x, expand, stack); });
      else if (v instanceof RegExp) r = '[regexp ' + String(v) + ']';
      else if (v instanceof Date) r = '[date ' + (isNaN(v) ? 'invalid' : v.toISOString()) + ']';
      else {
        r = {};
        Object.keys(v).forEach(function (k) { r[k] = canon(v[k], expand, stack); });
      }
      stack.pop();
      return r;
    }

    // ---- CONFIG (tree-relevant settings only)
    var cfgPart = {};
    ['title', 'subtitle', 'lines', 'spaces', 'roots', 'people', 'documentPeople', 'ignoreDocuments'].forEach(function (k) { cfgPart[k] = CFG[k]; });
    var lineObjs = Object.keys(CFG.lines || {}).map(function (l) { return CFG.lines[l]; });
    emit('CONFIG', 'settings', canon(cfgPart, lineObjs));
    emit('CONFIG', 'Genealogy.roots', canon(G.roots, []));

    // ---- MODEL / ORDER
    emit('MODEL', 'keys', Object.keys(M));
    emit('ORDER', 'people', Object.keys(M.people));
    emit('ORDER', 'model.docs', Object.keys(M.docs));
    emit('ORDER', 'data.docs', (D.docs || []).map(function (d) { return d.id; }));
    emit('STORIES', 'list', (M.stories || []).map(function (d) { return 'doc:' + (docRef.has(d) ? docRef.get(d) : '?'); }));

    // ---- PERSON
    var probe = {};
    function addProbe(k) { if (k && typeof k === 'string') probe[k] = 1; }
    Object.keys(M.people).forEach(function (k) {
      var p = M.people[k];
      var links = {
        fatherKey: G.fatherKey(k), motherKey: G.motherKey(k), childKey: G.childKey(k), spouseKey: G.spouseKey(k),
        resolved: G.resolve(k),
        father: G.resolve(G.fatherKey(k)), mother: G.resolve(G.motherKey(k)), child: G.resolve(G.childKey(k)), spouse: G.resolve(G.spouseKey(k)),
        sexOf: G.sexOf(k), relationTo: G.relationTo(p)
      };
      [k, links.fatherKey, links.motherKey, links.childKey, links.spouseKey].forEach(addProbe);
      (p.alsoAt || []).forEach(addProbe);
      emit('PERSON', k, { person: canon(p, [p]), links: links });
    });

    // ---- DOC (every document object the build saw)
    docRef.forEach(function (id, d) {
      var copy = {};
      Object.keys(d).forEach(function (k) { copy[k] = d[k]; });
      if ('b' in copy) copy.b = blob(d.b);
      if ('text' in copy) copy.text = blob(d.text);
      var expand = [copy];
      if (d.info && typeof d.info === 'object') {
        var inf = {};
        Object.keys(d.info).forEach(function (k) { inf[k] = d.info[k]; });
        if ('lines' in inf) inf.lines = blob(canon(d.info.lines, []));
        copy.info = inf;
        expand.push(inf);
      }
      addProbe(d.personKey); addProbe(d.fileKey); (d.alsoKeys || []).forEach(addProbe);
      emit('DOC', id, canon(copy, expand));
    });

    // ---- NOTE (every list of the notes, item by item)
    Object.keys(M.notes).forEach(function (sec) {
      var list = M.notes[sec];
      if (!Array.isArray(list)) { emit('NOTE', sec, canon(list, [])); return; }
      emit('NOTE', sec + '#count', list.length);
      list.forEach(function (item, i) {
        ['at', 'is', 'key', 'matched', 'chosen', 'expected', 'from', 'to'].forEach(function (f) { if (item && typeof item[f] === 'string') addProbe(item[f]); });
        emit('NOTE', sec + '#' + i, canon(item, []));
      });
    });

    // ---- ALIAS (pedigree collapse: every key that resolves elsewhere)
    Object.keys(probe).sort().forEach(function (k) {
      var r = G.resolve(k);
      if (r !== k) emit('ALIAS', k, r);
    });

    var count = lines.filter(function (l) { return l.charAt(0) !== '#'; }).length;
    info('TIMING', { buildMs: buildMs, totalMs: Math.round(performance.now() - t0) });
    lines.push('#END\t' + count);
    return lines.join('\n');
  }

  window.CompareTrees = {
    main: function () {
      var out = document.getElementById('out');
      var loadErrors = window.CT_LOAD_ERRORS || [];
      try {
        var text = run();
        if (loadErrors.length) text = '#LOAD-ERRORS\t' + JSON.stringify(loadErrors) + '\n' + text;
        out.textContent = text;
      } catch (e) {
        out.textContent = 'ERROR\t' + (e && e.message) + '\n' + (e && e.stack || '') + (loadErrors.length ? '\nLOAD ERRORS: ' + loadErrors.join(' | ') : '');
      }
    }
  };
})();
