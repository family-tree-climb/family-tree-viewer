# Family Tree Viewer: guide for maintainers and Claude

This is an offline family-tree website generated from a folder of life-history Word documents, one
document per ancestor. It runs from `file://` on one family's Windows PC. The program is public. The
family's documents, settings, generated data and private notes stay on that PC and are never in this
repository. `README.md` gives the overview. `README.txt` is the plain-English guide for the family.

## Rules that are never broken

1. **The documents are irreplaceable and are only read.**
   - The document updater opens every `.docx` read-only. It uses `FileShare.ReadWrite|Delete`, so Word
     can keep the document open.
   - Nothing in the program creates, changes, renames, moves or deletes anything in the documents
     folder outside the viewer's own folder.
   - Tests never use real documents. They generate made-up ones under `%TEMP%` / `%RUNNER_TEMP%`.
2. **The document updater** (`tools/Update-FamilyTree.ps1`) writes only inside `data\`. Every write and
   delete goes through `Assert-InsideDataFolder`:
   - a full-path prefix check;
   - refusal of junctions and links (`SAFETY STOP`).

   It deletes only its own generated names (`d<12 hex>.json|.key`,
   `media\d<12 hex>[.new|.old]\<n>.<img>`). It writes through a fresh temp file plus `File.Replace`.
3. **The program updater** (`tools/Update-Program.ps1`) writes only the following:
   - the files named in the installed or the new `tools/program-files.txt`;
   - `updates\` and `program-previous\`;
   - the `programMessage` field of `data\status.js`.

   One guard checks every write: a full path inside the viewer, an allow-listed target, and no junctions
   or links. There is one exception, on the first install over a program from before 1.0: it may
   CREATE `family-settings.js` from `-SettingsFrom`. It never replaces an existing one. It never touches
   `data\` (apart from `status.js`), `dev\`, `family-settings.js` or `tools\settings.txt`.
4. **Nothing private in this repository.** That means:
   - no real family names, places, dates, e-mail addresses, user names or paths of the family's PC;
   - no prose about the real family.

   Examples and test families are invented. Before adding a name to code comments, tests or docs,
   make sure it does not occur in the real tree; you can check that only on the family PC (see below).
   `.gitignore` keeps `data/`, `dev/`, `family-settings.js` (and any copy or backup of it), `updates/`,
   `program-previous/`, `tools/settings.txt`, `HANDOFF.md` and `*.docx` out of git.
   - **The git history is public too, for good.** Every commit's author and committer name and e-mail,
     and the account that opens a pull request or presses Release, are visible to anyone. In every clone,
     before the first commit, set `git config user.name` to a neutral maintainer name and
     `git config user.email` to the GitHub `noreply` address; keep GitHub's "Keep my email addresses
     private" and "Block command line pushes that expose my email" on. Before every push, check
     `git log --format='%an <%ae> | %cn <%ce>'`.
   - **Publish only through git.** GitHub's web "Upload files", dragging a folder onto the page, or zipping
     a working folder ignore `.gitignore` and would publish the family's settings and private notes.
     Keep private files (the real `family-settings.js`, handoff notes) outside the folder you push from,
     or push from a clean clone into which only the public files are copied.
5. **The family must never be stuck.** The icon always opens the tree. If the updater cannot even
   start, `Open Family Tree.cmd` runs the document update directly. A bad release rolls itself back.

## Layout

```
index.html                     loads, in this order: family-settings.js, app/config.js, app/version.js,
                               data/data.js, app/genealogy.js, app/render.js, app/app.js
Open Family Tree.cmd           desktop icon: runs a %TEMP% copy of tools\Update-Program.ps1 -Open
                               (falls back to tools\Update-FamilyTree.ps1 -Open -Quiet)
Go back to the previous version.cmd   manual rollback (Update-Program.ps1 -Rollback), visible window
family-settings.example.js     a made-up family; documents every settings entry
app/version.js                 window.FAMILY_VERSION = 'x.y.z';  the only place the version is kept
app/config.js                  generic defaults, merged with window.FAMILY_SETTINGS -> window.FAMILY_CONFIG
app/genealogy.js               all genealogy rules (see below)
app/render.js                  shows a document as written; person codes in the text become links
app/app.js                     hash-routed pages: home, tree, p/<code>, doc/<id>, people, stories,
                               search, notes, help (with "Report a problem"); polls data/status.js
