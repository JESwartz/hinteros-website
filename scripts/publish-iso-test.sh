# checks.publish-iso: publish-iso against a throwaway repo and key, with a small fake ISO.
# Covers the release checks, the checksum, the signature and release.json; not the ISO build.
set -euo pipefail
export HOME=$TMPDIR/home
mkdir -p "$HOME"
cd "$TMPDIR"

ssh-keygen -q -t ed25519 -N "" -C test-release -f release_key
ssh-keygen -q -t ed25519 -N "" -C intruder -f other_key

git init -q -b main repo
cd repo
git config user.name Test
git config user.email test@example.invalid
git config gpg.format ssh
mkdir release
{
  echo "# test signers"
  echo "release $(cut -d' ' -f1,2 ../release_key.pub) test-release"
} >release/allowed_signers
echo 1.0.0 >release/version
cat >release/notes.md <<'EOF'
# HinterOS release notes

## 1.0.0

- First item.
- Second item.

## 0.7.0

- Old item.
EOF
git add .
git -c user.signingkey=../release_key commit -q -S -m "HinterOS 1.0.0"
git branch stable
git -c user.signingkey=../other_key commit -q -S --allow-empty -m "HinterOS 1.0.0"
git branch forged
git checkout -q --detach stable
git commit -q --no-gpg-sign --allow-empty -m "HinterOS 1.0.0"
git branch unsigned
cd ..

head -c 1048576 /dev/urandom >fake.iso
run() { publish-iso --repo "$TMPDIR/repo" --key release_key --iso fake.iso --no-site "$@"; }

# The release commit of `stable`.
run --ref stable --out out --base-url https://example.invalid/v1.0.0
(cd out && sha256sum -c SHA256SUMS)
ssh-keygen -Y verify -f repo/release/allowed_signers -I release -n file \
  -s out/SHA256SUMS.sig <out/SHA256SUMS
jq -e '.version == "1.0.0" and .channel == "stable" and (.commit | length) == 40
  and .iso.name == "hinteros-1.0.0-x86_64.iso" and .iso.size == 1048576
  and .iso.url == "https://example.invalid/v1.0.0/hinteros-1.0.0-x86_64.iso"
  and .iso.sha256 == ($sums | split(" ")[0])
  and (.signer.fingerprint | startswith("SHA256:"))
  and .notes == "- First item.\n- Second item."' \
  --arg sums "$(cat out/SHA256SUMS)" out/release.json

# Refused: signed by a key not in allowed_signers, unsigned, not a release subject, non-empty out.
for ref in forged unsigned; do
  if run --ref "$ref" --out "out-$ref"; then
    echo "publish-iso accepted $ref" >&2
    exit 1
  fi
done
if run --ref stable --out out; then
  echo "publish-iso overwrote a non-empty output directory" >&2
  exit 1
fi

touch "$out"
