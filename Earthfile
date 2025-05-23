VERSION --arg-scope-and-set --global-cache 0.8

ARG --global go_version = 1.24
ARG --global node_version = 18
ARG --global rust_version = 1.79
ARG --global golangci_lint_version = 1.64.6

ARG --global go_builder_image = "golang:${go_version}-alpine"
ARG --global node_builder_image = "node:${node_version}"
ARG --global rust_builder_image = "rust:${rust_version}-bookworm"
ARG --global work_image = "alpine"

ARG --global outputDir = "./dist"

# Architectures:
# The list of rust targets we support. They will be automatically converted
# to GOOS, GOARCH and GOARM when building go binaries. See the +RUST_TO_GO_ARCH_STRING
# helper method at the bottom of the file.
#
# Linux:
# x86_64-unknown-linux-gnu
# aarch64-unknown-linux-gnu
# armv7-unknown-linux-gnueabihf
# arm-unknown-linux-gnueabi
#
# Windows:
# x86_64-pc-windows-gnu
# aarch64-pc-windows-gnu
#
# macOS:
# x86_64-apple-darwin
# aarch64-apple-darwin

# Import the earthly rust lib since it already provides some useful
# build-targets and methods to initialize the rust toolchain.
IMPORT github.com/earthly/lib/rust:3.0.2 AS rust

build:
    # Build all Golang binaries:
    # ./dist/linux_amd64/portmaster-core
    # ./dist/linux_amd64/portmaster-start
    # ./dist/linux_arm64/portmaster-core
    # ./dist/linux_arm64/portmaster-start
    # ./dist/windows_amd64/portmaster-core.exe
    # ./dist/windows_amd64/portmaster-start.exe
    # ./dist/windows_arm64/portmaster-core.exe
    # ./dist/windows_arm64/portmaster-start.exe
    BUILD +go-build --GOOS="linux"   --GOARCH="amd64"
    BUILD +go-build --GOOS="linux"   --GOARCH="arm64"
    BUILD +go-build --GOOS="windows" --GOARCH="amd64"
    BUILD +go-build --GOOS="windows" --GOARCH="arm64"
    BUILD +go-build --GOOS="darwin"  --GOARCH="amd64"
    BUILD +go-build --GOOS="darwin"  --GOARCH="arm64"

    # Build the Angular UI:
    # ./dist/all/portmaster-ui.zip
    BUILD +angular-release

    # Build Tauri app binaries:
    # ./dist/linux_amd64/portmaster-app
    # ./dist/linux_amd64/Portmaster-0.1.0-1.x86_64.rpm
    # ./dist/linux_amd64/Portmaster_0.1.0_amd64.deb
    BUILD +tauri-build --target="x86_64-unknown-linux-gnu"
    # TODO:
    # BUILD +tauri-build --target="x86_64-pc-windows-gnu"

    # Bild Tauri bundle for Windows:
    # ./dist/windows_amd64/portmaster-app_vX-X-X.zip
    BUILD +tauri-build-windows-bundle

    # Build UI assets:
    # ./dist/all/assets.zip
    BUILD +assets

    # Build macOS Network Extension
    # ./dist/darwin_amd64/PortmasterTunnelProvider.appex
    # ./dist/darwin_arm64/PortmasterTunnelProvider.appex
    BUILD +kext-build-macos --target="x86_64-apple-darwin"
    BUILD +kext-build-macos --target="aarch64-apple-darwin"

build-spn:
    BUILD +go-build --CMDS="hub" --GOOS="linux"   --GOARCH="amd64"
    BUILD +go-build --CMDS="hub" --GOOS="linux"   --GOARCH="arm64"
    # TODO: Add other platforms

go-ci:
    BUILD +go-build --GOOS="linux"   --GOARCH="amd64"
    BUILD +go-build --GOOS="linux"   --GOARCH="arm64"
    BUILD +go-build --GOOS="windows" --GOARCH="amd64"
    BUILD +go-build --GOOS="windows" --GOARCH="arm64"
    BUILD +go-build --GOOS="darwin"  --GOARCH="amd64"
    BUILD +go-build --GOOS="darwin"  --GOARCH="arm64"
    BUILD +go-test

angular-ci:
    BUILD +angular-release

tauri-ci:
    BUILD +tauri-build --target="x86_64-unknown-linux-gnu"
    BUILD +tauri-build-windows-bundle

kext-ci:
    BUILD +kext-build

