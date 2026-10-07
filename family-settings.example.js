/* Family Tree Viewer — EXAMPLE family settings (a made-up family).

   HOW TO USE
     Copy this file to "family-settings.js" in the same folder (next to index.html) and change the
     values to your own family. family-settings.js belongs to your computer: it is never part of a
     program update and an update never replaces it. If it is missing, the page says so.
     Built-in defaults for everything are in app/config.js.

   THE NUMBERING (Ahnentafel, counted per generation)
     Every person in a life-history document has a code such as A3,2: line letter A, generation 3,
     number 2. Generation 1 is the parents of a root person (see "roots" below).
     The father of (g, n) is (g+1, 2n-1) and the mother is (g+1, 2n).
     A document's file name starts with the code ("A3,2 Thornbury Lydia.docx") and its first line
     repeats it ("Lydia Ann Thornbury (A3,2)").

   THIS EXAMPLE
     Tom Ashworth and his wife Ruth are the two root persons.
       A = Ashworth, Tom's father's side   (a single line: A1,1 is Tom's father)
       B = Brennan,  Tom's mother's side   (a single line: B1,1 is Tom's mother)
       C and D share one count from Ruth  (a double space: generation g has 2^g places; the first
                                           half are C = Carrow, her father's side, the second half
                                           D = Dalby, her mother's side; so C1,1 is her father and
                                           D1,2 her mother)

   KEEP the "report" values each on one line, in single quotes, like   formUrl: '...',
   (no single quote inside a value): tools\Update-Program.ps1 reads them with a simple regular
   expression, one line at a time.
*/
window.FAMILY_SETTINGS = {
  // The name of the family tree (top of every page) and a line under it on the home page.
  title: 'Ashworth Family History',
  subtitle: 'Life histories collected by Tom Ashworth',

  // The letter at the start of each code, and what it stands for. The order here is the order
  // used in lists and menus.
  //   name  the line's surname (also used to recognise a folder named after it)
  //   root  the key of the root person this line belongs to (see "roots")
  //   side  how to describe the line in words
  lines: {
    A: { name: 'Ashworth', root: 'tom',  side: "Tom's father's side" },
    B: { name: 'Brennan',  root: 'tom',  side: "Tom's mother's side" },
    C: { name: 'Carrow',   root: 'ruth', side: "Ruth's father's side" },
    D: { name: 'Dalby',    root: 'ruth', side: "Ruth's mother's side" }
  },

  // How each set of letters is counted.
  //   width 'single'  one letter; generation g has 2^(g-1) places; generation 1 is ONE person
  //                   (whether that person is the father or the mother is given by the root below)
  //   width 'double'  two letters sharing one count; generation g has 2^g places; the first half
  //                   use the first letter, the second half the second letter
  //   child           the root person at the bottom of this count
  spaces: [
    { letters: ['A'], width: 'single', child: 'tom' },
    { letters: ['B'], width: 'single', child: 'tom' },
    { letters: ['C', 'D'], width: 'double', child: 'ruth' }
  ],

  // The people at the bottom of the trees (they have no code of their own).
  //   key     a short word used in addresses and in "documentPeople" (lower case, no spaces)
  //   name    full name;  short: the name used in "Tom's tree";  sex: 'm' or 'f';  years: '1950–'
  //   father / mother   the codes of their parents;  spouse: the key of the other root person
  roots: [
    { key: 'tom', name: 'Thomas R. Ashworth', short: 'Tom', sex: 'm', years: '1950–',
      father: 'A1,1', mother: 'B1,1', spouse: 'ruth' },
    { key: 'ruth', name: 'Ruth Carrow Ashworth', short: 'Ruth', sex: 'f', years: '1952–',
      father: 'C1,1', mother: 'D1,2', spouse: 'tom' }
  ],

  // People who have no document yet and are not named in any other document's Father:/Mother:
  // lines. (A document of their own, once written, takes over automatically.)
  people: {
    'C1,1': { name: 'Walter James Carrow', years: '1925–1990' },
    'D1,2': { name: 'Edna Mae Dalby', years: '' }
  },

  // Documents whose file name has no code but which describe one person.
  // (Left side: the file name without ".docx". Right side: the code, or a root person's key.)
  documentPeople: {
    'Ashworth Thomas': 'tom',
    'Brennan Margaret': 'B1,1'
  },

  // Documents that are not about any one person, e.g. the blank template (file names without ".docx").
  ignoreDocuments: ['template life history'],

  // Optional, shown on the Help page: the folders inside the documents folder.
  helpFolders: 'Ashworth, Brennan, Carrow, Dalby',

  // Optional, shown on the Help page as the example of how to write a life history.
  //   code      a person's number;  name: the name on the document's first line
  //   fileName  what follows the number in the file name (surname, then first name)
  //   years     the second line;  father: an example "Father:" line (without "Father:")
  //   story     the name of a document that is not about one person ('' = no example)
  helpExample: {
    code: 'C8,30',
    name: 'Rosalind Clementine Penrose',
    fileName: 'Penrose Rosalind',
    years: '1741-1799',
    father: 'Robert Penrose (C9,59)(1700-1770)',
    story: 'The Old Mill'
  },

  // Problem reports.
  //   email      where the "Report a problem" button on the Help page sends its email
  //              ('' hides the button)
  //   formUrl    a Google Form ".../formResponse" address that receives an automatic report when a
  //              program update or a document update fails ('' = no automatic reports)
  //   formFields the form's field names ("entry.123456") for the version, the time, the kind of
  //              problem and the details
  report: {
    email: '',
    formUrl: '',
    formFields: {
      version: 'entry.1',
      when: 'entry.2',
      what: 'entry.3',
      details: 'entry.4'
    }
  }
};