app/style.css
tools/Update-FamilyTree.ps1    .docx -> data\data.js (window.FAMILY_DATA) + data\status.js (window.FAMILY_STATUS)
tools/Update-Program.ps1       the program updater (check, download, validate, install, verify, roll back)
tools/Check-Tree.ps1 + check-tree.html   headless health summary: one JSON line
tools/Build-Release.ps1        zip + .sha256 of exactly the allow-list
tools/program-files.txt        THE allow-list of program files (it lists itself)
tools/Install-FamilyTree.ps1   creates the desktop icon;  tools/family-tree.ico
tests/                         see "Tests" below. Only tests/Compare-Trees.ps1, compare-trees.html and
                               compare-trees.js ship in releases (for real-data checks on the family PC).
.github/workflows/ci.yml       tests on every push and pull request (windows-latest)
.github/workflows/release.yml  the Release button (workflow_dispatch)
```

Local only, on the family PC (gitignored, never in a release, never replaced by an update):

- `data/`
- `dev/` (including `dev/private/`)
- `family-settings.js`
- `updates/`
- `program-previous/`
- `tools/settings.txt` (`SourceFolder = <folder>` when the documents are not in the folder above the viewer)

**A new program file must be added to `tools/program-files.txt`.** Otherwise it is not released, and the
tests' build stage (which copies exactly the listed files) fails or misses it. Never list anything that
belongs to the family; the installer refuses such a release. Names with `~` are refused (an 8.3 short
name could stand for another file). Be careful with a name that may already exist on the family PC as a
private, non-program file (for example `CLAUDE.md` or `HANDOFF.md` in an old installation): the installer
keeps a copy of such a file in `updates\kept\<date>\` and then replaces it, so move the private file away
first.

## How documents become a tree

- **Reading (`Update-FamilyTree.ps1`, Windows PowerShell 5.1).**
  - It is incremental: the cache key is the builder version, size, mtime and path of each document
    (`data\cache\<id>.json/.key`). A normal run takes a few seconds; a full re-read takes about 3 minutes
    on a slow 2-core PC. `-Full` re-reads everything.
  - It converts each docx into JSON blocks:
    - paragraph runs with b/i/u/sup/sub/strike/size;
    - hyperlinks, including HYPERLINK fields;
    - lists via numbering.xml;
    - tables;
    - images, with Word's srcRect crop applied and EMF converted to PNG.
  - It leaves `data.js` untouched when nothing changed (`build-state.txt` signature). Picture URLs carry
    `?v=<mtime ticks>`. `-Open` opens the browser before waiting for the lock.
  - The folder walk uses `\\?\` paths, never follows links and skips any copy of the viewer.
  - It holds the lock `Local\FamilyTreeViewerUpdate` while it runs.
- **Photos (`<documents>\Photos\`, since 1.1.0).**
  - `Update-FamilyTree.ps1` reads every `.jpg/.jpeg/.png/.gif/.bmp/.webp` under `Photos\` (read-only, never
    creates the folder) and writes `data\media\photos\p<12 hex>.jpg|.png` (upright by the EXIF rotation
    flag, at most 1200 px; WebP copied as it is) plus `p<12 hex>.key`. It deletes only names matching
    `$GenPhotoName`. These pictures are left out of `data.other`.
  - `data.js` gets `photosFolder: { path, exists }` and `photos: [{ path, mtime, img, w, h } | { path, mtime, err }]`.
    Their outcome is part of the build signature. `$PhotoVersion` plays the role of `$BuilderVersion` for photos.
  - `genealogy.js` (`matchPhotos`) gives a photo to the person whose code starts the file name (a root by its
    key, e.g. `tom.jpg`), through aliases. The name that is only the code wins, otherwise the newest. It
    sets `p.photo`, `p.photoFile` and keeps the document's picture in `p.docPhoto`. Unused photos go to
    `notes.photos` (`no number`, `nobody`, `unreadable`, `another`).
  - The person page's "Add a photo" / "Change photo" button (`photobtn`, box `photohelp`) explains the steps.
- **`$BuilderVersion`** (in Update-FamilyTree.ps1) is the data-format version, currently 4. Raise it only
  when the JSON a document turns into changes. Every document is then re-read once.
- **`app/genealogy.js`** (runs in the browser) holds all the genealogy rules:
  - It parses the title, the code and the years, and the header fields (Father, Mother, Descendant,
    Birth, Death, Marriage, Children, Siblings, ...).
  - When the file name and the first line disagree, it chooses the code by relationship consistency,
    then by folder letter.
  - Duplicates: the full version whose file name carries the number wins, otherwise the newest.
  - It creates placeholders from Father:/Mother: lines, plus backlinks and research notes.
  - Name evidence is ranked: a line giving exactly that number (6) beats a line with no number (5),
    which beats a number pointing elsewhere (2); a document title beats all.
  - "Mother: ?" blocks a slot from being filled by marriage lines.
  - Pedigree collapse is handled with `aliases` (slot -> the same person's main code, `Genealogy.resolve`).
  - Codes found only in running text never create people; they only link existing ones.
- **Numbering.** A code is LETTER + generation + "," + position (Ahnentafel per generation). The father
  of `(g, n)` is `(g+1, 2n-1)` and the mother is `(g+1, 2n)`. In `spaces`:
  - A `single` space is one letter; generation g has 2^(g-1) places, so generation 1 is one parent of the
    root.
  - A `double` space is two letters sharing one count; generation g has 2^g places, the first half
    using the first letter and the second half the second letter.

## Settings (`family-settings.js`)

- The page defines `window.FAMILY_SETTINGS`. `app/config.js` merges it shallowly over generic defaults
  into `window.FAMILY_CONFIG`:
  - a top-level key replaces its default as a whole;
  - `report` is merged one level deep, and `report.formFields` one level deeper;
  - unknown keys are copied as they are.
- `genealogy.js` and `app.js` read only `FAMILY_CONFIG`.
- The entries are:
  - `title`, `subtitle`, `lines`, `spaces`, `roots`, `people`, `documentPeople`, `ignoreDocuments`;
  - optional `helpFolders` and `helpExample` (Help page);
  - `report: { email, formUrl, formFields: { version, when, what, details } }`.
- `FAMILY_CONFIG.settingsProblem` is `''`, `'missing'`, `'broken'` or `'incomplete'`. When it is not empty,
  the page shows a friendly card instead of a blank page.
- **Keep every `report` value on one line in single quotes**, for example `    formUrl: '...',`.
  `Update-Program.ps1` reads them with `^\s*<key>\s*:\s*'([^']*)'` after the `report:` line. `formUrl`
  must be https (http only for localhost). An empty `email` hides the Report button; an empty `formUrl`
  means no automatic reports.
