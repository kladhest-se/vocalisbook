# VocalisBook — three clients, one repository.
#
# Every verb is prefixed with a platform: `make ios-run`, `make tvos-test`,
# `make macos-build`. The unprefixed ones act on everything that is not an app:
# `make packages` builds and tests Core and all three Platform packages.
#
# vocalisbook-tools/tests/app.sh and the publish checks call these rather than
# duplicating xcodebuild invocations.

.PHONY: help packages core platforms test clean 	
	ios-project ios-build ios-test ios-run ios-install ios-destinations \
	macos-project macos-build macos-test macos-run macos-install macos-destinations \
	tvos-project tvos-build tvos-test tvos-run tvos-install tvos-destinations \
	devices teams ios-device tvos-device \
	ios-sim-install tvos-sim-install ipados-sim-install \
	ipados-run ipados-install ipados-test ipados-destinations ipados-device \
	ios-open ipados-open macos-open tvos-open core-open

help:
	@echo "  make packages          Core and all three Platform packages"
	@echo "  make build             packages, then compile all three apps"
	@echo "  make test              build, then every app's tests on a simulator"
	@echo ""
	@echo "  make ios-build         does the iOS app compile"
	@echo "  make ios-test          the iOS app tests, on a simulator"
	@echo "  make ios-run           build and launch on a simulator, logs here"
	@echo "  make ios-install       build signed and install on the device in DEVICE"
	@echo "  make ios-open          generate and open the project in Xcode"
	@echo "  make ios-destinations  what is installed to run on"
	@echo ""
	@echo "  the same three verbs exist as ipados-*, macos-* and tvos-*"
	@echo ""
	@echo "  make devices           attached iPhones, iPads and Apple TVs"
	@echo "  make teams             signing teams this Mac can use"
	@echo ""
	@echo "  install needs TEAM_ID and DEVICE, both from the two lists above:"
	@echo "    make ipados-install DEVICE=00008132-… TEAM_ID=ABCDE12345"
	@echo ""
	@echo "  make clean             remove generated projects and build products"

# Core declares every platform, so it builds for the host like any package and
# its tests run without a simulator. This is the fast answer when the thing you
# broke is not in the app layer, which it usually is not.
core:
	@for pkg in Core/PlexKit Core/Audiobooks Platform/Shared; do \
		echo "--- $$pkg"; \
		( cd $$pkg && swift build && if [ -d Tests ]; then swift test; fi ) || exit 1; \
	done

# Each Platform package declares one platform, and `swift build` always targets
# the host — so only the macOS one can be built that way. The other two go
# through xcodebuild against the matching simulator SDK. Building the tvOS
# package on a Mac otherwise fails with
#
#   error: the library 'Platform' requires macos 10.13, but depends on the
#   product 'PlexKit' which requires macos 14.0
#
# which reads as a version mismatch and is really a wrong-platform one.
#
# The scheme name is discovered rather than assumed. When xcodebuild opens a
# package it invents a workspace named after the *directory*, and the scheme it
# generates does not necessarily match the product. `-scheme Platform` worked
# only while the folders were called Platform; renaming them to satisfy SwiftPM's
# package identity broke it with
#
#   error: The workspace named "iOS" does not contain a scheme named "Platform"
#
# Asking beats guessing, and if the answer is empty the list is printed rather
# than a bare failure.
define build_platform_package
set -e; cd Platform/$(1); \
scheme=$$(xcodebuild -list 2>/dev/null | awk '/Schemes:/{f=1;next} f && NF {print $$1; exit}'); \
if [ -z "$$scheme" ]; then \
	echo "Platform/$(1): xcodebuild lists no schemes"; \
	xcodebuild -list || true; \
	exit 1; \
fi; \
echo "--- Platform/$(1) (scheme $$scheme, $(2))"; \
xcodebuild build -scheme "$$scheme" -destination '$(2)' -quiet
endef