release:
    LOCALLY

    IF ! git diff --quiet
        RUN echo -e "\033[1;31m Refusing to release a dirty git repository. Please commit your local changes first! \033[0m" ; exit 1
    END

    BUILD +build

go-deps:
    FROM ${go_builder_image}
    WORKDIR /go-workdir

    # We need the git cli to extract version information for go-builds
    RUN apk add git

    # These cache dirs will be used in later test and build targets
    # to persist cached go packages.
    #
    # NOTE: cache only gets persisted on successful builds. A test
    # failure will prevent the go cache from being persisted.
    ENV GOCACHE = "/.go-cache"
    ENV GOMODCACHE = "/.go-mod-cache"

    # Copying only go.mod and go.sum means that the cache for this
    # target will only be busted when go.mod/go.sum change. This
    # means that we can cache the results of 'go mod download'.
    COPY go.mod .
    COPY go.sum .
    RUN go mod download

    # Explicitly cache here.
    SAVE IMAGE --cache-hint

go-base:
    FROM +go-deps

    # Copy the full repo, as Go embeds whether the state is clean.
    COPY . .

    LET version = "$(git tag --points-at || true)"
    IF [ -z "${version}" ]
        LET dev_version = "$(git describe --tags --first-parent --abbrev=0 || true)"
        IF [ -n "${dev_version}" ]
            SET version = "${dev_version}_dev_build"
        END
    END
    IF [ -z "${version}" ]
        SET version = "dev_build"
    END
    ENV VERSION="${version}"
    RUN echo "Version: $VERSION"

    LET source = $( ( git remote -v | cut -f2 | cut -d" " -f1 | head -n 1 ) || echo "unknown" )
    ENV SOURCE="${source}"
    RUN echo "Source: $SOURCE"

    LET build_time = $(date -u "+%Y-%m-%dT%H:%M:%SZ" || echo "unknown")
    ENV BUILD_TIME = "${build_time}"
    RUN echo "Build Time: $BUILD_TIME"

    # Explicitly cache here.
    SAVE IMAGE --cache-hint

# updates all go dependencies and runs go mod tidy, saving go.mod and go.sum locally.
go-update-deps:
    FROM +go-base

    RUN go get -u ./..
    RUN go mod tidy
    SAVE ARTIFACT --keep-ts go.mod AS LOCAL go.mod
    SAVE ARTIFACT --keep-ts --if-exists go.sum AS LOCAL go.sum

# mod-tidy runs 'go mod tidy', saving go.mod and go.sum locally.
mod-tidy:
    FROM +go-base

    RUN go mod tidy
    SAVE ARTIFACT --keep-ts go.mod AS LOCAL go.mod
    SAVE ARTIFACT --keep-ts --if-exists go.sum AS LOCAL go.sum

# go-build runs 'go build ./cmds/...', saving artifacts locally.
# If --CMDS is not set, it defaults to building portmaster-start, portmaster-core and hub
go-build:
    FROM +go-base

    # Arguments for cross-compilation.
    ARG GOOS=linux
    ARG GOARCH=amd64
    ARG GOARM
    ARG CMDS=portmaster-start portmaster-core

    CACHE --sharing shared "$GOCACHE"
    CACHE --sharing shared "$GOMODCACHE"

    RUN mkdir /tmp/build

    # Fall back to build all binaries when none is specified.
    IF [ "${CMDS}" = "" ]
        LET CMDS=$(ls -1 "./cmds/")
    END

    # Build all go binaries from the specified in CMDS
    FOR bin IN $CMDS
        # Add special build options.
        IF [ "${GOOS}" = "windows" ] &&  [ "${bin}" = "portmaster-start" ]
            # Windows, portmaster-start
            ENV CGO_ENABLED = "1"
            ENV EXTRA_LD_FLAGS = "-H windowsgui"
        ELSE
            # Defaults
            ENV CGO_ENABLED = "0"
            ENV EXTRA_LD_FLAGS = ""
        END

        RUN --no-cache go build -ldflags="${EXTRA_LD_FLAGS} -X github.com/safing/portmaster/base/info.version=${VERSION} -X github.com/safing/portmaster/base/info.buildSource=${SOURCE} -X github.com/safing/portmaster/base/info.buildTime=${BUILD_TIME}" -o "/tmp/build/" ./cmds/${bin}
    END

    DO +GO_ARCH_STRING --goos="${GOOS}" --goarch="${GOARCH}" --goarm="${GOARM}"
    FOR bin IN $(ls -1 "/tmp/build/")
        SAVE ARTIFACT --keep-ts "/tmp/build/${bin}" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/${bin}"
    END

    SAVE ARTIFACT --keep-ts "/tmp/build/" ./output

