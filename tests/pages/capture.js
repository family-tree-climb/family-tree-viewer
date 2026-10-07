/* Family Tree Viewer tests: records every script error of the page (used by tests/Run-Tests.ps1).
   Run-Tests makes a test copy of index.html that loads this file BEFORE the program's own scripts
   (and driver.js after them). Nothing here changes any file. */
(function () {
  'use strict';
  var T = window.__T = { errors: [], resources: [], loads: 0 };
  // how many times this tab has loaded the page (to see a reload happen exactly once)
  try {
    var n = +(sessionStorage.getItem('__t_loads') || 0) + 1;
    sessionStorage.setItem('__t_loads', String(n));
    T.loads = n;
  } catch (e) { T.loads = -1; }
  function short(src) { return String(src || '').replace(/^.*\//, ''); }
  window.onerror = function (msg, src, line, col, err) {
    T.errors.push('error: ' + msg + ' @ ' + short(src) + ':' + line + ':' + col + (err && err.stack ? ' | ' + String(err.stack).split('\n').slice(0, 4).join(' / ') : ''));
  };
  // a script, picture or style sheet that could not be loaded
  window.addEventListener('error', function (e) {
    var t = e.target;
    if (t && t !== window && t.tagName) T.resources.push(t.tagName + ' ' + (t.src || t.href || ''));
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    T.errors.push('unhandled promise rejection: ' + (e.reason && (e.reason.stack || e.reason.message) || e.reason));
  });
  var original = console.error;
  console.error = function () {
    T.errors.push('console.error: ' + Array.prototype.map.call(arguments, function (a) { return a && a.stack ? a.stack : String(a); }).join(' '));
    return original.apply(console, arguments);
  };
})();