- `family-settings.example.js` must keep the exact line `    email: '',`, because the tests replace it
  with a made-up address.

## Versions, status and the open page

- `app/version.js` is the only source of the version. Releases need a plain `x.y.z`; the updater compares
  versions numerically. Use a patch version for fixes and a minor version for features.
- `Update-FamilyTree.ps1` reads the version with `FAMILY_VERSION\s*=\s*['"]([0-9A-Za-z.+-]{1,40})['"]` and
  writes `data\status.js`:
  `window.FAMILY_STATUS = {"state":..,"time":..,"done":..,"total":..,"version":"x.y.z",...};`
  - `state` is running, done or error.
  - The file is rewritten whole on every run.
  - The program updater adds `"programMessage"` afterwards, keeping the other fields.
- The open page polls `status.js`. When `status.version` differs from its own `FAMILY_VERSION`, it
  reloads once per version (sessionStorage key `ft.reloadedForVersion`). It shows `programMessage` once
  in the status bar.
- The Help page shows "Program version x.y.z" and the "Report a problem" card. The card has a mailto
  link of at most 1800 characters and a "Copy the report" button, and it is hidden when
  `report.email` is empty. The Notes page has a small report link.

## The program updater (`tools/Update-Program.ps1`)

**What the icon runs.** The steps are:

