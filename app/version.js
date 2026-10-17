/* Family Tree Viewer: the program version. The line below is the single source of truth.
   tools\Update-FamilyTree.ps1 (and the program updater) read it with a regular expression, and the
   document update copies it into data\status.js as "version". Keep it as one line, in the same
   form, with a numeric major.minor.patch version in single quotes. */
window.FAMILY_VERSION = '1.1.0';