platforms:
	@echo "--- Platform/macOS"
	@cd Platform/macOS && swift build && if [ -d Tests ]; then swift test; fi
	@$(call build_platform_package,iOS,generic/platform=iOS Simulator)
	@$(call build_platform_package,tvOS,generic/platform=tvOS Simulator)

packages: core platforms

# Compiles everything, boots nothing.
#
# The `generic/platform=...` destinations need no installed simulator and start
# no device, so this catches every compile error without a simulator appearing on
# screen. It is what the publish check runs: publishing has to be quick and must
# never launch an app.
build: packages ios-build macos-build tvos-build

# The slow one. `xcodebuild test` installs the test host on a simulator and runs
# it, which means booting a device and waiting — minutes, and occasionally a
# stall. Worth it deliberately; not worth it before every push.
test: packages ios-test macos-test tvos-test

clean:
	@rm -rf Apps/*/VocalisBook.xcodeproj Apps/*/.build \
		Core/*/.build Platform/*/.build
	@echo "removed generated projects and build products"

IOS_PROJECT   := Apps/iOS/VocalisBook.xcodeproj
MACOS_PROJECT := Apps/macOS/VocalisBook.xcodeproj
TVOS_PROJECT  := Apps/tvOS/VocalisBook.xcodeproj

# The newest installed iPhone, by udid.
#
# By name is ambiguous the moment two runtimes are installed: the same device
# then exists twice and xcodebuild refuses to choose. No model is written down
# here on purpose — a name pinned in a Makefile goes stale the moment Apple stops
# shipping it, and the failure when it does is a wall of destinations rather than
# an answer.
#
#   make ios-run SIM='iPhone 17 Pro'
#
# stderr is discarded on both halves: with no Xcode, SIM_ID comes back empty and
# the guard on each target prints something useful. A python traceback in the
# middle of a make run is noise that explains nothing.
IOS_SIM ?=
# The iPad, which is the same app on a different destination.
#
# There is no iPadOS SDK and no separate scheme: `TARGETED_DEVICE_FAMILY = 1,2`
# means one binary runs on both, and the only thing that differs is what it is
# installed on. So these targets exist to *see* the iPad layouts — the split
# views, the larger covers, the player on its side — not because there is a
# second product to build.
#
# Same selection as the iPhone's, filtered to iPads and preferring the
# highest-numbered model, which is the one most likely to be current.
IPAD_DEVICE ?= $(DEVICE)
IPAD_SIM_ID = $(shell xcrun simctl list devices available --json 2>/dev/null \
	| python3 -c "import json,sys,re; \
d=json.load(sys.stdin)['devices']; \
c=[x for k,v in d.items() if 'iOS' in k for x in v if 'iPad' in x['name']]; \
n='$(IPAD_SIM)'; c=[x for x in c if x['name']==n] if n else c; \
c.sort(key=lambda x:[int(t) for t in re.findall(r'\d+',x['name'])] or [0]); \
print(c[-1]['udid'] if c else '')" 2>/dev/null)

IOS_SIM_ID = $(shell xcrun simctl list devices available --json 2>/dev/null \
	| python3 -c "import json,sys,re; \
d=json.load(sys.stdin)['devices']; \
c=[x for k,v in d.items() if 'iOS' in k for x in v if 'iPhone' in x['name']]; \
n='$(IOS_SIM)'; c=[x for x in c if x['name']==n] if n else c; \
c.sort(key=lambda x:[int(t) for t in re.findall(r'\d+',x['name'])] or [0]); \
print(c[-1]['udid'] if c else '')" 2>/dev/null)

define IOS_APP_INFO
settings=$$(xcodebuild -project $(IOS_PROJECT) -scheme VocalisBook \
	-sdk iphonesimulator -configuration Debug -showBuildSettings 2>/dev/null); \
app="$$(echo "$$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/VocalisBook.app"; \
bundle=$$(echo "$$settings" | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER /{print $$2; exit}'); \
test -d "$$app" || { echo "No app at $$app - run make ios-build first"; exit 1; }
endef