1. Open `index.html` first, then run the document update in the same PowerShell
   (`Update-FamilyTree.ps1 -Quiet`). If the document lock is busy, it does not wait.
   - A failed document update sends an automatic report, at most once a day per kind.
2. At most once a day (`updates\state.txt`), ask
   `https://api.github.com/repos/family-tree-climb/family-tree-viewer/releases/latest`.
   - The repo slug `$RepoSlug` is kept only at the top of the script.
   - TLS 1.2 is forced, with a 5 s time-out.
   - When offline or on any HTTP error, it logs one line and exits 0.
3. If the release is newer and not marked bad:
   1. Download `family-tree-viewer-<ver>.zip` + `.sha256` into `updates\<ver>\` and verify the hash.
   2. Validate the zip before unpacking. It is refused for:
      - a path not in its own allow-list;
      - an absolute path, `..`, `:` or a backslash;
      - anything under `data/`, `dev/`, `updates/`, `program-previous/` or `.git`;
      - `family-settings.js` or `tools/settings.txt`;
      - reserved names, trailing dots, case duplicates, or a `~` (an 8.3 short name);
      - a missing required file (index.html, both .cmd files, app/version.js, app/config.js,
        tools/Update-FamilyTree.ps1, Update-Program.ps1, program-files.txt, Check-Tree.ps1,
        check-tree.html);
      - an `app/version.js` that does not match the tag.
4. Measure the tree (`Check-Tree.ps1`). Then, under the document lock, save the current program into
   `updates\<ver>\previous\` and swap the files. Only files in the old list but not in the new one are
   removed.
5. Verify. The new version is rolled back if any of these happen:
   - the new document update fails;
   - `data.js` cannot be parsed;
   - the new `Update-Program.ps1 -SelfTest` fails;
   - Check-Tree reports a build error;
   - attached documents drop by more than max(3, 2%);
   - known people drop by more than 2%;
   - a root person goes missing.

   On a rollback, a report is sent and a `programMessage` is written. Then the old version is checked the
   same way (document update, `data.js`, Check-Tree):
   - if it works, the new version is marked bad and never retried;
   - if it has problems too, the computer may be at fault (documents folder missing, a health-check
     hiccup), so the new version is retried on another day and only counts as bad after failing on 3
     different days (`failedDays.<ver>` in `updates\state.txt`).

   While the icon's document update fails, no new version is tried (for at most 3 days, so a version
   that fixes the document update can still arrive).
   On success, the saved copy becomes `program-previous\` (the old one is moved aside first and put back
   if that fails).
   - **The health check is the INSTALLED version's `check-tree.html`** (copied to `updates\checker`), so
     before and after are measured the same way. It loads every script the installation's own
     `index.html` loads before `app/app.js`, so a new model file is picked up. Keep model scripts before
     `app/app.js`, and keep what the page uses: `FAMILY_CONFIG.roots`, `window.Render` and
     `Genealogy.build(data)` returning `{ people, docs }`. If the installed page reports a build error but
     the new version brings a different check page, that page is asked as a second opinion.
6. Recovery. An install interrupted by a power cut is undone at the next start. Every file is written
   through a temporary file that is flushed to disk first. A file that already holds the saved content is
   left alone, and a damaged saved copy may be replaced by an identical file in `program-previous\`; if
   some files still cannot be put back, the latest release is installed completely (`reinstall` in the
   state file). A version interrupted 3 times counts as bad; a swap that failed (a file held open) does
   not count as an interruption.

- **Logs:** `updates\program-update-log.txt` (last 500 lines). Stdout ends with `RESULT: <word>`.
- **Exit codes:**
  - 0: done, up to date, offline, or rolled back on request;
  - 1: refused, rolled back, failed, or error;
  - 2: cannot run.
- **Other switches:** `-CheckNow`, `-Rollback`, `-InstallZip <zip>` (needs the .sha256 next to it; add
  `-Force` for an older or the same version), `-SettingsFrom <file>` (first install over a pre-1.0
  program), `-ValidateZip <zip>` (changes nothing), `-SelfTest`, `-Chrome <exe>|none`, `-Quiet`.
  Test hooks: `-ReleaseUrl <url or file>`, `-NoDocumentUpdate`, `-PauseInSwapSec`.
- **Locks:**
  - document update: `Local\FamilyTreeViewerUpdate`;
  - program update: `Local\FamilyTreeViewerProgramUpdate-<16 hex of SHA-1 of the lower-case viewer path>`.
- **Automatic reports** go to the Google Form in `report.formUrl` as a POST with 4 fields: the
  version, the local ISO time, the kind, and details of at most 1500 characters of error lines (never
  document text; folders become `<folder>` or `<viewer folder>\...`, and a document's file name becomes
  its number, e.g. `document C4,1`). The kinds are `document-update-failed`, `program-update-refused`,
  `program-update-failed`, `program-update-rolled-back` and `rollback-failed`. At most one report is
  sent per kind per day.
- **A running script must not replace itself.** That is why the `.cmd` files run a `%TEMP%` copy. Do the
  same when you run it by hand on an installation.

## Release routine (works from a phone)

1. Open a Claude Code session on `family-tree-climb/family-tree-viewer` (claude.ai/code or the Claude
   app) and describe the change.
   - Claude works on a branch and opens a pull request.
   - Cloud sessions run on Linux without Windows PowerShell 5.1, so the real test run is CI.
2. CI (`ci.yml`, windows-latest) runs `tests\Run-Tests.ps1` on the pull request.
   - If it is red, read the failing step's log; the test folder is uploaded as an artifact for 14 days.
   - Fix it and push again until it is green.
3. If the change touches `genealogy.js`, `render.js` or `Update-FamilyTree.ps1`, think about the real
   data. The tests cover only the made-up family. A real-data check on the family PC (below) is the only
   proof that the tree is unchanged or changed only as intended.
4. Merge the pull request.
5. Raise the version in `app/version.js` (in the pull request or as its own commit on the default
   branch).
6. Press **Release**: Actions -> Release -> Run workflow on the default branch (this also works in the
   GitHub mobile app). The workflow:
   1. refuses a version that already exists;
   2. runs all tests again;
   3. builds and checks the zip;
   4. publishes `v<version>`.
7. The family PC installs the release the next time the Family Tree icon is clicked (the updater looks
   at most once a day).
   - The family sees the new version at the bottom of the Help page.
   - A rollback arrives as an automatic report (if a form is set up) and appears in
     `updates\program-update-log.txt`.

Release only when someone can read a problem report within a day or two. Rollback is automatic, but a
human should still look at what went wrong.

## What can only be checked on the family PC

- **Real-data checks.** Real documents never leave the family PC, so whether a change keeps the real
  tree identical can only be proved there. Releases ship `tests/Compare-Trees.ps1` for this:
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Compare-Trees.ps1 -Data <viewer>\data\data.js `
      -BaseDir <viewer> -NewDir <candidate program folder> -NewSettings <viewer>\family-settings.js
  ```
  - Unpack the candidate (e.g. the branch or release zip) into a folder under `%TEMP%`, never inside the
    documents folder.
  - Exit codes: 0 = identical, 1 = different (report.txt lists the items), 2 = could not run.
  - Output goes to `-Out` (default `%TEMP%\FamilyTree-CompareTrees-<stamp>`).
  - For a pre-1.0 program use `-BaseSettings none`.
  - Negative controls are cheap: change one name in a copy of the settings and the tool must report a
    difference.
- **Private material.** `dev/private/` on the family PC holds private reference material:
  - an independent ground-truth reading of the real documents;
  - the parser spec;
  - review findings;
  - the robustness report;
  - the private handoff notes.

  It is gitignored and must never be copied into this repository or a public issue.
- **The real feel.** Check how fast the icon opens the tree, the browser focus, and how the family
  member uses Word. Nobody may open windows on that PC while the family member may be using it. Use
  headless Chrome only (`--headless=new` with a throwaway `--user-data-dir`), and never automate Word.

## Tests

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 [-Out <folder>] [-Only <stages>] [-UpdateSnapshot] [-Chrome <exe>]
```

