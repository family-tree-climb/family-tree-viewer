<#
  TestDocx.psm1
  -------------
  Writes small Word documents (.docx) for the automatic tests, without Word: a .docx is a zip file
  of XML parts, and this module writes those parts the way Word does (document.xml, styles.xml,
  settings.xml, numbering.xml when there are lists, the relationship files, docProps, pictures).

  Only for MADE-UP test documents. It refuses to overwrite a file unless -Force is given.

  Exported:
    New-TestDocx -Path <file.docx> -Paragraphs <object[]> [-Time <DateTime>] [-Force]
    New-CorruptDocx -Path <file.docx> [-Time <DateTime>]      a file that is not a zip at all
    New-WordLockFile -Path <~$name.docx>                       like the owner file Word leaves next to an open document
    Get-TestPicture                                            the bytes of the 40 x 60 test PNG

  A paragraph is a string. Options come first, each followed by a space:
    @center  @right            alignment
    @list:<numId>:<level>      list paragraph (numId 1 and 3: 1. a. i.;  numId 2: bullets; numbering restarts per numId)
    @style:<styleId>           paragraph style (e.g. Title, ListParagraph)
    @indent:<twips>            left indent (720 = half an inch)
  Then the text, with these marks:
    {b} {/b}  {i} {/i}  {u} {/u}  {sup} {/sup}  {sub} {/sub}  {strike} {/strike}  {big} {/big}
    {br}       Shift+Enter (a line break inside the paragraph)
    {tab}      a Tab
    {split}    Word splitting the text into two runs with a spell-check mark in between
    {bookmark} Word's hidden "_GoBack" bookmark
    {del:x}    tracked deletion of x;   {ins:x}  tracked insertion of x;   {hidden:x}  hidden text x
    {link:<url>|<text>}    a hyperlink (w:hyperlink with a relationship)
    {field:<url>|<text>}   a hyperlink written as a HYPERLINK field (fldChar / instrText)
    {img:<description>|<crop>}  the test picture, 40 x 60; crop 0 = none, else Word's srcRect l/t/r/b
                                in 1/1000 percent (10000 = 10% off every side)
    {U+XXXX}   any Unicode character, e.g. {U+2019} for a curly apostrophe (the test scripts stay
               plain ASCII: Windows PowerShell 5.1 reads scripts without a BOM as ANSI, and curly
               quotes would act as PowerShell quotes)
  An empty string is an empty paragraph.

  A table is a hashtable @{ Table = @( @('cell', 'cell'), @('cell', 'cell') ) }. A cell is a paragraph
  string that may start with @span:<n> (gridSpan) and/or @vmerge:restart or @vmerge (merged with the
  cell above).
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

$script:W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
$script:RelBase = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:DocNs = 'xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas" ' +
  'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:o="urn:schemas-microsoft-com:office:office" ' +
  'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" ' +
  'xmlns:v="urn:schemas-microsoft-com:vml" xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" ' +
  'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:w10="urn:schemas-microsoft-com:office:word" ' +
  'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" ' +
  'xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml" xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup" ' +
  'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" mc:Ignorable="w14 w15 wp14"'

# 40 x 60 pixels: a green head over a brown body on a light background (made with System.Drawing once)
$script:PictureBase64 = 'iVBORw0KGgoAAAANSUhEUgAAACgAAAA8CAYAAAAUufjgAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAADhSURBVGhD7c6xDQIxEETRq4eEUqABKqBRiiCmDZDTL9be8Qp0Z03wEkve+dvr+Xjv2caHvXFglQOrHFi1fuD5dh3iH0UpkCE9/Js1HciADN7ImArksIK3RuRADs7gzZ61AjlUwdsRB0Z4O7JOIAeqeD+SDmw4UsHbEQdGeDuyVmDDoRm82bNeYMNBBW+NTAU2HM7gjYzpwIYBPfybVQpsGPIN/yjKgb/mwKrjBt4vp7/ivgNV3HegivsOVHHfgSruO1DFfQequO9AFfcdqOK+A1Xcd6CK+w5Ucd+BKu4fJvAD1WxBd3uiinwAAAAASUVORK5CYII='