# Installing on hardware, which is a different exercise from the simulator.
#
# `ios-install` and `tvos-install` speak to `simctl`, which only knows about
# simulators — a build that succeeds there is not a build that can run on a
# phone. Three things are different:
#
#   * the SDK is `iphoneos` rather than `iphonesimulator`
#   * the app must be *signed*, which needs an Apple ID and a team
#   * installing goes through `devicectl`, not `simctl`
#
# There is no signing configuration in `Config/`, deliberately: a team id is
# personal, it does not belong in a repository, and hardcoding one makes the
# project uncloneable by anybody else. It is passed in instead.
#
#   make ios-device TEAM_ID=ABCDE12345 DEVICE=00008130-000...
#
# A free Apple ID works. Its profiles expire after seven days, which is fine for
# a client you rebuild anyway and worth knowing before it stops launching on a
# Tuesday.
#
# No macOS equivalent: the Mac app runs on the machine that builds it, so
# `macos-run` is already the device case.
# Found rather than asked for, when it can be.
#
# A signing certificate carries the team id in its subject, as the organisational
# unit — so if Xcode has ever set this Mac up for development, the answer is
# already in the keychain and there is no reason to make somebody go and look it
# up. Passing `TEAM_ID=` explicitly still wins, which matters if you belong to
# more than one team.
#
# `find-identity` was the first suggestion here and it is the wrong tool: it
# lists identities and the code in its parentheses is the certificate's, which is
# the team id often enough to be misleading and not always.
TEAM_ID ?= $(shell security find-certificate -a -c "Apple Development" -p 2>/dev/null \
	| openssl x509 -noout -subject 2>/dev/null \
	| sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)

# One name for all of them: DEVICE.
#
# There were three — IOS_DEVICE, IPAD_DEVICE, TVOS_DEVICE — and the verb already
# says which kind of device it wants, so the prefix was a second way of saying
# the same thing and a first way of getting it wrong. `make devices` prints ids
# for all three kinds in one list; whichever you paste, `DEVICE` takes it.
#
# The old names still work. Somebody with them in a shell history or a note
# should not have to find out they were renamed.
DEVICE ?=

IOS_DEVICE  ?= $(DEVICE)
TVOS_DEVICE ?= $(DEVICE)

# The identifier has to belong to a device of the right kind.
#
# Passing a phone's identifier to `tvos-device` fails inside xcodebuild with a
# wall of available destinations and no hint that the id belongs to a phone —
# which is exactly the mistake somebody makes copying from two rows of output.
#
# Checked against the platform devicectl reports, so the message names both what
# was asked for and what was given.
define REQUIRE_PLATFORM
xcrun devicectl list devices --json-output /dev/stdout --quiet 2>/dev/null \
	| python3 -c "import json,sys; \
d=json.load(sys.stdin).get('result',{}).get('devices',[]); \
m={x.get('hardwareProperties',{}).get('udid'): \
   (x.get('hardwareProperties',{}).get('platform','?'), \
    x.get('deviceProperties',{}).get('name','?')) for x in d}; \
p,n=m.get('$(1)',(None,None)); \
msg=None if p=='$(2)' else ('  %s is %s (%s), not a $(2) device - make devices' % ('$(1)', n, p) \
                            if p else '  $(1) is not an attached device - make devices'); \
print(msg, file=sys.stderr) if msg else None; \
sys.exit(1 if msg else 0)"
endef

define REQUIRE_TEAM
test -n "$(TEAM_ID)" || { \
	echo "No Apple Development certificate in the keychain, so no team id to find."; \
	echo ""; \
	echo "Open one of the projects in Xcode once and let it sign in — Xcode"; \
	echo "creates the certificate. A free Apple ID is enough."; \
	echo ""; \
	echo "Or pass it directly:  make $@ TEAM_ID=ABCDE12345"; \
	exit 1; }
endef