spn-image:
    # Use minimal image as base.
    FROM alpine

    # Copy the static executable.
    COPY (+go-build/output/portmaster-start --GOARCH=amd64 --GOOS=linux --CMDS=portmaster-start) /init/portmaster-start

    # Copy the init script
    COPY spn/tools/container-init.sh /init.sh

    # Run the hub.
    ENTRYPOINT ["/init.sh"]

    # Get version.
    LET version = "$(/init/portmaster-start version --short | tr ' ' -)"
    RUN echo "Version: ${version}"

    # Save dev image
    SAVE IMAGE "spn:latest"
    SAVE IMAGE "spn:${version}"
    SAVE IMAGE "ghcr.io/safing/spn:latest"
    SAVE IMAGE "ghcr.io/safing/spn:${version}"

# Test one or more go packages.
# Test are always run as -short, as "long" tests require a full desktop system.
# Run `earthly +go-test` to test all packages
# Run `earthly +go-test --PKG="service/firewall"` to only test a specific package.
# Run `earthly +go-test --TESTFLAGS="-args arg1"` to add custom flags to go test (-args in this case)
go-test:
    FROM +go-base

    ARG GOOS=linux
    ARG GOARCH=amd64
    ARG GOARM
    ARG TESTFLAGS
    ARG PKG="..."

    CACHE --sharing shared "$GOCACHE"
    CACHE --sharing shared "$GOMODCACHE"

    FOR pkg IN $(go list -e "./${PKG}")
        RUN --no-cache go test -cover -short ${pkg} ${TESTFLAGS}
    END

go-test-all:
    FROM ${work_image}
    ARG --required architectures

    FOR arch IN ${architectures}
        DO +RUST_TO_GO_ARCH_STRING --rustTarget="${arch}"
        BUILD +go-test --GOARCH="${GOARCH}" --GOOS="${GOOS}" --GOARM="${GOARM}"
    END

go-lint:
    FROM +go-base

    RUN go install github.com/golangci/golangci-lint/cmd/golangci-lint@v${golangci_lint_version}
    RUN golangci-lint run -c ./.golangci.yml --timeout 15m --show-stats

# Builds portmaster-start, portmaster-core, hub and notifier for all supported platforms
go-release:
    FROM ${work_image}
    ARG --required architectures

    FOR arch IN ${architectures}
        DO +RUST_TO_GO_ARCH_STRING --rustTarget="${arch}"

        IF [ -z GOARCH ]
            RUN echo "Failed to extract GOARCH for ${arch}"; exit 1
        END

        IF [ -z GOOS ]
            RUN echo "Failed to extract GOOS for ${arch}"; exit 1
        END

        BUILD +go-build --GOARCH="${GOARCH}" --GOOS="${GOOS}" --GOARM="${GOARM}"
    END

# Builds all binaries from the cmds/ folder for linux/windows AMD64
# Most utility binaries are never needed on other platforms.
go-build-utils:
    BUILD +go-build --CMDS="" --GOARCH=amd64 --GOOS=linux
    BUILD +go-build --CMDS="" --GOARCH=amd64 --GOOS=windows

# Prepares the angular project by installing dependencies
angular-deps:
    FROM ${node_builder_image}
    WORKDIR /app/ui

    RUN apt update && apt install zip

    COPY desktop/angular/package.json .
    COPY desktop/angular/package-lock.json .

    RUN npm install

# Copies the UI folder into the working container
# and builds the shared libraries in the specified configuration (production or development)
angular-base:
    FROM +angular-deps
    ARG configuration="production"

    COPY desktop/angular/ .
    # Remove symlink and copy assets directly.
    RUN rm ./assets
    COPY assets/data ./assets

    IF [ "${configuration}" = "production" ]
        RUN --no-cache npm run build-libs
    ELSE
        RUN --no-cache npm run build-libs:dev
    END

    # Explicitly cache here.
    SAVE IMAGE --cache-hint

