#!/usr/bin/env bash
#
# OpenMCX Licence Information : AGPL-3.0-or-later
#

# Run the Gradle wrapper inside the Android build image; nothing is installed on the host.
# Usage: tools/gradle-docker.sh :core:test :app:assembleDebug ...
# The Gradle cache lives in the Docker volume mcx-android-gradle. The host debug keystore,
# if present, is copied in so debug APKs keep the signature of builds already on the phones.
# Release signing: a release task (any argument containing "Release") signs with ~/.android/openmcx-release.jks. If that key
# does not exist it is created (keytool in the build image) with a random password kept in ~/.android/openmcx-release.pass
# (mode 600). Back both files up: updates must be signed with the same key to install over earlier builds. To use another key,
# export MCX_RELEASE_KEYSTORE, MCX_RELEASE_STORE_PASSWORD, MCX_RELEASE_KEY_ALIAS and optionally MCX_RELEASE_KEY_PASSWORD.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
image="${MCX_ANDROID_BUILD_IMAGE:-mcx-android-build:jdk17-sdk37}"
docker image inspect "$image" >/dev/null 2>&1 || docker build -t "$image" "$here/tools/build-image"
docker volume create mcx-android-gradle >/dev/null
keystore=()
[ -f "$HOME/.android/debug.keystore" ] && keystore=(-v "$HOME/.android/debug.keystore:/host-debug.keystore:ro")
release=()
case "$*" in *Release*)
  if [ -z "${MCX_RELEASE_KEYSTORE:-}" ]; then
    MCX_RELEASE_KEYSTORE="$HOME/.android/openmcx-release.jks"
    pass_file="$HOME/.android/openmcx-release.pass"
    export MCX_RELEASE_KEY_ALIAS="${MCX_RELEASE_KEY_ALIAS:-openmcx}"
    if [ ! -f "$MCX_RELEASE_KEYSTORE" ]; then
      [ ! -f "$pass_file" ] || { echo "$pass_file exists but $MCX_RELEASE_KEYSTORE does not; remove one or restore the other" >&2; exit 1; }
      echo "Creating the release key $MCX_RELEASE_KEYSTORE (alias $MCX_RELEASE_KEY_ALIAS)" >&2
      mkdir -p "$HOME/.android"
      ( umask 077; od -An -tx1 -N24 /dev/urandom | tr -d ' \n' > "$pass_file" )
      docker image inspect "$image" >/dev/null 2>&1 || docker build -t "$image" "$here/tools/build-image"
      docker run --rm -u "$(id -u):$(id -g)" -v "$HOME/.android:/keys" --entrypoint keytool "$image" -genkeypair \
        -keystore /keys/openmcx-release.jks -alias "$MCX_RELEASE_KEY_ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
        -storepass "$(cat "$pass_file")" -dname "CN=OpenMCX Client" >/dev/null || { rm -f "$pass_file"; exit 1; }
    fi
    [ -n "${MCX_RELEASE_STORE_PASSWORD:-}" ] || export MCX_RELEASE_STORE_PASSWORD="$(cat "$pass_file")"
  fi
  release=(-v "$(realpath "$MCX_RELEASE_KEYSTORE"):/release.jks:ro" -e MCX_RELEASE_STORE_PASSWORD -e MCX_RELEASE_KEY_ALIAS -e MCX_RELEASE_KEY_PASSWORD
    -e MCX_RELEASE_KEYSTORE=/release.jks)
  ;;
esac
exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/home/builder -e ANDROID_USER_HOME=/home/builder/.android \
  -e GRADLE_USER_HOME=/gradle -v mcx-android-gradle:/gradle -v "$here:$here" -w "$here" "${keystore[@]}" "${release[@]}" \
  "$image" sh -c 'mkdir -p "$ANDROID_USER_HOME" && { [ ! -f /host-debug.keystore ] || cp /host-debug.keystore "$ANDROID_USER_HOME/debug.keystore"; } && exec ./gradlew "$@"' gradle "$@"