# `-allowProvisioningDeviceRegistration`, beside `-allowProvisioningUpdates`.
#
# A development profile only covers devices registered to the account, and a Mac
# is a device like any other here: "Tommy's MacBook isn't registered in your
# developer account" followed by "no profiles were found", which reads like a
# signing problem and is a device-list problem.
#
# Xcode's own UI offers to register it and xcodebuild will not without being
# asked. Asked here, on every verb that signs — a new phone or Apple TV hits the
# same wall the first time it is used.
#
# It spends a device slot, of which an account has a hundred per type per year.
# Worth knowing before pointing this at a lab full of machines; irrelevant for
# the handful somebody actually owns.

# The identifier a build can actually use.
#
# `devicectl list devices` prints a CoreDevice UUID. `xcodebuild -destination
# id=` wants the hardware UDID, and refuses the other one with "no available
# devices matched the request" while listing the UDID it would have accepted —
# two identifiers for one device, and the plain listing showed the wrong one.
#
# `devicectl` accepts either, so the UDID is the one to print: it works for the
# build and for the install.
# Every team this Mac can sign for.
#
# `TEAM_ID` is guessed from the first Apple Development certificate in the
# keychain, which is right for somebody in one team and silently wrong for
# anybody in two — the build signs with whichever certificate sorted first and
# says so in one line nobody reads. This lists them all, so `TEAM_ID=` can be
# passed deliberately.
#
# Read from the certificates rather than from Xcode's account list: a team with
# no certificate on this Mac cannot sign anything here, so listing it would be
# offering a choice that does not work.
teams:
	@echo "Teams this Mac holds a signing certificate for:"
	@security find-identity -v -p codesigning 2>/dev/null \
		| grep -oE '"[^"]+"' \
		| sort -u \
		| python3 -c "import re,sys; \
rows=[]; \
[rows.append((m.group(2), m.group(1))) for line in sys.stdin \
  for m in [re.match(r'\"(.+?) \((\w{10})\)\"', line.strip())] if m]; \
print('\n'.join('  %-12s %s' % r for r in sorted(set(rows))) if rows else '  none found')"
	@echo ""
	@echo "Pass one as TEAM_ID=<id>. Currently guessed: $(if $(TEAM_ID),$(TEAM_ID),none)"

devices:
	@echo "Signing team: $(if $(TEAM_ID),$(TEAM_ID),none found - see make teams)"
	@echo ""
	@echo "Attached devices. Pass one as DEVICE=<id>:"
	@xcrun devicectl list devices --json-output /dev/stdout --quiet 2>/dev/null \
		| python3 -c "import json,sys; \
d=json.load(sys.stdin).get('result',{}).get('devices',[]); \
rows=[(x.get('deviceProperties',{}).get('name','?'), \
       x.get('hardwareProperties',{}).get('udid','?'), \
       x.get('hardwareProperties',{}).get('marketingName','')) for x in d]; \
print('\n'.join('  %-26s %-26s %s' % r for r in rows) if rows else '  none attached')" \
		2>/dev/null || echo "  devicectl is missing - it ships with Xcode 15 and later"

# No `ios-project` prerequisite: make builds prerequisites before running any
# recipe, so with one the project would be regenerated and only then would you be
# told which variable is missing. Ask first, work second.
ios-device:
	@$(REQUIRE_TEAM)
	@test -n "$(IOS_DEVICE)" || { echo "Set IOS_DEVICE. make devices"; exit 1; }
	@echo "Signing with team $(TEAM_ID)"
	@$(MAKE) ios-project
	@$(call REQUIRE_PLATFORM,$(IOS_DEVICE),iOS)
	@set -e; $(call bump_build,iOS); \
	xcodebuild build -project $(IOS_PROJECT) -scheme VocalisBook \
		-destination 'platform=iOS,id=$(IOS_DEVICE)' \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration \
		DEVELOPMENT_TEAM=$(TEAM_ID) CODE_SIGN_STYLE=Automatic \
		CURRENT_PROJECT_VERSION=$$build; \
	settings=$$(xcodebuild -project $(IOS_PROJECT) -scheme VocalisBook \
		-sdk iphoneos -configuration Debug \
		DEVELOPMENT_TEAM=$(TEAM_ID) -showBuildSettings 2>/dev/null); \
	app="$$(echo "$$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/VocalisBook.app"; \
	test -d "$$app" || { echo "No app at $$app"; exit 1; }; \
	xcrun devicectl device install app --device $(IOS_DEVICE) "$$app"; \
	echo ""; \
	echo "  installed VocalisBook $$version ($$build) — iOS"

