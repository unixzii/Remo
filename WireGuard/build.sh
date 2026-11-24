#!/bin/sh
# Created by Cyandev.
set -eu

cargo_bin=$(command -v cargo || true)
if [ -z "$cargo_bin" ]; then
    cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
fi
if [ ! -x "$cargo_bin" ]; then
    echo "error: Install Rust with rustup to build Remo's WireGuard backend." >&2
    exit 1
fi

output_dir="$DERIVED_FILE_DIR/RemoWireGuard"
export CARGO_TARGET_DIR="$output_dir/cargo"
mkdir -p "$output_dir"
rustc_bin="$(dirname "$cargo_bin")/rustc"
if [ ! -x "$rustc_bin" ]; then
    rustc_bin=rustc
fi

if [ "$PLATFORM_NAME" = macosx ]; then
    # Mac Catalyst: rustc and cc read the iOS variable for *-apple-ios-macabi, and Catalyst
    # versions match macOS ones.
    export IPHONEOS_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
fi

set --
for arch in $ARCHS; do
    case "$PLATFORM_NAME:$arch" in
        iphoneos:arm64) target=aarch64-apple-ios ;;
        iphonesimulator:arm64) target=aarch64-apple-ios-sim ;;
        macosx:arm64) target=aarch64-apple-ios-macabi ;;
        *)
            echo "error: Unsupported WireGuard build target $PLATFORM_NAME:$arch." >&2
            exit 1
            ;;
    esac
    if [ ! -d "$("$rustc_bin" --print target-libdir --target "$target")" ]; then
        echo "error: Install the Rust target with 'rustup target add $target'." >&2
        exit 1
    fi
    "$cargo_bin" build --manifest-path "$SRCROOT/WireGuard/Cargo.toml" --locked --release --target "$target"
    set -- "$@" "$CARGO_TARGET_DIR/$target/release/libremo_wireguard.a"
done

if [ "$#" -eq 1 ]; then
    cp "$1" "$output_dir/libremo_wireguard.a"
else
    xcrun lipo -create "$@" -output "$output_dir/libremo_wireguard.a"
fi
