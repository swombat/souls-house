#!/usr/bin/env bash
# Regenerates the synthetic PDFs used by the Field PDF extraction tests.
# Everything in them is made up. Needs Ghostscript (ps2pdf, gs), ImageMagick
# and poppler-utils (pdfunite). The PDFs are committed; this script is the
# record of how they were made.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

page() { # page <text>: one page of native text
  printf '/Helvetica findfont 14 scalefont setfont 72 720 moveto (%s) show showpage\n' "$1"
}

# A grey "scan": text drawn into pixels, so the page has no text layer.
scan_png() { # scan_png <out> <text>
  magick -size 850x1100 xc:white -font DejaVu-Sans -pointsize 28 -fill black \
    -annotate +80+200 "$2" -colorspace Gray -depth 8 "$1"
}

# Text only, two pages.
{ echo '%!PS'; page 'Orchard ledger, page one: apricots and quinces.'; page 'Page two mentions the walnut harvest.'; } > "$work/text.ps"
ps2pdf "$work/text.ps" text_only.pdf

# One scanned page.
scan_png "$work/scan.png" 'Scanned receipt: 3 crates of figs, 42 euros.'
magick "$work/scan.png" -density 100 -units PixelsPerInch scanned_only.pdf

# A blank page.
{ echo '%!PS'; echo 'showpage'; } > "$work/blank.ps"
ps2pdf "$work/blank.ps" "$work/blank.pdf"

# Native heading above a scanned body on the same page.
scan_png "$work/body.png" 'Body text that exists only as pixels.'
magick "$work/body.png" -resize 50% -depth 8 "$work/body.pgm"
{
  echo '%!PS'
  echo '/Helvetica findfont 18 scalefont setfont 72 740 moveto (Quarterly note) show'
  echo 'gsave 72 100 translate 425 550 scale'
  echo '425 550 8 [425 0 0 -550 0 550] currentfile /ASCIIHexDecode filter image'
  tail -c $((425 * 550)) "$work/body.pgm" | od -An -v -tx1 | tr -d ' \n' | fold -w 72
  echo '>'
  echo 'grestore showpage'
} > "$work/heading.ps"
ps2pdf "$work/heading.ps" heading_over_scan.pdf

# Mixed: text page, scanned page, blank page.
pdfunite text_only.pdf scanned_only.pdf "$work/blank.pdf" mixed.pdf

# Needs a password to open.
gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -sOwnerPassword=owner -sUserPassword=user \
  -sOutputFile=encrypted.pdf text_only.pdf
# Opens without a password; only carries permission flags.
gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -sOwnerPassword=owner -dEncryptionR=3 -dKeyLength=128 -dPermissions=-3904 \
  -sOutputFile=permissions_only.pdf text_only.pdf

# Not a PDF at all, despite the name.
printf 'this is not a pdf\n' > broken.pdf