# No `tvos-project` prerequisite: make builds prerequisites before running any
# recipe, so with one the project would be regenerated and only then would you be
# told which variable is missing. Ask first, work second.
tvos-device:
	@$(REQUIRE_TEAM)
	@test -n "$(TVOS_DEVICE)" || { echo "Set TVOS_DEVICE. make devices"; exit 1; }
	@echo "Signing with team $(TEAM_ID)"
	@$(MAKE) tvos-project
	@$(call REQUIRE_PLATFORM,$(TVOS_DEVICE),tvOS)
	@set -e; $(call bump_build,tvOS); \
	xcodebuild build -project $(TVOS_PROJECT) -scheme VocalisBook \
		-destination 'platform=tvOS,id=$(TVOS_DEVICE)' \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration \
		DEVELOPMENT_TEAM=$(TEAM_ID) CODE_SIGN_STYLE=Automatic \
		CURRENT_PROJECT_VERSION=$$build; \
	settings=$$(xcodebuild -project $(TVOS_PROJECT) -scheme VocalisBook \
		-sdk appletvos -configuration Debug \
		DEVELOPMENT_TEAM=$(TEAM_ID) -showBuildSettings 2>/dev/null); \
	app="$$(echo "$$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/VocalisBook.app"; \
	test -d "$$app" || { echo "No app at $$app"; exit 1; }; \
	xcrun devicectl device install app --device $(TVOS_DEVICE) "$$app"; \
	echo ""; \
	echo "  installed VocalisBook $$version ($$build) — tvOS"

ios-project:
	@command -v xcodegen >/dev/null || { echo "xcodegen is missing - brew install xcodegen"; exit 1; }
	@cd Apps/iOS && xcodegen generate

# Opening a port in Xcode.
#
# Generates first, because the project is not committed — `open` on a path that
# does not exist yet fails with a message about the file rather than about the
# missing step, which is a confusing way to learn how this repository works.
#
ios-open: ios-project
	@open $(IOS_PROJECT)

# The same project. There is one iOS target and Xcode opens it the same way
# whichever device you pick from the scheme menu — but reaching for
# `ipados-open` after using `ipados-run` is what somebody will do, and a missing
# verb reads as a missing feature. Same reasoning as `ipados-device`.
ipados-open: ios-open

macos-open: macos-project
	@open $(MACOS_PROJECT)

tvos-open: tvos-project
	@open $(TVOS_PROJECT)

# The packages, for when the app layer is not what you are working on. Xcode
# opens a Package.swift as a project of its own.
core-open:
	@open Core/Audiobooks/Package.swift

# Build numbers, one counter per port.
#
# `Apps/<port>/build.number` holds the last number used. `next_build` bumps it
# and echoes the new value, which is passed to xcodebuild as
# CURRENT_PROJECT_VERSION — so a build number means "the nth build of this port
# on this machine", which is what a build number is for.
#
# Per port because the ports ship separately: the television's build 40 has
# nothing to do with the phone's, and a shared counter would imply otherwise.
#
# Not derived from git. A commit count changes when somebody rebases and stays
# still while you build twenty times chasing one bug, which is backwards.
# Bumps the counter and leaves the new number in `$$build`.
#
# A shell fragment rather than a `$$(shell …)` expansion, so a recipe can *use*
# the number as well as pass it: printing it meant calling the old version twice,
# which bumped it twice and printed the wrong one.
#
# Also reads the version beside it, so a summary can say "1.0.0 (42)" — the form
# a version is written in everywhere on Apple's platforms.
define bump_build
f="Apps/$(1)/build.number"; \
build=$$(( $$(cat "$$f" 2>/dev/null || echo 0) + 1 )); \
echo $$build > "$$f"; \
version=$$(awk -F' = ' '/^MARKETING_VERSION/{print $$2; exit}' Config/$(1).xcconfig)
endef

