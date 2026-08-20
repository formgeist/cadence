# Command Line Tools ships lib_TestingInterop.dylib outside the default linker
# search path, so `swift test` cannot link without being told where it is.
# Remove this once a full Xcode is installed.
TESTING_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS  := -Xlinker -L$(TESTING_LIB) -Xlinker -rpath -Xlinker $(TESTING_LIB)

SNAPSHOT_DIR ?= Snapshots

.PHONY: build test run app shots scan audio-check clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

run:
	swift run Cadence

## Assemble a real, signed, sandboxed Cadence.app — no Xcode required.
##   make app            sandboxed, ad-hoc signed
##   make app SANDBOX=0  to compare behaviour without the sandbox
app:
	@mkdir -p build
	@SANDBOX=$(or $(SANDBOX),1) CONFIG=$(or $(CONFIG),debug) ./Scripts/make-app.sh

## Answer PLAN.md §3: can a sandboxed build set the output sample rate?
audio-check: app
	@./build/Cadence.app/Contents/MacOS/Cadence --audio-check --switch-rates

## Render every screen against PreviewData for design review.
shots:
	swift run Cadence --snapshot $(SNAPSHOT_DIR)

## Scan a folder and print the resulting library, without opening a window.
##   make scan FOLDER=~/Music/FLAC [LIBRARY=/tmp/scratch.sqlite]
scan:
	swift run Cadence --scan $(FOLDER) $(if $(LIBRARY),--library $(LIBRARY),) $(if $(TRACKS),--tracks,)

clean:
	swift package clean
