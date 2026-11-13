# Command Line Tools ships lib_TestingInterop.dylib outside the default linker
# search path, so `swift test` cannot link without being told where it is.
# Remove this once a full Xcode is installed.
TESTING_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS  := -Xlinker -L$(TESTING_LIB) -Xlinker -rpath -Xlinker $(TESTING_LIB)

SNAPSHOT_DIR ?= Snapshots

# Git-ignored, and absent on a fresh checkout. Every build target depends on it
# so `make …` generates an empty stub before SwiftPM compiles the app target.
CREDENTIALS := Sources/Cadence/LastFMCredentials.swift Sources/Cadence/SpotifyCredentials.swift

.PHONY: build test run app dmg shots scan serve audio-check a11y bench clean

Sources/Cadence/LastFMCredentials.swift:
	@./Scripts/gen-lastfm-credentials.sh

Sources/Cadence/SpotifyCredentials.swift:
	@./Scripts/gen-spotify-credentials.sh

build: $(CREDENTIALS)
	swift build

test: $(CREDENTIALS)
	swift test $(TEST_FLAGS)

run: $(CREDENTIALS)
	swift run Cadence

## Assemble a real, signed, sandboxed Cadence.app — no Xcode required.
##   make app            sandboxed, ad-hoc signed
##   make app SANDBOX=0  to compare behaviour without the sandbox
app: $(CREDENTIALS)
	@mkdir -p build
	@SANDBOX=$(or $(SANDBOX),1) CONFIG=$(or $(CONFIG),debug) ./Scripts/make-app.sh

## Package a release Cadence.app as a drag-to-install disk image.
##   make dmg            build/Cadence-<version>.dmg, sandboxed, ad-hoc signed
dmg: CONFIG ?= release
dmg: app
	@./Scripts/make-dmg.sh

## Answer PLAN.md §3: can a sandboxed build set the output sample rate?
audio-check: app
	@./build/Cadence.app/Contents/MacOS/Cadence --audio-check --switch-rates

## Print the accessibility tree for each screen, flagging silent controls.
a11y: $(CREDENTIALS)
	@swift run Cadence --a11y

## Measure the store and scrolling against a synthetic library.
##   make bench [TRACKS=30000]
bench: $(CREDENTIALS)
	@swift run -c release Cadence --bench --tracks $(or $(TRACKS),30000) --with-artwork

## Render every screen against PreviewData for design review.
shots: $(CREDENTIALS)
	swift run Cadence --snapshot $(SNAPSHOT_DIR)

## Scan a folder and print the resulting library, without opening a window.
##   make scan FOLDER=~/Music/FLAC [LIBRARY=/tmp/scratch.sqlite]
scan: $(CREDENTIALS)
	swift run Cadence --scan $(FOLDER) $(if $(LIBRARY),--library $(LIBRARY),) $(if $(TRACKS),--tracks,)

## Run the library server on 127.0.0.1, for curl. Debug builds only. Needs an
## API key in CADENCE_DEV_API_KEY — see docs/library-server.md.
##   make serve [LIBRARY=/tmp/scratch.sqlite]
serve: $(CREDENTIALS)
	swift run Cadence --serve $(if $(LIBRARY),--library $(LIBRARY),)

clean:
	swift package clean
