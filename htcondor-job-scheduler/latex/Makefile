# Build the report.
#
# pdflatex via latexmk. The build host has no xelatex and no biber, so the
# document deliberately avoids fontspec and biblatex-with-biber; see preamble.tex.
# Intermediates land in build/ (set in latexmkrc), so the source tree stays clean.

.PHONY: all watch clean distclean

all:
	latexmk -pdf main.tex

# Rebuild on every save. Useful while editing a chapter.
watch:
	latexmk -pdf -pvc main.tex

# Remove intermediates, keep the PDF.
clean:
	latexmk -c

# Remove everything, PDF included.
distclean:
	latexmk -C