# (the comma keeps PowerShell from unrolling the byte array into single objects)
function Get-TestPicture { return , ([Convert]::FromBase64String($script:PictureBase64)) }

function ConvertFrom-UEscape([string]$s) {
  return [regex]::Replace($s, '\{U\+([0-9A-Fa-f]{4})\}', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}
function Esc([string]$s) { return [System.Security.SecurityElement]::Escape($s) }

function Get-RsId($ctx) { $ctx.Rsid++; return '00' + ('{0:X6}' -f (0x3A1000 + $ctx.Rsid)) }

function Add-Rel($ctx, [string]$type, [string]$target, [bool]$external) {
  $ctx.RelN++
  $id = 'rId' + $ctx.RelN
  $ctx.Rels.Add(@{ Id = $id; Type = $type; Target = $target; External = $external })
  return $id
}

function Get-RunXml($ctx, [string]$text, $fmt, [string]$kind) {
  if ($text -eq '') { return '' }
  $rPr = ''
  if ($fmt.link) { $rPr += '<w:rStyle w:val="Hyperlink"/>' }
  if ($fmt.b) { $rPr += '<w:b/><w:bCs/>' }
  if ($fmt.i) { $rPr += '<w:i/><w:iCs/>' }
  if ($fmt.strike) { $rPr += '<w:strike/>' }
  if ($kind -eq 'hidden') { $rPr += '<w:vanish/>' }
  $size = 24; if ($fmt.big) { $size = 32 }
  $rPr += '<w:sz w:val="' + $size + '"/><w:szCs w:val="' + $size + '"/>'
  if ($fmt.u) { $rPr += '<w:u w:val="single"/>' }
  if ($fmt.sup) { $rPr += '<w:vertAlign w:val="superscript"/>' } elseif ($fmt.sub) { $rPr += '<w:vertAlign w:val="subscript"/>' }
  $tag = 't'; if ($kind -eq 'del') { $tag = 'delText' }
  $xml ='<w:r w:rsidR="' + (Get-RsId $ctx) + '"><w:rPr>' + $rPr + '</w:rPr>'
  # a Tab inside the text is written as Word does it: <w:tab/> between text pieces
  $pieces = $text.Split("`t")
  for ($k = 0; $k -lt $pieces.Length; $k++) {
    if ($k -gt 0) { $xml += '<w:tab/>' }
    if ($pieces[$k] -ne '') {
      $sp = ''; if ($pieces[$k] -ne $pieces[$k].Trim()) { $sp = ' xml:space="preserve"' }
      $xml += '<w:' + $tag + $sp + '>' + (Esc $pieces[$k]) + '</w:' + $tag + '>'
    }
  }
  return $xml + '</w:r>'
}

function Get-PictureXml($ctx, [string]$spec) {
  $parts = $spec.Split('|')
  $alt = $parts[0]
  $crop = 0; if ($parts.Length -gt 1) { $crop = [int]$parts[1] }
  if (-not $ctx.PictureRel) { $ctx.PictureRel = Add-Rel $ctx "$script:RelBase/image" 'media/image1.png' $false }
  $ctx.DrawingId++
  $n = $ctx.DrawingId
  $cx = 40 * 9525; $cy = 60 * 9525
  $src = ''
  if ($crop -gt 0) { $src = '<a:srcRect l="' + $crop + '" t="' + $crop + '" r="' + $crop + '" b="' + $crop + '"/>' }
  return '<w:r w:rsidR="' + (Get-RsId $ctx) + '"><w:rPr><w:noProof/></w:rPr><w:drawing>' +
    '<wp:inline distT="0" distB="0" distL="0" distR="0" wp14:anchorId="' + ('{0:X8}' -f (0x2B000000 + $n)) + '" wp14:editId="' + ('{0:X8}' -f (0x1C000000 + $n)) + '">' +
    '<wp:extent cx="' + $cx + '" cy="' + $cy + '"/><wp:effectExtent l="0" t="0" r="0" b="0"/>' +
    '<wp:docPr id="' + $n + '" name="Picture ' + $n + '" descr="' + (Esc $alt) + '"/>' +
    '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
    '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
    '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="' + $n + '" name="Picture ' + $n + '"/><pic:cNvPicPr/></pic:nvPicPr>' +
    '<pic:blipFill><a:blip r:embed="' + $ctx.PictureRel + '"><a:extLst><a:ext uri="{28A0092B-C50C-407E-A947-70E740481C1C}"><a14:useLocalDpi xmlns:a14="http://schemas.microsoft.com/office/drawing/2010/main" val="0"/></a:ext></a:extLst></a:blip>' +
    $src + '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>' +
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="' + $cx + '" cy="' + $cy + '"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>' +
    '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>'
}

# Turns the marked-up text of one paragraph into Word runs.
function Get-InlineXml($ctx, [string]$text) {
  $text = ConvertFrom-UEscape $text
  $fmt = @{ b = $false; i = $false; u = $false; sup = $false; sub = $false; strike = $false; big = $false; link = $false }
  $re = New-Object System.Text.RegularExpressions.Regex('\{(/?)(b|i|u|sup|sub|strike|big)\}|\{(br|tab|split|bookmark)\}|\{(del|ins|hidden|link|field|img):([^}]*)\}')
  $xml = New-Object System.Text.StringBuilder
  $pos = 0
  foreach ($m in $re.Matches($text)) {
    [void]$xml.Append((Get-RunXml $ctx $text.Substring($pos, $m.Index - $pos) $fmt ''))
    $pos = $m.Index + $m.Length
    if ($m.Groups[2].Success) { $fmt[$m.Groups[2].Value] = ($m.Groups[1].Value -ne '/'); continue }
    if ($m.Groups[3].Success) {
      switch ($m.Groups[3].Value) {
        'br'       { [void]$xml.Append('<w:r w:rsidR="' + (Get-RsId $ctx) + '"><w:br/></w:r>') }
        'tab'      { [void]$xml.Append('<w:r w:rsidR="' + (Get-RsId $ctx) + '"><w:tab/></w:r>') }
        'split'    { [void]$xml.Append('<w:proofErr w:type="spellStart"/>') }
        'bookmark' { [void]$xml.Append('<w:bookmarkStart w:id="0" w:name="_GoBack"/><w:bookmarkEnd w:id="0"/>') }
      }
      continue
    }
    $what = $m.Groups[4].Value; $arg = $m.Groups[5].Value
    $ctx.ChangeId++
    $stamp = 'w:id="' + $ctx.ChangeId + '" w:author="Test Author" w:date="' + $ctx.TimeIso + '"'
    switch ($what) {
      'del'    { [void]$xml.Append('<w:del ' + $stamp + '>' + (Get-RunXml $ctx $arg $fmt 'del') + '</w:del>') }
      'ins'    { [void]$xml.Append('<w:ins ' + $stamp + '>' + (Get-RunXml $ctx $arg $fmt '') + '</w:ins>') }
      'hidden' { [void]$xml.Append((Get-RunXml $ctx $arg $fmt 'hidden')) }
      'img'    { [void]$xml.Append((Get-PictureXml $ctx $arg)) }
      'link' {
        $url, $label = $arg.Split('|', 2)
        $rid = Add-Rel $ctx "$script:RelBase/hyperlink" $url $true
        $f2 = $fmt.Clone(); $f2.link = $true
        [void]$xml.Append('<w:hyperlink r:id="' + $rid + '" w:history="1">' + (Get-RunXml $ctx $label $f2 '') + '</w:hyperlink>')
      }
      'field' {
        $url, $label = $arg.Split('|', 2)
        $f2 = $fmt.Clone(); $f2.link = $true
        [void]$xml.Append('<w:r><w:fldChar w:fldCharType="begin"/></w:r>')
        [void]$xml.Append('<w:r><w:instrText xml:space="preserve"> HYPERLINK "' + (Esc $url) + '" </w:instrText></w:r>')
        [void]$xml.Append('<w:r><w:fldChar w:fldCharType="separate"/></w:r>')
        [void]$xml.Append((Get-RunXml $ctx $label $f2 ''))
        [void]$xml.Append('<w:r><w:fldChar w:fldCharType="end"/></w:r>')
      }
    }
  }
  [void]$xml.Append((Get-RunXml $ctx $text.Substring($pos) $fmt ''))
  return $xml.ToString()
}

function Split-Options([string]$s) {
  $opts = @{}
  while ($s -match '^@(\w+)(?::(\S*))?(?: |$)') {
    $opts[$Matches[1]] = $(if ($Matches[2]) { $Matches[2] } else { $true })
    $s = $s.Substring($Matches[0].Length)
  }
  return @{ Options = $opts; Text = $s }
}

function Get-ParagraphXml($ctx, [string]$spec) {
  $sp = Split-Options $spec
  $o = $sp.Options
  $pPr = ''
  if ($o.style) { $pPr += '<w:pStyle w:val="' + $o.style + '"/>' }
  if ($o.list) {
    $numId, $lvl = ([string]$o.list).Split(':')
    if (-not $lvl) { $lvl = '0' }
    if (-not $o.style) { $pPr = '<w:pStyle w:val="ListParagraph"/>' + $pPr }
    $pPr += '<w:numPr><w:ilvl w:val="' + $lvl + '"/><w:numId w:val="' + $numId + '"/></w:numPr>'
    $ctx.UsesLists = $true
  }
  if ($o.indent) { $pPr += '<w:ind w:left="' + $o.indent + '"/>' }
  if ($o.center) { $pPr += '<w:jc w:val="center"/>' } elseif ($o.right) { $pPr += '<w:jc w:val="right"/>' }
  $ctx.ParaN++
  $rs = Get-RsId $ctx
  $head = '<w:p w14:paraId="' + ('{0:X8}' -f (0x10000000 + $ctx.ParaN)) + '" w14:textId="77777777" w:rsidR="' + $rs + '" w:rsidRDefault="' + $rs + '">'
  if ($pPr) { $head += '<w:pPr>' + $pPr + '</w:pPr>' }
  return $head + (Get-InlineXml $ctx $sp.Text) + '</w:p>'
}

function Get-TableXml($ctx, $rows) {
  $cols = 0
  $parsed = @()
  foreach ($row in $rows) {
    $cells = @()
    $n = 0
    foreach ($cell in $row) {
      $sp = Split-Options ([string]$cell)
      $span = 1; if ($sp.Options.span) { $span = [int]$sp.Options.span }
      # ([string]: in PowerShell $true -eq 'restart' is true)
      $vm = ''; if ($sp.Options.vmerge) { $vm = $(if ([string]$sp.Options.vmerge -eq 'restart') { 'restart' } else { 'continue' }) }
      $rest = ''
      foreach ($k in $sp.Options.Keys) { if ($k -ne 'span' -and $k -ne 'vmerge') { $rest += '@' + $k + $(if ($sp.Options[$k] -ne $true) { ':' + $sp.Options[$k] } else { '' }) + ' ' } }
      $cells += , @{ Span = $span; VMerge = $vm; Text = $rest + $sp.Text }
      $n += $span
    }
    if ($n -gt $cols) { $cols = $n }
    $parsed += , $cells
  }
  $width = [int](9360 / [Math]::Max(1, $cols))
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr><w:tblGrid>')
  for ($c = 0; $c -lt $cols; $c++) { [void]$sb.Append('<w:gridCol w:w="' + $width + '"/>') }
  [void]$sb.Append('</w:tblGrid>')
  foreach ($cells in $parsed) {
    [void]$sb.Append('<w:tr w:rsidR="' + (Get-RsId $ctx) + '">')
    foreach ($cell in $cells) {
      [void]$sb.Append('<w:tc><w:tcPr><w:tcW w:w="' + ($width * $cell.Span) + '" w:type="dxa"/>')
      if ($cell.Span -gt 1) { [void]$sb.Append('<w:gridSpan w:val="' + $cell.Span + '"/>') }
      if ($cell.VMerge -eq 'restart') { [void]$sb.Append('<w:vMerge w:val="restart"/>') } elseif ($cell.VMerge) { [void]$sb.Append('<w:vMerge/>') }
      [void]$sb.Append('</w:tcPr>')
      [void]$sb.Append((Get-ParagraphXml $ctx $cell.Text))
      [void]$sb.Append('</w:tc>')
    }
    [void]$sb.Append('</w:tr>')
  }
  [void]$sb.Append('</w:tbl>')
  return $sb.ToString()
}

$script:StylesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" +
  '<w:styles xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
  '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:eastAsia="Calibri" w:hAnsi="Times New Roman" w:cs="Times New Roman"/><w:sz w:val="24"/><w:szCs w:val="24"/><w:lang w:val="en-US" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>' +
  '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>' +
  '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:sz w:val="56"/></w:rPr></w:style>' +
  '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>' +
  '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>' +
  '<w:style w:type="numbering" w:default="1" w:styleId="NoList"><w:name w:val="No List"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/></w:style>' +
  '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/><w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>' +
  '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:color w:val="0563C1" w:themeColor="hyperlink"/><w:u w:val="single"/></w:rPr></w:style>' +
  '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders></w:tblPr></w:style>' +
  '</w:styles>'

$script:SettingsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" +
  '<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:zoom w:percent="100"/><w:proofState w:spelling="clean" w:grammar="clean"/>' +
  '<w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/>' +
  '<w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>'

# numId 1 and 3: 1. / a. / i.   numId 2: Word's Symbol-font bullet (U+F0B7), then "o"
$script:NumberingXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" +
  '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
  '<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>' +
  '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>' +
  '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%2."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>' +
  '<w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="lowerRoman"/><w:lvlText w:val="%3."/><w:lvlJc w:val="right"/><w:pPr><w:ind w:left="2160" w:hanging="180"/></w:pPr></w:lvl>' +
  '</w:abstractNum>' +
  '<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>' +
  '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#61623;"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/></w:rPr></w:lvl>' +
  '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="o"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New" w:hint="default"/></w:rPr></w:lvl>' +
  '</w:abstractNum>' +
  '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num><w:num w:numId="3"><w:abstractNumId w:val="0"/></w:num>' +
  '</w:numbering>'

function Write-ZipEntry($zip, [string]$name, $content, [DateTimeOffset]$when) {
  $e = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
  $e.LastWriteTime = $when
  $s = $e.Open()
  try {
    if ($content -is [byte[]]) { $bytes = $content } else { $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$content) }
    $s.Write($bytes, 0, $bytes.Length)
  } finally { $s.Dispose() }
}

