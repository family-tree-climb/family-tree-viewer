/* Family Tree Viewer — pages, tree chart, search and live updates. */
(function () {
  'use strict';
  var CFG = window.FAMILY_CONFIG, G = window.Genealogy, R = window.Render;
  var esc = R.esc;
  var main = document.getElementById('main');
  var M = null;                       // the family model (built from data.js)
  var LINE_ORDER = Object.keys(CFG.lines);
  var VERSION = typeof window.FAMILY_VERSION === 'string' ? window.FAMILY_VERSION : '';   // app/version.js

  // ------------------------------------------------------------------ small helpers
  function storeGet(k, d) { try { var v = localStorage.getItem('ft.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }
  function storeSet(k, v) { try { localStorage.setItem('ft.' + k, JSON.stringify(v)); } catch (e) { } }
  function personHref(p) { return '#/p/' + encodeURIComponent(p.key); }
  function treeHref(p) { return '#/tree/' + encodeURIComponent(p.key); }
  function byKey(k) { k = G.resolve(k); return k && M.people[k] ? M.people[k] : null; }
  function father(p) { return byKey(G.fatherKey(p.key)); }
  function mother(p) { return byKey(G.motherKey(p.key)); }
  function child(p) { return byKey(G.childKey(p.key)); }
  function spouse(p) { return byKey(G.spouseKey(p.key)); }
  function known(p) { return p && (p.doc || p.root || p.nameSource > 0); }
  function sortPeople(list) {
    return list.sort(function (a, b) {
      if (a.root !== b.root) return a.root ? -1 : 1;
      var la = LINE_ORDER.indexOf(a.letter), lb = LINE_ORDER.indexOf(b.letter);
      if (a.letter === 'W' && b.letter === 'M') la = lb + 1;
      if (la !== lb) return la - lb;
      return (a.gen - b.gen) || (a.pos - b.pos);
    });
  }
  function allPeople() {
    // each person once (a shared ancestor reached through two lines is listed at the main place only)
    return Object.keys(M.people).filter(function (k) { return G.resolve(k) === k; }).map(function (k) { return M.people[k]; }).filter(known);
  }
  function fmtDate(iso) {
    var d = new Date(iso); if (isNaN(d)) return '';
    return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  }
  function relTime(iso) {
    var d = new Date(iso); if (isNaN(d)) return '';
    var days = Math.floor((Date.now() - d.getTime()) / 86400000);
    var sameDay = new Date().toDateString() === d.toDateString();
    if (sameDay) return 'today ' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    if (days <= 1) return 'yesterday';
    if (days < 7) return days + ' days ago';
    return fmtDate(iso);
  }
  function lineName(p) { return p && p.line ? p.line.name + ' line' : ''; }
  function rootOf(p) {
    if (!p) return null;
    if (p.root) return p;
    return p.line ? byKey(p.line.root) : null;
  }
  var SIL = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8.2" r="4.4" fill="currentColor"/><path d="M3.5 21.5c.8-4.6 4.2-7.2 8.5-7.2s7.7 2.6 8.5 7.2" fill="currentColor"/></svg>';
  function avatar(p, extra) {
    var cls = 'avatar ' + ((p && p.sex) || '') + (extra ? ' ' + extra : '');
    if (p && p.photo) return '<span class="' + cls + '"><img src="' + esc(p.photo) + '" alt="" loading="lazy">' + flagImg(p) + '</span>';
    return '<span class="' + cls + ' noimg">' + SIL + flagImg(p) + '</span>';
  }
  // the flag of the country a person came from (genealogy.js decides which; app/flags.js has the pictures)
  var flagUrls = {};
  function flagUrl(code) {
    var svg = window.FAMILY_FLAGS && window.FAMILY_FLAGS[code];
    if (!svg) return '';
    return flagUrls[code] || (flagUrls[code] = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg));
  }
  function flagImg(p, cls) {
    var url = p && p.flag ? flagUrl(p.flag.code) : '';
    return url ? '<img class="' + (cls || 'flag') + '" src="' + url + '" alt="' + esc(p.flag.country) + '" title="Came from ' + esc(p.flag.country) + '">' : '';
  }
  function famPerson(p, emptyLabel, note) {
    if (!known(p)) return '<div class="fam-person unknown"><span class="avatar">' + SIL + '</span><div><div class="fp-name">' + esc(emptyLabel || 'Unknown') + '</div></div></div>';
    return '<a class="fam-person" href="' + personHref(p) + '">' + avatar(p) + '<div><div class="fp-name">' + esc(p.short) + '</div><div class="fp-years">' +
      esc([p.years, note].filter(Boolean).join(' · ')) + '</div></div></a>';
  }
  function setNav(page) {
    var map = { home: 'home', tree: 'tree', p: 'people', people: 'people', stories: 'stories', doc: 'stories', notes: 'notes', help: 'help' };
    Array.prototype.forEach.call(document.querySelectorAll('.mainnav a'), function (a) { a.classList.toggle('active', a.getAttribute('data-nav') === map[page]); });
  }
  // "‹ Back" goes to the page before (or home when there is none)
  function backButton() { return '<button class="btn backbtn" data-back="1">‹ Back</button>'; }
  document.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('[data-back]');
    if (!b) return;
    if (history.length > 1) history.back(); else location.hash = '#/';
  });
  function factsCount(p) { var f = p.facts || {}; return Object.keys(f).filter(function (k) { return f[k] && f[k].length; }).length; }
  function sameNames(a, b) {
    var x = G.normName(G.shortName(a)).split(' '), y = G.normName(G.shortName(b)).split(' ');
    return !!(x[0] && y[0] && x[0] === y[0] && x[x.length - 1] === y[y.length - 1]);
  }
  // Word writes ’ and “ ”; a keyboard types ' and " — treat them as the same when searching
  function plainQuotes(s) { return String(s || '').replace(/[’‘ʼ`´]/g, "'").replace(/[“”]/g, '"'); }
  function title(t) { document.title = t ? t + ' — ' + (CFG.title || 'Family Tree') : (CFG.title || 'Family Tree'); }
  function sourcePath(doc) { return (M.data.source || '') + '\\' + doc.path; }

  // ------------------------------------------------------------------ routing
  function route() {
    if (!M) return;
    var h = location.hash.replace(/^#\/?/, '');
    var parts = h.split('/').map(function (s) { try { return decodeURIComponent(s); } catch (e) { return s; } });
    var page = parts[0] || 'home';
    setNav(page);
    closeLightbox();
    closeTreeSide();
    try {
      switch (page) {
        case 'tree': pageTree(parts[1]); break;
        case 'p': pagePerson(parts[1], parts[2]); break;
        case 'doc': pageDoc(parts[1]); break;
        case 'people': pagePeople(); break;
        case 'stories': pageStories(); break;
        case 'search': pageSearch(parts.slice(1).join('/')); break;
        case 'notes': pageNotes(); break;
        case 'help': pageHelp(parts[1]); break;
        default: pageHome();
      }
    } catch (e) {
      main.innerHTML = '<div class="page narrow"><div class="card"><h2>Something went wrong showing this page</h2><p class="muted">' + esc(e && e.message) + '</p><p><a href="#/">Go to the home page</a></p></div></div>';
      if (window.console) console.error(e);
    }
    if (page !== 'tree' && !route.keepScroll) window.scrollTo(0, 0);
    route.keepScroll = false;
  }
  window.addEventListener('hashchange', route);

  document.getElementById('searchform').addEventListener('submit', function (e) {
    e.preventDefault();
    var q = document.getElementById('searchinput').value.trim();
    if (q) location.hash = '#/search/' + encodeURIComponent(q);
  });

  // ------------------------------------------------------------------ HOME
  function pageHome() {
    title('');
    var people = allPeople();
    var withDocs = people.filter(function (p) { return p.doc; }).length;
    var maxGen = people.reduce(function (m, p) { return Math.max(m, p.gen || 0); }, 0);
    var earliest = people.reduce(function (m, p) { return p.born && (!m || p.born < m) ? p.born : m; }, null);
    var surnames = {};
    people.forEach(function (p) { if (p.surname) surnames[p.surname.toLowerCase()] = 1; });
    var html = '<div class="page">';
    html += '<div class="hero"><div><h1>' + esc(CFG.title) + '</h1><p class="sub">' + esc(CFG.subtitle || '') + '</p></div>' +
      '<div class="stats">' +
      stat(people.length, 'people') + stat(withDocs, 'life histories') + stat(maxGen + 1, 'generations') +
      (earliest ? stat(earliest, 'earliest year') : '') + stat(Object.keys(surnames).length, 'surnames') + '</div></div>';

    html += '<div class="rootcards">';
    CFG.roots.forEach(function (r) {
      var p = byKey(r.key); if (!p) return;
      var f = father(p), m = mother(p);
      var lines = LINE_ORDER.filter(function (l) { return CFG.lines[l].root === r.key; });
      var count = people.filter(function (q) { return q.line && q.line.root === r.key; }).length;
      var oldest = people.filter(function (q) { return q.line && q.line.root === r.key && q.born; }).reduce(function (a, q) { return !a || q.born < a ? q.born : a; }, null);
      html += '<a class="card rootcard" href="' + treeHref(p) + '"><div class="faces">' + avatar(f) + avatar(m) + '</div><div>' +
        '<h2>' + esc(r.short) + '’s family tree</h2><p>' + count + ' ancestors' + (oldest ? ', back to ' + oldest : '') + '</p>' +
        '<div class="linelist">' + lines.map(function (l) { return '<span class="chip">' + esc(CFG.lines[l].name) + ' — ' + esc(CFG.lines[l].side) + '</span>'; }).join('') + '</div>' +
        '</div></a>';
    });
    html += '</div>';

    var recent = Object.keys(M.docs).map(function (id) { return M.docs[id]; }).filter(function (d) { return d.kind === 'person' || d.kind === 'story'; })
      .sort(function (a, b) { return a.mtime < b.mtime ? 1 : -1; }).slice(0, 10);
    html += '<div class="grid2"><div class="card"><h2>Recently written or updated</h2><ul class="recent">' +
      recent.map(function (d) {
        var p = d.personKey ? byKey(d.personKey) : null;
        var href = p ? personHref(p) : '#/doc/' + d.id;
        var label = p ? p.short : (d.title || d.name);
        var extra = p ? '<span class="chip code">' + esc(p.code || p.short) + '</span>' : '<span class="chip gold">story</span>';
        return '<li><a href="' + href + '">' + esc(label) + '</a> ' + extra + '<span class="when">' + esc(relTime(d.mtime)) + '</span></li>';
      }).join('') + '</ul></div>';

    html += '<div class="card"><h2>Stories &amp; research</h2><ul class="recent">' +
      M.stories.slice().sort(function (a, b) { return a.mtime < b.mtime ? 1 : -1; }).slice(0, 8).map(function (d) {
        return '<li><a href="#/doc/' + d.id + '">' + esc(d.title || d.name) + '</a><span class="when">' + esc(relTime(d.mtime)) + '</span></li>';
      }).join('') + '</ul><p class="small" style="margin:10px 0 0"><a href="#/stories">All stories and other documents →</a></p></div></div>';

    html += '<div class="card" style="margin-top:18px"><h2>Adding to the family tree</h2><p style="margin:0">Write or edit life histories in Word as usual, in the <b>life history</b> folder. ' +
      'Each time the <b>Family Tree</b> icon is opened, new and changed documents are read automatically and appear here. Your documents are never changed. ' +
      '<a href="#/help">How it works →</a></p></div>';
    html += footer() + '</div>';
    main.innerHTML = html;
  }
  function stat(n, label) { return '<div class="stat"><b>' + esc(n) + '</b><span>' + esc(label) + '</span></div>'; }
  function footer() {
    var d = M.data;
    return '<footer class="foot">Documents last checked ' + esc(relTime(lastChecked || d.built)) + ' · ' + d.docs.length + ' documents · <a href="#/help">Help</a></footer>';
  }

  // ------------------------------------------------------------------ TREE (pedigree chart)
  var treeState = { gens: 4 };          // always start at 4 generations (5 and 6 are for a closer look)
  // Is anyone known in the generations above this place?
  function hasKnownAbove(key, depth) {
    if (!key || depth <= 0) return false;
    key = G.resolve(key);
    var f = G.resolve(G.fatherKey(key)), m = G.resolve(G.motherKey(key));
    return known(byKey(f)) || known(byKey(m)) || hasKnownAbove(f, depth - 1) || hasKnownAbove(m, depth - 1);
  }
  // A place in the tree with nobody known there yet (used when the tree starts from such a place).
  function slotPerson(key) {
    var c = G.parseKey(key);
    if (!c) return null;
    var sex = G.sexOf(key);
    return { key: key, code: key, gen: c.gen, pos: c.pos, letter: c.letter, line: CFG.lines[c.letter], sex: sex, pseudo: true,
      name: sex === 'f' ? 'Mother not known yet' : 'Father not known yet', short: sex === 'f' ? 'Mother not known yet' : 'Father not known yet', years: '', docs: [], mentions: [] };
  }
  // "Walter Lemuel Lyle Thornbury" -> "Walter L. L. Thornbury" for a small card
  function cardName(p, maxChars) {
    var n = p.short;
    if (n.length <= maxChars) return n;
    var parts = n.split(' ');
    if (parts.length < 3) return n;
    var suffix = /^(Sr\.?|Jr\.?|I|II|III|IV|V|MD)$/.test(parts[parts.length - 1].replace(/,$/, '')) ? ' ' + parts.pop() : '';
    var last = parts.pop(), first = parts.shift();
    var mid = parts.map(function (w) { return /^["“'‘(]/.test(w) || /\d/.test(w) ? w : w.charAt(0) + '.'; }).join(' ');
    return (first + ' ' + mid + ' ' + last + suffix).replace(/\s+/g, ' ');
  }

  function pageTree(key) {
    var wanted = key;
    var root = byKey(key);
    var notice = '';
    if (!root && key && G.parseKey(key) && hasKnownAbove(key, 14)) root = slotPerson(key);
    if (!root) {
      if (key) notice = 'No one with the number ' + key + ' is in the tree yet, so ' + (byKey(storeGet('treeRoot', '')) || byKey(CFG.roots[0].key)).short + '’s tree is shown instead.';
      root = byKey(storeGet('treeRoot', '')) || byKey(CFG.roots[0].key);
    }
    if (!root.pseudo) storeSet('treeRoot', root.key);
    title(root.short + '’s tree');
    var gens = Math.max(3, Math.min(6, treeState.gens || 4));

    // chain from the base person (a root in the settings) up to this root, for the breadcrumb
    var chain = [], c = root, guard = 0;
    while (c && guard++ < 40) { chain.unshift(c); if (c.root) break; c = byKey(G.childKey(c.key)) || (G.childKey(c.key) ? slotPerson(G.childKey(c.key)) : null); }

    var first = root.short.split(' ')[0];
    var html = '<div class="page treepage">';
    if (notice) html += '<div class="notice">' + esc(notice) + '</div>';
    html += '<div class="treebar"><h1>' + esc(root.short) + '</h1><span class="muted">' + esc(root.years || '') + '</span>' +
      (root.root ? '' : '<span class="chip">' + esc(G.relationTo(root)) + '</span>') +
      '<span class="spacer"></span>' +
      '<div class="seg" role="group" aria-label="Whose tree">' + CFG.roots.map(function (r) {
        return '<button data-goto="' + esc(r.key) + '" class="' + (chain[0] && chain[0].key === r.key ? 'on' : '') + '">' + esc(r.short) + '’s tree</button>';
      }).join('') + '</div>' +
      '<span class="muted small">Show</span><div class="seg" role="group" aria-label="How many generations">' + [3, 4, 5, 6].map(function (g) {
        return '<button data-gens="' + g + '" class="' + (g === gens ? 'on' : '') + '">' + g + '</button>';
      }).join('') + '</div><span class="muted small">generations</span>' +
      (root.pseudo ? '' : '<a class="btn" href="' + personHref(root) + '">Open ' + esc(first) + '’s page</a>') + '</div>';
    if (chain.length > 1) {
      html += '<div class="crumbs">Back toward ' + esc(chain[0].short.split(' ')[0]) + ': ' + chain.map(function (p, i) {
        return i === chain.length - 1 ? '<b>' + esc(p.short) + '</b>' : (p.pseudo ? esc(p.short) : '<a href="' + treeHref(p) + '">' + esc(p.short) + '</a>');
      }).join(' › ') + '</div>';
    }
    html += '<div class="pedigree" id="pedigree"></div>' +
      '<div class="treekey"><span class="k">Click a name to read about that person.</span>' +
      '<span class="k"><span class="sw m"></span>man</span><span class="k"><span class="sw f"></span>woman</span>' +
      '<span class="k"><span class="sw u"></span>not found yet</span>' +
      '<span class="k"><b>›</b> go further back</span>' + (chain.length > 1 ? '<span class="k"><b>‹</b> back toward ' + esc(chain[0].short.split(' ')[0]) + '</span>' : '') +
      '<span class="k"><b>H3,1</b> = the number in the document’s name</span></div></div>';
    main.innerHTML = html;

    Array.prototype.forEach.call(main.querySelectorAll('[data-gens]'), function (b) {
      b.onclick = function () { treeState.gens = +b.getAttribute('data-gens'); pageTree(wanted || root.key); };
    });
    Array.prototype.forEach.call(main.querySelectorAll('[data-goto]'), function (b) {
      b.onclick = function () { location.hash = '#/tree/' + encodeURIComponent(b.getAttribute('data-goto')); };
    });
    drawPedigree(root, gens);
  }

  function drawPedigree(root, gens) {
    var box = document.getElementById('pedigree');
    var avail = Math.max(760, box.clientWidth || (window.innerWidth - 40));
    var chKey = G.childKey(root.key);
    var ch = byKey(chKey) || (chKey && !root.root ? slotPerson(chKey) : null);
    var gap = gens >= 5 ? 30 : 40, padX = ch ? 44 : 16, padTop = 30, padBottom = 10, arrowRoom = 40;
    var cardW = Math.floor(Math.min(gens <= 3 ? 320 : 290, (avail - padX * 2 - arrowRoom - gap * (gens - 1)) / gens));
    var rows = Math.pow(2, gens - 1);
    var compact = gens >= 5;
    // fit the chart to the screen height (a small laptop screen is only 768 pixels tall)
    var boxTop = box.getBoundingClientRect().top + window.scrollY;
    var keyH = 34;
    var viewH = Math.max(window.innerHeight - boxTop - keyH - 22, 340);
    var vgap = compact ? (gens >= 6 ? 3 : 5) : 8;
    var fitH = Math.floor((viewH - padTop - padBottom) / rows) - vgap;
    var cardH = compact ? Math.max(gens >= 6 ? 22 : 26, Math.min(gens >= 6 ? 28 : 34, fitH)) : Math.max(44, Math.min(gens === 3 ? 84 : 64, fitH));
    var tight = !compact && cardH < 56;
    var totalH = Math.max(rows * (cardH + vgap), viewH - padTop - padBottom);
    var width = padX * 2 + gens * cardW + (gens - 1) * gap + arrowRoom;
    var height = padTop + totalH + padBottom;
    var maxChars = Math.floor((cardW - (compact ? 90 : 60)) / (compact ? 7.4 : 8.3));

    var slots = [], shown = [];
    for (var c = 0; c < gens; c++) {
      slots[c] = []; shown[c] = [];
      for (var i = 0; i < Math.pow(2, c); i++) {
        if (c === 0) { slots[c][i] = root.key; continue; }
        var childKey = G.resolve(slots[c - 1][i >> 1]);
        slots[c][i] = childKey ? G.resolve(i % 2 === 0 ? G.fatherKey(childKey) : G.motherKey(childKey)) : null;
      }
    }
    var html = '', paths = '';
    var labels = ['', first(root) + '’s parents', 'Grandparents', 'Great-grandparents', '2nd great-grandparents', '3rd great-grandparents'];
    function first(p) { return p.short.split(' ')[0]; }
    for (c = 0; c < gens; c++) {
      var x = padX + c * (cardW + gap);
      html += '<div class="gencol-label" style="left:' + x + 'px">' + esc(labels[c] || '') + '</div>';
      var n = Math.pow(2, c);
      for (i = 0; i < n; i++) {
        var key = slots[c][i];
        var cy = padTop + (i + 0.5) * totalH / n;
        var y = Math.round(cy - cardH / 2);
        if (c > 0 && !shown[c - 1][i >> 1]) continue;
        var p = c === 0 ? root : byKey(key);
        var draw = false, isKnown = c === 0 || known(p);
        var above = !isKnown && key && hasKnownAbove(key, gens - 1 - c + 8);
        if (isKnown) draw = true;
        else if (key) {
          var childKnown = c > 0 && (c - 1 === 0 || known(byKey(slots[c - 1][i >> 1])));
          draw = childKnown || hasKnownAbove(key, gens - 1 - c);
        }
        if (!draw) continue;
        shown[c][i] = isKnown || hasKnownAbove(key, gens - 1 - c);
        if (c > 0) {
          var px = padX + (c - 1) * (cardW + gap) + cardW, pcy = padTop + ((i >> 1) + 0.5) * totalH / (n / 2);
          var mid = px + gap / 2;
          paths += '<path d="M' + px + ' ' + pcy + ' H' + mid + ' V' + cy + ' H' + x + '"/>';
        }
        // the person the tree starts from has room for a taller card with the whole name
        var h = c === 0 ? Math.max(cardH, 66) : cardH;
        if (c === 0) y = Math.round(cy - h / 2);
        var style = 'left:' + x + 'px;top:' + y + 'px;width:' + cardW + 'px;height:' + h + 'px';
        if (!isKnown) {
          var label = i % 2 === 0 ? 'Father not found yet' : 'Mother not found yet';
          if (above) html += '<a class="pcard empty link' + (compact ? ' compact' : '') + '" href="#/tree/' + encodeURIComponent(key) + '" style="' + style + '" title="Ancestors are known further back: click to see them">' + label + ' ›</a>';
          else html += '<div class="pcard empty' + (compact ? ' compact' : '') + '" style="' + style + '">' + label + '</div>';
          continue;
        }
        var small = c > 0 && (compact || tight);
        var nm = small ? cardName(p, maxChars) : p.short;
        var yearsText = p.years || (p.doc || p.root ? '' : (compact ? '' : 'no life history yet'));
        var tag = p.pseudo ? 'div' : 'a';
        html += '<' + tag + ' class="pcard ' + (p.sex || '') + (compact && c > 0 ? ' compact' + (gens >= 6 ? ' g6' : '') : '') + (tight && c > 0 ? ' tight' : '') + (c === 0 ? ' root' : '') + (p.doc || p.root ? '' : ' nodoc') + '"' +
          (p.pseudo ? '' : ' href="' + personHref(p) + '"') + ' style="' + style + '" title="' + esc(p.name + (p.years ? ' (' + p.years + ')' : '') + (p.code ? ' · ' + p.code : '')) + '">' +
          avatar(p) + '<div class="pc-text"><div class="pc-name">' + esc(nm) + '</div><div class="pc-years"><span>' + esc(yearsText) + '</span>' +
          (p.code && !compact ? '<span class="pc-flag">' + esc(p.code) + '</span>' : '') + '</div></div></' + tag + '>';
        // arrow to go further back
        if (c === gens - 1 && !p.pseudo && hasKnownAbove(p.key, 12)) {
          var aw = compact ? 22 : 30;
          html += '<a class="more-arrow' + (compact ? ' small' : '') + '" href="' + treeHref(p) + '" title="Show ' + esc(p.short) + '’s ancestors" style="left:' + (x + cardW + 6) + 'px;top:' + Math.round(cy - aw / 2) + 'px">›</a>';
        }
      }
    }
    if (ch) {
      html += '<a class="more-arrow" href="' + (ch.pseudo ? '#/tree/' + encodeURIComponent(ch.key) : treeHref(ch)) + '" title="Back to ' + esc(ch.short) + '" style="left:8px;top:' + Math.round(padTop + totalH / 2 - 15) + 'px">‹</a>';
    }
    box.style.height = Math.min(height + 4, viewH + 4) + 'px';
    box.innerHTML = '<div style="position:relative;width:' + width + 'px;height:' + height + 'px">' +
      '<svg class="links" width="' + width + '" height="' + height + '">' + paths + '</svg>' + html + '</div>';
  }
  function closeTreeSide() { }
  // ------------------------------------------------------------------ PERSON
  function pagePerson(key, tab) {
    var p = byKey(key);
    if (!p) { notFound('No one with the number ' + key + ' is in the tree yet.'); return; }
    title(p.short);
    tab = tab || 'story';     // a person always opens on the life story unless the address names a tab
    var pics = galleryOf(p);
    var mentions = p.mentions.filter(function (m) { return m.doc !== p.doc; });
    var tabs = [['story', 'Life story'], ['facts', 'Facts & timeline'], ['pictures', 'Pictures', pics.length], ['mentions', 'Mentioned in', mentions.length]];
    if (!p.doc) tabs[0][1] = 'About';
    tabs = tabs.filter(function (t) { return t[2] == null || t[2] > 0; });           // no empty tabs
    if (!p.doc && !factsCount(p)) tabs = tabs.filter(function (t) { return t[0] !== 'facts'; });
    if (tabs.every(function (t) { return t[0] !== tab; })) tab = 'story';

    var relation = G.relationTo(p);
    var html = '<div class="page">' + backButton() + '<div class="person-head">' + avatar(p, p.photo ? '' : 'noimg').replace('<span class="avatar', p.photo ? '<span tabindex="0" title="Enlarge" class="avatar' : '<span class="avatar') +
      '<div><h1>' + esc(p.name) + '</h1><div class="years">' + esc(p.years || '') + '</div><div class="rel">' +
      (relation ? '<span class="chip">' + esc(relation) + '</span>' : '') +
      (p.line ? '<span class="chip gold">' + esc(lineName(p)) + '</span>' : '') +
      (p.flag ? '<span class="chip flagchip">' + flagImg(p, 'chipflag') + 'Came from ' + esc(p.flag.country) + '</span>' : '') +
      (p.code ? '<span class="chip code" title="Generation ' + p.gen + ', number ' + p.pos + '">' + esc(p.code) + '</span>' : '') +
      '</div></div><div class="actions"><a class="btn primary" href="' + treeHref(p) + '">Show ' + esc(p.short.split(' ')[0]) + '’s ancestors</a>' +
      (photoName(p) ? '<button class="btn" id="photobtn" type="button" aria-expanded="false" aria-controls="photohelp">' + (p.photoFile ? 'Change photo' : 'Add a photo') + '</button>' : '') +
      (p.doc ? '<button class="btn" id="printbtn">Print</button>' : '') + '</div></div>' + photoHelp(p);

    if (p.doc && p.doc.lastError) {
      html += '<div class="notice">The Word document could not be read at the last update (' + esc(p.doc.lastError) + '). The version from ' + esc(fmtDate(p.doc.mtime)) + ' is shown until it can be read again.</div>';
    }
    if (p.alsoAt && p.alsoAt.length) {
      html += '<div class="notice soft">' + esc(p.short.split(' ')[0]) + ' appears more than once in the tree (the same ancestor reached through two lines). Also at: ' +
        p.alsoAt.map(function (k) { var c = byKey(G.childKey(k)); return '<b>' + esc(k) + '</b>' + (c ? ' (parent of <a href="' + personHref(c) + '">' + esc(c.short) + '</a>)' : ''); }).join(', ') + '.</div>';
    }
    var others = p.docs.filter(function (d) { return d !== p.doc && d.personKey === p.key; });
    var otherPeople = others.filter(function (d) { return d.info && p.doc && p.doc.info && !sameNames(d.info.titleName, p.doc.info.titleName); });
    others = others.filter(function (d) { return otherPeople.indexOf(d) < 0; });
    if (otherPeople.length) {
      html += '<div class="notice">Another document with the number ' + esc(p.code) + ' is about a different name: ' + otherPeople.map(function (d) {
        return '<a href="#/doc/' + d.id + '">' + esc(d.info.titleName || d.name) + '</a> <span class="small">(' + esc(d.name) + ', changed ' + esc(fmtDate(d.mtime)) + ')</span>';
      }).join(', ') + '. Only one person can have each number; see Research notes.</div>';
    }
    if (others.length) {
      html += '<div class="notice">There ' + (others.length === 1 ? 'is another document' : 'are ' + others.length + ' other documents') + ' about ' + esc(p.short.split(' ')[0]) + ': ' +
        others.map(function (d) { return '<a href="#/doc/' + d.id + '">' + esc(d.name) + '</a> <span class="small">(changed ' + esc(fmtDate(d.mtime)) + ')</span>'; }).join(', ') +
        '. The version whose file name starts with the number (or else the most recently changed one) is shown below.</div>';
    }

    html += '<div class="person-layout"><div><div class="tabs" role="tablist">' + tabs.map(function (t) {
      return '<button data-tab="' + t[0] + '" class="' + (t[0] === tab ? 'on' : '') + '">' + esc(t[1]) + (t[2] != null ? '<span class="count">' + t[2] + '</span>' : '') + '</button>';
    }).join('') + '</div><div id="tabbody"></div></div>' + familySide(p) + '</div>' + footer() + '</div>';
    main.innerHTML = html;
    Array.prototype.forEach.call(main.querySelectorAll('[data-tab]'), function (b) {
      b.onclick = function () {
        var t = b.getAttribute('data-tab');
        try { history.replaceState(null, '', personHref(p) + (t === 'story' ? '' : '/' + t)); } catch (e) { }
        Array.prototype.forEach.call(main.querySelectorAll('[data-tab]'), function (x) { x.classList.toggle('on', x === b); });
        showTab(p, t, pics, mentions);
      };
    });
    var pb = document.getElementById('printbtn');
    if (pb) pb.onclick = function () {
      showTab(p, 'story', pics, mentions);
      Array.prototype.forEach.call(main.querySelectorAll('[data-tab]'), function (x) { x.classList.toggle('on', x.getAttribute('data-tab') === 'story'); });
      setTimeout(function () { window.print(); }, 60);
    };
    var phb = document.getElementById('photobtn'), phh = document.getElementById('photohelp');
    if (phb && phh) {
      phb.onclick = function () {
        phh.hidden = !phh.hidden;
        phb.setAttribute('aria-expanded', String(!phh.hidden));
        if (!phh.hidden) phh.scrollIntoView({ block: 'nearest' });
      };
      Array.prototype.forEach.call(phh.querySelectorAll('[data-copytext]'), function (b) {
        var label = b.textContent;
        b.onclick = function () { copyText(b.getAttribute('data-copytext'), function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = label; }, 2000); }); };
      });
    }
    var av = main.querySelector('.person-head .avatar img:not(.flag)');
    if (av) av.parentNode.onclick = function () { openLightbox([{ img: p.photo, caption: p.name }], 0); };
    showTab(p, tab, pics, mentions);
  }

  // ------------------------------------------------------------------ PHOTOS
  // A photo for the square: a picture in the Photos folder of the life-history folder whose file name is
  // the person's number (genealogy.js matches them; tools\Update-FamilyTree.ps1 makes the copies).
  function photoName(p) { return p && !p.pseudo ? (p.code || (p.root ? p.key : '')) : ''; }
  function photosFolder() {
    var f = M.data.photosFolder || {};
    return { path: f.path || ((M.data.source || '') + '\\Photos'), exists: f.exists === true || (M.data.photos || []).length > 0 };
  }
  function photoHelp(p) {
    var name = photoName(p);
    if (!name) return '';
    var first = esc(p.short.split(' ')[0]), folder = photosFolder();
    var where = folder.path + '\\' + name;
    var parent = folder.path.replace(/\\[^\\]*$/, '');
    var html = '<div class="card photohelp" id="photohelp" hidden><h2>' + (p.photoFile ? 'Change the photo of ' : 'Add a photo of ') + first + '</h2>';
    if (p.photoFile) html += '<p>The photo now comes from <b>' + esc(p.photoFile) + '</b>. To change it, put another picture in its place with the same name (or delete it to have no photo).</p>';
    else if (p.photo) html += '<p>Right now the photo is a picture from the life history. A photo you put in the Photos folder is shown instead.</p>';
    html += '<ol class="helpsteps">';
    if (!folder.exists) {
      html += '<li><b>Only the first time:</b> make a folder named <b>Photos</b> in the life history folder (<span class="path">' + esc(parent) + '</span>). ' +
        'Open that folder, right-click an empty spot, choose <i>New</i> \u2192 <i>Folder</i> and type <b>Photos</b>.</li>';
    }
    html += '<li>Save the photo in the <b>Photos</b> folder with the name <b>' + esc(name) + '</b>. ' +
      '<p class="photo-copy"><button class="btn" type="button" data-copytext="' + esc(where) + '">Copy where to save</button> ' +
      '<button class="btn" type="button" data-copytext="' + esc(name) + '">Copy the name</button></p>' +
      '<p class="small muted">Saving a picture from an email or a web page (<i>Save as\u2026</i>): click <b>Copy where to save</b>, paste it into the <i>File name</i> box and click <i>Save</i>. ' +
      'A picture already on the computer: copy it into the Photos folder, then rename it to <b>' + esc(name) + '</b> (the ending, such as .jpg, stays).</p></li>' +
      '<li>Open the <b>Family Tree</b> icon on the desktop again. The photo appears in ' + first + '\u2019s square, in the tree and everywhere else.</li></ol>' +
      '<p class="small muted" style="margin-bottom:0">JPEG and PNG pictures work. Words may follow the number, for example <i>' + esc(name) + ' at 20.jpg</i>. ' +
      'The square shows the middle of the picture and keeps the top, so faces are not cut off; a picture cropped close around the face looks best.</p>' +
      '<p class="small muted" style="margin-bottom:0"><b>A flag in the corner</b> shows where someone came from. Write a line at the top of the life history such as ' +
      '<i>Arrived: 1848, from Ireland</i> (or <i>Flag: Ireland</i>), then open the Family Tree icon again.' + (p.flag ? ' Now: ' + esc(p.flag.country) + '.' : '') + '</p></div>';
    return html;
  }

  function showTab(p, tab, pics, mentions) {
    var body = document.getElementById('tabbody');
    if (tab === 'facts') body.innerHTML = factsHtml(p);
    else if (tab === 'pictures') {
      body.innerHTML = pics.length ? '<div class="gallery">' + pics.map(function (g, i) {
        return '<figure tabindex="0" data-i="' + i + '"><img src="' + esc(g.img) + '" loading="lazy" alt="">' + (g.caption ? '<figcaption>' + esc(g.caption) + '</figcaption>' : '') + '</figure>';
      }).join('') + '</div>' : '<div class="empty-state">There are no pictures in ' + esc(p.short.split(' ')[0]) + '’s life history yet.</div>';
      Array.prototype.forEach.call(body.querySelectorAll('figure'), function (f) { f.onclick = function () { openLightbox(pics, +f.getAttribute('data-i')); }; });
    }
    else if (tab === 'mentions') body.innerHTML = mentionsHtml(p, mentions);
    else body.innerHTML = storyHtml(p);
    if (tab === 'story' || !tab) wireDoc(body, p.doc);
  }

  function storyHtml(p) {
    if (p.doc) {
      var hl = takeHighlight();
      var out = R.renderDoc(p.doc, { selfKey: p.key, highlight: hl });
      return '<article class="docpaper linked">' + out.html + '</article>' + docMeta(p.doc);
    }
    var html = '<div class="card">';
    if (p.root) {
      html += '<p>' + esc(p.name) + ' is at the root of this family tree.</p>';
    } else {
      var pron = p.sex === 'f' ? 'her' : p.sex === 'm' ? 'his' : 'their';
      html += '<p style="margin-top:0">' + esc(p.short) + ' does not have a life history of ' + pron + ' own yet. This is what the other documents say:</p>';
    }
    var roles = { father: 'is named as the father in', mother: 'is named as the mother in', descendant: 'is named as the child in', text: 'is mentioned in' };
    var seen = {}, roleDocs = {};
    p.mentions.forEach(function (m) { if (m.role !== 'text') roleDocs[m.doc.id] = 1; });
    var items = p.mentions.filter(function (m) {
      if (m.role === 'text' && roleDocs[m.doc.id]) return false;      // already listed by its Father/Mother/Child line
      var k = m.doc.id + m.role; if (seen[k]) return false; seen[k] = 1; return true;
    }).map(function (m) {
      var who = m.doc.personKey ? byKey(m.doc.personKey) : null;
      return '<li>' + esc(p.short.split(' ')[0]) + ' ' + roles[m.role] + ' <a href="' + (who ? personHref(who) : '#/doc/' + m.doc.id) + '">' + esc(who ? who.short + '’s life history' : m.doc.title || m.doc.name) + '</a>' +
        (m.snippet ? '<div class="snippet linked">' + R.linkCodes(m.snippet) + '</div>' : '') + '</li>';
    });
    if (items.length) html += '<ul class="fam-list">' + items.join('') + '</ul>';
    if (p.code) html += '<p class="muted small" style="margin-bottom:0">To add a life history, create a Word document whose name starts with <b>' + esc(p.code) + '</b> (for example “' + esc(p.code + ' ' + (p.surname || 'Surname') + ' ' + (p.short.split(' ')[0] || '')) + '”) in the life history folder.</p>';
    return html + '</div>';
  }

  function docMeta(doc) {
    return '<div class="docmeta"><span>Word document:</span><code>' + esc(sourcePath(doc)) + '</code>' +
      '<button class="btn" data-copy="' + esc(sourcePath(doc)) + '" style="padding:3px 10px;font-size:.85rem">Copy location</button>' +
      '<span>· last changed ' + esc(fmtDate(doc.mtime)) + '</span></div>';
  }
  function wireDoc(container, doc) {
    if (!container) return;
    var imgs = Array.prototype.slice.call(container.querySelectorAll('img.dimg'));
    if (imgs.length) {
      var caps = doc ? captionsOf(doc) : {};
      var list = imgs.map(function (im) { return { img: im.getAttribute('src'), caption: caps[im.getAttribute('src')] || im.getAttribute('alt') || '' }; });
      imgs.forEach(function (im, i) { im.onclick = function () { openLightbox(list, i); }; });
    }
    Array.prototype.forEach.call(container.querySelectorAll('[data-copy]'), function (b) {
      b.onclick = function () {
        var text = b.getAttribute('data-copy');
        var done = function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy location'; }, 1800); };
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
        else { fallbackCopy(text); done(); }
      };
    });
    var mark = container.querySelector('mark');
    if (mark) setTimeout(function () { mark.scrollIntoView({ block: 'center' }); }, 50);
  }
  function fallbackCopy(text) {
    var ta = document.createElement('textarea'); ta.value = text; document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); } catch (e) { }
    document.body.removeChild(ta);
  }

  var FACT_ROWS = [['birth', 'Born'], ['baptism', 'Baptized'], ['death', 'Died'], ['burial', 'Buried'], ['marriage', 'Married'],
    ['immigration', 'Immigration'], ['flag', 'Flag'], ['residence', 'Residence'], ['occupation', 'Occupation'], ['military', 'Military'], ['religion', 'Religion']];
  function factsHtml(p) {
    var f = p.facts || {};
    var html = '<div class="card"><h2>Facts</h2><table class="facts linked">';
    var any = false;
    FACT_ROWS.forEach(function (r) {
      if (!f[r[0]] || !f[r[0]].length) return;
      any = true;
      html += '<tr><th>' + r[1] + '</th><td>' + f[r[0]].map(function (v) { return R.linkCodes(v); }).join('<br>') + '</td></tr>';
    });
    if (!any) html += '<tr><td class="muted">' + (p.doc ? 'No birth, death or marriage lines were found at the top of the document.' : esc(p.short.split(' ')[0]) + ' has no life history of ' + (p.sex === 'f' ? 'her' : p.sex === 'm' ? 'his' : 'their') + ' own yet, so there are no facts to list. The years shown come from other documents (see About).') + '</td></tr>';
    html += '</table></div>';
    // timeline
    var ev = [];
    var y;
    if (f.birth && f.birth.length && (y = G.firstYear(f.birth[0]))) ev.push({ year: y, label: 'Birth', text: f.birth[0], key: true });
    if (f.marriage) f.marriage.forEach(function (m) { var yy = G.marriageYear(m); if (yy) ev.push({ year: yy, label: 'Marriage', text: m, key: true }); });
    if (f.death && f.death.length && (y = G.firstYear(f.death[0]))) ev.push({ year: y, label: 'Death', text: f.death[0], key: true });
    (p.events || []).forEach(function (e) { ev.push(e); });
    ev.sort(function (a, b) { return a.year - b.year; });
    html += '<div class="card"><h2>Timeline</h2>';
    if (!ev.length) html += '<p class="muted" style="margin:0">' + (p.doc ? 'No dated lines were found in the life history.' : 'There is no life history yet, so there is no timeline.') + '</p>';
    else html += '<ul class="timeline linked">' + ev.map(function (e) {
      return '<li class="' + (e.key ? 'key' : '') + '"><span class="ty">' + (e.approx ? '~' : '') + e.year + '</span><span class="tdot"></span><span class="tt">' +
        (e.label ? '<span class="tlabel">' + esc(e.label) + ':</span> ' : '') + R.linkCodes(e.text) + '</span></li>';
    }).join('') + '</ul>';
    return html + '</div>';
  }

  function mentionsHtml(p, mentions) {
    if (!mentions.length) return '<div class="empty-state">No other document mentions ' + esc(p.short.split(' ')[0]) + ' by number yet.</div>';
    var byDoc = {};
    mentions.forEach(function (m) { (byDoc[m.doc.id] = byDoc[m.doc.id] || { doc: m.doc, items: [] }).items.push(m); });
    return '<div class="card"><ul class="results">' + Object.keys(byDoc).map(function (id) {
      var g = byDoc[id], who = g.doc.personKey ? byKey(g.doc.personKey) : null;
      var href = who ? personHref(who) : '#/doc/' + g.doc.id;
      var roleWords = g.items.filter(function (m) { return m.role !== 'text'; }).map(function (m) { return 'named as the ' + (m.role === 'descendant' ? 'child' : m.role); });
      var snip = g.items.filter(function (m) { return m.snippet; })[0];
      return '<li><a class="rtitle" href="' + href + '">' + esc(who ? who.short + '’s life history' : g.doc.title || g.doc.name) + '</a>' +
        (roleWords.length ? ' <span class="chip gray">' + esc(roleWords.join(', ')) + '</span>' : '') +
        (snip ? '<div class="snippet linked">' + R.linkCodes(snip.snippet) + '</div>' : '') + '</li>';
    }).join('') + '</ul></div>';
  }

  function familySide(p) {
    var html = '<aside class="family-side"><div class="card">';
    var f = father(p), m = mother(p);
    var fk = G.fatherKey(p.key), mk = G.motherKey(p.key);
    if (fk || mk) {
      html += '<h3>Parents</h3>' + famPerson(f, 'Father unknown') + famPerson(m, 'Mother unknown');
    }
    var sp = spouse(p);
    var others = p.otherSpouses || [];
    if (known(sp) || others.length) {
      html += '<h3>Spouse' + (others.length ? 's' : '') + '</h3>' + (known(sp) ? famPerson(sp) : '');
      if (others.length) html += '<ul class="fam-list linked">' + others.map(function (r) { return '<li>' + R.linkCodes(r.text) + '</li>'; }).join('') + '</ul>';
    }
    var ch = child(p);
    var kids = (p.otherChildren || []).filter(function (r) {
      if (!ch) return true;
      var a = G.normName(r.name).split(' ')[0], b = G.normName(ch.name).split(' ')[0];
      return !(a && a === b) && !(r.code && r.code === ch.key);
    });
    var alsoKids = (p.alsoAt || []).map(function (k) { return byKey(G.childKey(k)); }).filter(function (c) { return known(c) && c !== ch; });
    if (ch || kids.length || alsoKids.length) {
      html += '<h3>Children</h3>' + (ch ? famPerson(ch, '', 'in this line') : '') + alsoKids.map(function (c) { return famPerson(c, '', 'also in the tree'); }).join('');
      if (kids.length) html += '<ul class="fam-list linked">' + kids.map(function (r) { return '<li>' + R.linkCodes(r.text) + '</li>'; }).join('') + '</ul>';
    }
    if (p.siblings && p.siblings.length) {
      html += '<h3>Brothers &amp; sisters</h3><ul class="fam-list linked">' + p.siblings.map(function (r) { return '<li>' + R.linkCodes(r.text) + '</li>'; }).join('') + '</ul>';
    }
    if (p.root) {
      var lines = LINE_ORDER.filter(function (l) { return CFG.lines[l].root === p.key; });
      html += '<h3>Family lines</h3><ul class="fam-list">' + lines.map(function (l) { return '<li>' + esc(CFG.lines[l].name) + ' — ' + esc(CFG.lines[l].side) + '</li>'; }).join('') + '</ul>';
    }
    return html + '</div></aside>';
  }

  // Pictures of a person with captions guessed from the line under each picture.
  function captionsOf(doc) {
    if (doc._caps) return doc._caps;
    var caps = {};
    var lines = R.docLines(doc);
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i];
      if (!l.images) continue;
      var own = l.text.trim();
      var j = i + 1;
      while (j < lines.length && !lines[j].text.trim() && !lines[j].images) j++;
      var next = lines[j];
      var cap = '';
      if (!own && next && !next.images && next.text.trim().length < 220 && !/^\s*(father|mother|birth|death|marriage|siblings|children|descendant)\b/i.test(next.text)) cap = next.text;
      else if (own && own.length < 220) cap = own;
      var parts = cap ? cap.trim().split(/\t+|\s{3,}/).filter(function (s) { return s.trim(); }) : [];
      l.imgs.forEach(function (im, k) {
        caps[im.img] = parts.length === l.imgs.length ? parts[k].trim() : (cap.trim() || R.cleanAlt(im.alt));
      });
    }
    doc._caps = caps;
    return caps;
  }
  function galleryOf(p) {
    var out = [], seen = {};
    var docs = p.doc ? [p.doc].concat(p.docs.filter(function (d) { return d !== p.doc && d.personKey === p.key; })) : [];
    docs.slice(0, 1).forEach(function (d) {
      var caps = captionsOf(d);
      R.docLines(d).forEach(function (l) {
        (l.imgs || []).forEach(function (im) { if (!seen[im.img]) { seen[im.img] = 1; out.push({ img: im.img, caption: caps[im.img] || '' }); } });
      });
    });
    return out;
  }

  // ------------------------------------------------------------------ DOCUMENT (stories etc.)
  function pageDoc(id) {
    var d = M.docs[id];
    if (!d) { notFound('That document is no longer in the folder.'); return; }
    title(d.title || d.name);
    var p = d.personKey ? byKey(d.personKey) : null;
    var codes = {};
    G.findCodes(d.text || '').forEach(function (c) { var k = G.validKey(c.letter, c.gen, c.pos); if (k && M.people[k] && k !== d.personKey) codes[k] = 1; });
    var people = sortPeople(Object.keys(codes).map(byKey));
    var html = '<div class="page narrow"><h1>' + esc(d.title || d.name) + '</h1>';
    if (p) html += '<p class="sub">About <a href="' + personHref(p) + '">' + esc(p.short) + '</a>' + (p.doc !== d ? ' · this is another version of the life history' : '') + '</p>';
    else html += '<p class="sub">' + esc(d.dir ? d.dir + ' folder' : 'Story or research notes') + ' · changed ' + esc(fmtDate(d.mtime)) + '</p>';
    if (d.err) html += '<div class="notice">This document could not be read: ' + esc(d.err) + '. It will be tried again at the next update.</div>';
    if (people.length) {
      html += '<div class="card" style="margin-bottom:16px"><h3>People in this document</h3><div class="peoplehits" style="margin:0">' +
        people.map(function (q) { return famPerson(q, '', q.code); }).join('') + '</div></div>';
    }
    var out = R.renderDoc(d, { highlight: takeHighlight(), selfKey: d.personKey });
    html += '<article class="docpaper linked">' + out.html + '</article>' + docMeta(d) + footer() + '</div>';
    main.innerHTML = html;
    wireDoc(main, d);
  }

  // ------------------------------------------------------------------ PEOPLE index
  var peopleState = { q: '', line: '', sort: 'name', letter: '', onlyDocs: false };
  function pagePeople() {
    title('People');
    var html = '<div class="page"><h1>People</h1><p class="sub">Everyone in the tree, including ancestors who are only named in someone else’s life history so far.</p>' +
      '<div class="filters"><input type="search" id="pq" placeholder="Filter by name…" value="' + esc(peopleState.q) + '">' +
      '<select id="pline"><option value="">All family lines</option>' + LINE_ORDER.map(function (l) { return '<option value="' + l + '"' + (peopleState.line === l ? ' selected' : '') + '>' + esc(CFG.lines[l].name + ' — ' + CFG.lines[l].side) + '</option>'; }).join('') + '</select>' +
      '<select id="psort"><option value="name">Sort by surname</option><option value="born">Sort by birth year</option><option value="gen">Sort by generation</option><option value="changed">Recently updated first</option></select>' +
      '<label class="small"><input type="checkbox" id="pdocs"' + (peopleState.onlyDocs ? ' checked' : '') + '> Only people with a life history</label></div>' +
      '<div class="letters" id="pletters"></div><div id="plist"></div></div>';
    main.innerHTML = html;
    document.getElementById('psort').value = peopleState.sort;
    var redraw = function () {
      peopleState.q = document.getElementById('pq').value;
      peopleState.line = document.getElementById('pline').value;
      peopleState.sort = document.getElementById('psort').value;
      peopleState.onlyDocs = document.getElementById('pdocs').checked;
      drawPeople();
    };
    ['pq', 'pline', 'psort', 'pdocs'].forEach(function (id) { var el = document.getElementById(id); el.oninput = el.onchange = redraw; });
    drawPeople();
  }
  function drawPeople() {
    var raw = peopleState.q.trim();
    var codeQ = /^[A-Za-z]\s?\d/.test(raw) ? raw.toUpperCase().replace(/\s+/g, '').replace('.', ',') : '';   // "A3,1" or "B6"
    var q = codeQ ? '' : G.normName(raw);
    var list = allPeople().filter(function (p) {
      if (peopleState.line && p.letter !== peopleState.line) return false;
      if (peopleState.onlyDocs && !p.doc) return false;
      if (codeQ) return !!p.code && (p.code === codeQ || (!/,/.test(codeQ) && p.code.indexOf(codeQ + ',') === 0));
      if (q && q.length >= 2 && (' ' + G.normName(p.name) + ' ').indexOf(q) < 0) return false;
      return true;
    });
    var letters = {};
    list.forEach(function (p) { letters[(p.surname || '?').charAt(0).toUpperCase()] = 1; });
    var lbox = document.getElementById('pletters');
    lbox.innerHTML = '<button data-l="" class="' + (!peopleState.letter ? 'on' : '') + '">All</button>' + 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('').map(function (L) {
      return '<button data-l="' + L + '" class="' + (peopleState.letter === L ? 'on' : '') + '"' + (letters[L] ? '' : ' disabled') + '>' + L + '</button>';
    }).join('');
    Array.prototype.forEach.call(lbox.querySelectorAll('button'), function (b) { b.onclick = function () { peopleState.letter = b.getAttribute('data-l'); drawPeople(); }; });
    if (peopleState.letter) list = list.filter(function (p) { return (p.surname || '?').charAt(0).toUpperCase() === peopleState.letter; });
    var s = peopleState.sort;
    list.sort(function (a, b) {
      if (s === 'born') return (a.born || 9999) - (b.born || 9999) || a.name.localeCompare(b.name);
      if (s === 'gen') return sortPeople([a, b])[0] === a ? -1 : 1;
      if (s === 'changed') return ((b.doc && b.doc.mtime) || '').localeCompare((a.doc && a.doc.mtime) || '');
      if (!a.surname !== !b.surname) return a.surname ? -1 : 1;          // people without a surname last
      return (a.surname || '').localeCompare(b.surname || '') || a.short.localeCompare(b.short);
    });
    document.getElementById('plist').innerHTML = '<p class="muted small">' + list.length + ' people</p>' +
      '<table class="list"><thead><tr><th>Name</th><th>Years</th><th>Relationship</th><th>Line</th><th>Number</th><th></th></tr></thead><tbody>' +
      list.map(function (p) {
        return '<tr><td><a class="pname" href="' + personHref(p) + '">' + avatar(p) + '<span>' + esc(p.short) + '</span></a></td><td>' + esc(p.years || '') + '</td>' +
          '<td class="small">' + esc(p.root ? '' : G.relationTo(p)) + '</td><td class="small">' + esc(p.line ? p.line.name : '') + '</td>' +
          '<td>' + (p.code ? '<span class="chip code">' + esc(p.code) + '</span>' : '') + '</td>' +
          '<td class="small muted">' + (p.doc ? '' : 'no life history yet') + '</td></tr>';
      }).join('') + '</tbody></table>';
  }

  // ------------------------------------------------------------------ STORIES
  function pageStories() {
    title('Stories');
    var stories = M.stories.slice().sort(function (a, b) { return (a.title || a.name).localeCompare(b.title || b.name); });
    var html = '<div class="page"><h1>Stories &amp; research</h1><p class="sub">Documents in the life history folder that are not about one single person.</p><div class="storylist">';
    html += stories.map(function (d) {
      var para = R.docLines(d).map(function (l) { return l.text.trim(); }).filter(function (t) { return t.length > 80; })[0] || '';
      return '<a class="card storycard" href="#/doc/' + d.id + '"><h3>' + esc(d.title || d.name) + '</h3><p>' + esc(para.slice(0, 260)) + '</p>' +
        '<div class="small muted" style="margin-top:8px">' + esc(d.dir ? d.dir + ' · ' : '') + 'changed ' + esc(fmtDate(d.mtime)) + (d.nimg ? ' · ' + d.nimg + (d.nimg === 1 ? ' picture' : ' pictures') : '') + '</div></a>';
    }).join('');
    html += '</div>';
    var other = (M.data.other || []);
    if (other.length) {
      html += '<div class="card" style="margin-top:20px"><h2>Other files in the folder</h2><p class="muted small">Pictures, PDFs and other files that are not Word documents. Click to open.</p><ul class="recent">' +
        other.map(function (o) {
          var href = 'file:///' + (M.data.source + '\\' + o.path).replace(/\\/g, '/').split('/').map(encodeURIComponent).join('/').replace(/^([A-Za-z])%3A/, '$1:');
          return '<li><a href="' + esc(href) + '" target="_blank" rel="noopener">' + esc(o.path) + '</a><span class="when">' + esc(fmtDate(o.mtime)) + '</span></li>';
        }).join('') + '</ul></div>';
    }
    main.innerHTML = html + footer() + '</div>';
  }

  // ------------------------------------------------------------------ SEARCH
  function pageSearch(q) {
    title('Search');
    document.getElementById('searchinput').value = q;
    var terms = plainQuotes(q).toLowerCase().split(/\s+/).filter(function (t) { return t.length > 0; });
    var html = '<div class="page narrow"><h1>Search: “' + esc(q) + '”</h1>';
    if (!terms.length) { main.innerHTML = html + '</div>'; return; }
    // a person code typed directly
    var direct = G.findByCode(q.replace(/\s+/g, '').toUpperCase());
    if (direct) { location.replace(personHref(direct)); return; }
    var nterms = terms.map(function (t) { return G.normName(t); }).filter(Boolean);
    var people = allPeople().filter(function (p) {
      var n = ' ' + G.normName(p.name) + ' ';
      return nterms.length && nterms.every(function (t) { return n.indexOf(t) >= 0; });
    });
    sortPeople(people);
    if (people.length) html += '<h2>People (' + people.length + ')</h2><div class="peoplehits">' + people.slice(0, 60).map(function (p) { return famPerson(p, '', p.code); }).join('') + '</div>';
    var hits = [];
    Object.keys(M.docs).forEach(function (id) {
      var d = M.docs[id];
      if (!d.text || d.kind === 'ignored') return;
      var low = d.searchText || (d.searchText = plainQuotes(d.text).toLowerCase());
      if (!terms.every(function (t) { return low.indexOf(t) >= 0; })) return;
      var count = 0; terms.forEach(function (t) { var i = -1; while ((i = low.indexOf(t, i + 1)) >= 0) count++; });
      var at = low.indexOf(terms[0]);
      var s = Math.max(0, at - 110), e = Math.min(d.text.length, at + 170);
      hits.push({ d: d, count: count, snippet: (s ? '…' : '') + d.text.slice(s, e).replace(/\s+/g, ' ') + (e < d.text.length ? '…' : '') });
    });
    hits.sort(function (a, b) { return b.count - a.count; });
    html += '<h2>In the documents (' + hits.length + ')</h2>';
    if (!hits.length) html += '<p class="muted">No document contains ' + (terms.length > 1 ? 'all of these words' : 'this word') + '.</p>';
    html += '<div class="card"><ul class="results">' + hits.slice(0, 200).map(function (h) {
      var p = h.d.personKey ? byKey(h.d.personKey) : null;
      var href = p && p.doc === h.d ? personHref(p) : '#/doc/' + h.d.id;
      return '<li><a class="rtitle" href="' + href + '" data-hl="1">' + esc(p ? p.short : (h.d.title || h.d.name)) + '</a> ' +
        (p && p.code ? '<span class="chip code">' + esc(p.code) + '</span>' : '<span class="chip gold">story</span>') +
        ' <span class="small muted">' + h.count + ' match' + (h.count === 1 ? '' : 'es') + '</span>' +
        '<div class="snippet">' + R.highlight(esc(h.snippet), terms) + '</div></li>';
    }).join('') + '</ul></div></div>';
    main.innerHTML = html;
    Array.prototype.forEach.call(main.querySelectorAll('a[data-hl]'), function (a) {
      a.addEventListener('click', function () { setHighlight(terms); storeSet('personTab', 'story'); });
    });
  }
  var pendingHighlight = null;
  function setHighlight(terms) { pendingHighlight = terms; }
  function takeHighlight() { var h = pendingHighlight; pendingHighlight = null; return h; }

  // ------------------------------------------------------------------ RESEARCH NOTES
  function pageNotes() {
    title('Research notes');
    var n = M.notes;
    var people = allPeople();
    var html = '<div class="page narrow"><h1>Research notes</h1><p class="sub">Things the program noticed while reading the documents. They may be useful for research or tidying up — ' +
      'nothing here is ever changed automatically, and the documents themselves are never touched.</p>';

    // where each line ends
    var ends = sortPeople(people.filter(function (p) { return p.doc && !p.root && (!known(father(p)) || !known(mother(p))); }));
    html += section('Where the lines end', ends.length, 'People with a life history whose father or mother is not known yet.', ends.map(function (p) {
      var miss = [!known(father(p)) ? 'father' : '', !known(mother(p)) ? 'mother' : ''].filter(Boolean).join(' and ');
      return '<a href="' + personHref(p) + '">' + esc(p.short) + '</a> <span class="chip code">' + esc(p.code) + '</span> — ' + miss + ' unknown <span class="muted small">(' + esc(G.relationTo(p)) + ')</span>';
    }));

    var waiting = sortPeople(people.filter(function (p) { return !p.doc && !p.root && p.nameSource > 0; }));
    html += section('Named, but no life history yet', waiting.length, 'Ancestors who appear in other documents (for example on a "Father:" line) but have no document of their own.', waiting.map(function (p) {
      return '<a href="' + personHref(p) + '">' + esc(p.short) + '</a> <span class="chip code">' + esc(p.code) + '</span> <span class="muted small">' + esc(p.years || '') + ' · ' + esc(G.relationTo(p)) + '</span>';
    }));

    html += section('More than one document for the same person', n.duplicates.length, 'The version whose file name starts with the number (or else the most recently changed one) is shown on the person’s page; the others are listed there too.', n.duplicates.map(function (d) {
      var p = byKey(d.key);
      return '<a href="' + personHref(p) + '">' + esc(p.short) + '</a> <span class="chip code">' + esc(d.key) + '</span>' + (d.differentPeople ? ' <span class="chip gold">names differ — maybe two different people?</span>' : '') +
        '<ul>' + d.docs.map(function (doc) { return '<li><a href="#/doc/' + doc.id + '">' + esc(doc.path) + '</a> <span class="muted small">changed ' + esc(fmtDate(doc.mtime)) + (doc === d.main ? ' — shown' : '') + '</span></li>'; }).join('') + '</ul>';
    }));

    var mism = n.codeMismatch.map(function (c) {
      return '<a href="#/doc/' + c.doc.id + '">' + esc(c.doc.path) + '</a>: the file name says <b>' + esc(c.file) + '</b>, the first line says <b>' + esc(c.head) + '</b>. Used <b>' + esc(c.chosen) + '</b> (' + esc(c.why) + ').';
    }).concat(n.refMismatch.map(function (r) {
      var p = r.doc.personKey ? byKey(r.doc.personKey) : null;
      return '<a href="#/doc/' + r.doc.id + '">' + esc(p ? p.short : r.doc.name) + '</a>: the ' + esc(r.field) + ' line gives <b>' + esc(r.written) + '</b>' + (r.name ? ' for ' + esc(r.name) : '') +
        ', but by the numbering it would be <b>' + esc(r.expected || '—') + '</b>.';
    })).concat((n.moved || []).map(function (mv) {
      var to = byKey(mv.to);
      return '<a href="#/doc/' + mv.doc.id + '">' + esc(mv.doc.path) + '</a> has the number <b>' + esc(mv.from) + '</b>, but it is about <a href="' + personHref(to) + '">' + esc(to.short) + '</a> (<b>' + esc(mv.to) + '</b>), so it is shown there.';
    })).concat(n.badCodes.map(function (b) {
      return '<a href="#/doc/' + b.doc.id + '">' + esc(b.doc.path) + '</a>: <b>' + esc(b.raw) + '</b> in the ' + esc(b.where) + ' is not a possible number for that generation.';
    }));
    html += section('Numbers that do not agree', mism.length, 'Where a document’s numbers disagree with each other or with the numbering rule (father = 2n−1, mother = 2n in the next generation).', mism);

    html += section('The same ancestor in two places', n.collapse.length, 'A Father: or Mother: line names someone who already has a life history at another number (pedigree collapse). The tree shows that person in both places.', n.collapse.map(function (c) {
      var p = byKey(c.is);
      return '<a href="' + personHref(p) + '">' + esc(p.short) + '</a> <span class="chip code">' + esc(c.is) + '</span> also stands at <b>' + esc(c.at) + '</b> (from <a href="#/doc/' + c.doc.id + '">' + esc(c.doc.name) + '</a>)';
    }));
    html += section('Matched by name', n.unmatched.length, 'Documents without a number in their name, connected to a person because the name and years match.', n.unmatched.map(function (u) {
      var p = byKey(u.matched);
      return '<a href="#/doc/' + u.doc.id + '">' + esc(u.doc.path) + '</a> → <a href="' + personHref(p) + '">' + esc(p.short) + '</a> <span class="chip code">' + esc(p.code || '') + '</span>';
    }));
    html += section('Documents that could not be read', n.unreadable.length, 'These will be tried again at the next update. A document that is open in Word is normally fine.', n.unreadable.map(function (d) {
      return esc(d.path) + ' — <span class="muted">' + esc(d.err || d.lastError) + (d.lastError ? ' (the version from ' + esc(fmtDate(d.mtime)) + ' is shown until then)' : '') + '</span>';
    }));
    var photoNotes = n.photos || [];
    if (photoNotes.length) html += section('Photos that are not shown', photoNotes.length, 'Pictures in the Photos folder whose file name does not lead to one person, or that could not be read.', photoNotes.map(function (x) {
      var who = x.person ? byKey(x.person) : null;
      var whoLink = who ? '<a href="' + personHref(who) + '">' + esc(who.short) + '</a>' : '';
      var why = x.problem === 'no number' ? 'the file name does not start with a person\u2019s number' :
        x.problem === 'nobody' ? 'there is no one with the number <b>' + esc(x.code) + '</b> in the tree' :
        x.problem === 'another' ? whoLink + ' has more than one photo; <b>' + esc(x.shown) + '</b> is shown (the one named by the number alone, or else the newest)' :
        'the picture could not be read' + (whoLink ? ' (for ' + whoLink + ')' : '') + ' <span class="muted">' + esc(x.err || '') + '</span>';
      return esc(x.path) + ' \u2014 ' + why;
    }));
    var flagNotes = n.flags || [];
    if (flagNotes.length) html += section('Flags that could not be shown', flagNotes.length, 'A Flag: line, or an Arrived: / Immigration: line, that does not name a country the program knows. Writing \u201cfrom\u201d and the country (for example \u201c1848, from Ireland\u201d) or a Flag: line fixes it.', flagNotes.map(function (x) {
      var who = byKey(x.person);
      return (who ? '<a href="' + personHref(who) + '">' + esc(who.short) + '</a>' : esc(x.person)) + ' \u2014 <i>' + esc(x.value) + '</i>';
    }));
    if (n.ignored.length) html += section('Skipped on purpose', n.ignored.length, 'Listed in family-settings.js as not being about a person.', n.ignored.map(function (d) { return esc(d.path); }));
    if (reportEmail()) {
      html += '<p class="small muted" id="notes-report" style="margin:16px 0 0">Something not right? <a href="' + esc(reportMailto()) + '">Report a problem</a> ' +
        '(or copy a report from the <a href="#/help/report">Help</a> page).</p>';
    }
    main.innerHTML = html + footer() + '</div>';
  }
  function section(t, count, intro, items) {
    return '<details class="card notes-section"' + (count && count < 25 ? ' open' : '') + '><summary>' + esc(t) + '<span class="chip ' + (count ? 'gold' : 'gray') + '">' + count + '</span></summary>' +
      '<p class="muted small">' + esc(intro) + '</p>' + (items.length ? '<ul>' + items.map(function (i) { return '<li>' + i + '</li>'; }).join('') + '</ul>' : '<p class="muted">Nothing to note.</p>') + '</details>';
  }

  // ------------------------------------------------------------------ HELP
  // The example life history on the Help page: from the settings (helpExample), else a made-up one on
  // the first line letter (number 30 of generation 8 exists in every kind of line).
  function helpExample() {
    var ex = CFG.helpExample || {};
    var code = ex.code && G.parseKey(ex.code) ? ex.code : '';
    if (!code) {
      var sp = CFG.spaces[0];
      code = sp && sp.letters && sp.letters[0] ? sp.letters[0] + '8,30' : '';
      var fk = code ? G.fatherKey(code) : null;
      ex = { name: 'Rosalind Clementine Penrose', fileName: 'Penrose Rosalind', years: '1741-1799', father: 'Robert Penrose' + (fk ? ' (' + fk + ')' : '') + '(1700-1770)', story: '' };
    }
    return { code: code, name: ex.name || '', fileName: ex.fileName || '', years: ex.years || '', father: ex.father || '', story: ex.story || '' };
  }
  function curlyQuotes(s) { return String(s || '').replace(/'/g, '’'); }

  function pageHelp(sub) {
    title('Help');
    var d = M.data;
    var ex = helpExample();
    var pf = ex.code ? G.fatherKey(ex.code) : null, pm = ex.code ? G.motherKey(ex.code) : null;
    var template = (CFG.ignoreDocuments || []).filter(function (n) { return /template/i.test(n); })[0];
    var letters = LINE_ORDER.map(function (l) { return esc(l) + ' = ' + esc(curlyQuotes(CFG.lines[l].side || CFG.lines[l].name)); }).join(', ');
    var html = '<div class="page narrow"><h1>How the family tree works</h1>' +
      '<div class="card"><h2>Adding a person, or changing a life history</h2><ol class="helpsteps">' +
      '<li>Write the life history in <b>Word</b> as usual' + (template ? ' (starting from <i>' + esc(template) + '</i> is easiest)' : '') + '. Save it with <b>Ctrl+S</b> into the <b>life history</b> folder, or one of its folders' +
      (CFG.helpFolders ? ' (' + esc(CFG.helpFolders) + ')' : '') + '. Word can stay open.</li>' +
      '<li>Begin the <b>file name</b> with the person’s number, then surname and first name: <b>' + esc(ex.code + ' ' + ex.fileName) + '</b>.</li>' +
      '<li>On the <b>first line</b> of the document: the name and the same number in brackets — <i>' + esc(ex.name + ' (' + ex.code + ')') + '</i>. On the <b>second line</b>: the years — <i>' + esc(ex.years) + '</i>.</li>' +
      '<li>Then, each on its own line: <i>Father:</i>, <i>Mother:</i>, <i>Descendant:</i> (the child in the line), <i>Birth:</i>, <i>Death:</i>, <i>Marriage:</i>. Put the number after a name when you know it: <i>Father: ' + esc(ex.father) + '</i>. Write <i>?</i> when a parent is not known.</li>' +
      '<li>Open the <b>Family Tree</b> icon on the desktop. New and changed documents are read by themselves (a few seconds) and the page refreshes on its own. The new person appears in the tree, joined to their parents and child.</li>' +
      '</ol><p class="muted">Pictures in the documents appear automatically. To put a photo in a person’s square, open their page and click <b>Add a photo</b>. A line such as <i>Arrived: 1848, from Ireland</i> (or <i>Flag: Ireland</i>) puts that country’s flag in the corner of the square. Documents that are not about one person' + (ex.story ? ' (like “' + esc(ex.story) + '”)' : '') + ' appear under <a href="#/stories">Stories</a>.</p>' +
      '<p class="muted" style="margin-bottom:0"><b>The numbering:</b> the father of <i>(g, n)</i> is <i>(g+1, 2n−1)</i> and the mother is <i>(g+1, 2n)</i>. ' +
      (pf && pm ? 'For example, the parents of ' + esc(ex.code) + ' are ' + esc(pf) + ' and ' + esc(pm) + '. ' : '') +
      letters + '.</p></div>' +
      '<div class="card"><h2>If something does not show up</h2><ul class="fam-list">' +
      '<li>Check that the document is saved (Ctrl+S) inside the <b>life history</b> folder.</li>' +
      '<li>Check that the number at the start of the file name and on the first line agree, and that it fits the generation (generation 5 has numbers 1–16).</li>' +
      '<li>Look at <a href="#/notes">Notes</a>: it lists documents that could not be read and numbers that do not agree.</li>' +
      '<li>Open the <b>Family Tree</b> icon again; it only reads documents when it is opened.</li></ul></div>' +
      reportCard() +
      '<div class="card"><h2>Your documents are safe</h2><p style="margin:0">This program only <b>reads</b> the Word documents. It never changes, moves or deletes them. ' +
      'Everything it makes is kept in its own folder, <b>Family Tree Viewer</b>, inside the life history folder.</p></div>' +
      '<div class="card"><h2>Details</h2><table class="facts">' +
      '<tr><th>Documents</th><td>' + esc(d.source) + '</td></tr>' +
      '<tr><th>Last update</th><td>' + esc(new Date(d.built).toLocaleString()) + ' — ' + d.docs.length + ' Word documents' + (d.errors && d.errors.length ? ', ' + d.errors.length + ' could not be read' : '') + '</td></tr>' +
      '<tr><th>People</th><td>' + allPeople().length + '</td></tr>' +
      '<tr><th>Settings</th><td><code>Family Tree Viewer\\family-settings.js</code> (rarely needed)</td></tr>' +
      '<tr><th>If the desktop icon is missing</th><td>Double-click <code>Open Family Tree.cmd</code> in the Family Tree Viewer folder (it does the same thing), or run <code>tools\\Install-FamilyTree.ps1</code> to put the icon back.</td></tr>' +
      '</table><p class="small muted" id="program-version" style="margin:12px 0 0">Program version ' + esc(VERSION || 'unknown') + '</p></div>' + footer() + '</div>';
    main.innerHTML = html;
    wireReport();
    if (sub === 'report') {
      var card = document.getElementById('report');
      if (card) setTimeout(function () { card.scrollIntoView({ block: 'start' }); }, 0);
    }
  }

  // ------------------------------------------------------------------ REPORT A PROBLEM
  // A mailto: link to the address in family-settings.js (report.email), with the program version and
  // the latest update details filled in. "Copy the report" is for when no email program opens.
  var REPORT_URL_MAX = 1800;          // some email programs cut longer mailto: links
  function reportEmail() { return String((CFG.report && CFG.report.email) || '').trim(); }
  function oneLine(s, max) { s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); return s.length > max ? s.slice(0, max - 1) + '…' : s; }
  function reportSubject() { return 'Family tree problem (version ' + (VERSION || 'unknown') + ')'; }
  // The body: an empty "What happened" section, then the system details (at most maxErrors error lines).
  function reportBody(maxErrors) {
    var st = window.FAMILY_STATUS || {}, d = (M && M.data) || window.FAMILY_DATA || {};
    var errs = d.errors || [];
    var sys = [
      '--- Details for whoever looks after the program ---',
      'Program version: ' + (VERSION || 'unknown') + (st.version && st.version !== VERSION ? ' (status says ' + oneLine(st.version, 20) + ')' : ''),
      'Last update: ' + (d.built ? oneLine(new Date(d.built).toLocaleString(), 40) + ' (' + oneLine(d.built, 30) + ')' : 'none yet'),
      'Last check: ' + (st.time ? oneLine(st.time, 30) : 'unknown'),
      'Documents: ' + (d.docs ? d.docs.length : 0),
      'Read errors: ' + errs.length
    ];
    errs.slice(0, maxErrors).forEach(function (e) { sys.push('  - ' + oneLine(e.path, 90) + ': ' + oneLine(e.msg, 110)); });
    if (errs.length > maxErrors && maxErrors > 0) sys.push('  - … and ' + (errs.length - maxErrors) + ' more');
    sys.push('Last status: ' + oneLine(st.state || 'unknown', 20) + (st.msg ? ' - ' + oneLine(st.msg, 200) : ''));
    if (st.programMessage) sys.push('Program message: ' + oneLine(st.programMessage, 200));
    sys.push('Page: ' + oneLine(location.hash || '#/', 60));
    return 'What happened:\n\n\n\n' + sys.join('\n') + '\n';
  }
  function reportMailto() {
    var email = reportEmail(), url = '';
    for (var n = 5; n >= 0; n--) {          // fewer error lines until the link is short enough
      url = 'mailto:' + encodeURIComponent(email).replace(/%40/g, '@') + '?subject=' + encodeURIComponent(reportSubject()) + '&body=' + encodeURIComponent(reportBody(n));
      if (url.length <= REPORT_URL_MAX) return url;
    }
    return url.slice(0, REPORT_URL_MAX).replace(/%[0-9A-Fa-f]?$/, '');
  }
  function reportText() { return 'To: ' + reportEmail() + '\nSubject: ' + reportSubject() + '\n\n' + reportBody(25); }
  function reportCard() {
    var email = reportEmail();
    if (!email) return '';
    return '<div class="card" id="report"><h2>Report a problem</h2><p>If something in the family tree looks wrong or does not work, send a short email about it. ' +
      'The program version and the details of the last update are filled in for you; just write what happened.</p>' +
      '<p style="margin:0"><a class="btn primary" id="reportbtn" href="' + esc(reportMailto()) + '">Report a problem</a> <button class="btn" id="copyreport" type="button">Copy the report</button></p>' +
      '<p class="small muted" style="margin:10px 0 0">If no email window opens, click <b>Copy the report</b> and paste it into an email to <b>' + esc(email) + '</b>.</p>' +
      '<textarea id="reporttext" class="reporttext" readonly rows="10" hidden style="width:100%;margin-top:10px;font:inherit;font-size:.85rem"></textarea></div>';
  }
  function wireReport() {
    var btn = document.getElementById('copyreport'), link = document.getElementById('reportbtn');
    if (link) link.addEventListener('click', function () { link.href = reportMailto(); });       // the details as they are now
    if (!btn) return;
    btn.onclick = function () {
      var text = reportText(), box = document.getElementById('reporttext');
      if (box) { box.value = text; box.hidden = false; }       // also shown, in case copying is not allowed
      copyText(text, function () { btn.textContent = 'Copied'; setTimeout(function () { btn.textContent = 'Copy the report'; }, 2500); });
    };
  }
  // navigator.clipboard first; document.execCommand('copy') when it is missing or refused (file:// pages)
  function copyText(text, done) {
    var fallback = function () { fallbackCopy(text); done(); };
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, fallback);
      else fallback();
    } catch (e) { fallback(); }
  }

  function notFound(msg) {
    main.innerHTML = '<div class="page narrow"><div class="empty-state"><h2>Not found</h2><p>' + esc(msg) + '</p><p><a class="btn primary" href="#/">Go to the home page</a></p></div></div>';
  }

  // ------------------------------------------------------------------ LIGHTBOX
  var lb = document.getElementById('lightbox'), lbList = [], lbIdx = 0, lbOpener = null;
  function openLightbox(list, idx) {
    lbList = list; lbIdx = idx;
    lbOpener = document.activeElement;
    drawLightbox();
    lb.hidden = false;
    var c = lb.querySelector('.lb-close'); if (c) c.focus();
  }
  function drawLightbox() {
    var it = lbList[lbIdx];
    lb.innerHTML = '<button class="lb-close" aria-label="Close">×</button>' +
      (lbList.length > 1 ? '<button class="lb-btn lb-prev" aria-label="Previous picture">‹</button><button class="lb-btn lb-next" aria-label="Next picture">›</button>' : '') +
      '<img src="' + esc(it.img) + '" alt="">' + (it.caption ? '<div class="lb-cap">' + esc(it.caption) + '</div>' : '') +
      (lbList.length > 1 ? '<div class="lb-count">' + (lbIdx + 1) + ' of ' + lbList.length + '</div>' : '');
    lb.querySelector('.lb-close').onclick = closeLightbox;
    var pv = lb.querySelector('.lb-prev'), nx = lb.querySelector('.lb-next');
    if (pv) pv.onclick = function (e) { e.stopPropagation(); step(-1); };
    if (nx) nx.onclick = function (e) { e.stopPropagation(); step(1); };
  }
  function step(d) { lbIdx = (lbIdx + d + lbList.length) % lbList.length; drawLightbox(); var c = lb.querySelector('.lb-close'); if (c) c.focus(); }
  function closeLightbox() {
    if (lb.hidden) return;
    lb.hidden = true; lb.innerHTML = '';
    if (lbOpener && lbOpener.focus) try { lbOpener.focus(); } catch (e) { }
  }
  lb.addEventListener('click', function (e) { if (e.target === lb) closeLightbox(); });
  document.addEventListener('keydown', function (e) {
    if (!lb.hidden) {
      if (e.key === 'Escape') closeLightbox();
      if (e.key === 'ArrowLeft' && lbList.length > 1) step(-1);
      if (e.key === 'ArrowRight' && lbList.length > 1) step(1);
      return;
    }
    // pictures can be opened with the keyboard too
    var t = e.target;
    if ((e.key === 'Enter' || e.key === ' ') && t && t.matches && t.matches('img.dimg, .gallery figure, .person-head .avatar[tabindex]')) { e.preventDefault(); t.click(); }
  });
  window.addEventListener('resize', function () {
    if (/^#\/tree/.test(location.hash) && M) { clearTimeout(window.__rt); window.__rt = setTimeout(function () { route.keepScroll = true; route(); }, 200); }
  });

  // ------------------------------------------------------------------ LIVE UPDATES
  // The updater writes data/status.js while it works; this page checks it every few seconds and
  // reloads the family data by itself when a new version is ready.
  var bar = document.getElementById('statusbar');
  var barTimer = null, polling = false, reloading = false, lastChecked = null, warnedOld = false;
  function showBar(kind, html, autoHide) {
    bar.className = 'statusbar' + (kind ? ' ' + kind : '');
    bar.innerHTML = (kind === 'run' ? '<span class="spinner"></span>' : '') + '<span>' + html + '</span><button aria-label="Dismiss">×</button>';
    bar.hidden = false;
    bar.querySelector('button').onclick = function () { bar.hidden = true; };
    clearTimeout(barTimer);
    if (autoHide) barTimer = setTimeout(function () { bar.hidden = true; }, autoHide);
  }
  function poll() {
    if (polling) return;
    polling = true;
    var s = document.createElement('script');
    s.src = 'data/status.js?t=' + Date.now();
    s.onload = s.onerror = function () {
      polling = false;
      if (s.parentNode) s.parentNode.removeChild(s);
      handleStatus(window.FAMILY_STATUS);
    };
    document.head.appendChild(s);
  }
  // A program update was installed while this page was open: data/status.js then carries the new
  // version (written by tools\Update-FamilyTree.ps1 from app/version.js). Reload the whole page so the
  // new program files are used. sessionStorage remembers the version reloaded for, so this happens at
  // most once per version and can never loop; without sessionStorage it never reloads.
  // An older updater writes no version: nothing happens.
  function reloadForNewVersion(st) {
    var v = st && typeof st.version === 'string' ? st.version : '';
    if (!v || v === VERSION) return false;
    try {
      if (sessionStorage.getItem('ft.reloadedForVersion') === v) return false;
      sessionStorage.setItem('ft.reloadedForVersion', v);
      if (sessionStorage.getItem('ft.reloadedForVersion') !== v) return false;
    } catch (e) { return false; }
    location.reload();
    return true;
  }
  var lastState = '', shownProgramMessage = '';
  function handleStatus(st) {
    var next = 8000;
    if (st && reloadForNewVersion(st)) return;
    if (st) {
      var age = (Date.now() - new Date(st.time).getTime()) / 60000;
      if (st.state === 'done' || st.state === 'error') lastChecked = st.time;
      if (st.state === 'running' && age > 10) {
        // the update was interrupted (computer switched off, window closed); nothing is lost
        if (lastState !== 'stale') showBar('', 'The last update did not finish. Open the <b>Family Tree</b> icon on the desktop to try again; the tree shown is from the update before.');
        st = { state: 'stale' };
      } else if (st.state === 'running') {
        next = 1500;
        showBar('run', (M ? 'Checking the life history documents for changes… ' : 'Reading the life history documents for the first time… ') + (st.total ? '(' + st.done + ' of ' + st.total + ')' : ''));
      } else if (st.state === 'done' && st.built && (!window.FAMILY_DATA || st.built !== window.FAMILY_DATA.built)) {
        reloadData(st);
      } else if (st.state === 'done' && lastState === 'running') {
        showBar('ok', 'The family tree is up to date.', 4000);
      } else if (st.state === 'error' && lastState !== 'error') {
        showBar('err', 'The last update had a problem: ' + esc(st.msg || 'unknown') + '. The family tree shown is from the previous update.');
      } else if (st.state === 'done' && !warnedOld && age > 7 * 24 * 60) {
        warnedOld = true;
        showBar('', 'The documents were last checked ' + esc(relTime(st.time)) + '. To include the newest ones, open the <b>Family Tree</b> icon on the desktop.');
      }
      if (st.state === 'done' && age <= 7 * 24 * 60) warnedOld = true;
      lastState = st.state;
      // one line from the program updater (a new version was installed, or it went back to the previous one)
      var pmsg = typeof st.programMessage === 'string' ? st.programMessage : '';
      if (pmsg && pmsg !== shownProgramMessage && st.state !== 'running' && st.state !== 'stale' && bar.hidden) {
        shownProgramMessage = pmsg;
        showBar('', esc(pmsg), 30000);
      }
    }
    setTimeout(poll, next);
  }
  function buildModel() {
    try { M = G.build(window.FAMILY_DATA); return true; }
    catch (e) {
      if (window.console) console.error(e);
      if (!M) main.innerHTML = '<div class="page narrow"><div class="empty-state"><h2>The family tree could not be put together</h2><p>Something in the latest documents could not be understood (' + esc(e && e.message) + ').</p><p class="small">Open the <b>Family Tree</b> icon on the desktop again. If this keeps happening, the update-log.txt file in Family Tree Viewer\\data says more.</p></div></div>';
      else showBar('err', 'The newest documents could not be put together; the previous view is kept.');
      return false;
    }
  }
  function reloadData(st) {
    if (reloading) return;
    reloading = true;
    var s = document.createElement('script');
    s.src = 'data/data.js?t=' + Date.now();
    s.onload = s.onerror = function () {
      reloading = false;
      if (s.parentNode) s.parentNode.removeChild(s);
      if (!window.FAMILY_DATA || window.FAMILY_DATA.built !== st.built) return;     // not written yet: the next check tries again
      var first = !M;
      if (!buildModel()) return;
      var y = window.scrollY;
      route.keepScroll = true;
      route();
      window.scrollTo(0, y);
      var d = window.FAMILY_DATA;
      var what = [];
      if (d.added) what.push(d.added + ' new document' + (d.added === 1 ? '' : 's'));
      if (d.changed - d.added > 0) what.push((d.changed - d.added) + ' changed');
      if (d.removed) what.push(d.removed + ' removed');
      if (first) showBar('ok', 'The family tree is ready.', 9000);
      else if (what.length) showBar('ok', 'The family tree was just updated: ' + what.join(', ') + '.', 9000);
      else bar.hidden = true;
    };
    document.head.appendChild(s);
  }

  // ------------------------------------------------------------------ start
  // family-settings.js is missing or cannot be used (see app/config.js): say so instead of a blank page
  function settingsCard() {
    var what = CFG.settingsProblem;
    var why = what === 'missing' ? 'The file <b>family-settings.js</b> was not found in the <b>Family Tree Viewer</b> folder (it belongs next to <b>index.html</b>).'
      : what === 'broken' ? 'The file <b>family-settings.js</b> in the <b>Family Tree Viewer</b> folder could not be read; it may contain a typing mistake.'
      : 'The file <b>family-settings.js</b> in the <b>Family Tree Viewer</b> folder does not say who is at the root of the tree or which family lines there are.';
    main.innerHTML = '<div class="page narrow"><div class="card" id="settings-problem"><h2>' + (what === 'missing' ? 'The family settings are missing' : 'The family settings cannot be used') + '</h2>' +
      '<p>' + why + ' That file holds the name of the family tree, the family lines and who is at the root of the tree, so the tree cannot be shown without it.</p>' +
      '<p>Your Word documents are not affected.</p>' +
      '<p class="small">To fix it, put back <b>family-settings.js</b> from a backup, or make a new one from <b>family-settings.example.js</b> in the same folder. Then open the <b>Family Tree</b> icon again.</p>' +
      '<p class="small muted" style="margin-bottom:0">Program version ' + esc(VERSION || 'unknown') + '</p></div></div>';
  }
  function start() {
    var t = document.getElementById('brand-title');
    t.textContent = CFG.title || 'Family Tree';
    if (CFG.settingsProblem) { settingsCard(); return; }
    if (!window.FAMILY_DATA) {
      main.innerHTML = '<div class="page narrow"><div class="empty-state"><h2>Getting the family tree ready…</h2>' +
        '<p>The life history documents are being read for the first time. This page will fill in by itself in a few minutes.</p>' +
        '<p class="small">If nothing happens, open the <b>Family Tree</b> icon on the desktop (or double-click <b>Open Family Tree</b> in the Family Tree Viewer folder).</p></div></div>';
    } else if (buildModel()) {
      route();
    }
    poll();
  }  window.FamilyApp = { get model() { return M; }, route: route, version: VERSION };
  start();
})();