ios-build: ios-project
	@set -e; $(call bump_build,iOS); \
	xcodebuild build -project $(IOS_PROJECT) -scheme VocalisBook \
		-sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
		CURRENT_PROJECT_VERSION=$$build; \
	echo "  built VocalisBook $$version ($$build) — iOS"

ios-test: ios-project
	@test -n "$(IOS_SIM_ID)" || { echo "No iPhone simulator installed. make ios-destinations"; exit 1; }
	@xcodebuild test -project $(IOS_PROJECT) -scheme VocalisBook -destination 'id=$(IOS_SIM_ID)'

# `-install` means a device; `-run` means a simulator.
#
# It was the other way round: `-install` put the app on a simulator and
# `-device` reached hardware, so `make ios-install DEVICE=…` built for a
# simulator and ignored the id. The verbs now say what they do — install goes to
# the thing in your hand, run starts it on this Mac.
ios-install: ios-device
tvos-install: tvos-device
ipados-install: ipados-device

# The simulator halves, which only `-run` uses now.
ios-sim-install: ios-build
	@test -n "$(IOS_SIM_ID)" || { echo "No iPhone simulator installed. make ios-destinations"; exit 1; }
	@set -e; $(IOS_APP_INFO); \
	xcrun simctl boot $(IOS_SIM_ID) 2>/dev/null || true; \
	xcrun simctl install $(IOS_SIM_ID) "$$app"; \
	echo "installed $$bundle on $(IOS_SIM_ID)"

# Launches with the console attached, so print and os_log output land in this
# terminal rather than only in Console.app. Ctrl-C detaches; the app keeps
# running on the simulator.
ios-run: ios-sim-install
	@set -e; $(IOS_APP_INFO); \
	open -a Simulator; \
	xcrun simctl launch --console-pty $(IOS_SIM_ID) "$$bundle"

# The iPad verbs. Same project, same scheme, iPad destination.
#
# No `ipados-build`: the build is `ios-build`, byte for byte, and a second name
# for it would suggest there are two binaries to keep in step.
ipados-run: ipados-sim-install
	@set -e; $(IOS_APP_INFO); \
	open -a Simulator; \
	xcrun simctl launch --console-pty $(IPAD_SIM_ID) "$$bundle"

ipados-sim-install: ios-build
	@test -n "$(IPAD_SIM_ID)" || { echo "No iPad simulator installed. make ipados-destinations"; exit 1; }
	@set -e; $(IOS_APP_INFO); \
	xcrun simctl boot $(IPAD_SIM_ID) 2>/dev/null || true; \
	xcrun simctl install $(IPAD_SIM_ID) "$$app"; \
	echo "installed $$bundle on $(IPAD_SIM_ID)"

ipados-test: ios-project
	@test -n "$(IPAD_SIM_ID)" || { echo "No iPad simulator installed. make ipados-destinations"; exit 1; }
	@xcodebuild test -project $(IOS_PROJECT) -scheme VocalisBook -destination 'id=$(IPAD_SIM_ID)'

ipados-destinations:
	@xcrun simctl list devices available | sed -n '/-- iOS/,/^--/p' | grep -i ipad || \
		echo "  no iPad simulators - add one in Xcode > Settings > Components"

# An attached iPad is an iOS device as far as signing and installing go, so this
# is `ios-device` with a different variable name — kept because looking for
# IPAD_DEVICE when installing on an iPad is what somebody will do.
ipados-device:
	@$(REQUIRE_TEAM)
	@test -n "$(IPAD_DEVICE)" || { echo "Set IPAD_DEVICE. make devices"; exit 1; }
	@$(MAKE) ios-device IOS_DEVICE=$(IPAD_DEVICE)

ios-destinations:
	@xcrun simctl list devices available | sed -n '/-- iOS/,/^--/p'