# Build an angualr project, zip it and save artifacts locally
angular-project:
    ARG --required project
    ARG --required dist
    ARG configuration="production"
    ARG baseHref="/"

    FROM +angular-base --configuration="${configuration}"

    IF [ "${configuration}" = "production" ]
        ENV NODE_ENV="production"
    END

    RUN --no-cache ./node_modules/.bin/ng build --configuration ${configuration} --base-href ${baseHref} "${project}"

    RUN --no-cache cwd=$(pwd) && cd "${dist}" && zip -r "${cwd}/${project}.zip" ./
    SAVE ARTIFACT --keep-ts "${dist}" "./output/${project}"

    # Save portmaster UI as local artifact.
    IF [ "${project}" = "portmaster" ]
        SAVE ARTIFACT --keep-ts "./${project}.zip" AS LOCAL ${outputDir}/all/${project}-ui.zip
    END

# Build the angular projects (portmaster-UI and tauri-builtin) in dev mode
angular-dev:
    BUILD +angular-project --project=portmaster --dist=./dist --configuration=development --baseHref=/ui/modules/portmaster/
    BUILD +angular-project --project=tauri-builtin --dist=./dist/tauri-builtin --configuration=development --baseHref=/

# Build the angular projects (portmaster-UI and tauri-builtin) in production mode
angular-release:
    BUILD +angular-project --project=portmaster --dist=./dist --configuration=production --baseHref=/ui/modules/portmaster/
    BUILD +angular-project --project=tauri-builtin --dist=./dist/tauri-builtin --configuration=production --baseHref=/

assets:
    FROM ${work_image}
    RUN apk add zip

    WORKDIR /app/assets
    COPY --keep-ts ./assets/data .
    RUN zip -r -9 -db assets.zip *

    SAVE ARTIFACT --keep-ts "assets.zip" AS LOCAL "${outputDir}/all/assets.zip"

# A base target for rust to prepare the build container
rust-base:
    FROM ${rust_builder_image}

    RUN apt-get update -qq

    # Tools and libraries required for cross-compilation
    RUN apt-get install --no-install-recommends -qq \
        autoconf \
        autotools-dev \
        libtool-bin \
        clang \
        cmake \
        bsdmainutils \
        gcc-multilib \
        linux-libc-dev \
        linux-libc-dev-amd64-cross \
        build-essential \
        curl \
        wget \
        file \
        libsoup-3.0-dev \
        libwebkit2gtk-4.1-dev \
        gcc-mingw-w64-x86-64 \
        zip

    # Install library dependencies for all supported architectures
    # required for succesfully linking.
    RUN apt-get install --no-install-recommends -qq \
        libsoup-3.0-0 \
        libwebkit2gtk-4.1-0 \
        libssl3 \
        libayatana-appindicator3-1 \
        librsvg2-bin \
        libgtk-3-0 \
        libjavascriptcoregtk-4.1-0  \
        libssl-dev \
        libayatana-appindicator3-dev \
        librsvg2-dev \
        libgtk-3-dev \
        libjavascriptcoregtk-4.1-dev  

    # Add some required rustup components
    RUN rustup component add clippy
    RUN rustup component add rustfmt

    DO rust+INIT --keep_fingerprints=true

    # For now we need tauri-cli 2.0.0 for bulding
    DO rust+CARGO --args="install tauri-cli --version 2.1.0 --locked"

    # Explicitly cache here.
    SAVE IMAGE --cache-hint

tauri-src:
    FROM +rust-base

    WORKDIR /app/tauri

    # --keep-ts is necessary to ensure that the timestamps of the source files
    # are preserved such that Rust's incremental compilation works correctly.
    COPY --keep-ts ./desktop/tauri/ .
    COPY assets/data ./../../assets/data
    COPY packaging/linux ./../../packaging/linux
    COPY (+angular-project/output/tauri-builtin --project=tauri-builtin --dist=./dist/tauri-builtin --configuration=production --baseHref="/") ./../angular/dist/tauri-builtin

    WORKDIR /app/tauri/src-tauri

    # Explicitly cache here.
    SAVE IMAGE --cache-hint

