/* Family Tree Viewer — built-in defaults for the family settings.

   The family's own values live in family-settings.js, next to index.html (see
   family-settings.example.js for a documented example). That file belongs to the family: it is
   never part of a program update and an update never replaces it. You normally never need to
   change THIS file.

   index.html loads, in this order:
     family-settings.js   defines window.FAMILY_SETTINGS (if the file is missing, its onerror sets
                          window.FAMILY_SETTINGS_MISSING = true)
     app/config.js        this file: builds window.FAMILY_CONFIG from the defaults below + FAMILY_SETTINGS
     app/version.js, data/data.js, app/genealogy.js, app/render.js, app/app.js
   genealogy.js and app.js only ever read window.FAMILY_CONFIG.

   How the settings are merged with the defaults:
     * A top-level value given in FAMILY_SETTINGS replaces the default of the same name as a whole.
       lines, spaces, roots, people, documentPeople and ignoreDocuments are NOT mixed with anything
       (their defaults are empty), so their order is exactly the order written in the settings.
     * report is merged one level deep and report.formFields one level deeper, so a settings file
       may leave out any of their entries.
     * Unknown top-level values are copied as they are.
     * FAMILY_CONFIG.settingsProblem tells the page whether the settings can be used:
         ''           fine
         'missing'    family-settings.js was not found
         'broken'     the file is there but did not define FAMILY_SETTINGS (e.g. a typing mistake)
         'incomplete' it defines no roots, no lines or no spaces
       When it is not '', the page shows a card explaining what to do instead of the tree.

   Numbering (Ahnentafel, counted per generation):
     A code like A3,2 means line A, generation 3, number 2.
     The father of (g, n) is (g+1, 2n-1) and the mother is (g+1, 2n).
*/
(function () {
  'use strict';

  var DEFAULTS = {
    title: 'Family Tree',
    subtitle: '',

    // The letter at the start of each code: { A: { name, root, side }, ... } (see the example file).
    lines: {},
    // How each set of letters is counted: [{ letters: ['A'], width: 'single', child: '<root key>' }, ...]
    spaces: [],
    // The people at the bottom of the trees (they have no code of their own).
    roots: [],
    // People who have no document yet and are not named in any other document: { 'A1,1': { name, years } }
    people: {},
    // Documents whose file name has no code but which describe one person: { 'file name': 'A1,1' or a root key }
    documentPeople: {},
    // Documents that are not about any one person (file names without ".docx").
    ignoreDocuments: [],

    // Shown on the Help page: the folders inside the documents folder, e.g. 'Ashworth, Brennan'. '' = not shown.
    helpFolders: '',
    // Shown on the Help page as the example of a life history; null = a made-up example.
    // { code, name, fileName, years, father, story } (see family-settings.example.js)
    helpExample: null,

    // "Report a problem" (Help page) and automatic problem reports (tools\Update-Program.ps1).
    //   email   ''  hides the Report-a-problem button
    //   formUrl ''  means no automatic reports
    report: {
      email: '',
      formUrl: '',
      formFields: { version: '', when: '', what: '', details: '' }
    }
  };

  function isObject(v) { return !!v && typeof v === 'object' && !(v instanceof Array); }
  function mergeShallow(base, over) {
    var out = {}, k;
    for (k in base) if (Object.prototype.hasOwnProperty.call(base, k)) out[k] = base[k];
    if (isObject(over)) for (k in over) if (Object.prototype.hasOwnProperty.call(over, k) && over[k] !== undefined) out[k] = over[k];
    return out;
  }

  var S = window.FAMILY_SETTINGS;
  var problem = '';
  if (!isObject(S)) {
    problem = window.FAMILY_SETTINGS_MISSING ? 'missing' : 'broken';
    S = {};
  }

  var cfg = mergeShallow(DEFAULTS, S);
  var report = mergeShallow(DEFAULTS.report, S.report);
  report.formFields = mergeShallow(DEFAULTS.report.formFields, isObject(S.report) ? S.report.formFields : null);
  cfg.report = report;

  if (!problem && (!(cfg.roots instanceof Array) || !cfg.roots.length || !isObject(cfg.lines) || !Object.keys(cfg.lines).length ||
      !(cfg.spaces instanceof Array) || !cfg.spaces.length)) {
    problem = 'incomplete';
  }
  if (problem) {
    // keep the rest of the program loadable: it shows the settings card instead of the tree
    if (!isObject(cfg.lines)) cfg.lines = {};
    if (!(cfg.spaces instanceof Array)) cfg.spaces = [];
    if (!(cfg.roots instanceof Array)) cfg.roots = [];
  }
  cfg.settingsProblem = problem;

  window.FAMILY_CONFIG = cfg;
})();