- **Exit codes:** 0 = all passed, 1 = something failed.
- **`-Out`** defaults to `%TEMP%\FamilyTree-Tests-...`. It must be outside the repository and must be new,
  empty, or made by an earlier run.
- **Stages:**

  | Stage | What it checks |
  |---|---|
  | parse | Every .ps1/.psm1 parses; non-ASCII files need a UTF-8 BOM. |
  | build | The made-up family is generated by `tests/New-TestFamily.ps1` + `tests/TestDocx.psm1`. A test viewer is made from exactly the allow-list, with the example settings, and its updater is run. |
  | snapshot | The model must equal `tests/expected/snapshot.json`. |
  | checks | Named expectations. |
  | media | Pictures. |
  | pages | Every route in headless Chrome; any script error fails. |
  | settings | The settings file is missing or broken. |
  | reload | The version reload. |
  | compare | `tests/Compare-Trees.ps1` on the test data. |
  | e2e | The document updater on changing documents, including a junction safety stop. |
  | updater | Every `tests/updater/Test-*.ps1`, each in its own PowerShell, with `FAMILYTREE_TEST_OUT`, `FAMILYTREE_TEST_REPO` and `FAMILYTREE_TEST_CHROME`. |

- **After an intended change to reading or genealogy:**
  1. Run with `-UpdateSnapshot`.
  2. Read the diff of `tests/expected/snapshot.json` line by line.
  3. Adjust the counts and checks in `Run-Tests.ps1`.
