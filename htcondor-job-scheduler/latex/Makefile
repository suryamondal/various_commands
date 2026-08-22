# Build the HTCondor pool report.
#
# Engine is pdflatex via latexmk (see latexmkrc). The build host has no xelatex
# and no biber, so the document deliberately avoids fontspec and
# biblatex-with-biber - do not "modernise" the preamble without checking those
# are installed first.
#
# Intermediates land in $(BUILD)/, set in latexmkrc, so the source tree stays
# clean and .gitignore only has to exclude one directory.
#
#   make            build the PDF
#   make watch      rebuild continuously on save
#   make view       build, then open the PDF
#   make check      the checks that matter: warnings, refs, and sanitisation
#   make sanitise   leak scan only - hostnames, addresses, credentials
#   make strict     build and FAIL on any LaTeX warning (use in CI)
#   make stats      page count, word count, per-chapter line counts
#   make clean      remove intermediates, keep the PDF
#   make distclean  remove everything including the PDF

MAIN      := main
BUILD     := build
PDF       := $(BUILD)/$(MAIN).pdf
LOG       := $(BUILD)/$(MAIN).log
SOURCES   := $(MAIN).tex preamble.tex $(wildcard chapters/*.tex) $(wildcard appendix/*.tex)

LATEXMK   := latexmk -pdf
VIEWER    := $(shell command -v xdg-open || command -v open)


.PHONY: all watch view check sanitise strict stats clean distclean help

all: $(PDF)

$(PDF): $(SOURCES) latexmkrc
	$(LATEXMK) $(MAIN).tex

# -pvc watches the sources and rebuilds on every save. Ctrl-C to stop.
watch:
	$(LATEXMK) -pvc $(MAIN).tex

view: $(PDF)
	@if [ -n "$(VIEWER)" ]; then $(VIEWER) $(PDF); \
	else echo "no xdg-open/open found; PDF is at $(PDF)"; fi

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
# A clean build is not the same as a correct one. Undefined references still
# produce a PDF - with "??" where the number should be - so they are checked
# explicitly rather than trusted to surface.
# `clean` removes the log this reads, and an up-to-date PDF means latexmk will
# not regenerate it - so force a build when the log is absent.
check: $(PDF) sanitise
	@test -f $(LOG) || $(LATEXMK) -g $(MAIN).tex >/dev/null
	@echo "== LaTeX warnings =="
	@grep -c "LaTeX Warning" $(LOG) | xargs printf "   %s warning(s)\n"
	@grep "LaTeX Warning" $(LOG) || true
	@echo "== undefined references =="
	@if grep -q "undefined" $(LOG); then grep "undefined" $(LOG); \
	else echo "   none"; fi
	@echo "== overfull boxes wider than 20pt =="
	@grep -oE "Overfull \\\\hbox \(([0-9.]+)pt" $(LOG) 2>/dev/null \
	  | grep -oE "[0-9.]+" | awk '$$1>20' | wc -l | xargs printf "   %s\n"

# The repo's rule is machine classes only. Run this before every commit.
# The check lives in tools/sanitise.sh so it can scan `git ls-files` - including
# this Makefile. Machine names are read from the untracked condor-host-list,
# never listed in a tracked file.
sanitise:
	@echo "== sanitisation: hostnames, addresses, credentials =="
	@../tools/sanitise.sh

# For CI: any warning at all is a failure.
strict:
	@$(LATEXMK) $(MAIN).tex >/dev/null
	@$(MAKE) --no-print-directory sanitise
	@n=$$(grep -c "LaTeX Warning" $(LOG) || true); \
	if [ "$$n" -ne 0 ]; then \
	  echo "FAIL: $$n LaTeX warning(s)"; grep "LaTeX Warning" $(LOG); exit 1; \
	else echo "OK: no warnings"; fi

stats: $(PDF)
	@printf "pages   : %s\n" "$$(grep -oE 'Output written.*\(([0-9]+) pages' $(LOG) | grep -oE '[0-9]+ pages' | tail -1)"
	@printf "size    : %s\n" "$$(du -h $(PDF) | cut -f1)"
	@if command -v pdftotext >/dev/null; then \
	  printf "words   : %s\n" "$$(pdftotext $(PDF) - | wc -w)"; fi
	@echo "sources :"
	@wc -l $(SOURCES) | sed 's/^/   /'

clean:
	$(LATEXMK) -c

distclean:
	$(LATEXMK) -C
	@rm -rf $(BUILD)

help:
	@sed -n '/^#   make/s/^#   //p' Makefile