tauri-build:
    FROM +tauri-src

    ARG --required target
    ARG output=".*/release/(([^\./]+|([^\./]+\.(dll|exe)))|bundle/(deb|rpm)/.*\.(deb|rpm))"
    ARG bundle="none"

    # if we want tauri to create the installer bundles we also need to provide all external binaries
    # we need to do some magic here because tauri expects the binaries to include the rust target tripple.
    # We already know that triple because it's a required argument. From that triple, we use +RUST_TO_GO_ARCH_STRING
    # function from below to parse the triple and guess wich GOOS and GOARCH we need.
    RUN mkdir /tmp/gobuild
    RUN mkdir ./binaries

    DO +RUST_TO_GO_ARCH_STRING --rustTarget="${target}"
    RUN echo "GOOS=${GOOS} GOARCH=${GOARCH} GOARM=${GOARM} GO_ARCH_STRING=${GO_ARCH_STRING}"

    # Our tauri app has externalBins configured so tauri will try to embed them when it finished compiling
    # the app. Make sure we copy portmaster-start and portmaster-core in all architectures supported.
    # See documentation for externalBins for more information on how tauri searches for the binaries.
    COPY (+go-build/output --CMDS="portmaster-start portmaster-core" --GOOS="${GOOS}" --GOARCH="${GOARCH}" --GOARM="${GOARM}") /tmp/gobuild

    # Place them in the correct folder with the rust target tripple attached.
    FOR bin IN $(ls /tmp/gobuild)
        # ${bin$.*} does not work in SET commands unfortunately so we use a shell
        # snippet here:
        RUN set -e ; \
            dest="./binaries/${bin}-${target}" ; \
            if [ -z "${bin##*.exe}" ]; then \
                dest="./binaries/${bin%.*}-${target}.exe" ; \
            fi ; \
            cp "/tmp/gobuild/${bin}" "${dest}" ;
    END

    # Just for debugging ...
    # RUN ls -R ./binaries

    # The following is exected to work but doesn't. for whatever reason cargo-sweep errors out on the windows-toolchain.
    #
    #   DO rust+CARGO --args="tauri build --bundles none --ci --target=${target}" --output="release/[^/\.]+"
    #
    # For, now, we just directly mount the rust target cache and call cargo ourself.

    DO rust+SET_CACHE_MOUNTS_ENV
    RUN rustup target add "${target}"
    RUN --mount=$EARTHLY_RUST_TARGET_CACHE cargo tauri build  --ci --target="${target}"
    DO rust+COPY_OUTPUT --output="${output}"

    # BUG(cross-compilation):
    #
    # The above command seems to correctly compile for all architectures we want to support but fails during
    # linking since the target libaries are not available for the requested platforms. Maybe we need to download
    # the, manually ...
    #
    # The earthly rust lib also has support for using cross-rs for cross-compilation but that fails due to the
    # fact that cross-rs base docker images used for building are heavily outdated (latest = ubunut:16.0, main = ubuntu:20.04)
    # which does not ship recent enough glib versions (our glib dependency needs glib>2.70 but ubunut:20.04 only ships 2.64)
    #
    # The following would use the CROSS function from the earthly lib, this 
    # DO rust+CROSS --target="${target}"

    RUN echo output: $(ls -R "target/${target}/release")

    # Binaries
    SAVE ARTIFACT --if-exists --keep-ts "target/${target}/release/app" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/portmaster-app"
    SAVE ARTIFACT --if-exists --keep-ts "target/${target}/release/app.exe" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/portmaster-app.exe"
    SAVE ARTIFACT --if-exists --keep-ts "target/${target}/release/WebView2Loader.dll" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/WebView2Loader.dll"

    # Installers
    SAVE ARTIFACT --if-exists --keep-ts "target/${target}/release/bundle/deb/*.deb" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/"
    SAVE ARTIFACT --if-exists --keep-ts "target/${target}/release/bundle/rpm/*.rpm" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/"