- **Test names stay invented.** The test family (Ashworth / Brennan / Carrow / Dalby, roots tom and ruth)
  is fictional. Never add a real person, place or document text.
- **The page tests rely on element ids in app.js:** main, statusbar, lightbox, searchform, searchinput,
  psort, pline, pq, pdocs, pletters, plist, program-version, reportbtn, copyreport, reporttext,
  notes-report, settings-problem, photobtn and photohelp. Renaming them breaks the tests.
- **Other tools:**
  - `tools\Check-Tree.ps1 [-Viewer <folder>]` prints `{version, built, docs, personDocs, peopleKnown,
    people, roots, errors, settingsProblem, buildError, loadErrors}`. Exit codes: 0 healthy, 1 build
    error or no answer, 3 skipped (no Chrome).
  - `tools\Build-Release.ps1 -Version <x.y.z> -OutDir <dir>` builds the release files.
  - `tools\Update-Program.ps1 -ValidateZip <zip>` checks a zip.
  - `tests\Serve-Viewer.ps1 [-Root <viewer>] [-Port 8765]` is a read-only loopback web server, for
    browsers that cannot load `file://` pages with scripts.

## Windows PowerShell 5.1 traps (all hit in this project)

- Only Windows PowerShell 5.1: no `&&`, `||`, `?:`, `??` or `?.`. There is no Python or Node on the
  family PC.
- **Variable names are case-insensitive:** `$r` and `$R` are the same variable.
- **`$null` passed to a .NET `[string]` parameter becomes `""`.** Use `[NullString]::Value`, for example
  for `File.Replace`'s backup argument.
- **Curly quotes inside PowerShell strings act as quote characters.** Keep `.ps1` files ASCII (or save
  them with a UTF-8 BOM; the parse stage enforces this). Write JS that contains curly quotes with an
  editor, not through a PowerShell string.
- **The comma binds tighter than `+`.** `New-Object T('a' + $b, 'x')` passes ONE joined string. Build the
  string first, or use `[T]::new(...)`.
- **`Remove-Item` can be blocked or surprising** on some paths. Use explicit `[IO.File]::Delete` /
  `[IO.Directory]::Delete` inside your own folders, after a path check.
- **`2>&1` on a native exe** turns stderr lines into errors and sets `$?` to false. Read `$LASTEXITCODE`
  instead.
- **Force TLS 1.2** before any web call:
  `[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12`.
- **`ConvertFrom-Json` returns PSCustomObject**, and it fails on very large inputs. For big JSON use
  `System.Web.Script.Serialization.JavaScriptSerializer` with a raised `MaxJsonLength`.
- **Chrome's `--dump-dom` output uses CRLF.** Split on `\r?\n`. Chrome also fails with a profile folder in
  a very deep path; keep `--user-data-dir` short.
- **`.cmd` files must keep CR LF line endings** (`.gitattributes`). `Build-Release.ps1` refuses LF-only
  `.cmd` files.
- **`@($null).Count` is 1.** Filter `$null` out before counting.
