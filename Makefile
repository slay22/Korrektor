# Korrektor — on-device proofreading for German, English, French and Spanish
#
# `make` builds everything, `make install` puts the CLI and the app in place.

DEVELOPER ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR := $(DEVELOPER)

PREFIX ?= $(HOME)/.local
APPLICATIONS ?= $(HOME)/Applications

.PHONY: all build test install app cli clean run live-test

all: build

build: cli app
	@echo "Fertig."

cli:
	swift build -c release --product korrektor
	@./.build/release/korrektor --version >/dev/null || \
		{ echo "CLI broke: the app product must not be called 'Korrektor' (case-insensitive collision)."; exit 1; }

app:
	./Scripts/build-app.sh release

test:
	swift test

# The live test talks to the real model and takes a few seconds.
live-test:
	KORREKTOR_LIVE=1 swift test --filter LiveProofreaderTests

install: cli app
	mkdir -p "$(PREFIX)/bin"
	cp .build/release/korrektor "$(PREFIX)/bin/korrektor"
	@echo "CLI:  $(PREFIX)/bin/korrektor"
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; *) echo "Hinweis: $(PREFIX)/bin ist nicht im PATH.";; esac
	mkdir -p "$(APPLICATIONS)"
	rm -rf "$(APPLICATIONS)/Korrektor.app"
	cp -R build/Korrektor.app "$(APPLICATIONS)/Korrektor.app"
	@echo "App:  $(APPLICATIONS)/Korrektor.app"

run: build
	open build/Korrektor.app

clean:
	swift package clean
	rm -rf build