tauri-build-windows-bundle:
    FROM +tauri-src

    ARG target="x86_64-pc-windows-gnu"
    ARG output=".*/release/(([^\./]+|([^\./]+\.(dll|exe))))"
    ARG bundle="none"

    ARG GOOS=windows
    ARG GOARCH=amd64
    ARG GOARM

    # The binaries will not be used but we still need to create them. Tauri will check for them.
    RUN mkdir /tmp/gobuild
    RUN mkdir ./binaries

    DO +RUST_TO_GO_ARCH_STRING --rustTarget="${target}"
    RUN echo "GOOS=${GOOS} GOARCH=${GOARCH} GOARM=${GOARM} GO_ARCH_STRING=${GO_ARCH_STRING}"

    # Our tauri app has externalBins configured so tauri will look for them when it finished compiling
    # the app. Make sure we copy portmaster-start and portmaster-core in all architectures supported.
    # See documentation for externalBins for more information on how tauri searches for the binaries.
    COPY (+go-build/output --GOOS="${GOOS}" --CMDS="portmaster-start portmaster-core" --GOARCH="${GOARCH}" --GOARM="${GOARM}") /tmp/gobuild

    # Place them in the correct folder with the rust target tripple attached.
    FOR bin IN $(ls /tmp/gobuild)
        # ${bin$.*} does not work in SET commands unfortunately so we use a shell
        # snippet here:
        RUN set -e ; \
            dest="./binaries/${bin}-${target}" ; \
            if [ -z "${bin##*.exe}" ]; then \
                dest="./binaries/${bin%.*}-${target}.exe" ; \
            fi ; \
            cp "/tmp/gobuild/${bin}" "${dest}" ;
    END

    # Just for debugging ...
    # RUN ls -R ./binaries

    DO rust+SET_CACHE_MOUNTS_ENV
    RUN rustup target add "${target}"
    RUN --mount=$EARTHLY_RUST_TARGET_CACHE cargo tauri build --no-bundle --ci --target="${target}"
    DO rust+COPY_OUTPUT --output="${output}"

    # Get version from git.
    COPY .git .
    LET version = "$(git tag --points-at || true)"
    IF [ -z "${version}" ]
        LET dev_version = "$(git describe --tags --first-parent --abbrev=0 || true)"
        IF [ -n "${dev_version}" ]
            SET version = "${dev_version}"
        END
    END
    IF [ -z "${version}" ]
        SET version = "v0.0.0"
    END
    ENV VERSION="${version}"
    RUN echo "Version: $VERSION"
    ENV VERSION_SUFFIX="$(echo $VERSION | tr '.' '-')"
    RUN echo "Version Suffix: $VERSION_SUFFIX"

    RUN echo output: $(ls -R "target/${target}/release")
    RUN mv "target/${target}/release/app.exe" "target/${target}/release/portmaster-app_${VERSION_SUFFIX}.exe"
    RUN zip "target/${target}/release/portmaster-app_${VERSION_SUFFIX}.zip" "target/${target}/release/portmaster-app_${VERSION_SUFFIX}.exe" -j portmaster-app${VERSION_SUFFIX}.exe "target/${target}/release/WebView2Loader.dll" -j WebView2Loader.dll
    SAVE ARTIFACT --if-exists "target/${target}/release/portmaster-app_${VERSION_SUFFIX}.zip" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/"

tauri-prep-windows:
    FROM +angular-base --configuration=production
    ARG target="x86_64-pc-windows-msvc"

    # if we want tauri to create the installer bundles we also need to provide all external binaries
    # we need to do some magic here because tauri expects the binaries to include the rust target tripple.
    # We already know that triple because it's a required argument. From that triple, we use +RUST_TO_GO_ARCH_STRING
    # function from below to parse the triple and guess wich GOOS and GOARCH we need.
    RUN mkdir /tmp/gobuild
    RUN mkdir ./binaries

    DO +RUST_TO_GO_ARCH_STRING --rustTarget="${target}"
    RUN echo "GOOS=${GOOS} GOARCH=${GOARCH} GOARM=${GOARM} GO_ARCH_STRING=${GO_ARCH_STRING}"

    # Our tauri app has externalBins configured so tauri will try to embed them when it finished compiling
    # the app. Make sure we copy portmaster-start and portmaster-core in all architectures supported.
    # See documentation for externalBins for more information on how tauri searches for the binaries.

    COPY (+go-build/output --GOOS="${GOOS}" --CMDS="portmaster-start portmaster-core" --GOARCH="${GOARCH}" --GOARM="${GOARM}") /tmp/gobuild

    # Place them in the correct folder with the rust target tripple attached.
    FOR bin IN $(ls /tmp/gobuild)
        # ${bin$.*} does not work in SET commands unfortunately so we use a shell
        # snippet here:
        RUN set -e ; \
            dest="./binaries/${bin}-${target}" ; \
            if [ -z "${bin##*.exe}" ]; then \
                dest="./binaries/${bin%.*}-${target}.exe" ; \
            fi ; \
            cp "/tmp/gobuild/${bin}" "${dest}" ;
    END

    # Copy source
    COPY --keep-ts ./desktop/tauri/src-tauri src-tauri
    COPY --keep-ts ./assets assets

    # Build UI
    ENV NODE_ENV="production"
    RUN --no-cache ./node_modules/.bin/ng build --configuration production --base-href / "tauri-builtin"

    # Just for debugging ...
    # RUN ls -R ./binaries
    # RUN ls -R ./dist

    SAVE ARTIFACT "./dist/tauri-builtin" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/desktop/angular/dist/"
    SAVE ARTIFACT "./src-tauri" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/desktop/tauri/src-tauri"
    SAVE ARTIFACT "./binaries" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/desktop/tauri/src-tauri/"
    SAVE ARTIFACT "./assets" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/assets"

