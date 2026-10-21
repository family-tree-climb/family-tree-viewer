<#
  New-TestFamily.ps1
  ------------------
  Makes a MADE-UP test family of life-history Word documents (.docx) for the automatic tests: the
  Ashworth family of family-settings.example.js (Tom Ashworth and his wife Ruth; lines A, B, C, D).
  Everyone in it is invented. Word is not needed (see TestDocx.psm1).

  Usage (Windows PowerShell 5.1):
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\New-TestFamily.ps1 -Path <new or empty folder>

  The folder must not exist yet, or be empty: nothing that is already there is ever replaced.
  Every file gets a fixed "last changed" time, so the documents (and what the viewer makes of them)
  are the same on every computer.

  What the documents cover (the parser features of app\genealogy.js and tools\Update-FamilyTree.ps1):
    * title line with the code, years on the second line (also after Shift+Enter, at the end of the
      title line, "abt.", "c.", spaced dashes, an open end "1950-")
    * Father:, Mother:, Descendant:, Birth:, Death:, Marriage:, Siblings:, Children: lines, with and
      without codes; "Mother: ?", "Father: unknown", "Mother: Not known" (the place stays empty and a
      marriage line cannot fill it); "Marriage: 1914 to ...", "Marriage: 5/20/1895 to ..."
    * codes written "A3, 1", "A3.3", "(C 4,5)", a file name "A5.1 ...", a code split over two runs
    * a file name whose number disagrees with the first line (the first line wins, noted)
    * a wrong number on a Descendant: line (noted)
    * an older, shorter copy of one person's document (a duplicate; the newer full one is shown)
    * pedigree collapse: the parents of D2,4 are C3,1 and C3,2 (Ruth's parents were cousins)
    * documents without a code: one named in the settings (documentPeople), one matched by name and
      years, two stories, and the template (ignoreDocuments)
    * a picture above the first line (the person's photo), the same picture again cropped (srcRect)
    * a w:hyperlink with a relationship (an address with & in it) and a HYPERLINK field
    * numbered and bulleted lists (numbering.xml), a table with a merged and a spanning cell
    * Shift+Enter breaks, Tabs, bold / italic / underline / superscript / subscript / strike-through,
      bigger text, tracked changes, hidden text, a bookmark, curly quotes and an accented letter
    * a Word lock file (~$...), a damaged .docx and a file that is not a Word document
    * the Photos folder (photos for the squares): a big photo (made smaller), a newer second photo of the
      same person (the one named by the number alone still wins), a PNG that replaces the picture found
      in the life history, a photo with the camera's rotation flag, a photo for a place of pedigree
      collapse (D3,8 = C3,2), one for a person without a document, a lower-case "d4,12.JPG", one for a
      root person ("ruth.jpg"), one for a number nobody has, one without a number and a damaged one
    * flags come only from a Flag: line: "Flag: Irish" (Ireland), "Flag: Atlantis" (no such country: noted);
      "Immigration: 1855, from Kent, England ..." and "Immigration: 1888, to New England from Wales" give none

  Changing a document here changes what the tests expect: run tests\Run-Tests.ps1 -UpdateSnapshot, read
  the changes in tests\expected\snapshot.json, and adjust the counts and checks in Run-Tests.ps1. The
  names and places are invented; keep it that way (no real family's names in this public file).
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TestDocx.psm1') -Force

$Root = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
if ($Root.Length -le 3) { throw "New-TestFamily: give a folder, not a whole drive ($Root)" }
if ([System.IO.Directory]::Exists($Root) -and [System.IO.Directory]::GetFileSystemEntries($Root).Length -gt 0) {
  throw "New-TestFamily: $Root is not empty. Give a new or empty folder (nothing that is already there is ever replaced)."
}
[void][System.IO.Directory]::CreateDirectory($Root)

function T([string]$s) { return [DateTime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal') }

# Each document: relative path, last changed (UTC), paragraphs (see TestDocx.psm1 for the marks).
$Family = @(
  @{ File = 'template life history.docx'; Time = '2019-01-01 09:00'; Paras = @(
      'Rosalind Clementine Penrose (C8,30)'
      '1741-1799'
      'Father: Robert Penrose (C9,59)(1700-1770)'
      'Mother: '
      'Birth: '
      'Death: '
      'Marriage: '
      ''
      'Write the life story here.'
    ) }

  # ---------------------------------------------------------------- A = Ashworth (Tom's father's side)
  @{ File = 'Ashworth\Ashworth Thomas.docx'; Time = '2024-05-01 18:30'; Paras = @(
      'Thomas R. Ashworth'
      '1950-'
      'Father: Henry Lowell Ashworth (A1,1)(1922-1998)'
      'Mother: Margaret Ann Brennan (B1,1)(1926-2010)'
      'Birth: 6/2/1950, Millbrook, IL'
      'Marriage: Ruth Carrow, 8/16/1975, Millbrook, IL'
      'Children: Daniel Ashworth (1978-), Laura Ashworth (1981-)'
      ''
      'Tom grew up on the family farm outside Millbrook and wrote down these family stories over many winters, starting with the ones his grandmother Clara told him.'
      '1968 Graduated from Millbrook High School.'
    ) }
  @{ File = 'Ashworth\A1,1 Ashworth Henry.docx'; Time = '2023-02-10 10:00'; Paras = @(
      '{big}{b}Henry Lowell Ashworth (A1,1){/b}{/big}{br}1922-1998'
      '{b}Father:{/b} Samuel Ashworth (A2,1)(1890-1960)'
      '{b}Mother:{/b} Clara Bell Thornfield (A2,2)(1895-1970)'
      '{b}Descendant:{/b} Thomas R. Ashworth'
      '{b}Birth:{/b} 3/14/1922, Millbrook, IL'
      '{b}Death:{/b} 11/2/1998, Millbrook, IL'
      '{b}Marriage:{/b} Margaret Ann Brennan (B1,1)(1926-2010), 1948, Millbrook, IL'
      '{b}Siblings:{/b} Ellen Ashworth Kersey (1920-1991)'
      '{tab}George Ashworth (1925-1944)'
      '{tab}Walter Ashworth (1928-2001)'
      'Children: Thomas R. Ashworth (1950-), Anne Ashworth (1953-)'
      ''
      'Henry was the 3{sup}rd{/sup} child of Samuel and Clara. He served in the {i}Army Air Forces{/i} from 1942 to 1945 and kept a {u}detailed diary{/u} that the family still has.'
      '1942 Enlisted in the Army Air Forces at Millbrook.'
      '1948 Married Margaret Ann Brennan at {link:https://example.com/st-anne|St. Anne{U+2019}s Church}.'
      'Read more in the {link:https://example.com/records?id=12&page=3|county records} and in the family Bible.'
    ) }
  @{ File = 'Ashworth\A2,1 Ashworth Samuel.docx'; Time = '2022-06-01 14:00'; Paras = @(
      'Samuel Ashworth (A2,{split}1)'
      '1890-1960'
      'Father: John Ashworth (A3, 1)(1860-1930)'
      'Mother: ?'
      'Descendant: Henry Lowell Ashworth (A1,1)'
      'Birth: 1890, Millbrook, IL'
      'Death: 1960, Millbrook, IL'
      'Marriage: 1914 to Clara Bell Thornfield (A2,2)'
      ''
      'Samuel ran the grist mill on Mill Creek. His mother{U+2019}s name was never found; the parish book has a torn page.'
      '1910 census: living in Millbrook with his father.'
    ) }
  @{ File = 'Ashworth\A2,2 Thornfield Clara.docx'; Time = '2022-06-15 09:30'; Paras = @(
      'Clara Bell Thornfield (A2,2)'
      '1895-1970'
      'Father: Edward Thornfield (A3.3)(1865-1940)'
      'Mother: Rose Ellen Marsh (A3,4)(1868 - 1950)'
      'Descendant: Henry Lowell Ashworth (A1,1)'
      'Birth: 4/9/1895, Fairview, IL'
      'Death: 1970, Millbrook, IL'
      'Marriage: Samuel Ashworth (A2,1), 1914, Fairview, IL'
      ''
      'Clara taught at the Fairview school before her marriage and told her grandchildren the old family stories.'
    ) }
  @{ File = 'Ashworth\A3,1 Ashworth John.docx'; Time = '2023-09-01 16:45'; Paras = @(
      'John Ashworth (A3,1)'
      '1860-1930'
      'Father: William Ashworth (A4,1)(1830-1895)'
      'Mother: Sarah Tolland (A4,2)'
      'Descendant: Samuel Ashworth (A2,1)'
      'Birth: 1860, Oak County, Ohio'
      'Death: 1930, Millbrook, IL'
      'Marriage: Mary Penrose, 1885'
      ''
      'John came west with his parents in 1868 and built the first mill on Mill Creek. The mill ground wheat and corn for farms up and down the valley.'
      '1880 census: farming with his father near Millbrook.'
      '1885 Married Mary Penrose at the Millbrook chapel.'
    ) }
  @{ File = 'Ashworth\A3,1 Ashworth John (old copy).docx'; Time = '2021-01-01 12:00'; Paras = @(
      'John Ashworth (A3,1)'
      '1860-1930'
      'Father: William Ashworth (A4,1)'
      'Birth: 1860, Ohio'
      ''
      'John came west with his parents and built the first mill on Mill Creek.'
    ) }
  @{ File = 'Ashworth\A3,3 Thornfield Edward.docx'; Time = '2022-08-20 11:15'; Paras = @(
      'Edward Thornfield (A3,3)'
      '1865-1940'
      'Father: Thomas Thornfield (A4,5)'
      'Mother: Ann Lacey (A4,6)'
      'Descendant: Clara Bell Thornfield (A2,2)'
      'Birth: 1865, Fairview, IL'
      'Death: 1940, Fairview, IL'
      'Marriage: Rose Ellen Marsh (A3,4), 1889'
      'Children:'
      '@list:1:0 Clara Bell Thornfield (A2,2)(1895-1970)'
      '@list:1:0 Frank Thornfield (1897-1961)'
      ''
      'Edward kept the store accounts in three books:'
      '@list:3:0 The day book'
      '@list:3:1 sales'
      '@list:3:1 credit'
      '@list:3:0 The ledger'
      '@list:3:0 The letter book'
      '@list:2:0 Each book has a brown leather cover.'
      '@list:2:1 The ledger is the largest.'
      # (rows separated by commas: on separate lines alone PowerShell would run them together)
      @{ Table = @(
          @('{b}Year{/b}', '{b}Event{/b}', '{b}Place{/b}'),
          @('1889', 'Married Rose Ellen Marsh', 'Fairview'),
          @('1895', '@span:2 Daughter Clara born at home'),
          @('@vmerge:restart 1900', 'Census', 'Fairview'),
          @('@vmerge', 'Store opened', 'Main Street')
        ) }
      ''
      '1900 census: merchant in Fairview.'
    ) }
  @{ File = 'Ashworth\A3,4 Marsh Rose.docx'; Time = '2020-11-11 08:00'; Paras = @(
      'Rose Ellen Marsh (A3,4)'
      '1868 - 1950'
      'Father: unknown'
      'Mother: Martha Garvey (A4,8)(1840-1910)'
      'Descendant: Clara Bell Thornfield (A2,2)'
      'Birth: 1868, Fairview, IL'
      'Death: 1950, Fairview, IL'
      ''
      'Rose{U+2019}s recipe book is described on {field:https://example.org/recipes|the family recipe page}.'
      'Her obituary appeared in the {i}Fairview Gazette{/i}{tab}(page 4).'
    ) }
  @{ File = 'Ashworth\A4,2 Ashworth William.docx'; Time = '2023-03-03 13:20'; Paras = @(
      'William Ashworth (A4,1)'
      'abt. 1830-1895'
      'Father: Robert Ashworth (A5,1)'
      'Mother: Jane Doyle (A5,2)'
      'Descendant: John Ashworth (A3,1)'
      'Birth: abt. 1830, Kent, England'
      'Death: 1895, Millbrook, IL'
      ''
      'William crossed the ocean with his wife Sarah and their young son John.'
      '1852 Arrived at New York on the ship Mary Ellen.'
    ) }
  @{ File = 'Ashworth\A5.1 Ashworth Robert.docx'; Time = '2019-05-05 10:10'; Paras = @(
      'Robert Ashworth (A5,1)'
      '1800-1870'
      'Descendant: William Ashworth (A4,2)'
      'Birth: 1800, Kent, England'
      'Death: 1870, Kent, England'
      'Marriage: Jane Doyle (A5,2)'
      ''
      'Robert stayed in England when his son William emigrated.'
    ) }

  # ---------------------------------------------------------------- B = Brennan (Tom's mother's side)
  @{ File = 'Brennan\Brennan Margaret.docx'; Time = '2024-01-20 15:00'; Paras = @(
      'Margaret Ann Brennan'
      '1926-2010'
      'Father: Patrick Brennan (B2,1)(1895-1965)'
      'Mother: Nora Quinn (B2,2)(1898-1980)'
      'Descendant: Thomas R. Ashworth'
      'Birth: 7/30/1926, Millbrook, IL'
      'Death: 2010, Millbrook, IL'
      'Marriage: Henry Lowell Ashworth (A1,1), 1948'
      ''
      'Margaret kept the family photographs and wrote the names on the back of every one.'
    ) }
  @{ File = 'Brennan\Brennan Patrick.docx'; Time = '2023-07-07 07:07'; Paras = @(
      'Patrick Brennan'
      '1895-1965'
      'Birth: 1895, Ballyglen, Ireland'
      'Death: 1965, Millbrook, IL'
      'Marriage: Nora Quinn, 1922'
      ''
      'Patrick came to Millbrook in 1920 and worked for the railway for forty years.'
    ) }
  @{ File = 'Brennan\B2,2 Quinn Nora.docx'; Time = '2022-12-12 12:12'; Paras = @(
      '@center {img:Portrait of a woman wearing a hat|0}'
      'Nora Quinn (B2,2)'
      '1898-1980'
      'Father: Michael Quinn (B3,3)(1870-1940)'
      'Mother: Bridget Farrow (B3,4)'
      'Descendant: Margaret Ann Brennan (B1,1)'
      'Birth: 1898, Ballyglen, Ireland'
      'Death: 1980, Millbrook, IL'
      'Marriage: Patrick Brennan (B2,1), 1922'
      'Flag: Irish'
      ''
      'Nora sailed from Ireland with her sister in 1919.'
      '@center {img:Headstone in the churchyard|10000}'
      '@center {i}Nora{U+2019}s headstone, photographed in 2005.{/i}'
    ) }
  @{ File = 'Brennan\B3,3 Quinn Michael.docx'; Time = '2021-05-05 05:05'; Paras = @(
      'Michael Quinn (B3,3)'
      '1870-1940'
      'Father: Daniel Quinn (1840-1901)'
      'Mother: Catherine Walsh'
      'Descendant: Nora Quinn (B2,2)'
      'Birth: 1870, Ballyglen, Ireland'
      'Death: 1940, Ballyglen, Ireland'
      'Marriage: Bridget Farrow'
      'Children: Nora Quinn (B2,2)(1898-1980); Sean Quinn (1900-1950)'
      ''
      'Michael farmed near Ballyglen all his life.'
    ) }

  # ---------------------------------------------------------------- C = Carrow (Ruth's father's side)
  @{ File = 'Carrow\C2,1 Carrow Arthur.docx'; Time = '2023-04-04 10:00'; Paras = @(
      'Arthur Carrow (C2,1)'
      '1898-1970'
      'Father: Joseph Carrow (C3,1)(1870-1945)'
      'Mother: Hannah Quarles (C3,2)(1872-1950)'
      'Descendant: Walter James Carrow (C1,1)'
      'Birth: 1898, Riverton, Iowa'
      'Death: 1970, Riverton, Iowa'
      'Marriage: Ida May Fenwick (C2,2), 1922'
      'Siblings: Lucy Carrow Dalby (1902-1985)'
      ''
      'Arthur and his sister Lucy grew up above their father{U+2019}s hardware store.'
    ) }
  @{ File = 'Carrow\C2,2 Fenwick Ida.docx'; Time = '2023-04-05 10:00'; Paras = @(
      'Ida May Fenwick (C2,2)'
      '1900-1988'
      'Father: Robert Fenwick (C3,3)(1868-1931)'
      'Mother: Alice Pennock (C3,4)'
      'Descendant: Walter James Carrow (C1,1)'
      'Birth: 1900, Riverton, Iowa'
      'Death: 1988, Riverton, Iowa'
      'Marriage: Arthur Carrow (C2,1), 1922, Riverton, Iowa'
      ''
      'Ida played the organ at the Riverton church for forty years.'
    ) }
  @{ File = 'Carrow\C3,1 Carrow Joseph.docx'; Time = '2022-02-02 10:00'; Paras = @(
      'Joseph Carrow (C3,1)'
      '1870-1945'
      'Father: Isaac Carrow (C4,1)'
      'Mother: Ellen Hart (C4,2)'
      'Descendant: Arthur Carrow (C2,1)'
      'Birth: 1870, Riverton, Iowa'
      'Death: 1945, Riverton, Iowa'
      'Marriage: Hannah Quarles (C3,2), 1896'
      'Children: Arthur Carrow (C2,1)(1898-1970), Lucy Carrow (D2,4)(1902-1985)'
      ''
      'Joseph opened the Riverton hardware store and ran it until his sons took over.'
      '1895 Opened the hardware store on Front Street.'
    ) }
  @{ File = 'Carrow\C3,3 Fenwick Robert.docx'; Time = '2020-07-07 10:00'; Paras = @(
      'Robert Fenwick (C3,3)'
      '1868-1931'
      'Father: John Fenwick (C 4,5)(1840-1910)'
      'Mother: Sarah Fenwick (C4,6)'
      'Descendant: Ida May Fenwick (C2,2)'
      'Birth: 1868, Riverton, Iowa'
      'Death: 1931, Riverton, Iowa'
      'Immigration: 1888, to New England from Wales'
      'Marriage: 5/20/1895 to Alice Pennock (C3,4)(1872-1950)'
      ''
      'Robert was the Riverton postmaster for twenty years.'
    ) }

  # ---------------------------------------------------------------- D = Dalby (Ruth's mother's side)
  @{ File = 'Dalby\D2,3 Dalby Frank.docx'; Time = '2023-06-06 10:00'; Paras = @(
      'Frank Dalby (D2,3)'
      '1896-1960'
      'Father: George Dalby (D3,5)(1860-1931)'
      'Mother: Emma Lindale (D3,6)(1862-1940)'
      'Descendant: Edna Mae Dalby (D1,2)'
      'Birth: 1896, Riverton, Iowa'
      'Death: 1960, Riverton, Iowa'
      'Marriage: Lucy Carrow (D2,4), 1924'
      ''
      'Frank drove the mail wagon between Riverton and Lone Oak.'
    ) }
  @{ File = 'Dalby\D2,4 Dalby Lucy.docx'; Time = '2023-06-07 10:00'; Paras = @(
      'Lucy Carrow Dalby (D2,4)'
      '1902-1985'
      'Father: Joseph Carrow (C3,1)(1870-1945)'
      'Mother: Hannah Quarles (C3,2)(1872-1950)'
      'Descendant: Edna Mae Dalby (D1,2)'
      'Birth: 1902, Riverton, Iowa'
      'Death: 1985, Lone Oak, Iowa'
      'Marriage: Frank Dalby (D2,3), 1924'
      ''
      'Lucy was Arthur Carrow{U+2019}s younger sister, so Ruth{U+2019}s parents were first cousins.'
    ) }
  @{ File = 'Dalby\D3,5 Dalby George.docx'; Time = '2021-09-09 10:00'; Paras = @(
      'George Dalby (D3,5)'
      '1860-1931'
      'Father: Henry Dalby'
      'Mother: Not known'
      'Descendant: Frank Dalby (D2,3)'
      'Birth: 1860, Lone Oak, Iowa'
      'Death: 1931, Lone Oak, Iowa'
      'Flag: Atlantis'
      'Marriage: Emma Lindale (D3,6), 1885'
      ''
      'George was {b}the{/b} {i}blacksmith{/i} of {u}Lone Oak{/u} and the 1{sup}st{/sup} man in town to own a motor car. Water is H{sub}2{/sub}O; the old sign said {strike}Smithy{/strike} Blacksmith.'
      'He married Emma in {del:1884}{ins:1885} at the {hidden:secret }{bookmark}Caf{U+00E9} Corner chapel.'
      '1885 Married Emma Lindale at Lone Oak.'
    ) }
  @{ File = 'Dalby\D3,6 Lindale Emma.docx'; Time = '2020-03-03 10:00'; Paras = @(
      'Emma Lindale (D3,6)'
      'c. 1862-1940'
      'Father: William Lindale (D4,11)(1830-1899)'
      'Mother: Mary Byrne (D4,12)'
      'Descendant: Frank Dalby (D2,3)'
      'Birth: c. 1862, Lone Oak, Iowa'
      'Death: 1940, Lone Oak, Iowa'
      ''
      'Emma kept bees and sold honey at the Saturday market.'
    ) }
  @{ File = 'Dalby\D4,11 Lindale William.docx'; Time = '2019-10-10 10:00'; Paras = @(
      'William Lindale (D4,11) 1830-1899'
      'Descendant: Emma Lindale (D3,6)'
      'Birth: 1830, Kent, England'
      'Death: 1899, Lone Oak, Iowa'
      'Immigration: 1855, from Kent, England to New York'
      ''
      'William was a stonemason; the church in Lone Oak is his work.'
    ) }

  # ---------------------------------------------------------------- stories (not about one person)
  @{ File = 'Stories\The Old Mill.docx'; Time = '2024-03-03 10:00'; Paras = @(
      'The Old Mill'
      ''
      'The mill on Mill Creek was built by John Ashworth (A3,1) and later run by his son Samuel (A2,1). Rose (A3,4) baked bread from its flour every Saturday for forty years.'
      'A man written in the parish book as (A9,1) is not in the tree.'
      'Picture of the mill: {img:Old mill by the creek|0}'
      'See also {link:https://example.com/mill|the county history page}.'
    ) }
  @{ File = 'Stories\Family Reunion 1985.docx'; Time = '2024-03-04 10:00'; Paras = @(
      'Family Reunion, 1985'
      ''
      'Forty-two relatives came to the farm. Henry Lowell Ashworth (A1,1) gave a speech and Margaret (B1,1) made six pies.'
      @{ Table = @(
          @('{b}Who{/b}', '{b}Came from{/b}'),
          @('Henry and Margaret Ashworth', 'Millbrook'),
          @('The Carrow cousins', 'Riverton')
        ) }
      ''
    ) }
)

$made = 0
foreach ($d in $Family) {
  New-TestDocx -Path (Join-Path $Root $d.File) -Paragraphs $d.Paras -Time (T $d.Time)
  $made++
}
# a damaged document, Word's lock file next to an open document, and a file that is not a Word document
New-CorruptDocx -Path (Join-Path $Root 'Carrow\C4,1 Carrow Isaac.docx') -Time (T '2022-03-03 10:00')
New-WordLockFile -Path (Join-Path $Root 'Carrow\~$C2,1 Carrow Arthur.docx')
$notes = Join-Path $Root 'Dalby\research notes.txt'
[System.IO.File]::WriteAllText($notes, "Things to look up: Emma Lindale's parents.`r`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::SetLastWriteTimeUtc($notes, (T '2021-02-02 10:00'))

# the Photos folder
$photos = Join-Path $Root 'Photos'
New-TestPhoto -Path (Join-Path $photos 'A2,1.jpg') -Width 1600 -Height 2000 -Time (T '2024-06-01 10:00')
New-TestPhoto -Path (Join-Path $photos 'A2,1 older.jpg') -Width 300 -Height 400 -Time (T '2024-07-01 10:00')
New-TestPhoto -Path (Join-Path $photos 'B2,2 Nora at 20.png') -Width 240 -Height 320 -Png -Time (T '2024-06-02 10:00')
New-TestPhoto -Path (Join-Path $photos 'C3,1 Joseph.jpg') -Width 400 -Height 240 -Orientation 6 -Time (T '2024-06-03 10:00')
New-TestPhoto -Path (Join-Path $photos 'D3,8.jpg') -Width 300 -Height 400 -Time (T '2024-06-04 10:00')
New-TestPhoto -Path (Join-Path $photos 'd4,12.JPG') -Width 300 -Height 400 -Time (T '2024-06-05 10:00')
New-TestPhoto -Path (Join-Path $photos 'ruth.jpg') -Width 300 -Height 400 -Time (T '2024-06-06 10:00')
New-TestPhoto -Path (Join-Path $photos 'A9,1.jpg') -Width 300 -Height 400 -Time (T '2024-06-07 10:00')
New-TestPhoto -Path (Join-Path $photos 'Family picnic.jpg') -Width 400 -Height 300 -Time (T '2024-06-08 10:00')
$broken = Join-Path $photos 'B3,3.jpg'
[System.IO.File]::WriteAllBytes($broken, [byte[]](1..200 | ForEach-Object { [byte](($_ * 53 + 7) % 256) }))
[System.IO.File]::SetLastWriteTimeUtc($broken, (T '2024-06-09 10:00'))

if (-not $Quiet) { Write-Host "Made $made test documents (+ 1 damaged, 1 lock file, 1 text file) and 10 photos in $Root" }