function Assert-NewFile([string]$path, [bool]$force) {
  $full = [System.IO.Path]::GetFullPath($path)
  if ([System.IO.File]::Exists($full) -and -not $force) { throw "New-TestDocx: $full already exists (use -Force to replace a test document)" }
  $dir = [System.IO.Path]::GetDirectoryName($full)
  if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
  return $full
}

function New-TestDocx {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object[]]$Paragraphs,
    [DateTime]$Time = [DateTime]::UtcNow,
    [switch]$Force
  )
  if ([System.IO.Path]::GetExtension($Path) -ne '.docx') { throw "New-TestDocx: not a .docx name: $Path" }
  $full = Assert-NewFile $Path $Force
  $utc = $Time.ToUniversalTime()
  $ctx = @{ Rsid = 0; RelN = 3; Rels = (New-Object System.Collections.Generic.List[hashtable]); PictureRel = $null; DrawingId = 0; ParaN = 0; ChangeId = 0
    UsesLists = $false; TimeIso = $utc.ToString('yyyy-MM-ddTHH:mm:ssZ') }

  $body = New-Object System.Text.StringBuilder
  foreach ($p in $Paragraphs) {
    if ($p -is [hashtable] -and $p.ContainsKey('Table')) { [void]$body.Append((Get-TableXml $ctx $p.Table)) }
    else { [void]$body.Append((Get-ParagraphXml $ctx ([string]$p))) }
  }
  $sect = '<w:sectPr w:rsidR="' + (Get-RsId $ctx) + '"><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/><w:cols w:space="720"/><w:docGrid w:linePitch="360"/></w:sectPr>'
  $docXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" + '<w:document ' + $script:DocNs + '><w:body>' + $body.ToString() + $sect + '</w:body></w:document>'

  $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="' + $script:RelBase + '/styles" Target="styles.xml"/>' +
    '<Relationship Id="rId2" Type="' + $script:RelBase + '/settings" Target="settings.xml"/>'
  if ($ctx.UsesLists) { $rels += '<Relationship Id="rId3" Type="' + $script:RelBase + '/numbering" Target="numbering.xml"/>' }
  foreach ($r in $ctx.Rels) {
    $rels += '<Relationship Id="' + $r.Id + '" Type="' + $r.Type + '" Target="' + (Esc $r.Target) + '"' + $(if ($r.External) { ' TargetMode="External"' } else { '' }) + '/>'
  }
  $rels += '</Relationships>'

  $types = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="png" ContentType="image/png"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
  if ($ctx.UsesLists) { $types += '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>' }
  $types += '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>' +
    '<Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>' +
    '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' +
    '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'

  $pkgRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'

  $core = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
    '<dc:title></dc:title><dc:creator>Test Author</dc:creator><cp:lastModifiedBy>Test Author</cp:lastModifiedBy><cp:revision>2</cp:revision>' +
    '<dcterms:created xsi:type="dcterms:W3CDTF">' + $ctx.TimeIso + '</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">' + $ctx.TimeIso + '</dcterms:modified></cp:coreProperties>'
  $app = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`r`n" + '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
    '<Template>Normal.dotm</Template><TotalTime>1</TotalTime><Pages>1</Pages><Application>Microsoft Office Word</Application><DocSecurity>0</DocSecurity><AppVersion>16.0000</AppVersion></Properties>'

  $when = New-Object DateTimeOffset($utc)
  $fs = [System.IO.File]::Open($full, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      Write-ZipEntry $zip '[Content_Types].xml' $types $when
      Write-ZipEntry $zip '_rels/.rels' $pkgRels $when
      Write-ZipEntry $zip 'word/document.xml' $docXml $when
      Write-ZipEntry $zip 'word/_rels/document.xml.rels' $rels $when
      if ($ctx.PictureRel) { Write-ZipEntry $zip 'word/media/image1.png' ([Convert]::FromBase64String($script:PictureBase64)) $when }
      Write-ZipEntry $zip 'word/styles.xml' $script:StylesXml $when
      Write-ZipEntry $zip 'word/settings.xml' $script:SettingsXml $when
      if ($ctx.UsesLists) { Write-ZipEntry $zip 'word/numbering.xml' $script:NumberingXml $when }
      Write-ZipEntry $zip 'docProps/core.xml' $core $when
      Write-ZipEntry $zip 'docProps/app.xml' $app $when
    } finally { $zip.Dispose() }
  } finally { $fs.Dispose() }
  [System.IO.File]::SetLastWriteTimeUtc($full, $utc)
}

