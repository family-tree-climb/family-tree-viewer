FAMILY TREE VIEWER
==================

WHAT IT IS
  A family-tree website made from the life-history Word documents in the life-history folder
  (the folder that holds this "Family Tree Viewer" folder, and the folders inside it).
  The tree runs entirely on this computer. Your documents and the tree are never uploaded anywhere.

HOW TO OPEN IT
  Double-click the "Family Tree" icon on the desktop.
  (If the icon is ever missing, double-click "Open Family Tree.cmd" in this folder instead.)
  The tree opens in the web browser straight away. New and changed documents are read at the same
  time, and the page refreshes itself when that is done (usually a few seconds).

ADDING A PERSON, OR CHANGING A LIFE HISTORY
  The Help page of the tree (click "Help" at the top) shows the same steps with an example in your
  own family's letters, and lists the family folders.
  1. Write the life history in Word. Starting from the template document is easiest.
     For a NEW person, use File > Save As and type the new file name, so the template itself stays
     as it is. When you change an existing life history, just save it (Ctrl+S). Word can stay open.
     Save it in the life-history folder or one of its folders.
  2. Start the file name with the person's number, then surname and first name, for example:
         A5,12 Penrose Rosalind.docx
     The letter at the front is the family line; the Help page says which letter is which.
  3. In the document:
       first line   - the name and the same number in brackets:   Rosalind Ann Penrose (A5,12)
       second line  - the years:                                  1835-1903
       then, each on its own line:  Father: ...   Mother: ...   Descendant: ...   Birth: ...   Death: ...   Marriage: ...
       Put the number after a name when you know it:   Father: Robert Penrose (A6,23)(1800-1870)
       Write ? when a parent is not known:              Mother: ?
  4. Open the Family Tree icon. The person appears in the tree, joined to their parents and child.

IF SOMEONE DOES NOT SHOW UP
  - Is the document saved inside the life-history folder (or one of its folders)?
  - Do the number at the start of the file name and the number on the first line agree?
  - Does the number fit the generation? Each generation further back has twice as many places;
    the Help page explains the numbering.
  - The "Notes" page lists documents that could not be read and numbers that do not agree.
  - The icon only reads documents when it is opened - open it again.
  Pictures in the documents appear automatically. Documents that are not about one person are
  listed under "Stories".

A PHOTO IN A PERSON'S SQUARE
  Every person has a square next to their name. To put a photo in it:
  1. Open the person's page in the tree and click "Add a photo" (or "Change photo").
     The box that opens shows the exact name to give the photo, with buttons to copy it.
  2. Save the photo in the "Photos" folder of the life-history folder, named with the person's
     number, for example:   A5,12.jpg
     Words may follow the number:   A5,12 Rosalind at 20.jpg
     (The first time, make the folder: in the life-history folder, right-click an empty spot,
     New > Folder, and type Photos.)
  3. Open the Family Tree icon again. The photo appears in the square, in the tree and everywhere else.
  - JPEG and PNG pictures work. The program keeps its own smaller copy; your photo is never changed.
  - A photo in the Photos folder is used instead of a picture from the life history.
  - The "Notes" page lists photos it could not use (for example a number nobody has).

A FLAG FOR AN ANCESTOR WHO CAME FROM ANOTHER COUNTRY
  Write a line at the top of the life history (with Birth:, Death: and the others):
       Flag: Ireland
  Save it and open the Family Tree icon again. The flag appears in the corner of the person's
  square, and "Came from Ireland" on their page. Delete the line to take the flag away.
  The person's page has an "Add a flag" button with the same steps and the list of countries.
  The "Notes" page lists Flag: lines with a country the program has no flag for.

THE NUMBERING
  The father of (generation g, number n) is (g+1, 2n-1). The mother is (g+1, 2n).
  For example, the parents of A5,12 are A6,23 (father) and A6,24 (mother).