# The newest installed Apple TV, by udid.
#
# By name is ambiguous the moment two runtimes are installed: the same device
# then exists twice and xcodebuild refuses to choose. No model is written down
# here on purpose — a name pinned in a Makefile goes stale the moment Apple stops
# shipping it, and the failure when it does is a wall of destinations rather than
# an answer.
#
#   make tvos-run SIM='Apple TV 4K (3rd generation)'
#
# stderr is discarded on both halves: with no Xcode, SIM_ID comes back empty and
# the guard on each target prints something useful. A python traceback in the
# middle of a make run is noise that explains nothing.
TVOS_SIM ?=
TVOS_SIM_ID = $(shell xcrun simctl list devices available --json 2>/dev/null \
	| python3 -c "import json,sys,re; \
d=json.load(sys.stdin)['devices']; \
c=[x for k,v in d.items() if 'tvOS' in k for x in v if 'Apple TV' in x['name']]; \
n='$(TVOS_SIM)'; c=[x for x in c if x['name']==n] if n else c; \
c.sort(key=lambda x:[int(t) for t in re.findall(r'\d+',x['name'])] or [0]); \
print(c[-1]['udid'] if c else '')" 2>/dev/null)

define TVOS_APP_INFO
settings=$$(xcodebuild -project $(TVOS_PROJECT) -scheme VocalisBook \
	-sdk appletvsimulator -configuration Debug -showBuildSettings 2>/dev/null); \
app="$$(echo "$$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/VocalisBook.app"; \
bundle=$$(echo "$$settings" | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER /{print $$2; exit}'); \
test -d "$$app" || { echo "No app at $$app - run make tvos-build first"; exit 1; }
endef

tvos-project:
	@command -v xcodegen >/dev/null || { echo "xcodegen is missing - brew install xcodegen"; exit 1; }
	@cd Apps/tvOS && xcodegen generate

tvos-build: tvos-project
	@set -e; $(call bump_build,tvOS); \
	xcodebuild build -project $(TVOS_PROJECT) -scheme VocalisBook \
		-sdk appletvsimulator -destination 'generic/platform=tvOS Simulator' \
		CURRENT_PROJECT_VERSION=$$build; \
	echo "  built VocalisBook $$version ($$build) — tvOS"

tvos-test: tvos-project
	@test -n "$(TVOS_SIM_ID)" || { echo "No Apple TV simulator installed. make tvos-destinations"; exit 1; }
	@xcodebuild test -project $(TVOS_PROJECT) -scheme VocalisBook -destination 'id=$(TVOS_SIM_ID)'

tvos-sim-install: tvos-build
	@test -n "$(TVOS_SIM_ID)" || { echo "No Apple TV simulator installed. make tvos-destinations"; exit 1; }
	@set -e; $(TVOS_APP_INFO); \
	xcrun simctl boot $(TVOS_SIM_ID) 2>/dev/null || true; \
	xcrun simctl install $(TVOS_SIM_ID) "$$app"; \
	echo "installed $$bundle on $(TVOS_SIM_ID)"

# Launches with the console attached, so print and os_log output land in this
# terminal rather than only in Console.app. Ctrl-C detaches; the app keeps
# running on the simulator.
tvos-run: tvos-sim-install
	@set -e; $(TVOS_APP_INFO); \
	open -a Simulator; \
	xcrun simctl launch --console-pty $(TVOS_SIM_ID) "$$bundle"

tvos-destinations:
	@xcrun simctl list devices available | sed -n '/-- tvOS/,/^--/p'

define MACOS_APP_INFO
settings=$$(xcodebuild -project $(MACOS_PROJECT) -scheme VocalisBook \
	-configuration Debug -showBuildSettings 2>/dev/null); \
app="$$(echo "$$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/VocalisBook.app"; \
bundle=$$(echo "$$settings" | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER /{print $$2; exit}'); \
test -d "$$app" || { echo "No app at $$app - run make macos-build first"; exit 1; }
endef

