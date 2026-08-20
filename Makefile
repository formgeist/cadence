# Command Line Tools ships lib_TestingInterop.dylib outside the default linker
# search path, so `swift test` cannot link without being told where it is.
# Remove this once a full Xcode is installed.
TESTING_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS  := -Xlinker -L$(TESTING_LIB) -Xlinker -rpath -Xlinker $(TESTING_LIB)

SNAPSHOT_DIR ?= Snapshots

.PHONY: build test run shots clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

run:
	swift run Cadence

## Render every screen against PreviewData for design review.
shots:
	swift run Cadence --snapshot $(SNAPSHOT_DIR)

clean:
	swift package clean
