#!/bin/bash
# SPSE4 documentation build script
#
# Two paths:
#   1. If you have Emacs with org-mode, the canonical source is spse4.org.
#      Run:  emacs --batch spse4.org -f org-latex-export-to-pdf
#      and then hand-merge any layout tweaks into spse4.tex.
#
#   2. If you don't have Emacs, or prefer to skip the Org round trip, the
#      hand-authored spse4.tex is already kept in sync with spse4.org by
#      hand.  Just run pdflatex against it directly.
#
# This script does path (2) by default, because it's the one that always
# works.  Pass --via-org to do path (1) instead.

set -e
cd "$(dirname "$0")"

if [ "$1" = "--via-org" ]; then
    if ! command -v emacs >/dev/null 2>&1; then
        echo "emacs not found; falling back to pdflatex on spse4.tex" >&2
    else
        echo "Exporting spse4.org -> spse4-from-org.pdf via Emacs..."
        emacs --batch spse4.org -f org-latex-export-to-pdf
        echo "Done. See spse4.pdf (generated from org)."
        exit 0
    fi
fi

echo "Running pdflatex on spse4.tex (2 passes for TOC + cross-refs)..."
pdflatex -interaction=nonstopmode -halt-on-error spse4.tex >/dev/null
bibtex spse4 >/dev/null
pdflatex -interaction=nonstopmode -halt-on-error spse4.tex >/dev/null
pdflatex -interaction=nonstopmode -halt-on-error spse4.tex >/dev/null

# Clean up intermediate files, keep the PDF
rm -f spse4.aux spse4.log spse4.out spse4.toc spse4.bbl spse4.blg

echo "Done. Output: spse4.pdf ($(stat -c%s spse4.pdf 2>/dev/null || stat -f%z spse4.pdf) bytes)"