macos-project:
	@command -v xcodegen >/dev/null || { echo "xcodegen is missing - brew install xcodegen"; exit 1; }
	@cd Apps/macOS && xcodegen generate

# arm64 only, matching Config/macOS.xcconfig. There is no Intel slice to build,
# so an Intel machine cannot produce this at all — deliberate, and worth failing
# loudly on rather than quietly producing half a binary.
# `CODE_SIGNING_ALLOWED=NO`, because this verb asks one question.
#
# The Mac app gained iCloud entitlements, and an entitlement is a claim only a
# provisioning profile can grant — so a plain compile started demanding a
# profile, a team and a network round trip to Apple, and the check suite failed
# on a machine that was only ever asked "does this build".
#
# Signing belongs to the verbs that produce something to run: `macos-run` and
# `macos-device`. This one produces an answer.
macos-build: macos-project
	@set -e; $(call bump_build,macOS); \
	xcodebuild build -project $(MACOS_PROJECT) -scheme VocalisBook \
		-destination 'platform=macOS,arch=arm64' \
		CODE_SIGNING_ALLOWED=NO \
		CURRENT_PROJECT_VERSION=$$build; \
	echo "  built VocalisBook $$version ($$build) — macOS"

# Unsigned, like `macos-build`, and for the same reason: a test run asks whether
# the code works, not whether Apple would let it talk to iCloud.
#
# The simulator verbs need no such flag — entitlements are not enforced there,
# which is why only the Mac hit this.
macos-test: macos-project
	@xcodebuild test -project $(MACOS_PROJECT) -scheme VocalisBook \
		-destination 'platform=macOS,arch=arm64' \
		CODE_SIGNING_ALLOWED=NO

# ~/Applications rather than /Applications: no sudo, no authentication prompt,
# and the Finder treats it as an applications folder like any other.
#
#   make macos-install APP_DEST=/Applications
APP_DEST ?= $(HOME)/Applications

# Depends on `macos-run`'s build, not `macos-build`'s.
#
# `macos-build` stopped signing when the app gained iCloud entitlements, and an
# unsigned copy in ~/Applications is one that will not launch. Installing a thing
# that cannot run is worse than refusing to install.
macos-install: macos-project
	@$(REQUIRE_TEAM)
	@set -e; $(call bump_build,macOS); \
	xcodebuild build -project $(MACOS_PROJECT) -scheme VocalisBook \
		-destination 'platform=macOS,arch=arm64' \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration \
		DEVELOPMENT_TEAM=$(TEAM_ID) CODE_SIGN_STYLE=Automatic \
		CURRENT_PROJECT_VERSION=$$build; \
	echo "  built VocalisBook $$version ($$build) — macOS"
	@set -e; $(MACOS_APP_INFO); \
	mkdir -p "$(APP_DEST)"; \
	rm -rf "$(APP_DEST)/VocalisBook.app"; \
	cp -R "$$app" "$(APP_DEST)/"; \
	echo "installed to $(APP_DEST)/VocalisBook.app"

# Runs the freshly built app, not the installed copy, so what you are looking at
# is what you just compiled.
# Built again, signed this time.
#
# `macos-build` deliberately does not sign, and an app with iCloud entitlements
# will not launch unsigned — so this cannot just open what that produced.
macos-run: macos-project
	@$(REQUIRE_TEAM)
	@set -e; $(call bump_build,macOS); \
	xcodebuild build -project $(MACOS_PROJECT) -scheme VocalisBook \
		-destination 'platform=macOS,arch=arm64' \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration \
		DEVELOPMENT_TEAM=$(TEAM_ID) CODE_SIGN_STYLE=Automatic \
		CURRENT_PROJECT_VERSION=$$build; \
	echo "  built VocalisBook $$version ($$build) — macOS"
	@set -e; $(MACOS_APP_INFO); \
	open "$$app"

macos-destinations:
	@xcodebuild -project $(MACOS_PROJECT) -scheme VocalisBook -showdestinations 2>/dev/null \
		| sed -n '/Available destinations/,/^$$/p'
