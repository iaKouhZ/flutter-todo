#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
  printf 'Usage: %s INPUT.apk OUTPUT.apk RELEASE.p12\n' "$0" >&2
  exit 2
fi

: "${ANDROID_KEYSTORE_PASSWORD:?Set ANDROID_KEYSTORE_PASSWORD}"
export ANDROID_KEYSTORE_PASSWORD
input=$1
output=$2
keystore=$3
expected=$(keytool -exportcert -alias todo-release -storetype PKCS12 -keystore "$keystore" \
  -storepass:env ANDROID_KEYSTORE_PASSWORD | sha256sum | awk '{print $1}')

if [[ -n ${APKSIGNER_JAR:-} ]]; then
  apksigner=(java -jar "$APKSIGNER_JAR")
else
  apksigner=(apksigner)
fi

mkdir -p "$(dirname "$output")"
temp_dir=$(mktemp -d)
trap 'rm -f "$temp_dir/signed.apk"; rmdir "$temp_dir"' EXIT

"${apksigner[@]}" sign --ks "$keystore" --ks-type PKCS12 --ks-key-alias todo-release \
  --ks-pass env:ANDROID_KEYSTORE_PASSWORD --key-pass env:ANDROID_KEYSTORE_PASSWORD \
  --v4-signing-enabled false --out "$temp_dir/signed.apk" "$input"

report=$("${apksigner[@]}" verify --verbose --print-certs "$temp_dir/signed.apk")
actual=$(printf '%s\n' "$report" | awk '/certificate SHA-256 digest: / {print $NF}' | sort -u)
if ! grep -qx 'Number of signers: 1' <<< "$report" || [[ "$actual" != "$expected" ]]; then
  printf 'APK signing certificate does not match the release key.\n' >&2
  exit 1
fi

mv "$temp_dir/signed.apk" "$output"
printf 'Verified release certificate SHA-256: %s\n' "$actual"