tauri-release:
    FROM ${work_image}
    ARG --required architectures

    FOR arch IN ${architectures}
        BUILD +tauri-build --target="${arch}"
    END

kext-build:
    FROM ${rust_builder_image}

    # Install architecture target
    DO rust+INIT --keep_fingerprints=true

    # Build kext
    WORKDIR /app/kext
    # --keep-ts is necessary to ensure that the timestamps of the source files
    # are preserved such that Rust's incremental compilation works correctly.
    COPY --keep-ts ./windows_kext/ .

    # Add target architecture
    RUN rustup target add x86_64-pc-windows-msvc
    
    # Build using special earthly lib
    WORKDIR /app/kext/release
    DO rust+CARGO --args="run"

    SAVE ARTIFACT --keep-ts "portmaster-kext-release-bundle.zip" AS LOCAL "${outputDir}/windows_amd64/portmaster-kext-release-bundle.zip"

# Build the macOS Network Extension. This is a placeholder and needs to be implemented.
kext-build-macos:
    FROM ${rust_builder_image} # Using rust_builder_image as a placeholder

    ARG --required target

    # Placeholder for actual macOS build commands
    RUN echo "Building macOS Network Extension for target ${target}..."
    # This target will need to be significantly more complex, involving:
    # 1. Compiling the Swift code (likely using xcodebuild).
    # 2. Compiling the Go CGo code into a static library.
    # 3. Linking the Go static library into the Swift extension.
    # 4. Packaging the .appex bundle.

    # Step 2: Compile Go CGo bridge code (illustrative)
    # The GOOS and GOARCH should align with the macOS target.
    # For example, if target is 'aarch64-apple-darwin', GOOS='darwin', GOARCH='arm64'.
    # This requires RUST_TO_GO_ARCH_STRING to correctly parse darwin targets.
    DO +RUST_TO_GO_ARCH_STRING --rustTarget="${target}"
    RUN echo "Building Go bridge for ${GOOS}/${GOARCH}"
    # The output of this would typically be a .a file (e.g., macos_bridge.a)
    # This command is a simplified representation. CGO_ENABLED=1 is crucial.
    # The actual build command would need to specify the output type as a C archive.
    # FROM +go-base is used to get the Go environment.
    FROM +go-base AS go-bridge-builder
    ARG target # Propagate target to this stage
    WORKDIR /app/service/firewall/interception/macos
    # This is a conceptual step. A real CGo build for a static library would be like:
    # RUN go build -buildmode=c-archive -o macos_bridge.a .
    # For now, we'll just create a dummy file to represent the library.
    RUN echo "Go bridge compiled for ${target}" > "macos_bridge_${target}.a"
    RUN mkdir -p "/build_output/macos_bridge/${target}/lib"
    RUN cp "macos_bridge_${target}.a" "/build_output/macos_bridge/${target}/lib/"
    RUN cp "macos-bridge.h" "/build_output/macos_bridge/${target}/include/"


    # In a real scenario, the Swift compilation (xcodebuild) would then be configured
    # to link against macos_bridge.a and include macos-bridge.h.
    # This is complex to orchestrate solely within Earthly without an existing Xcode project setup.

    RUN echo "Simulating Swift extension build and packaging for ${target}..."
    RUN mkdir -p "${outputDir}/${GO_ARCH_STRING}"
    # Create a dummy .appex file
    RUN echo "Placeholder macOS Extension for ${target}" > "${outputDir}/${GO_ARCH_STRING}/PortmasterTunnelProvider.appex"
    # Copy the dummy Go library artifact as well, to show it's part of the output
    RUN cp "/build_output/macos_bridge/${target}/lib/macos_bridge_${target}.a" "${outputDir}/${GO_ARCH_STRING}/"

    SAVE ARTIFACT --keep-ts "${outputDir}/${GO_ARCH_STRING}/PortmasterTunnelProvider.appex" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/PortmasterTunnelProvider.appex"
    SAVE ARTIFACT --keep-ts "${outputDir}/${GO_ARCH_STRING}/macos_bridge_${target}.a" AS LOCAL "${outputDir}/${GO_ARCH_STRING}/macos_bridge.a"

