#!/bin/zsh
# Publishes a GitHub Release of the app (and the Companion module) for download.
#
#   scripts/release.sh            uses the version in Resources/Info.plist
#   scripts/release.sh --dry-run  builds and packages into build/release, no upload
#
# The app is signed with the "KeyPoint OSC Development" identity (not notarized), so
# users approve it once per version under Privacy & Security > Open Anyway; see
# docs/INSTALL.md. Keep using the same identity: users' permissions are tied to it.
set -euo pipefail
cd "${0:A:h}/.."
dry_run=0
[[ ${1:-} == --dry-run ]] && dry_run=1

identity="KeyPoint OSC Development"
security find-identity -p codesigning | grep -q "\"$identity\"" || {
  echo "Missing signing identity \"$identity\". Restore it from the backup .p12, or (first time only) run scripts/make-dev-cert.sh." >&2
  exit 1
}

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
tag="v$version"
module_dir=companion-module
module_version=$(node -p "require('./$module_dir/package.json').version")

if (( ! dry_run )); then
  [[ -z $(git status --porcelain) ]] || { echo "Commit or stash changes first." >&2; exit 1; }
  [[ -z $(git -C $module_dir status --porcelain) ]] || { echo "Commit or stash changes in $module_dir first." >&2; exit 1; }
  if gh release view "$tag" >/dev/null 2>&1; then
    echo "Release $tag already exists. Bump CFBundleShortVersionString (and CFBundleVersion) in Resources/Info.plist." >&2
    exit 1
  fi
fi

echo "== Tests"
scripts/test.sh >/dev/null
(cd $module_dir && npm test >/dev/null)

echo "== App $version (universal)"
UNIVERSAL=1 SIGN_ID="$identity" scripts/build-app.sh
out=build/release
rm -rf $out && mkdir -p $out
app_zip="$out/KeyPoint-OSC-$version.zip"
ditto -c -k --keepParent "build/KeyPoint OSC.app" "$app_zip"

echo "== Companion module $module_version"
(cd $module_dir && rm -f *.tgz && npm run package >/dev/null)
module_tgz=$(ls $module_dir/*.tgz)
cp "$module_tgz" $out/

notes="$out/notes.md"
cat > $notes <<EOF
**KeyPoint OSC $version**: control PowerPoint for Mac and Keynote from Bitfocus Companion.

Downloads:
- \`$(basename $app_zip)\`: the Mac app (Apple Silicon and Intel, macOS 14 or later)
- \`$(basename $module_tgz)\`: the Companion module (Companion: Modules > Import module package)

The app isn't notarized by Apple, so macOS asks you to approve it once per version. See the
[install guide](https://github.com/BasilChessman/KeyPoint-OSC/blob/$tag/docs/INSTALL.md).
EOF
(cd $out && shasum -a 256 $(basename $app_zip) $(basename $module_tgz)) >> $notes.sha
{ echo; echo "SHA-256:"; echo '```'; cat $notes.sha; echo '```'; } >> $notes
rm $notes.sha

ls -la $out
if (( dry_run )); then
  echo "Dry run: not uploading. Release notes:"; cat $notes
  exit 0
fi

echo "== Publishing $tag"
git tag -a "$tag" -m "KeyPoint OSC $version"
git push origin "$tag"
gh release create "$tag" "$app_zip" $out/$(basename $module_tgz) --title "KeyPoint OSC $version" --notes-file $notes

module_tag="v$module_version"
if ! gh release view "$module_tag" -R "$(git -C $module_dir remote get-url origin)" >/dev/null 2>&1; then
  git -C $module_dir tag -a "$module_tag" -m "Companion module $module_version"
  git -C $module_dir push origin "$module_tag"
  (cd $module_dir && gh release create "$module_tag" "$(basename $module_tgz)" --title "KeyPoint OSC module $module_version" \
    --notes "Companion module for KeyPoint OSC $version. In Companion: Modules > Import module package, then choose the .tgz.")
fi
echo "Done: $(gh release view "$tag" --json url --jq .url)"
