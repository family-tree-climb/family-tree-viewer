/* Family Tree Viewer — builds the family tree from the converted Word documents.

   Each life-history document normally starts like this:
       Samuel Abel Thornbury (A2,1)
       1868-1941
       Father: Walter Lemuel Thornbury (A3,1)(1842-1901)
       Mother: Lydia H Marlow (A3,2)(1847-9)
       Birth: 3/14/1868, Millbrook, IL
       ...
   The code (A2,1) places the person in the tree; parents, spouse and child follow from the
   numbering. People who are only mentioned (e.g. a "Mother:" line with no document of her own yet)
   are added too, so the tree is as complete as the research. Nothing here changes any document. */
(function () {
  'use strict';

  var CFG = window.FAMILY_CONFIG;
  var LETTERS = Object.keys(CFG.lines).join('');

  // ---------------------------------------------------------------- codes & numbering
  // "A3,1", "A5, 14", "B10.342", "C11, 73" — a letter, the generation, a comma (or period), the number.
  // A space after the letter ("(H 4,1)") is accepted only right after an opening bracket.
  var CODE_SRC = '(\\(\\s?)?([' + LETTERS + '])( ?)(\\d{1,2})\\s?[,.]\\s?(\\d{1,5})(?!\\d)';
  function findCodes(text) {
    var re = new RegExp(CODE_SRC, 'g'), out = [], m;
    text = String(text || '');
    while ((m = re.exec(text))) {
      var lead = m[1] ? m[1].length : 0, idx = m.index + lead;
      if (m[3] && !m[1]) continue;
      if (!m[1] && idx > 0 && /[A-Za-z0-9]/.test(text.charAt(idx - 1))) continue;   // part of a longer word
      out.push({ letter: m[2], gen: +m[4], pos: +m[5], raw: m[0].slice(lead), index: idx, end: m.index + m[0].length });
    }
    return out;
  }
  var SPACE_BY_LETTER = {};
  CFG.spaces.forEach(function (sp, i) { sp.id = i; sp.letters.forEach(function (l) { SPACE_BY_LETTER[l] = sp; }); });

  // Canonical key for (space, gen, pos) or null when the place does not exist.
  function keyFor(space, gen, pos) {
    if (!space || gen < 1 || pos < 1 || gen > 30) return null;
    if (space.width === 'single') {
      if (pos > Math.pow(2, gen - 1)) return null;
      return space.letters[0] + gen + ',' + pos;
    }
    var half = Math.pow(2, gen - 1);
    if (pos > 2 * half) return null;
    return (pos <= half ? space.letters[0] : space.letters[1]) + gen + ',' + pos;
  }
  // Validate a code exactly as written (letter must match the half of the generation for M/W).
  function validKey(letter, gen, pos) {
    var sp = SPACE_BY_LETTER[letter];
    var k = keyFor(sp, gen, pos);
    if (!k || k.charAt(0) !== letter) return null;
    return k;
  }
  function parseKey(key) {
    var m = /^([A-Z])(\d+),(\d+)$/.exec(key || '');
    if (!m) return null;
    return { letter: m[1], gen: +m[2], pos: +m[3], space: SPACE_BY_LETTER[m[1]] };
  }
  function fatherKey(key) {
    var r = ROOTS[key]; if (r) return r.father;
    var c = parseKey(key); return c ? keyFor(c.space, c.gen + 1, 2 * c.pos - 1) : null;
  }
  function motherKey(key) {
    var r = ROOTS[key]; if (r) return r.mother;
    var c = parseKey(key); return c ? keyFor(c.space, c.gen + 1, 2 * c.pos) : null;
  }
  function childKey(key) {
    var c = parseKey(key); if (!c) return null;
    if (c.gen === 1) return c.space.child;
    return keyFor(c.space, c.gen - 1, Math.ceil(c.pos / 2));
  }
  function spouseKey(key) {
    var r = ROOTS[key]; if (r) return r.spouse || null;
    var c = parseKey(key); if (!c) return null;
    if (c.gen === 1 && c.space.width === 'single') {
      // generation 1 of a single line: the spouse is the other parent of the root person
      var root = ROOTS[c.space.child];
      if (!root) return null;
      return root.father === key ? root.mother : root.mother === key ? root.father : null;
    }
    return keyFor(c.space, c.gen, c.pos % 2 ? c.pos + 1 : c.pos - 1);
  }
  function sexOf(key) {
    var r = ROOTS[key]; if (r) return r.sex || '';
    var c = parseKey(key); if (!c) return '';
    if (c.gen === 1 && c.space.width === 'single') {
      // A1,1 and B1,1 are both "number 1" of their own line: ask the root person which is the mother
      var root = ROOTS[c.space.child];
      if (root && root.mother === key) return 'f';
      if (root && root.father === key) return 'm';
    }
    return c.pos % 2 ? 'm' : 'f';
  }

  var ROOTS = {};
  CFG.roots.forEach(function (r) { ROOTS[r.key] = r; });

  // ---------------------------------------------------------------- text helpers
  // a four-digit year, also when glued to letters ("c1635")
  var YEAR_RE = /(?:^|[^0-9])(1[0-9]{3}|20[0-9]{2})(?![0-9])/;
  function firstYear(s) { var m = YEAR_RE.exec(s || ''); return m ? +m[1] : null; }
  function years(s) { var out = [], re = /(?:^|[^0-9])(1[0-9]{3}|20[0-9]{2})(?![0-9])/g, m; while ((m = re.exec(s || ''))) out.push(+m[1]); return out; }
  // The year of a marriage line, ignoring person codes and the spouse's life span:
  // "Hannah Pellham (A10,214)(1652-1709) 1671" -> 1671; "6/11/1903 to Martha … (1881-1940)" -> 1903
  function marriageYear(v) {
    var s = String(v || '').replace(/\(\s*[A-Z]\s?\d{1,2}\s?[,.]\s?\d{1,5}\s*\)/g, ' ')
      .replace(/\([^()]*\d{3,4}[^()]*\)/g, ' ')
      .replace(/\b\d{3,4}\s*[-–]\s*(\d{1,4}|\?)(?=\D|$)/g, ' ');
    return firstYear(s);
  }
  function squash(s) { return String(s || '').replace(/[ \t ]+/g, ' ').trim(); }
  function normName(s) {
    return squash(String(s || '').toLowerCase()
      .replace(/[“”"‘’'`]/g, '')
      .replace(/\(.*?\)/g, ' ')
      .replace(/\b(sr|jr|dr|rev|capt|cpt|captain|lt|col|maj|major|sgt|deacon|mrs|mr|md|ii|iii|iv|i)\b\.?/g, ' ')
      .replace(/[^a-z\s]/g, ' '));
  }
  // A life span as it appears in a title line: "1868-1941", "(c. 1642–1709)", "~1747-1812-13", "1611-a 1679".
  var SPAN_RE = /^\(?\s*(?:c\.?|ca\.?|abt\.?|about|~|bef\.?|before|aft\.?|after|b\.)?\s*\d{3,4}/i;
  // the life span at the start of a piece of text: "1683-1727 Larchmont Hollow" -> "1683–1727", "c. 1642–1709", "1653–?"
  var SPAN_AT = /^\s*\(?\s*((?:c\.?\s*|ca\.?\s*|abt\.?\s*|about\s+|~\s*|bef\.?\s*|before\s*|aft\.?\s*|after\s*)?\d{3,4}(?:\s+or\s+(?:about\s+|abt\.?\s*|c\.?\s*)?\d{3,4})?(?:\s*[\/-]\s*\d{1,4}(?=\s*[-–—]))?(?:\s*[-–—]+\s*(?:(?:c\.?\s*|abt\.?\s*|~\s*|bef\.?\s*|aft\.?\s*|after\s*|before\s*|a\s+)?(?:[A-Za-z]{3,9}\.?\s+\d{1,2},?\s+)?\d{1,4}(?:\s*[-\/]\s*\d{1,4})?|\?)?)?)/i;
  function spanFrom(s) { var m = SPAN_AT.exec(String(s || '')); return m ? cleanSpan(m[1]) : ''; }
  // Years inside a bracket. "(1693, Millbrook, Fernhill County -- 14 Mar 1751, Millbrook)" -> "1693–1751";
  // "( Feb, Old Mill -- April 17, 1761 • Old Mill Creek)" -> "?–1761"
  function spanFromBracket(s) {
    s = String(s || '');
    var sides = s.split(/\s*--\s*|\s+[–—-]\s+/);
    var wordy = /[A-Za-z]{3,}/.test(s.replace(/\b(c|ca|abt|about|bef|before|aft|after|circa|or)\b\.?/gi, ''));
    if (sides.length >= 2 && wordy) {
      var by = firstYear(sides[0]), dy = firstYear(sides[sides.length - 1]);
      if (by || dy) return (by || '?') + '–' + (dy || '');
    }
    var sp = spanFrom(s);
    if (sp) return sp;
    if (wordy) { var ys = years(s); return ys.length ? ys[0] + (ys.length > 1 ? '–' + ys[ys.length - 1] : '') : ''; }
    return cleanSpan(s);
  }
  function cleanSpan(s) {
    s = squash(s).replace(/^\(|\)$/g, '').replace(/\s*[-–—]\s*/g, '–');
    return s;
  }

  var LABELS = [
    ['father', /^(father)\b/i], ['mother', /^(mother)\b/i], ['parents', /^(parents)\b/i],
    ['descendant', /^(descendants?|descendent|child in line)\b/i],
    ['children', /^(children|child|sons?|daughters?)\b/i],
    ['siblings', /^(siblings?|brothers?|sisters?|half[- ]siblings?)\b/i],
    ['birth', /^(birth|born|b\.)(?=[\s:])/i], ['baptism', /^(baptism|baptized|baptised|christened|christening)\b/i],
    ['death', /^(death|died|d\.)(?=[\s:])/i], ['burial', /^(burial|buried|grave)\b/i],
    ['marriage', /^(marriages?|married|spouses?|husband|wife|m\.)(?=[\s:(])/i],
    ['immigration', /^(immigration|emigration|arrival|arrived)\b/i], ['residence', /^(residences?)\b/i],
    ['occupation', /^(occupation)\b/i], ['military', /^(military|service)\b/i], ['religion', /^(religion)\b/i]
  ];
  var MULTI = { children: 1, siblings: 1, marriage: 1, residence: 1, parents: 1 };
  var HEADERISH = { father: 1, mother: 1, parents: 1, descendant: 1, siblings: 1, children: 1, birth: 1, baptism: 1, death: 1, burial: 1, marriage: 1, immigration: 1 };
  var MONTH_START = /^(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s/i;
  var MONTHS = '(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?';
  var LEAD_DATE = new RegExp('^\\s*(?:(?:abt\\.?|about|c\\.|ca\\.?|circa|~|bef\\.?|aft\\.?|before|after|on|around)\\s*)?(?:\\d{1,2}\\s+' + MONTHS + ',?\\s*\\d{2,4}|' + MONTHS + '\\s+\\d{1,2},?\\s*\\d{2,4}|\\d{1,2}[\\/.-]\\d{1,2}[\\/.-]\\d{2,4}|\\d{3,4})(?:\\s*[•·]\\s*[^,]*)?\\s*[,;:]?\\s*(?:to\\s+)?', 'i');
  var MONTH_TAIL = new RegExp('\\s+' + MONTHS + '\\s+\\d.*$', 'i');
  // a line under the header that is a sentence, not another name
  var PROSE_START = /^(the|there|he|she|they|it|this|that|his|her|their|i|we|from|after|before|when|information|evidence|source|see|note)\b/i;
  var DATEY = /^[\s:–-]*(\(?\s*(c\.|ca\.?|abt\.?|about|~|bef\.?|aft\.?|before|after)?\s*\d|\d|[A-Z][a-z]{2,8}\.?\s+\d|unknown|\?)/i;

  // "Birth: Birth 1690 • Brightwater" -> "1690 • Brightwater"
  function cleanValue(v, label) {
    v = squash(v);
    var again = new RegExp('^' + label.replace(/[.]/g, '\\.') + '\\b\\s*:?\\s*', 'i');
    return v.replace(again, '');
  }

  // Is this line a header field? Returns {field, label, value, colon} or null.
  function labelOf(line, inHeader) {
    var t = line.replace(/^[\s ]+/, '');
    for (var i = 0; i < LABELS.length; i++) {
      var m = LABELS[i][1].exec(t);
      if (!m) continue;
      var rest = t.slice(m[0].length);
      var colon = /^\s*(\(s\))?\s*\??\s*[:：]/.exec(rest);            // "Marriage:", "Marriage?:", "Children(s):"
      if (colon) return { field: LABELS[i][0], label: m[1], value: cleanValue(rest.slice(colon[0].length), m[1]), colon: true };
      // "Children of Robert and Anne: Sarah (1835–), …"
      var of = /^\s+of\b[^:]{0,60}:/.exec(rest);
      if (of && LABELS[i][0] === 'children') return { field: 'children', label: m[1], value: squash(rest.slice(of[0].length)), colon: true };
      // label without a colon: only accept a short, date-like value ("Death 11 Mar 1931")
      if (/^\s+of\b/i.test(rest)) return null;
      if (inHeader && t.length < 160 && (DATEY.test(rest) || (LABELS[i][0] === 'father' || LABELS[i][0] === 'mother') && /\([A-Z]\d/.test(rest))) {
        return { field: LABELS[i][0], label: m[1], value: cleanValue(rest, m[1]), colon: false };
      }
      return null;
    }
    return null;
  }

  // "Walter Lemuel Thornbury (A3,1)(1842-1901)" -> { name, code, years, text }
  function parseRef(text) {
    text = squash(text).replace(/^\(?\d\)\s*/, '');                   // "1) William Fenwick, Jr. …"
    var ref = { text: text, name: '', code: '', rawCode: '', years: '' };
    if (!text) return ref;
    var codes = findCodes(text);
    var before = text, after = '';
    if (codes.length) {
      var c = codes[0];
      ref.rawCode = c.raw;
      ref.code = validKey(c.letter, c.gen, c.pos) || '';
      ref.badCode = !ref.code;
      before = text.slice(0, c.index).replace(/\(\s*$/, '');
      after = text.slice(c.index + c.raw.length).replace(/^\s*\)/, '');
    }
    // years in brackets right after the code, or right before it
    var ym = /^\s*\(([^)]*\d{3,4}[^)]*)\)?/.exec(after) || /\(([^)]*\d{3,4}[^)]*)\)\s*$/.exec(before);
    if (ym) {
      ref.years = spanFromBracket(ym[1]);
      if (before.slice(-ym[0].length) === ym[0]) before = before.slice(0, -ym[0].length);
    } else if (!codes.length) {
      var y2 = /\(([^)]*\d{3,4}[^)]*)\)/.exec(text) || /\b(\d{4}\s*[-–]\s*\d{0,4})\b/.exec(text);
      if (y2) { ref.years = cleanSpan(y2[1]); before = text.slice(0, y2.index); }
    } else {
      var y3 = /^\s*(\d{4}\s*[-–]\s*\d{0,4})/.exec(after);
      if (y3) ref.years = cleanSpan(y3[1]);
      // "(A9,212) 17 OCT 1683 • Oakhurst Bridge -- 1769 • …"
      var yrs = years(after);
      if (!ref.years && yrs.length >= 2 && /\s(--|–|-)\s/.test(after)) ref.years = yrs[0] + '–' + yrs[yrs.length - 1];
    }
    // "Francis Whitcombe II Birth 1673, Kettering Co. Death 1739 • Eng" -> the relative's own birth and death
    var bm = /\b(?:birth|born)\b\s*:?\s*(.*?)(?=[,;]?\s*\b(?:death|died|buried|burial)\b|$)/i.exec(text);
    var dm = /\b(?:death|died)\b\s*:?\s*(.*?)(?=[,;]?\s*\b(?:birth|born|buried|burial)\b|$)/i.exec(text);
    if (bm && /\d{3,4}/.test(bm[1])) ref.birth = squash(bm[1]).replace(/[,;]$/, '');
    if (dm && /\d{3,4}/.test(dm[1])) ref.death = squash(dm[1]).replace(/[,;]$/, '');
    if (!ref.years && (ref.birth || ref.death)) ref.years = (firstYear(ref.birth) || '?') + '–' + (firstYear(ref.death) || '');
    var name = before;
    // "5/20/1904 to Martha Frances Quimby" / "1928 to Edith ..." -> drop the date part
    var to = /^(.*?\d.*?)\s+to\s+(.+)$/i.exec(name);
    if (to) { ref.date = squash(to[1]); name = to[2]; }
    // leading dates: "3/18/1733 Lydia Rowntree", "Abt. 1764, Honora A. Stanwick", "Oct. 9, 1652 Walter …", "1711 • Riverton, OH, Lydia …"
    for (var k = 0; k < 3; k++) { var nn = name.replace(LEAD_DATE, ''); if (nn === name) break; name = nn; }
    name = name.replace(/^to\s+/i, '').replace(/^[A-Z]{2}\.?,\s*/, '');
    // "Ancestry gives Isaac Tolliver", "Possibly John Ellery" -> the name
    name = name.replace(/^\s*(?:ancestry\s+gives|ancestry\s+says|possibly|maybe|probably|perhaps|ancestor|grandfather|grandmother)\s*:?\s+/i, '');
    // "Francis Whitcombe II Birth 1673, Kettering…" / "Mary Prewitt Whitcombe, Birth 1663" / "Richard Bramble 1705" -> just the name
    name = name.replace(/[,;]?\s+(?:birth|born|death|died|bapt\w*|buried|burial|married)(?=[\s:]|$).*$/i, '');
    // "b. 1690" / "d. 1739" / "m. 1712" only when a date follows ("Mabel D. Hartwell" keeps her initial)
    name = name.replace(/[,;]?\s+(?:b|d|m)\.\s*(?=(?:c\.|abt|bef|aft|about|~|\d|[A-Za-z]{3,9}\.?\s+\d)).*$/i, '');
    name = name.replace(MONTH_TAIL, '').replace(/\s+(?:at|in|near|around|about|on)\s+.*$/i, '');
    name = name.replace(/\s*[•·].*$/, '').replace(/\s+(?:c\.\s*|~|abt\.?\s*)?\d.*$/, '');
    name = name.replace(/\s+(?:bef|aft|abt|before|after|about|ca|circa|c)\.?\s*$/i, '');
    name = name.replace(/[\s,;:(]+$/, '').replace(/^\s*[,;:)]\s*/, '');
    // keep brackets balanced: "Isabella (Coldbrook)" stays whole, "Mary Penrose (or Mary Winslow" gets its ")"
    var opens = (name.match(/\(/g) || []).length, closes = (name.match(/\)/g) || []).length;
    while (closes > opens && /\)\s*$/.test(name)) { name = name.replace(/\)\s*$/, ''); closes--; }
    if (opens > closes) name = name.replace(/\s+$/, '') + ')';
    ref.name = squash(name);
    if (!ref.name && !codes.length) ref.name = squash(text.replace(/[\s(].*?\d.*$/, '').replace(/\(.*$/, ''));
    return ref;
  }
  // Split a list value ("A (1881-1919), B (1890-1966) and C") into separate references.
  function splitList(value) {
    var parts = [], depth = 0, cur = '';
    for (var i = 0; i < value.length; i++) {
      var ch = value.charAt(i);
      if (ch === '(') depth++;
      if (ch === ')') depth = Math.max(0, depth - 1);
      if (depth === 0 && (ch === ';' || (ch === ',' && /\)\s*$/.test(cur)))) { parts.push(cur); cur = ''; continue; }
      cur += ch;
    }
    parts.push(cur);
    var out = [];
    parts.forEach(function (p) {
      p.split(/\s+and\s+(?=[A-Z])/).forEach(function (q) { q = squash(q); if (q && /[A-Za-z]/.test(q)) out.push(q); });
    });
    return out;
  }

  function placeOf(value) {
    // "3/14/1871, Millbrook, IL"  /  "9 Jun 1866 • Maplewood, Oak County, Ohio, USA"
    var v = squash(value);
    var bullet = v.split(/\s*[•·]\s*/);
    if (bullet.length > 1) return squash(bullet.slice(1).join(', '));
    var m = /^[^,]*\d{3,4}\s*,\s*(.+)$/.exec(v);
    if (m) return squash(m[1]);
    var m2 = /\b(?:in|at)\s+([A-Z].+)$/.exec(v);
    return m2 ? squash(m2[1]) : '';
  }

  // ---------------------------------------------------------------- document analysis
  function analyse(doc) {
    // one logical line per paragraph, and also per Shift+Enter line break inside a paragraph
    var lines = [];
    window.Render.docLines(doc).forEach(function (l) {
      var parts = String(l.text).split('\n');
      parts.forEach(function (t, k) {
        lines.push(k === 0 ? (parts.length === 1 ? l : { text: t, block: l.block, images: l.images, imgs: l.imgs, center: l.center, list: l.list }) : { text: t, block: l.block, images: 0, imgs: [], center: l.center, list: l.list });
      });
    });
    var info = { doc: doc, lines: lines, fields: {}, fieldOrder: [], refs: {}, title: '', titleName: '', titleCode: null, titleRawCode: '', span: '', extraPeople: [], headerEnd: 0 };
    var nonEmpty = [];
    lines.forEach(function (l, i) { if (squash(l.text)) nonEmpty.push(i); });
    if (!nonEmpty.length) return info;

    // --- title line(s)
    var ti = nonEmpty[0];
    var titleText = squash(lines[ti].text);
    info.title = titleText;
    var tcodes = findCodes(titleText);
    var spanFromTitle = '';
    if (tcodes.length) {
      var c = tcodes[0];
      info.titleRawCode = c.raw;
      info.titleCode = { letter: c.letter, gen: c.gen, pos: c.pos, key: validKey(c.letter, c.gen, c.pos) };
      var beforeT = titleText.slice(0, c.index).replace(/\(\s*$/, '');
      var afterT = titleText.slice(c.index + c.raw.length).replace(/^\s*\)/, '');
      if (!squash(beforeT.replace(/[()]/g, ''))) { beforeT = afterT; afterT = ''; }   // "(B6,27) Walter Merriweather 'The Miller'"
      var ys = /^\s*\(([^)]*\d{3,4}[^)]*)\)?/.exec(afterT) || /^\s*(\d{3,4}.*)$/.exec(afterT);
      if (ys) spanFromTitle = spanFrom(ys[1]) || cleanSpan(ys[1]);
      info.titleName = squash(beforeT.replace(/\s*\($/, ''));
    } else {
      var yy = /^(.*?)\s*\(([^)]*\d{3,4}[^)]*)\)/.exec(titleText);
      if (yy && squash(yy[1])) { info.titleName = squash(yy[1].replace(/\s*\([A-Z]\d{0,2}\)\s*$/, '')); spanFromTitle = spanFrom(yy[2]) || cleanSpan(yy[2]); }
      else info.titleName = titleText;
    }
    // a second person in the title area (couple documents, e.g. "A4,5-6")
    var next = nonEmpty[1] != null ? squash(lines[nonEmpty[1]].text) : '';
    var nextCodes = findCodes(next);
    var cursor = 1;
    if (nextCodes.length && !labelOf(next, true) && next.length < 120 && info.titleCode) {
      var r2 = parseRef(next);
      if (r2.code) { info.extraPeople.push(r2); cursor = 2; }
    }
    if (!spanFromTitle && nonEmpty[cursor] != null) {
      var cand = squash(lines[nonEmpty[cursor]].text);
      if (cand.length < 60 && SPAN_RE.test(cand) && !labelOf(cand, true)) { spanFromTitle = spanFrom(cand) || cleanSpan(cand); cursor++; }
    }
    info.span = spanFromTitle;

    // --- header fields
    var last = null, lastIdx = -1, longProse = 0, blank = false, parentCtx = null, seen = {};
    var start = nonEmpty[cursor] != null ? nonEmpty[cursor] : lines.length;
    var i;
    info.parentDetails = {};
    for (i = ti + 1; i < lines.length && i < ti + 70; i++) {
      var raw = lines[i].text;
      var t = squash(raw);
      if (i < start) continue;
      if (!t) { if (lines[i].images) continue; last = null; blank = true; continue; }
      var lab = labelOf(raw, true);
      if (blank && info.fieldOrder.length) {
        // after a blank line the header only goes on if another header line follows (e.g. Marriage: after Death:)
        var core = seen.birth || seen.death || seen.marriage;
        var more = lab && HEADERISH[lab.field] && !seen[lab.field];
        if (core && !more && !(lines[i].images && t.length < 3)) break;
      }
      blank = false;
      if (lab) {
        if (!lab.colon && parentCtx && /^(birth|death|burial|baptism)$/.test(lab.field)) {
          // "Birth 21 APR 1712 • Blackwood" right under "Father:" describes the father, not this person
          (info.parentDetails[parentCtx] = info.parentDetails[parentCtx] || []).push({ field: lab.field, value: lab.value });
          lastIdx = i; info.headerEnd = i;
          continue;
        }
        parentCtx = (lab.field === 'father' || lab.field === 'mother') ? lab.field : null;
        if (!info.fields[lab.field]) { info.fields[lab.field] = []; info.fieldOrder.push(lab.field); }
        if (lab.value) info.fields[lab.field].push(lab.value);     // "Birth: " with nothing after it adds no fact
        seen[lab.field] = 1;
        last = lab.field; lastIdx = i;
        info.headerEnd = i;
        continue;
      }
      // continuation of a list field ("Siblings:" then indented names on the next lines; "2) second marriage")
      if (last && MULTI[last] && i === lastIdx + 1 && t.length < 200 &&
          (/^[\s\u00a0\t]/.test(raw) || /^\(?\d\)\s/.test(t) || (last !== 'marriage' && /\(\s*\d|\([A-Z]\d/.test(t))) &&
          !/^[^(]*:/.test(t) && !PROSE_START.test(t) && !/(?:[A-Z][a-z]+\s+[A-Z][a-z]+\s+\d{1,3},\s*){2}/.test(t)) {      // not a census household list
        var arr = info.fields[last];
        var afterDate = t.replace(LEAD_DATE, '');
        var newEntry = /^\(?\d\)\s/.test(t) || (/^[A-Z][a-z]/.test(t) && !MONTH_START.test(t)) ||
          (afterDate !== t && /^(to\s+)?[A-Z]/.test(afterDate));            // "4/11/1868 to Martha Ann Gresham"
        if (last === 'marriage' && !newEntry && arr.length) arr[arr.length - 1] += ' ' + t;   // value wrapped onto the next line
        else arr.push(t);
        lastIdx = i; info.headerEnd = i;
        continue;
      }
      last = null; parentCtx = null;
      if (lines[i].images && t.length < 3) continue;     // picture row
      if (t.length > 200) { longProse++; if (info.fieldOrder.length || longProse >= 2) break; }
    }

    // --- references in the fields (the first Father:/Mother:/Descendant: line counts)
    ['father', 'mother', 'descendant'].forEach(function (f) {
      if (info.fields[f] && info.fields[f].length) info.refs[f] = parseRef(info.fields[f][0]);
    });
    if (info.fields.parents && !info.refs.father) {
      var pl = splitList(info.fields.parents.join('; '));
      if (pl[0]) info.refs.father = parseRef(pl[0]);
      if (pl[1]) info.refs.mother = parseRef(pl[1]);
    }
    if (info.fields.marriage) {
      // one marriage per line (commas inside a line are usually the place: "…(1884-1938), Fairview, TX")
      info.refs.marriage = [];
      info.fields.marriage.forEach(function (v) {
        v.split(/\s*;\s*/).forEach(function (part) { var r = parseRef(part); if (r.name || r.code) info.refs.marriage.push(r); });
      });
    }
    ['children', 'siblings'].forEach(function (f) {
      if (!info.fields[f]) return;
      info.refs[f] = [];
      info.fields[f].forEach(function (v) {
        // "Odette Lyle, Ada Mae, Walter J." (no brackets) is a plain comma list
        var parts = /\(/.test(v) ? splitList(v) : v.split(/\s*,\s*|\s+and\s+(?=[A-Z])/).filter(function (q) { return /[A-Za-z]/.test(q); });
        parts.forEach(function (part) { info.refs[f].push(parseRef(part)); });
      });
    });
    return info;
  }

  // ---------------------------------------------------------------- timeline
  var EVENT_WORDS = [
    ['Birth', /\b(born|birth)\b/i], ['Baptism', /\b(bapti[sz]ed|baptism|christened)\b/i],
    ['Marriage', /\b(married|marriage|wed)\b/i], ['Death', /\b(died|death|killed)\b/i], ['Burial', /\b(buried|burial)\b/i],
    ['Census', /\bcensus\b/i], ['Military', /\b(war|regiment|militia|enlisted|army|navy|soldier|served|draft)\b/i],
    ['Land', /\b(deed|land|acres|grant|patent|purchased|sold)\b/i], ['Will', /\b(will|probate|estate|inventory)\b/i],
    ['Residence', /\b(moved|lived|living|residence|settled)\b/i]
  ];
  function timelineOf(info) {
    var ev = [];
    var lines = info.lines;
    for (var i = info.headerEnd + 1; i < lines.length; i++) {
      var t = squash(lines[i].text);
      if (!t || t.length > 700) continue;
      var m = /^(?:(c\.|ca\.?|abt\.?|~|about|bef\.?|aft\.?)\s*)?(1[0-9]{3}|20[0-2][0-9])(?:\s*[-–/]\s*\d{2,4})?\b[\s,.:;–-]*(.*)$/i.exec(t);
      if (!m) continue;
      var rest = m[3];
      if (!rest || /^(census|\d|[a-z])/i.test(rest) === false && rest.length < 3) continue;
      var kind = '';
      for (var k = 0; k < EVENT_WORDS.length; k++) { if (EVENT_WORDS[k][1].test(rest.slice(0, 80))) { kind = EVENT_WORDS[k][0]; break; } }
      ev.push({ year: +m[2], approx: !!m[1], text: t.slice(m[0].length - m[3].length), label: kind, line: i });
    }
    return ev;
  }

  // ---------------------------------------------------------------- build everything
  var model = null;
  var aliases = {};          // place in the tree -> the same person's main place (pedigree collapse)
  function resolve(key) { return (key && aliases[key]) || key; }
  function sameName(a, b) {
    var x = normName(shortName(a)).split(' '), y = normName(shortName(b)).split(' ');
    return !!(x[0] && y[0] && x[0] === y[0] && x[x.length - 1] === y[y.length - 1]);
  }

  function build(data) {
    var people = {}, docs = {}, stories = [], notes = { duplicates: [], codeMismatch: [], refMismatch: [], badCodes: [], unreadable: [], unmatched: [], ignored: [], warnings: [], collapse: [], photos: [] };
    aliases = {};
    var docList = (data && data.docs) || [];
    var ignore = {};
    (CFG.ignoreDocuments || []).forEach(function (n) { ignore[n.toLowerCase()] = 1; });

    function person(key) {
      if (!key) return null;
      if (!people[key]) {
        var root = ROOTS[key];
        people[key] = {
          key: key, code: root ? '' : key, root: !!root, sex: sexOf(key), name: root ? root.name : '', nameSource: root ? 9 : 0,
          span: root ? (root.years || '') : '', docs: [], doc: null, info: null, mentions: [], facts: {}, otherSpouses: [], otherChildren: [], siblings: [],
          refNames: []
        };
        var c = parseKey(key);
        if (c) { people[key].gen = c.gen; people[key].pos = c.pos; people[key].letter = c.letter; people[key].line = CFG.lines[c.letter]; }
      }
      return people[key];
    }
    CFG.roots.forEach(function (r) { person(r.key); });

    function setName(p, name, span, source) {
      if (!p || !name) return;
      name = squash(name).replace(/^[,;:\s]+|[,;:\s]+$/g, '');
      if (!name || name.length > 90) return;
      if (source <= 5 && !looksLikeName(name)) return;     // e.g. "The identity of Quentin Vickery's father is currently unknown"
      p.refNames.push(name);
      if (source > p.nameSource || (source === p.nameSource && name.length > p.name.length && source < 5)) {
        p.name = name; p.nameSource = source;
        if (span) p.span = span;
      } else if (span && !p.span) p.span = span;
    }

    // --- 1. analyse every document and decide whom it describes
    var analysed = [];
    // documents that could not be read at the last update but have an earlier copy: shown, with a note
    var lastErrors = {};
    ((data && data.errors) || []).forEach(function (e) { lastErrors[String(e.path).toLowerCase()] = e.msg; });
    docList.forEach(function (doc) {
      docs[doc.id] = doc;
      var le = lastErrors[String(doc.path).toLowerCase()];
      if (le && !doc.err) { doc.lastError = le; notes.unreadable.push(doc); }
      doc.text = window.Render.docLines(doc).map(function (l) { return l.text; }).join('\n');
      if (doc.err) { notes.unreadable.push(doc); return; }
      if (ignore[doc.name.toLowerCase()]) { notes.ignored.push(doc); doc.kind = 'ignored'; return; }
      var info = analyse(doc);
      doc.info = info;
      doc.title = info.titleName || info.title || doc.name;
      // code from the file name
      var fcodes = findCodes(doc.name);
      var fileKey = null, fileRaw = '';
      if (fcodes.length) { fileRaw = fcodes[0].raw; fileKey = validKey(fcodes[0].letter, fcodes[0].gen, fcodes[0].pos); }
      var headKey = info.titleCode ? info.titleCode.key : null;
      var mapped = CFG.documentPeople && CFG.documentPeople[doc.name];
      var key = null, why = '';
      if (mapped) { key = mapped; why = 'settings'; }
      else if (headKey && fileKey && headKey !== fileKey) {
        // disagreement: trust whichever agrees with the document's own Father/Mother/Descendant codes
        var score = function (k) {
          var s = 0, r = info.refs;
          if (r.father && r.father.code) s += r.father.code === fatherKey(k) ? 2 : -1;
          if (r.mother && r.mother.code) s += r.mother.code === motherKey(k) ? 2 : -1;
          if (r.descendant && r.descendant.code) s += r.descendant.code === childKey(k) ? 2 : -1;
          return s;
        };
        var sh = score(headKey), sf = score(fileKey);
        if (sh === sf && headKey.charAt(0) !== fileKey.charAt(0)) {
          // still undecided and the letters differ: prefer the letter of the folder the file is in
          var folderLetter = folderLine(doc.dir);
          if (folderLetter && SPACE_BY_LETTER[fileKey.charAt(0)] === SPACE_BY_LETTER[folderLetter]) sf += 1;
          else if (folderLetter && SPACE_BY_LETTER[headKey.charAt(0)] === SPACE_BY_LETTER[folderLetter]) sh += 1;
        }
        key = sf > sh ? fileKey : headKey; why = sf > sh ? 'file name' : 'document title';
      }
      else if (headKey) { key = headKey; why = 'document title'; }
      else if (fileKey) { key = fileKey; why = 'file name'; }
      if (info.titleCode && !headKey) notes.badCodes.push({ doc: doc, raw: info.titleRawCode, where: 'title' });
      if (fcodes.length && !fileKey) notes.badCodes.push({ doc: doc, raw: fileRaw, where: 'file name' });
      if (headKey && fileKey && headKey !== fileKey) notes.codeMismatch.push({ doc: doc, file: fileRaw, head: info.titleRawCode, chosen: key, why: why });
      doc.fileKey = fileKey;
      // the generation and number in the file name, whatever the letter ("D8,117 Haverford Cordelia" carries 8,117)
      var gp = /^\s*[A-Za-z](\d{1,2})\s?[,.]\s?(\d{1,5})/.exec(doc.name);
      doc.fileGenPos = gp ? (+gp[1]) + ',' + (+gp[2]) : '';
      analysed.push({ doc: doc, info: info, key: key });
    });

    // --- 2. documents with a code: attach to people
    analysed.forEach(function (a) {
      if (!a.key) return;
      var p = person(a.key);
      p.docs.push(a.doc);
      a.doc.kind = 'person'; a.doc.personKey = a.key;
      setName(p, a.info.titleName, a.info.span, 8);
      a.info.extraPeople.forEach(function (r) {
        var q = person(r.code);
        q.docs.push(a.doc); setName(q, r.name, r.years, 7);
        a.doc.alsoKeys = (a.doc.alsoKeys || []).concat(r.code);
      });
    });

    // people that have no document and are not named in any (set in config.js)
    Object.keys(CFG.people || {}).forEach(function (k) {
      var e = CFG.people[k];
      setName(person(k), e.name, e.years, 6);
    });

    // --- 3. names from the Father/Mother/Descendant lines of other documents (then marriages)
    // How much a line counts as evidence for the name in a slot:
    //   6 = the line gives exactly this slot's number, 5 = no number given, 2 = its number points elsewhere
    analysed.forEach(function (a) {
      if (!a.key) return;
      var r = a.info.refs, k = a.key;
      [['father', fatherKey(k)], ['mother', motherKey(k)], ['descendant', childKey(k)]].forEach(function (pair) {
        var ref = r[pair[0]], expected = pair[1];
        if (!ref || !(ref.name || ref.code)) return;
        if (ref.badCode) notes.badCodes.push({ doc: a.doc, raw: ref.rawCode, where: pair[0] + ' line' });
        // Pedigree collapse: the parent written is someone already in the tree at another place
        // (e.g. Lydia Jane Nettles's father "Barnaby Nettle (C11,73)"). Show that same person here.
        var host = ref.code && people[ref.code];
        var collapse = pair[0] !== 'descendant' && ref.code && expected && ref.code !== expected && host && host.docs.length &&
            !(people[expected] && people[expected].docs.length) && sameName(ref.name, host.name);
        // ... and the mother of such a child is then the wife of that person
        if (!collapse && pair[0] === 'mother' && expected && aliases[fatherKey(k)] && !(people[expected] && people[expected].docs.length)) {
          var hostWife = spouseKey(aliases[fatherKey(k)]);
          if (hostWife && people[hostWife] && (ref.code === hostWife || sameName(ref.name, people[hostWife].name))) { collapse = true; ref.code = hostWife; host = people[hostWife]; }
        }
        if (collapse) {
          aliases[expected] = ref.code;
          host.alsoAt = (host.alsoAt || []).concat(expected);
          host.mentions.push({ doc: a.doc, role: pair[0], from: k });
          notes.collapse.push({ doc: a.doc, at: expected, is: ref.code, name: host.name });
          return;
        }
        if (ref.code && expected && ref.code !== expected) {
          notes.refMismatch.push({ doc: a.doc, field: pair[0], written: ref.rawCode, expected: expected, name: ref.name });
          // a Descendant: line pointing at another person who is already in the tree says nothing about this slot
          if (pair[0] === 'descendant' && people[ref.code] && (people[ref.code].docs.length || people[ref.code].nameSource)) return;
        }
        var target = expected || ref.code;
        if (!target) return;
        var q = person(target);
        if (/^\s*(\?+|unknown|not known)\s*\.?\s*$/i.test(ref.name) || !looksLikeName(ref.name)) {
          // "Mother: ?" — the author says this parent is not known; don't fill the place from elsewhere
          if (!q.docs.length && /\?|unknown|not known/i.test(ref.name)) q.blocked = true;
          return;
        }
        setName(q, ref.name, ref.years, ref.code ? (ref.code === expected ? 6 : 2) : 5);
        q.mentions.push({ doc: a.doc, role: pair[0], from: k });
        var det = (a.info.parentDetails && a.info.parentDetails[pair[0]]) || [];
        if (ref.birth) det = det.concat({ field: 'birth', value: ref.birth });
        if (ref.death) det = det.concat({ field: 'death', value: ref.death });
        if (det.length && !q.docs.length && !q.extraFacts) {
          q.extraFacts = {};
          det.forEach(function (d) { (q.extraFacts[d.field] = q.extraFacts[d.field] || []).push(d.value); });
          if (!q.span) {
            var by = q.extraFacts.birth && firstYear(q.extraFacts.birth[0]), dy = q.extraFacts.death && firstYear(q.extraFacts.death[0]);
            if (by || dy) q.span = (by || '?') + '–' + (dy || '');
          }
        }
      });
    });
    analysed.forEach(function (a) {
      if (!a.key || !a.info.refs.marriage) return;
      var k = a.key, sp = spouseKey(k), list = [];
      var entries = a.info.refs.marriage;
      var codedLine = entries.some(function (r) { return r.code && r.code === sp; });
      var first = function (n) { return normName(shortName(n)).split(' ')[0]; };
      entries.forEach(function (ref) {
        if (ref.code && sp && ref.code === sp) { if (looksLikeName(ref.name)) setName(person(sp), ref.name, ref.years, 6); ref.isLine = true; return; }
        if (ref.code && ref.code !== sp) {
          notes.refMismatch.push({ doc: a.doc, field: 'marriage', written: ref.rawCode, expected: sp, name: ref.name });
          ref.isLine = true;
          return;
        }
        if (!ref.name || !looksLikeName(ref.name)) return;          // a date, a place or a remark, not a person
        // written without a code: is it the spouse in the tree, or another marriage?
        var spouse = sp && person(sp);
        var same = spouse && spouse.nameSource && first(spouse.name) === first(ref.name);
        if (same) { ref.isLine = true; return; }
        // only a single marriage line, with nothing else known about the spouse's place, may name it
        if (spouse && !codedLine && !spouse.nameSource && !spouse.blocked && entries.length === 1) {
          setName(spouse, ref.name, ref.years, 3); ref.isLine = true; return;
        }
        list.push(ref);
      });
      a.doc.otherMarriages = list;
    });
    // --- 4. documents without a code: match them to a person by name, else they are stories
    var nameIndex = {};
    Object.keys(people).forEach(function (k) {
      var p = people[k];
      p.refNames.concat([p.name]).forEach(function (n) { var nn = normName(n); if (nn) (nameIndex[nn] = nameIndex[nn] || []).push(k); });
    });
    analysed.forEach(function (a) {
      if (a.key) return;
      var nn = normName(a.info.titleName);
      var cands = (nn && nameIndex[nn]) || [];
      var span = years(a.info.span);
      var near = function (k) {
        var py = years(people[k].span);
        return !span.length || !py.length || Math.abs(py[0] - span[0]) <= 2;
      };
      cands = cands.filter(function (k, i) { return cands.indexOf(k) === i; }).filter(near);
      if (!cands.length && span.length) {
        // looser: same first and last name and the same birth year ("Johann Andres Pruett" = "Johann Andreas Pruett")
        cands = Object.keys(people).filter(function (k) {
          var q = people[k];
          return q.docs.length && years(q.span).length && sameName(a.info.titleName, q.name) && Math.abs(years(q.span)[0] - span[0]) <= 1;
        });
      }
      if (cands.length === 1 && a.info.span) {
        var p = person(cands[0]);
        p.docs.push(a.doc); a.doc.kind = 'person'; a.doc.personKey = p.key; a.doc.matchedByName = true;
        setName(p, a.info.titleName, a.info.span, 8);
        notes.unmatched.push({ doc: a.doc, matched: p.key });
      } else {
        a.doc.kind = 'story';
        stories.push(a.doc);
      }
    });

    // --- 4b. a document filed under someone else's number but clearly about another person who has
    //          a life history ("B10,342 Cobb Thaddeus" on Honora Ravenscroft's number) joins that person
    Object.keys(people).forEach(function (k) {
      var p = people[k];
      var own = p.docs.filter(function (d) { return d.personKey === k; });
      if (own.length < 2) return;
      var anchor = own.slice().sort(function (x, y) { return y.text.length - x.text.length; })[0];
      own.forEach(function (d) {
        if (d === anchor || sameName(d.info.titleName, anchor.info.titleName)) return;
        var dy = years(d.info.span);
        var home = Object.keys(people).filter(function (j) {
          var q = people[j];
          if (j === k || !q.docs.length) return false;
          var qy = years(q.span);
          return sameName(d.info.titleName, q.name) && (!dy.length || !qy.length || Math.abs(dy[0] - qy[0]) <= 1);
        });
        if (home.length !== 1) return;
        p.docs.splice(p.docs.indexOf(d), 1);
        people[home[0]].docs.push(d);
        d.personKey = home[0]; d.movedFrom = k;
        notes.moved = notes.moved || [];
        notes.moved.push({ doc: d, from: k, to: home[0] });
      });
    });

    // --- 5. pick the main document for each person; the rest are "other versions"
    Object.keys(people).forEach(function (k) {
      var p = people[k];
      if (!p.docs.length) return;
      var own = p.docs.filter(function (d) { return d.personKey === k; });
      var pool = own.length ? own : p.docs;
      var longest = Math.max.apply(null, pool.map(function (d) { return d.text.length; }));
      var sorted = pool.slice().sort(function (x, y) { return x.mtime < y.mtime ? 1 : x.mtime > y.mtime ? -1 : 0; });
      // main version: a full document (not a stub), preferably one whose file name carries this number, then the newest
      var full = sorted.filter(function (d) { return d.text.length >= longest * 0.25; });
      var kc = parseKey(k), kgp = kc ? kc.gen + ',' + kc.pos : '';
      var main = full.filter(function (d) { return d.fileKey === k || (kgp && d.fileGenPos === kgp); })[0] || full[0] || sorted[0];
      p.doc = main; p.info = main.info;
      if (own.length > 1) {
        var names = own.map(function (d) { var n = normName(shortName(d.info.titleName)).split(' '); return n[0] + ' ' + n[n.length - 1]; });
        var differ = names.some(function (n) { return n !== names[0]; });
        notes.duplicates.push({ key: k, docs: own, main: main, differentPeople: differ });
      }
      if (main.info && main.personKey === k) {
        setName(p, main.info.titleName, main.info.span, 9);
        var r = main.info.refs;
        p.facts = main.info.fields;
        p.otherChildren = r.children || [];
        p.siblings = r.siblings || [];
        p.otherSpouses = main.otherMarriages || [];
      }
    });

    // --- 6. mentions of codes anywhere in the text (backlinks)
    docList.forEach(function (doc) {
      if (!doc.text || doc.kind === 'ignored') return;
      var seen = {};
      findCodes(doc.text).forEach(function (c) {
        var k = validKey(c.letter, c.gen, c.pos);
        if (!k || seen[k] || k === doc.personKey) return;
        seen[k] = 1;
        var p = people[k];
        if (!p) return;     // only people already in the tree are linked; a number in running text alone does not add anyone
        var s = Math.max(0, c.index - 90), e = Math.min(doc.text.length, c.end + 110);
        p.mentions.push({ doc: doc, role: 'text', snippet: (s > 0 ? '…' : '') + doc.text.slice(s, e).replace(/\s+/g, ' ') + (e < doc.text.length ? '…' : '') });
      });
    });

    // --- 7. finishing touches
    Object.keys(people).forEach(function (k) {
      var p = people[k];
      if (!p.name) p.name = (p.sex === 'f' ? 'Unknown mother' : p.sex === 'm' ? 'Unknown father' : 'Unknown');
      p.short = shortName(p.name);
      p.years = p.span ? p.span.replace(/-/g, '–') : '';
      var ys = years(p.span);
      p.born = ys.length ? ys[0] : null;
      p.died = ys.length > 1 ? ys[ys.length - 1] : null;
      p.surname = surnameOf(p);
      p.photo = p.doc ? pickPhoto(p.doc) : null;
      p.events = p.info && p.doc.personKey === k ? timelineOf(p.info) : [];
      p.placeholder = !p.doc && !p.root;
      if (p.placeholder && p.extraFacts) p.facts = p.extraFacts;
    });

    // --- 8. photos from the Photos folder (they win over a picture found in the life history)
    matchPhotos(data.photos || [], people, notes.photos);

    model = { people: people, docs: docs, stories: stories, notes: notes, data: data };
    return model;
  }

  // A Father:/Mother: value can be a remark rather than a name.
  function looksLikeName(n) {
    var s = String(n).replace(/\bsurname unknown\b/i, '').trim();
    if (!s || /^[a-z]/.test(s) || (s.match(/[A-Za-z]/g) || []).length < 2 || /^unknown$/i.test(s)) return false;
    if (s.split(/\s+/).length > 8) return false;
    if (/\b(co|county|parish|township|twp|cemetery|church)\b\.?/i.test(s) || /,?\s[A-Z]{2}\.?$/.test(s)) return false;     // a place: "Pine Co. AR"
    return !/\b(is|was|are|were|identity|currently|suspect|believed?|probably|possibly|perhaps|might|either|belonged|not known|no record|unclear|see)\b/i.test(s);
  }

  // Which line letter does a folder belong to? (a folder named "Ashworth" -> the line named Ashworth)
  function folderLine(dir) {
    var d = String(dir || '').toLowerCase();
    var hit = null;
    Object.keys(CFG.lines).forEach(function (l) { if (!hit && d && d.indexOf(CFG.lines[l].name.toLowerCase()) >= 0) hit = l; });
    return hit;
  }

  function shortName(n) { return squash(String(n).replace(/\((m\.|married|wife of|husband of)[^)]*\)/ig, ' ')); }
  function surnameOf(p) {
    var n = shortName(p.name).replace(/\(.*?\)/g, ' ').replace(/,?\s+(Sr|Jr|II|III|IV|I|MD|Esq)\.?,?$/i, '').replace(/[“”"‘’].*?[“”"‘’]/g, ' ');
    n = squash(n.replace(/\b(surname unknown)\b/i, ''));
    var parts = n.split(/\s+/).filter(function (w) { return /^[A-Za-z]/.test(w) && !/^(Sr|Jr|II|III|IV|MD|Lt|Capt|Col|Rev|Dr|Sgt|Maj|Deacon|Captain|Major)\.?,?$/i.test(w); });
    var s = parts.length ? parts[parts.length - 1] : '';
    if (/^(Unknown|father|mother)$/i.test(s)) return '';
    return s.replace(/[,.]$/, '');
  }

  var PHOTO_YES = /\b(person|man|woman|men|women|boy|girl|child|children|people|couple|family|portrait|face|soldier|uniform|bride|groom|wedding|baby|lady|gentleman|sailor|smiling|wearing|posing)\b/i;
  var PHOTO_NO = /\b(grave|headstone|tombstone|gravestone|cemetery|document|text|letter|map|newspaper|census|paper|screenshot|chart|table|book|page|certificate|sign|marker|plaque)\b/i;
  function pickPhoto(doc) {
    var best = null;
    (function walk(blocks) {
      blocks.forEach(function (b) {
        if (best) return;
        if (b.tbl) { b.tbl.forEach(function (row) { row.forEach(function (c) { walk(c.b); }); }); return; }
        (b.r || []).forEach(function (r) {
          if (best || !r.img) return;
          var alt = window.Render.cleanAlt(r.alt);
          if (alt && PHOTO_YES.test(alt) && !PHOTO_NO.test(alt) && (!r.w || !r.h || (r.h / r.w > 0.55 && r.h / r.w < 2.2))) best = r.img;
        });
      });
    })(doc.b || []);
    return best;
  }

  // A picture in the Photos folder belongs to the person whose number starts its file name: "A3,2.jpg",
  // "A3,2 John at 20.jpg" (also "A3.2", "a3,2"); a root person's by the key in the settings: "tom.jpg".
  // When one person has several, the one named by the number alone wins, otherwise the newest.
  var PHOTO_CODE = /^([A-Za-z])\s?(\d{1,2})\s?[,.]\s?(\d{1,5})(?!\d)/;
  function photoTarget(name) {
    var m = PHOTO_CODE.exec(name);
    if (m) {
      var k = validKey(m[1].toUpperCase(), +m[2], +m[3]);
      return { code: m[1].toUpperCase() + m[2] + ',' + m[3], key: k ? resolve(k) : null, exact: m[0].length === name.length };
    }
    var low = name.toLowerCase(), hit = null;
    Object.keys(ROOTS).forEach(function (rk) {
      var r = rk.toLowerCase();
      if (!hit && (low === r || low.indexOf(r + ' ') === 0)) hit = { code: rk, key: rk, exact: low === r };
    });
    return hit;
  }
  function matchPhotos(list, people, notes) {
    var found = {};
    list.forEach(function (ph) {
      var name = String(ph.path).split('\\').pop().replace(/\.[^.]*$/, '').trim();
      var t = photoTarget(name);
      if (!t) { notes.push({ path: ph.path, problem: 'no number' }); return; }
      if (!t.key || !people[t.key]) { notes.push({ path: ph.path, problem: 'nobody', code: t.code }); return; }
      if (ph.err || !ph.img) { notes.push({ path: ph.path, problem: 'unreadable', person: t.key, err: ph.err || '' }); return; }
      (found[t.key] = found[t.key] || []).push({ ph: ph, exact: t.exact });
    });
    Object.keys(found).forEach(function (k) {
      var all = found[k].sort(function (a, b) {
        return (b.exact - a.exact) || (a.ph.mtime < b.ph.mtime ? 1 : a.ph.mtime > b.ph.mtime ? -1 : 0) || (a.ph.path < b.ph.path ? -1 : 1);
      });
      var p = people[k], best = all[0].ph;
      p.docPhoto = p.photo;
      p.photo = best.img;
      p.photoFile = best.path;
      all.slice(1).forEach(function (x) { notes.push({ path: x.ph.path, problem: 'another', person: k, shown: best.path }); });
    });
  }

  // ---------------------------------------------------------------- relationship words
  function ordinal(n) { var s = ['th', 'st', 'nd', 'rd'], v = n % 100; return n + (s[(v - 20) % 10] || s[v] || s[0]); }
  function relationWord(gen, sex) {
    var base = sex === 'f' ? 'mother' : sex === 'm' ? 'father' : 'parent';
    if (gen === 1) return base;
    if (gen === 2) return 'grand' + base;
    if (gen === 3) return 'great-grand' + base;
    return ordinal(gen - 2) + ' great-grand' + base;
  }
  function relationTo(p) {
    if (!p || p.root) return '';
    var root = ROOTS[p.line && p.line.root];
    if (!root) return '';
    return root.short + "'s " + relationWord(p.gen, p.sex);
  }

  function findByCode(code) {
    if (!model) return null;
    var m = /^([A-Z])\s?(\d{1,2})\s?[,.]\s?(\d{1,5})$/.exec(code);
    if (!m) return null;
    var k = validKey(m[1], +m[2], +m[3]);
    k = resolve(k);
    return k && model.people[k] ? model.people[k] : null;
  }

  window.Genealogy = {
    build: build, resolve: resolve,
    get model() { return model; },
    findByCode: findByCode,
    fatherKey: fatherKey, motherKey: motherKey, childKey: childKey, spouseKey: spouseKey, sexOf: sexOf,
    parseKey: parseKey, validKey: validKey, findCodes: findCodes,
    relationTo: relationTo, relationWord: relationWord, placeOf: placeOf, firstYear: firstYear, marriageYear: marriageYear, shortName: shortName,
    normName: normName, roots: ROOTS, analyse: analyse, parseRef: parseRef
  };
})();