# Build the macOS XPC Service (Objective-C).
# This target simulates the packaging of the XPC service. Actual compilation
# would occur in an Xcode environment.
xpc-service-macos:
    FROM alpine # Using a minimal image as we are just copying files
    ARG target="all_macos" # Could be x86_64-apple-darwin or aarch64-apple-darwin if specific resources were needed

    WORKDIR /app

    # Copy the Objective-C XPC service source files
    COPY macos-xpc-service ./macos-xpc-service

    # Create a placeholder .xpc bundle structure (conceptual)
    # In a real build, xcodebuild would create this.
    RUN mkdir -p "${outputDir}/${target}/PortmasterXPC.xpc/Contents"
    RUN cp ./macos-xpc-service/Info.plist "${outputDir}/${target}/PortmasterXPC.xpc/Contents/Info.plist"
    # Simulate copying compiled binary (though we don't compile it here)
    RUN echo "Placeholder XPC Service Binary" > "${outputDir}/${target}/PortmasterXPC.xpc/Contents/MacOS_PortmasterXPC"
    # Copy source files into a subdirectory for reference, as they aren't compiled by this Earthly target.
    RUN cp -r ./macos-xpc-service "${outputDir}/${target}/PortmasterXPC.xpc/Contents/Resources/sources"


    # Save the placeholder .xpc bundle as an artifact.
    # The GO_ARCH_STRING might not be directly applicable if it's a universal binary,
    # but we'll use a generic name for now.
    SAVE ARTIFACT --keep-ts "${outputDir}/${target}/PortmasterXPC.xpc" AS LOCAL "${outputDir}/macos_all/PortmasterXPC.xpc"


# Takes GOOS, GOARCH and optionally GOARM and creates a string representation for file-names.
# in the form of ${GOOS}_{GOARCH} if GOARM is empty, otherwise ${GOOS}_${GOARCH}v${GOARM}.
# Thats the same format as expected and served by our update server.
#
# The result is available as GO_ARCH_STRING environment variable in the build context.
GO_ARCH_STRING:
    FUNCTION
    ARG --required goos
    ARG --required goarch
    ARG goarm

    LET result = "${goos}_${goarch}"
    IF [ "${goarm}" != "" ]
        SET result = "${goos}_${goarch}v${goarm}"
    END

    ENV GO_ARCH_STRING="${result}"

# Takes a rust target (--rustTarget) and extracts architecture and OS and arm version
# and finally calls GO_ARCH_STRING.
#
# The result is available as GO_ARCH_STRING environment variable in the build context.
# It also exports GOOS, GOARCH and GOARM environment variables.
RUST_TO_GO_ARCH_STRING:
    FUNCTION
    ARG --required rustTarget

    LET goos=""
    IF [ -z "${rustTarget##*linux*}" ]
        SET goos="linux"
    ELSE IF [ -z "${rustTarget##*windows*}" ]
        SET goos="windows"
    ELSE IF [ -z "${rustTarget##*darwin*}" ]
        SET goos="darwin"
    ELSE
        RUN echo "GOOS not detected"; \
            exit 1;
    END

    LET goarch=""
    LET goarm=""
    IF [ -z "${rustTarget##*x86_64*}" ]
        SET goarch="amd64"
    ELSE IF [ -z "${rustTarget##*arm*}" ]
        SET goarch="arm"
        SET goarm="6"

        IF [ -z "${rustTarget##*v7*}" ]
            SET goarm="7"
        END
    ELSE IF [ -z "${rustTarget##*aarch64*}" ]
        SET goarch="arm64"
    ELSE
        RUN echo "GOARCH not detected"; \
            exit 1;
    END

    ENV GOOS="${goos}"
    ENV GOARCH="${goarch}"
    ENV GOARM="${goarm}"

    DO +GO_ARCH_STRING --goos="${goos}" --goarch="${goarch}" --goarm="${goarm}"

# Takes an architecture or GOOS string and sets the BINEXT env var.
BIN_EXT:
    FUNCTION
    ARG --required arch

    LET binext=""
    IF [ -z "${arch##*windows*}" ]
        SET binext=".exe"
    END
    ENV BINEXT="${goos}"