function New-CorruptDocx {
  param([Parameter(Mandatory = $true)][string]$Path, [DateTime]$Time = [DateTime]::UtcNow, [switch]$Force)
  $full = Assert-NewFile $Path $Force
  $bytes = New-Object byte[] 200
  for ($k = 0; $k -lt 200; $k++) { $bytes[$k] = [byte](($k * 37 + 11) % 256) }
  [System.IO.File]::WriteAllBytes($full, $bytes)
  [System.IO.File]::SetLastWriteTimeUtc($full, $Time.ToUniversalTime())
}

function New-WordLockFile {
  param([Parameter(Mandatory = $true)][string]$Path, [switch]$Force)
  if (-not [System.IO.Path]::GetFileName($Path).StartsWith('~$')) { throw "New-WordLockFile: the name must start with ~`$ ($Path)" }
  $full = Assert-NewFile $Path $Force
  # Word's owner file: the length of the user name, the name, padding; 162 bytes in all
  $bytes = New-Object byte[] 162
  $name = [System.Text.Encoding]::ASCII.GetBytes('Test Author')
  $bytes[0] = [byte]$name.Length
  [Array]::Copy($name, 0, $bytes, 1, $name.Length)
  for ($k = 1 + $name.Length; $k -lt 54; $k++) { $bytes[$k] = 0x20 }
  [System.IO.File]::WriteAllBytes($full, $bytes)
}

