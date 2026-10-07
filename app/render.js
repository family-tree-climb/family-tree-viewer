/* Family Tree Viewer — turns a converted Word document back into a readable page.
   Everything the author wrote is shown; nothing is left out. */
(function () {
  'use strict';

  // (all attributes are written in double quotes, so an apostrophe can stay as it is)
  var ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return ESC[c]; }); }

  // Escape text and turn person codes into links (only when the person exists in the tree).
  function linkCodes(text, opts) {
    text = String(text == null ? '' : text);
    var G = window.Genealogy;
    if (!G || !G.findCodes) return esc(text);
    var out = '', last = 0;
    G.findCodes(text).forEach(function (c) {
      var key = G.validKey(c.letter, c.gen, c.pos);
      if (!key) return;                                   // not a possible number: leave the text as written
      var person = G.findByCode(key);
      out += esc(text.slice(last, c.index));
      if (person && !(opts && opts.selfKey === person.key)) {
        out += '<a class="code" href="#/p/' + encodeURIComponent(person.key) + '" title="' + esc(person.name) + '">' + esc(c.raw) + '</a>';
      } else if (person) {
        out += esc(c.raw);
      } else {
        out += '<a class="code missing" title="No one with this number in the tree yet">' + esc(c.raw) + '</a>';
      }
      last = c.end;
    });
    return out + esc(text.slice(last));
  }

  function highlight(html, terms) {
    if (!terms || !terms.length) return html;
    // the words as written, with ' matching ’ too; "&" and quotes appear escaped in the page
    var re = new RegExp('(' + terms.map(function (t) {
      return esc(t).replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/'/g, "['’‘]").replace(/&quot;/g, '(?:&quot;|[“”])');
    }).join('|') + ')', 'gi');
    // only outside tags and never inside &...; entities
    return html.replace(/(<[^>]+>|&[#\w]+;)|([^<&]+)/g, function (all, keep, txt) {
      return keep ? keep : txt.replace(re, '<mark>$1</mark>');
    });
  }

  // Word's automatic picture descriptions are not the author's captions; keep only useful wording.
  function cleanAlt(alt) {
    var s = String(alt || '')
      .replace(/\s*AI-generated content may be incorrect\.?\s*/ig, ' ')
      .replace(/\s*Description automatically generated( with (medium|low|high) confidence)?\.?\s*/ig, ' ')
      .replace(/\s+/g, ' ').trim();
    if (/^(table|text|diagram|chart|shape|icon|graphical user interface|application|website|logo|picture \d*|image \d*|a picture containing\s*\w*)$/i.test(s)) return '';
    return s;
  }

  // ---- list numbering (Word stores the style; we count) ----
  function toRoman(n) {
    var r = '', map = [[1000, 'm'], [900, 'cm'], [500, 'd'], [400, 'cd'], [100, 'c'], [90, 'xc'], [50, 'l'], [40, 'xl'], [10, 'x'], [9, 'ix'], [5, 'v'], [4, 'iv'], [1, 'i']];
    map.forEach(function (p) { while (n >= p[0]) { r += p[1]; n -= p[0]; } });
    return r;
  }
  function toLetter(n) { var s = ''; while (n > 0) { n--; s = String.fromCharCode(97 + (n % 26)) + s; n = Math.floor(n / 26); } return s; }
  function formatNum(fmt, n) {
    switch (fmt) {
      case 'lowerLetter': return toLetter(n);
      case 'upperLetter': return toLetter(n).toUpperCase();
      case 'lowerRoman': return toRoman(n);
      case 'upperRoman': return toRoman(n).toUpperCase();
      case 'none': return '';
      default: return String(n);
    }
  }
  function listMarker(li, counters) {
    if (li.f === 'bullet' || li.f === 'none') {
      var ch = li.x || '•';
      var code = ch.charCodeAt(0);
      if (code >= 0xF000 || /[-]/.test(ch) || ch === 'o' || ch === '§' || ch === '·') ch = li.l % 2 ? '◦' : '•';
      return li.f === 'none' ? '' : ch;
    }
    var key = li.n;
    var c = counters[key] || (counters[key] = []);
    c[li.l] = (c[li.l] || (li.s || 1) - 1) + 1;
    for (var k = li.l + 1; k < c.length; k++) c[k] = 0;
    var text = li.x || ('%' + (li.l + 1) + '.');
    return text.replace(/%(\d)/g, function (all, d) {
      var lvl = +d - 1;
      return formatNum(lvl === li.l ? li.f : 'decimal', c[lvl] || 1);
    });
  }

  function baseSize(blocks) {
    var counts = {};
    (function walk(bs) {
      bs.forEach(function (b) {
        if (b.r) b.r.forEach(function (r) { if (r.t && r.z) counts[r.z] = (counts[r.z] || 0) + r.t.length; });
        if (b.tbl) b.tbl.forEach(function (row) { row.forEach(function (cell) { walk(cell.b); }); });
      });
    })(blocks);
    var best = 24, n = -1;
    Object.keys(counts).forEach(function (z) { if (counts[z] > n) { n = counts[z]; best = +z; } });
    return best;
  }

  function renderRuns(runs, ctx) {
    var html = '';
    runs.forEach(function (r) {
      if (r.img) {
        ctx.images.push(r);
        var idx = ctx.images.length - 1;
        var w = r.w > 0 ? r.w : 300;
        html += '<img class="dimg" loading="lazy" tabindex="0" src="' + esc(r.img) + '" data-img="' + idx + '" alt="' + esc(cleanAlt(r.alt)) + '" style="width:' + w + 'px">';
        return;
      }
      var t = r.t;
      var inner = r.h ? esc(t) : linkCodes(t, ctx.opts);
      if (r.f & 1) inner = '<b>' + inner + '</b>';
      if (r.f & 2) inner = '<i>' + inner + '</i>';
      if (r.f & 4) inner = '<u>' + inner + '</u>';
      if (r.f & 32) inner = '<s>' + inner + '</s>';
      if (r.f & 8) inner = '<sup>' + inner + '</sup>';
      if (r.f & 16) inner = '<sub>' + inner + '</sub>';
      if (r.z && ctx.base && r.z !== ctx.base) {
        var em = Math.max(.8, Math.min(1.9, r.z / ctx.base));
        if (Math.abs(em - 1) > .04) inner = '<span style="font-size:' + em.toFixed(2) + 'em">' + inner + '</span>';
      }
      if (r.h) {
        var href = r.h;
        if (/^(https?:|mailto:|file:)/i.test(href)) inner = '<a href="' + esc(href) + '" target="_blank" rel="noopener noreferrer">' + inner + '</a>';
      }
      html += inner;
    });
    return html;
  }

  function renderBlocks(blocks, ctx) {
    var html = '', empties = 0;
    blocks.forEach(function (b) {
      if (b.tbl) {
        empties = 0;
        html += '<table class="dtbl"><tbody>';
        b.tbl.forEach(function (row) {
          html += '<tr>';
          row.forEach(function (cell) {
            if (cell.vm === 'continue') { html += '<td></td>'; return; }
            html += '<td' + (cell.cs > 1 ? ' colspan="' + cell.cs + '"' : '') + '>' + renderBlocks(cell.b, ctx) + '</td>';
          });
          html += '</tr>';
        });
        html += '</tbody></table>';
        return;
      }
      var runs = b.r || [];
      var text = runs.map(function (r) { return r.t || ''; }).join('');
      var hasImg = runs.some(function (r) { return r.img; });
      if (!hasImg && !text.trim()) {
        empties++;
        if (empties <= 1) html += '<p class="dp empty"></p>';
        return;
      }
      empties = 0;
      var cls = 'dp' + (b.a ? ' ' + b.a : '');
      var style = '';
      if (b.ind) {
        var left = Math.max(0, Math.min(200, b.ind[0] || 0)), first = Math.max(-100, Math.min(120, b.ind[1] || 0));
        if (b.li) { style += 'padding-left:' + Math.max(0, left - 18) + 'px;'; }
        else {
          if (left) style += 'padding-left:' + left + 'px;';
          if (first) style += 'text-indent:' + first + 'px;';
        }
      }
      var body = renderRuns(runs, ctx);
      if (b.li) {
        var marker = listMarker(b.li, ctx.counters);
        if (!b.ind) style += 'padding-left:' + (b.li.l * 24 + 6) + 'px;';
        html += '<p class="' + cls + ' li" style="' + style + '"><span class="lm">' + esc(marker) + '</span><span class="lt">' + body + '</span></p>';
      } else {
        html += '<p class="' + cls + '"' + (style ? ' style="' + style + '"' : '') + '>' + body + '</p>';
      }
    });
    return html;
  }

  /* Public: render a whole document. Returns { html, images } */
  function renderDoc(doc, opts) {
    var ctx = { images: [], counters: {}, base: baseSize(doc.b || []), opts: opts || {} };
    var html = renderBlocks(doc.b || [], ctx);
    if (opts && opts.highlight) html = highlight(html, opts.highlight);
    return { html: html, images: ctx.images };
  }

  /* Plain text lines of a document (paragraph per line; tables as tab-separated rows). */
  function docLines(doc) {
    var lines = [];
    (function walk(blocks) {
      blocks.forEach(function (b) {
        if (b.tbl) {
          b.tbl.forEach(function (row) {
            lines.push({ text: row.map(function (cell) { return cellText(cell.b); }).join('\t'), table: true, images: 0 });
          });
          return;
        }
        var runs = b.r || [];
        var text = '', imgs = [];
        runs.forEach(function (r) {
          if (r.img) { imgs.push(r); text += ' '; } else text += r.t;
        });
        lines.push({ text: text, block: b, images: imgs.length, imgs: imgs, center: b.a === 'c', list: !!b.li });
      });
    })(doc.b || []);
    return lines;
  }
  function cellText(blocks) {
    return blocks.map(function (b) { return (b.r || []).map(function (r) { return r.t || ''; }).join(''); }).join(' ').trim();
  }

  window.Render = { esc: esc, linkCodes: linkCodes, renderDoc: renderDoc, docLines: docLines, cleanAlt: cleanAlt, highlight: highlight };
})();
