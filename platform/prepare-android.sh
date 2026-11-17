#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f android/gradlew ]]; then
  scaffold="$(mktemp -d)"
  trap 'rm -rf "$scaffold"' EXIT
  flutter create --platforms=android --org io.github.iakouhz \
    --project-name todo_endfield --no-pub "$scaffold/todo_endfield"
  mkdir -p android
  cp -a "$scaffold/todo_endfield/android/." android/
fi
cp -a platform/android/. android/
if ! grep -q 'androidx.work:work-runtime' android/app/build.gradle.kts; then
  cat >> android/app/build.gradle.kts <<'GRADLE'

dependencies {
    implementation("androidx.work:work-runtime:2.10.1")
    implementation("org.jsoup:jsoup:1.18.3")
}
GRADLE
fi
if ! grep -q 'junit:junit' android/app/build.gradle.kts; then
  cat >> android/app/build.gradle.kts <<'GRADLE'

dependencies {
    testImplementation("junit:junit:4.13.2")
}
GRADLE
fi