THE PROGRAM SOMETIMES UPDATES ITSELF
  Now and then a new version of this program comes out, to fix something or add something small.
  It installs itself when you open the Family Tree icon (it looks at most once a day, and only when
  the computer is on the internet). You don't need to do anything.
  - The page may reload itself once, a little while after it opened. That is all you will notice.
  - If a new version does not work properly on this computer, the program puts the previous
    version back by itself.
  - The version you have is shown at the bottom of the Help page ("Program version ...").

REPORT A PROBLEM
  If something in the tree looks wrong or does not work, open the Help page and click
  "Report a problem". An email opens with the program version and the details of the last update
  already filled in; just write what happened and send it.
  If no email window opens, click "Copy the report" and paste it into an email.
  (The button is only there when an address for reports has been set up.)
  When a program update or a document update fails, the program can also send a short automatic
  report by itself, if that has been set up: the program version, the time, the kind of problem and
  the error lines. Error lines never contain a document's text; folder names are left out and a
  document is named only by its number (for example "document A5,12").

GOING BACK TO THE PREVIOUS VERSION (only when you are asked to)
  If the person who looks after the program asks you to, double-click
  "Go back to the previous version.cmd" in this folder. A window shows what happens; press a key to
  close it when it says so. Then open the Family Tree icon as usual.
  Your documents and the family settings are not changed by this; the tree is simply read again from
  the documents by the previous version.

YOUR DOCUMENTS ARE SAFE
  This program only READS the Word documents and the photos. It never changes, renames, moves or
  deletes them.
  Everything it makes is kept inside this "Family Tree Viewer" folder.
  A program update only replaces the program's own files (the ones listed in tools\program-files.txt).
  It never touches your documents or the family settings (family-settings.js).

WHAT IS IN THIS FOLDER
  index.html                          the family tree (opens in the web browser)
  Open Family Tree.cmd                what the desktop icon runs: opens the tree, reads new documents,
                                      and installs a new program version when there is one
  Go back to the previous version.cmd only when you are asked to (see above)
  family-settings.js                  this family's settings: the title, the family lines and their
                                      letters, who is at the bottom of the trees, the report address.
                                      Program updates never change it.
  family-settings.example.js          a made-up example of that file, with explanations
  app\                                the program: the web page (app\version.js holds the version number)
  tools\                              the program: reading the documents, installing updates
                                      (tools\Install-FamilyTree.ps1 puts the desktop icon back)
  tests\                              tools for the people who look after the program
  data\                               made automatically from the documents (text, picture copies,
                                      update-log.txt)
  updates\                            made by program updates (program-update-log.txt says what happened;
                                      kept\ holds copies of any file of yours an update had to replace)
  program-previous\                   the previous version of the program, kept for going back

IF THE FOLDER IS EVER MOVED OR RENAMED
  Double-click "Open Family Tree.cmd" in this folder once - it always works from wherever the folder is.
  To put the desktop icon right again, right-click tools\Install-FamilyTree.ps1 and choose "Run with PowerShell".

FOR WHOEVER HELPS LOOK AFTER THIS
  - Needs only Windows PowerShell 5.1 (built into Windows) and a web browser. Nothing to install.
    Google Chrome, when present, is also used for a quick health check of the tree around a program update.
  - Please don't keep your own files inside "data", "updates" or "program-previous" - the program
    manages those folders.
  - data\update-log.txt says what happened at each document update (and any document that could not
    be read). updates\program-update-log.txt says what happened at each program update.
  - To re-read every document from scratch:  powershell -ExecutionPolicy Bypass -File tools\Update-FamilyTree.ps1 -Full
  - If the documents are not in the folder above this one, tools\settings.txt can name their folder
    with a line   SourceFolder = <folder>
  - The family's own values (line letters, the people at the bottom of the trees, names for people who
    have no document, documents without a number in their name) are in family-settings.js.
    family-settings.example.js explains every entry.
  - How documents become people (names, numbers, Father:/Mother: lines) is in app\genealogy.js.
  - The "Notes" page lists duplicate documents, numbers that disagree, and where each line ends.
  - The program's source, its tests and the notes for maintainers are published at
    https://github.com/family-tree-climb/family-tree-viewer
