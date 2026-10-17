# Family Tree Viewer

An offline family-tree website built from a folder of life-history Word documents.

A family historian writes one Word document per ancestor. The file name and the first line carry a
code such as `A5,12`, and header lines follow: `Father:`, `Mother:`, `Birth:`, `Death:`, `Marriage:` and
so on. The viewer reads those documents (read-only) and builds a browsable site:

- pedigree charts;
- a page per person, showing the life history as it was written, with its pictures, links, lists and tables;
- people, stories and search pages;
- a photo in each person's square, from a `Photos` folder next to the documents (file name = the person's
  code, e.g. `A5,12.jpg`; the person's page has an "Add a photo" button that says exactly what to do);
- a flag in the corner of the square for an ancestor who came from another country (from an
  `Arrived:` / `Immigration:` line, e.g. "1848, from Ireland", or a `Flag: Ireland` line);
- a "Research notes" page listing duplicates, numbers that disagree and where each line ends.

It runs entirely on the family's Windows PC from `file://`, with no server and nothing to install. It
needs only Windows PowerShell 5.1 and a web browser. The internet is used only to look for new program
versions and, if the family sets it up, to send a short report when an update fails. Documents and the
tree are never uploaded.

New versions of the program reach that PC as GitHub releases. The PC installs them by itself, checks the
result and rolls back automatically if anything looks wrong. It never needs a login, token or key.

## How it works

```
life-history folder\                      the family's Word documents (only ever read)
  Photos\                                 photos for the squares, named by code (only ever read)
  Family Tree Viewer\                     this program, plus the family's own local files
    Open Family Tree.cmd                  the desktop icon: opens the tree, reads the documents, installs updates
    index.html  app\                      the web page (genealogy.js = all genealogy rules)
    tools\Update-FamilyTree.ps1           .docx -> data\data.js + data\status.js (incremental)
    tools\Update-Program.ps1              program updater with automatic rollback
    family-settings.js                    the family's settings (local, never in the repository)
    data\  updates\  program-previous\    made on the PC (local, never in the repository)
```

- **Numbering.** Each person has a code: a line letter, a generation and a number, for example `A3,2`.
  The father of `(g, n)` is `(g+1, 2n-1)` and the mother is `(g+1, 2n)`. Several letters can share one
  count; see `family-settings.example.js`.
- **Reading.** `Update-FamilyTree.ps1` converts each changed `.docx` into JSON blocks. It skips documents
  it has already read, so a normal run takes a few seconds. It writes only inside `data\`.
- **Photos.** `Update-FamilyTree.ps1` also makes a smaller, upright copy of each picture in `Photos\` (in
  `data\media\photos\`, also incremental) and lists them in `data.js`. `genealogy.js` gives each photo to the
  person whose code starts its file name; it wins over a picture found in the person's document.
- **Building.** `app/genealogy.js` turns the documents into people, links, aliases and notes in the
  browser. `app/render.js` shows a document as it was written. `app/app.js` contains the pages.

## Setting it up for a family

1. Put the program folder (a release zip, unpacked) into the folder that holds the life-history
   documents, as `Family Tree Viewer\`. Alternatively, keep it elsewhere and name the documents folder
   in `tools\settings.txt` with a line `SourceFolder = <folder>`.
2. Copy `family-settings.example.js` to `family-settings.js` and describe your family:
   - the title;
   - the line letters and how they are counted;
   - the root people at the bottom of the trees;
   - names for people who have no document yet;
   - documents without a code in their file name;
   - optionally, the e-mail address for the "Report a problem" button and a Google Form for automatic
     failure reports.

   The example file documents every entry. Program updates never replace `family-settings.js`.
3. Run `tools\Install-FamilyTree.ps1` once ("Run with PowerShell") to create the desktop icon, then click
   the icon.

`README.txt` is the plain-English guide for the person who uses the tree.

## Releases and automatic updates

- `app/version.js` holds the version, and it is the only place the version is kept.
- `tools/program-files.txt` is the allow-list: exactly the files that make up the program.
- The **Release** workflow (`.github/workflows/release.yml`, started by hand with *Run workflow*) does
  the following:
  1. reads the version;
  2. refuses a version that has already been released;
  3. runs all tests;
  4. builds `family-tree-viewer-<version>.zip` and its `.sha256` with `tools/Build-Release.ps1`;
  5. publishes the release `v<version>`.
- When the desktop icon is clicked, `tools/Update-Program.ps1` checks the latest release at most once a
  day. If it finds a newer version, it:
  1. downloads the zip and checks its SHA-256;
  2. refuses any file that is not in the zip's own allow-list, and anything that belongs to the family
     (`data/`, `dev/`, `updates/`, `program-previous/`, `family-settings.js`, `tools/settings.txt`);
  3. measures the tree with `tools/Check-Tree.ps1`, then swaps the program files;
  4. re-reads the documents with the new version and measures again.

  The update is rolled back automatically if the document update fails, if `data.js` cannot be read,
  if the tree cannot be built, or if attached documents, known people or a root person go missing.
  A rolled-back version is never tried again when the previous version still works; when the previous
  version has problems on that computer too (so the computer may be at fault), it is retried on another
  day, at most on 3 days.
- `Go back to the previous version.cmd` restores the previous version by hand.

## Tests

All tests run the same way locally and in CI (`.github/workflows/ci.yml`, `windows-latest`). They need
Windows PowerShell 5.1 and Google Chrome (used headless):

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

- The tests build a made-up family of generated `.docx` files (`tests/New-TestFamily.ps1`) and read it
  with the real updater.
- They compare the resulting model with `tests/expected/snapshot.json`.
- They open every page of the viewer in headless Chrome and fail on any script error.
- They run the document updater end to end on changing documents, and run the program-updater tests in
  `tests/updater/`.
- Exit code 0 means everything passed. Use `-Only <stages>` to run part of the tests, and
  `-UpdateSnapshot` after an intended change to how documents are read.

`tests/Compare-Trees.ps1` checks two program versions against each other on the same `data.js`. It
reports whether they build an identical tree. Use it on real data before a release that touches
`genealogy.js`.

## Privacy

This repository holds only the program and a made-up example family. A family's documents, settings,
generated data and private notes stay on their own computer (see `.gitignore`). They are never part of
a release, and the updater refuses a release that contains them.

Maintainer notes are in [CLAUDE.md](CLAUDE.md).
