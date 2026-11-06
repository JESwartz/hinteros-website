# Build, checksum and sign the HinterOS installer ISO of a stable release, and write the
# release.json manifest the website reads (see README.md, "Releasing").
#
#   nix run .#publish-iso -- [--ref stable] [--repo <url>] [--key <path>] [--out <dir>]
#                            [--base-url <url>] [--iso <file>] [--no-site] [--dry-run]
#
# Steps, each checked before the next:
#   1. Clone the system repo and resolve --ref (default `stable`) to a commit.
#   2. Verify the commit is signed by a key in its own release/allowed_signers (git namespace),
#      as a box does before it installs a release.
#   3. Build the ISO from exactly that commit (`nix build git+file://<clone>?rev=<commit>#iso`).
#   4. Copy it to <out>/hinteros-<version>-x86_64.iso, write SHA256SUMS, sign it with the release
#      key file (`ssh-keygen -Y sign -n file`, passphrase on the terminal, never an agent) and
#      verify the signature against the commit's release/allowed_signers.
#   5. Write <out>/release.json and, unless --no-site, ./release.json for the site build.
#
# Nothing is uploaded: put the three files from <out> at --base-url yourself.
#
# Environment:
#   HINTEROS_RELEASE_KEY   signing key file (default ~/.ssh/hinteros/release_ed25519)
#   HINTEROS_REPO          system repo (default https://git.hinteros.org/hinteros.git)

set -euo pipefail

ok() { printf '  [ok]   %s\n' "$*"; }
info() { printf '  [info] %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
fail() {
  printf '  [FAIL] %s\n' "$*"
  printf '\npublish-iso: stopped. Nothing was signed or written to the site.\n' >&2
  exit 1
}

usage() {
  echo "usage: publish-iso [--ref stable] [--repo <url>] [--key <path>] [--out <dir>]"
  echo "                   [--base-url <url>] [--iso <file>] [--no-site] [--dry-run]"
}

# Never sign through an agent: the key must be unlocked with its passphrase, each time.
unset SSH_AUTH_SOCK SSH_AGENT_PID

ref=stable
repo=${HINTEROS_REPO:-https://git.hinteros.org/hinteros.git}
key=${HINTEROS_RELEASE_KEY:-$HOME/.ssh/hinteros/release_ed25519}
forge=https://git.hinteros.org/hinteros
out=
base_url=
iso_override=
site=1
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref | --repo | --key | --out | --base-url | --iso)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      case "$1" in
        --ref) ref=$2 ;;
        --repo) repo=$2 ;;
        --key) key=$2 ;;
        --out) out=$2 ;;
        --base-url) base_url=$2 ;;
        --iso) iso_override=$2 ;;
      esac
      shift 2
      ;;
    --no-site) site=0; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

if [ "$site" = 1 ] && [ ! -f build.py ]; then
  fail "run this from the HinterOS.org checkout (it writes ./release.json), or pass --no-site"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
g() { git -C "$tmp/repo" "$@"; }

step "Release commit"
git clone --quiet --no-checkout "$repo" "$tmp/repo" || fail "cannot clone $repo"
commit=$(g rev-parse --verify --quiet "origin/$ref^{commit}" || g rev-parse --verify --quiet "$ref^{commit}") ||
  fail "$ref is not a branch, tag or commit in $repo"
ok "$ref = $commit"

version=$(g show "$commit:release/version" | tr -d '[:space:]')
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "release/version of $commit is not MAJOR.MINOR.PATCH: '$version'"
subject=$(g show -s --format=%s "$commit")
[ "$subject" = "HinterOS $version" ] ||
  fail "$commit is not a stable release commit (subject '$subject', expected 'HinterOS $version')"
ok "HinterOS $version"