# A made-up photo: a plain background with a darker head-and-shoulders shape in the upper half, so a
# test can tell top from bottom (the head is near the top). -Orientation n adds the camera's rotation
# flag (EXIF 0x0112): 6 means "turn 90 degrees clockwise to show it upright".
function New-TestPhoto {
  param([Parameter(Mandatory = $true)][string]$Path, [int]$Width = 300, [int]$Height = 400, [DateTime]$Time = [DateTime]::UtcNow,
        [int]$Orientation = 0, [switch]$Png, [switch]$Force)
  Add-Type -AssemblyName System.Drawing
  $full = Assert-NewFile $Path $Force
  $bmp = New-Object System.Drawing.Bitmap($Width, $Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.Clear([System.Drawing.Color]::FromArgb(214, 196, 168))
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 52, 40))
    $r = [int]([Math]::Min($Width, $Height) / 6)
    $g.FillEllipse($brush, [int]($Width / 2 - $r), [int]($Height * 0.12), 2 * $r, 2 * $r)
    $g.FillRectangle($brush, [int]($Width / 2 - 2 * $r), [int]($Height * 0.12 + 2.3 * $r), 4 * $r, $Height)
    $brush.Dispose()
  } finally { $g.Dispose() }
  try {
    if ($Orientation -gt 0) {
      $pi = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject([System.Drawing.Imaging.PropertyItem])
      $pi.Id = 0x0112; $pi.Type = 3; $pi.Len = 2; $pi.Value = [byte[]]@([byte]$Orientation, 0)
      $bmp.SetPropertyItem($pi)
    }
    if ($Png) { $bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png) }
    else {
      $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
      $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
      $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]90)
      $bmp.Save($full, $codec, $ep)
    }
  } finally { $bmp.Dispose() }
  [System.IO.File]::SetLastWriteTimeUtc($full, $Time.ToUniversalTime())
}

# The width and height of a picture file (JPEG, PNG ...), as Windows reads it.
function Get-PictureSize([string]$Path) {
  Add-Type -AssemblyName System.Drawing
  $fs = [System.IO.File]::OpenRead($Path)
  try {
    $img = [System.Drawing.Image]::FromStream($fs)
    try { return @($img.Width, $img.Height, ($img.PropertyIdList -contains 0x0112)) } finally { $img.Dispose() }
  } finally { $fs.Dispose() }
}

Export-ModuleMember -Function New-TestDocx, New-CorruptDocx, New-WordLockFile, Get-TestPicture, New-TestPhoto, Get-PictureSize
