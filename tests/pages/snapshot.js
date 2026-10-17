/* Family Tree Viewer tests: a readable snapshot of the family model (used by tests/Run-Tests.ps1).

   It builds the model from data/data.js exactly as the viewer does (Genealogy.build) and writes it as
   JSON into <pre id="out">, one item per line, so a change shows up as a small line diff:

     summary   counts
     people    every place in the tree: name, years, sex, relationship, documents, parents, facts,
               other spouses / children / siblings, timeline events, where the person is mentioned
     aliases   places that are the same person as another place (pedigree collapse)
     docs      every document: what kind it is, whom it describes, what the title line said
     stories   the documents shown under Stories
     notes     everything listed on the Research notes page
     data      read errors and other (non-Word) files, as written by tools\Update-FamilyTree.ps1
     blocks    the text of every document as read from Word (runs, links, lists, tables, pictures)

   Only things that are the same on every computer are written: no file sizes (zip compression may
   differ), no "built" time, no folder names outside the documents folder. Picture addresses are
   written as "media:<document>#<file>", plus "?v=mtime" when the cache-busting number equals the
   document's last-changed time; photo copies as "photo:<file in the Photos folder>", plus "?v=mtime"
   in the same way. Nothing here changes any file. */
(function () {
  'use strict';
  var out = document.getElementById('out');

  function isEmpty(v) {
    return v == null || v === '' || v === false || (Array.isArray(v) && !v.length) ||
      (typeof v === 'object' && !Array.isArray(v) && !Object.keys(v).length);
  }
  // drop empty fields so every line stays short; numbers (also 0) are kept
  function compact(o) {
    var r = {};
    Object.keys(o).forEach(function (k) { if (!isEmpty(o[k])) r[k] = o[k]; });
    return r;
  }

  function run() {
    var G = window.Genealogy, CFG = window.FAMILY_CONFIG, D = window.FAMILY_DATA;
    var missing = [!CFG && 'FAMILY_CONFIG', !D && 'FAMILY_DATA', !G && 'Genealogy', !window.Render && 'Render'].filter(Boolean);
    if (missing.length) throw new Error('not loaded: ' + missing.join(', '));
    if (CFG.settingsProblem) throw new Error('the settings cannot be used: ' + CFG.settingsProblem);
    var M = G.build(D);

    var docById = {};
    (D.docs || []).forEach(function (d) { docById[d.id] = d; });
    Object.keys(M.docs).forEach(function (id) { docById[id] = M.docs[id]; });
    var personOf = new Map();
    Object.keys(M.people).forEach(function (k) { personOf.set(M.people[k], k); });
    var docSet = new Map();
    Object.keys(docById).forEach(function (id) { docSet.set(docById[id], id); });

    function ticks(iso) {
      var ms = Date.parse(iso);
      if (isNaN(ms)) return '';
      return String((BigInt(ms) + 62135596800000n) * 10000n);
    }
    var photoByCopy = {};
    (D.photos || []).forEach(function (ph) { if (ph.img) photoByCopy[String(ph.img).split('?')[0]] = ph; });
    function media(u) {
      if (!u) return u;
      return String(u).replace(/data\/media\/photos\/(p[0-9a-f]{12}\.[a-z]+)(?:\?v=(\d+))?/g, function (all, file, v) {
        var ph = photoByCopy['data/media/photos/' + file];
        var s = 'photo:' + (ph ? ph.path : 'UNKNOWN PHOTO ' + file);
        if (v) s += (ph && v === ticks(ph.mtime)) ? '?v=mtime' : '?v=' + v;
        return s;
      }).replace(/data\/media\/(d[0-9a-f]{12})\/([^?"]+)(?:\?v=(\d+))?/g, function (all, id, file, v) {
        var d = docById[id];
        var s = 'media:' + (d ? d.path : 'UNKNOWN DOCUMENT ' + id) + '#' + file;
        if (v) s += (d && v === ticks(d.mtime)) ? '?v=mtime' : '?v=' + v;
        return s;
      });
    }
    // documents, people and lines are written by name; everything else as it is
    function canon(v, depth) {
      depth = depth || 0;
      if (depth > 12) return '[too deep]';
      if (v === undefined) return '[undefined]';
      if (typeof v === 'function') return '[function]';
      if (typeof v === 'string') return media(v);
      if (v === null || typeof v !== 'object') return v;
      if (docSet.has(v)) return 'doc:' + v.path;
      if (personOf.has(v)) return 'person:' + personOf.get(v);
      for (var l in CFG.lines) if (CFG.lines[l] === v) return 'line:' + l;
      if (Array.isArray(v)) return v.map(function (x) { return canon(x, depth + 1); });
      var r = {};
      Object.keys(v).forEach(function (k) { r[k] = canon(v[k], depth + 1); });
      return r;
    }
    function refs(list) {
      return (list || []).map(function (r) {
        return compact({ name: r.name, code: r.code, written: r.rawCode && r.rawCode !== r.code ? r.rawCode : '', years: r.years, date: r.date, birth: r.birth, death: r.death, badCode: r.badCode, isLine: r.isLine });
      });
    }

    // ---- people, roots first, then by line, generation and number
    var lineOrder = Object.keys(CFG.lines);
    var rootOrder = CFG.roots.map(function (r) { return r.key; });
    var keys = Object.keys(M.people).sort(function (a, b) {
      var pa = M.people[a], pb = M.people[b];
      if (pa.root !== pb.root) return pa.root ? -1 : 1;
      if (pa.root) return rootOrder.indexOf(a) - rootOrder.indexOf(b);
      return (lineOrder.indexOf(pa.letter) - lineOrder.indexOf(pb.letter)) || (pa.gen - pb.gen) || (pa.pos - pb.pos) || (a < b ? -1 : a > b ? 1 : 0);
    });
    var people = keys.map(function (k) {
      var p = M.people[k];
      return [k, compact({
        name: p.name, years: p.years, born: p.born, died: p.died, sex: p.sex, surname: p.surname,
        root: p.root, line: p.letter, relation: G.relationTo(p), nameSource: p.nameSource,
        placeholder: p.placeholder, blocked: p.blocked,
        doc: p.doc ? p.doc.path : null,
        otherDocs: p.docs.filter(function (d) { return d !== p.doc; }).map(function (d) { return d.path; }),
        alsoAt: p.alsoAt,
        father: G.resolve(G.fatherKey(k)), mother: G.resolve(G.motherKey(k)), child: G.resolve(G.childKey(k)), spouse: G.resolve(G.spouseKey(k)),
        photo: media(p.photo), photoFile: p.photoFile, docPhoto: media(p.docPhoto),
        facts: p.facts,
        otherSpouses: refs(p.otherSpouses), otherChildren: refs(p.otherChildren), siblings: refs(p.siblings),
        events: (p.events || []).map(function (e) { return e.year + (e.approx ? ' (about)' : '') + ' ' + (e.label || '-') + ': ' + e.text; }),
        mentions: p.mentions.map(function (m) { return m.role + (m.from ? ' from ' + m.from : '') + ' in ' + (m.doc ? m.doc.path : '?'); })
      })];
    });

    // ---- aliases (every key that resolves to another place)
    var probe = {};
    keys.forEach(function (k) {
      probe[k] = 1;
      [G.fatherKey(k), G.motherKey(k), G.childKey(k), G.spouseKey(k)].forEach(function (x) { if (x) probe[x] = 1; });
      (M.people[k].alsoAt || []).forEach(function (x) { probe[x] = 1; });
    });
    var aliases = Object.keys(probe).sort().filter(function (k) { return G.resolve(k) !== k; }).map(function (k) { return [k, G.resolve(k)]; });

    // ---- documents, in the order of data.js
    var docs = (D.docs || []).map(function (d0) {
      var d = M.docs[d0.id] || d0, info = d.info || {};
      return [d.path, compact({
        id: d.id, kind: d.kind, person: d.personKey, alsoKeys: d.alsoKeys, matchedByName: d.matchedByName, movedFrom: d.movedFrom,
        title: d.title, titleCode: info.titleRawCode, titleName: info.titleName, span: info.span,
        fileKey: d.fileKey, fields: info.fieldOrder, otherMarriages: refs(d.otherMarriages),
        err: d.err, lastError: d.lastError, warn: d.warn, mtime: d.mtime, pictures: d.nimg,
        lines: info.lines ? info.lines.length : 0
      })];
    });

    // ---- notes, item by item
    var notes = Object.keys(M.notes).map(function (sec) {
      var list = M.notes[sec];
      return [sec, Array.isArray(list) ? list.map(function (x) { return canon(x); }) : [canon(list)]];
    });

    var blocks = (D.docs || []).map(function (d) { return [d.path, (d.b || []).map(function (b) { return canon(b); })]; });

    var known = keys.filter(function (k) { var p = M.people[k]; return G.resolve(k) === k && (p.doc || p.root || p.nameSource > 0); });
    var summary = {
      documents: (D.docs || []).length, readErrors: (D.errors || []).length, otherFiles: (D.other || []).length,
      photos: (D.photos || []).length, withPhoto: keys.filter(function (k) { return M.people[k].photo; }).length,
      places: keys.length, knownPeople: known.length,
      withLifeHistory: keys.filter(function (k) { return M.people[k].doc && !M.people[k].root; }).length,
      aliases: aliases.length, stories: (M.stories || []).length, builder: D.builder
    };

    // ---- write: valid JSON, one item per line
    var L = [];
    function J(v) { return JSON.stringify(v); }
    function lines(pairs, deep) {
      return pairs.map(function (pair, i) {
        var comma = i < pairs.length - 1 ? ',' : '';
        if (!deep) return '  ' + J(pair[0]) + ': ' + J(pair[1]) + comma;
        var items = pair[1];
        if (!items.length) return '  ' + J(pair[0]) + ': []' + comma;
        return '  ' + J(pair[0]) + ': [\n' + items.map(function (x, j) { return '   ' + J(x) + (j < items.length - 1 ? ',' : ''); }).join('\n') + '\n  ]' + comma;
      }).join('\n');
    }
    function section(name, pairs, deep, last) {
      L.push(' ' + J(name) + ': {' + (pairs.length ? '\n' + lines(pairs, deep) + '\n ' : '') + '}' + (last ? '' : ','));
    }
    L.push('{');
    L.push(' "snapshot": "Family Tree Viewer test family, format 1",');
    L.push(' "summary": ' + J(summary) + ',');
    section('people', people);
    section('aliases', aliases);
    section('docs', docs);
    L.push(' "stories": ' + J((M.stories || []).map(function (d) { return d.path; })) + ',');
    section('notes', notes, true);
    section('data', [['errors', (D.errors || []).map(function (e) { return canon(e); })], ['other', (D.other || []).map(function (o) { return o.path; })],
      ['photosFolder', [D.photosFolder ? { exists: D.photosFolder.exists, inSource: D.photosFolder.path === D.source + '\\Photos' } : null]],
      ['photos', (D.photos || []).map(function (ph) { return canon(ph); })]], true);
    section('blocks', blocks, true, true);
    L.push('}');
    return L.join('\n');
  }

  try {
    var text = run();
    var loadErrors = window.SNAP_LOAD_ERRORS || [];
    out.textContent = loadErrors.length ? 'ERROR\tsomething could not be loaded: ' + loadErrors.join(' | ') : text;
  } catch (e) {
    out.textContent = 'ERROR\t' + (e && e.message) + '\n' + (e && e.stack || '') + '\n' + (window.SNAP_LOAD_ERRORS || []).join(' | ');
  }
})();