# release/allowed_signers in ssh-keygen's format with the namespace pinned, as promote reads it.
signers() {
  local namespace=$1 line n=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$line" in "" | "#"*) continue ;; esac
    [[ $line =~ ^([^\ #]+)\ (ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?)$ ]] ||
      fail "release/allowed_signers of $commit: bad line: $line"
    printf '%s namespaces="%s" %s\n' "${BASH_REMATCH[1]}" "$namespace" "${BASH_REMATCH[2]}"
    n=$((n + 1))
  done < <(g show "$commit:release/allowed_signers")
  [ "$n" -gt 0 ] || fail "release/allowed_signers of $commit has no keys"
}
signers git >"$tmp/signers.git"
signers file >"$tmp/signers.file"

g -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c "gpg.ssh.allowedSignersFile=$tmp/signers.git" \
  verify-commit "$commit" >/dev/null 2>&1 ||
  fail "$commit is not signed by a key in its release/allowed_signers"
ok "signed by a release key"

date=$(TZ=UTC g show -s --format=%cd --date=format-local:%Y-%m-%d "$commit")
# The notes of this version: its section of release/notes.md, without the heading.
notes=$(g show "$commit:release/notes.md" |
  awk -v h="## $version" '$0 == h { on = 1; next } on && /^## / { exit } on { print }' |
  sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')
[ -n "$notes" ] || fail "release/notes.md of $commit has no '## $version' section"
ok "release notes for $version ($(printf '%s\n' "$notes" | grep -c '^- ') items)"

name=hinteros-$version-x86_64.iso
out=${out:-dist/$version}
base_url=${base_url:-$forge/releases/download/v$version}

if [ "$dry_run" = 1 ]; then
  step "Dry run"
  info "would build git+file://<clone>?rev=$commit#iso"
  info "would write $out/{$name,SHA256SUMS,SHA256SUMS.sig,release.json}"
  info "would sign SHA256SUMS with $key"
  info "download URL: $base_url/$name"
  exit 0
fi

[ -f "$key" ] || fail "the signing key $key does not exist. Use --key or HINTEROS_RELEASE_KEY."
if [ -e "$out" ] && [ -n "$(ls -A "$out")" ]; then
  fail "$out already exists and is not empty"
fi

step "ISO"
if [ -n "$iso_override" ]; then
  info "using --iso $iso_override instead of building (tests only)"
  iso=$iso_override
else
  info "building the ISO of $commit; this takes a while"
  result=$(nix build --no-link --print-out-paths "git+file://$tmp/repo?rev=$commit#iso") ||
    fail "the ISO build failed"
  iso=$(find "$result/iso" -maxdepth 1 -name '*.iso' | head -n1)
  [ -n "$iso" ] || fail "no .iso in $result/iso"
fi
mkdir -p "$out"
cp --no-preserve=mode "$iso" "$out/$name"
size=$(stat -c %s "$out/$name")
ok "$out/$name ($size bytes)"

step "Checksum and signature"
(cd "$out" && sha256sum "$name" >SHA256SUMS)
sha256=$(cut -d' ' -f1 "$out/SHA256SUMS")
ok "sha256 $sha256"
info "signing SHA256SUMS with $key (asks for the passphrase)"
ssh-keygen -Y sign -f "$key" -n file "$out/SHA256SUMS" ||
  fail "signing failed"
verified=$(ssh-keygen -Y verify -f "$tmp/signers.file" -I release -n file \
  -s "$out/SHA256SUMS.sig" <"$out/SHA256SUMS" 2>&1) ||
  fail "the signature does not verify against release/allowed_signers of $commit: $verified"
fingerprint=$(printf '%s\n' "$verified" | grep -o 'SHA256:[A-Za-z0-9+/=]*' | head -n1)
[ -n "$fingerprint" ] || fail "cannot read the key fingerprint from: $verified"
ok "$verified"

step "Manifest"
jq -n \
  --arg version "$version" --arg date "$date" --arg commit "$commit" \
  --arg source "$forge/src/commit/$commit" \
  --arg name "$name" --arg url "$base_url/$name" --argjson size "$size" --arg sha256 "$sha256" \
  --arg sums "$base_url/SHA256SUMS" --arg sig "$base_url/SHA256SUMS.sig" \
  --arg fingerprint "$fingerprint" --arg notes "$notes" \
  '{version: $version, channel: "stable", date: $date, commit: $commit, source: $source,
    iso: {name: $name, url: $url, size: $size, sha256: $sha256},
    sha256sums_url: $sums, signature_url: $sig,
    signer: {principal: "release", namespace: "file", fingerprint: $fingerprint},
    notes: $notes}' >"$out/release.json"
ok "$out/release.json"
if [ "$site" = 1 ]; then
  cp "$out/release.json" release.json
  ok "./release.json (commit it with the site)"
fi

step "Done"
info "upload $out/$name, $out/SHA256SUMS and $out/SHA256SUMS.sig to $base_url/"
info "check the upload: curl -sL $base_url/SHA256SUMS | diff - $out/SHA256SUMS"
info "users verify with:"
info "  sha256sum -c SHA256SUMS"
info "  ssh-keygen -Y verify -f allowed_signers -I release -n file -s SHA256SUMS.sig < SHA256SUMS"
