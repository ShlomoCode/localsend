#!/bin/bash
# Source-reviewed cloud-host module; normal signed APT installs remain in guest.
# Caller must complete cloud-init without an automatic packages: installation,
# provide PREP_DEADLINE (epoch seconds), and let its SSH wrapper honor SSH_TIMEOUT.
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux ]] || { echo 'Cloud Linux runner required' >&2; exit 1; }
[[ ${PREP_DEADLINE:-} =~ ^[0-9]+$ ]] || { echo 'PREP_DEADLINE required' >&2; exit 1; }
vm=/home/runner/3417-vm
cache="$vm/package-cache"
evidence="$PWD/evidence/vm/package-preparation"
scripts="$PWD/support/diagnostics"
mkdir -p "$evidence"
status="$evidence/phases.tsv"
printf 'utc\tphase\tstate\tremaining_seconds\tstage_limit\n' > "$status"
remaining() { echo "$((PREP_DEADLINE - $(date +%s)))"; }
record() { printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$(remaining)" "${3:-0}" | tee -a "$status"; }
active=initialization
retain_cache_receipts() {
  # Keep binary archives outside upload evidence, including on stage failure.
  [[ -d "$cache" ]] || return 0
  mkdir -p "$evidence/cache-receipts"
  local item
  local retained=()
  for item in inputs receipts manifest.json validated-manifest.json final-receipt.json; do
    [[ ! -e "$cache/$item" ]] || retained+=("$cache/$item")
  done
  # Outer preparation TERM has a 10-second kill grace; reserve time to exit.
  (( ${#retained[@]} == 0 )) || timeout --signal=TERM --kill-after=1s 5s cp -a "${retained[@]}" "$evidence/cache-receipts/"
}
abort_phase() {
  local rc=$1
  trap - ERR TERM INT
  record "$active" "failed:$rc" || true
  retain_cache_receipts || true
  # Caller always collects /home/probe/3417-package-provenance on failure.
  exit "$rc"
}
trap 'abort_phase "$?"' ERR
trap 'abort_phase 143' TERM
trap 'abort_phase 130' INT
budget() {
  local left
  left=$(remaining)
  (( left > 0 )) || { record "$active" deadline-exhausted; return 1; }
  if (( left < $1 )); then echo "$left"; else echo "$1"; fi
}
guest() {
  local limit=$1
  shift
  SSH_TIMEOUT="$limit" timeout --signal=TERM --kill-after=10s "$limit" "$vm/ssh" "$@"
}
guest_script() {
  local limit=$1 remote_limit
  remote_limit=$((limit - 10))
  (( remote_limit > 0 )) || return 1
  guest "$limit" "sudo timeout --signal=TERM --kill-after=5s '$remote_limit' bash -s"
}
copy() {
  local limit=$1
  shift
  timeout --signal=TERM --kill-after=10s "$limit" scp -i "$vm/key" -P 2222 \
    -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$vm/known_hosts" \
    -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$@"
}

active=cloud-init-and-initial-provenance
limit=$(budget 600)
record "$active" started "$limit"
initial_end=$(( $(date +%s) + limit ))
ssh_ready=0
while (( $(date +%s) < initial_end )); do
  left=$(( initial_end - $(date +%s) ))
  attempt=10
  (( left >= attempt )) || attempt=$left
  if guest "$attempt" 'true' >> "$evidence/ssh-readiness.log" 2>&1; then ssh_ready=1; break; fi
  (( initial_end - $(date +%s) > 2 )) || break
  sleep 2
done
test "$ssh_ready" = 1
limit=$(( initial_end - $(date +%s) ))
guest_script "$limit" > "$evidence/initial-provenance.log" 2>&1 <<'GUEST'
set -euo pipefail
export LC_ALL=C
out=/home/probe/3417-package-provenance
mkdir -p "$out/raw" "$out/verified" /home/probe/3417-package-input /var/tmp/3417-plan-empty/partial
chmod 0755 "$out" "$out/raw" "$out/verified"
chown probe:probe /home/probe/3417-package-input
chmod 0700 /home/probe/3417-package-input
# Initial evidence precedes cloud-init/update admission, including failure cases.
cat /etc/os-release > "$out/os-release.txt"
uname -a > "$out/kernel.txt"
cloud-init status --long > "$out/cloud-init-before.txt" 2>&1 || true
cp /etc/cloud/cloud.cfg "$out/cloud.cfg"
cp /var/lib/cloud/instance/user-data.txt "$out/cloud-user-data.txt"
cp /var/lib/dpkg/status "$out/dpkg-status-before"
dpkg-query -W > "$out/dpkg-query-before.txt"
apt-config dump > "$out/apt-config-before.txt"
apt-mark showhold > "$out/apt-holds-before.txt"
tar -C / -cf "$out/raw/apt-config-and-keyring.tar" etc/apt usr/share/keyrings/ubuntu-archive-keyring.gpg
cloud-init status --wait --long > "$out/cloud-init-complete.txt" 2>&1
test -e /var/lib/cloud/instance/boot-finished
# Preserve the actual source/configuration bytes after cloud-init completes;
# the earlier archive intentionally records only the initial state.
tar -C / -cf "$out/raw/apt-config-and-keyring-post-cloud-init.tar" etc/apt usr/share/keyrings/ubuntu-archive-keyring.gpg
sha256sum "$out/raw/apt-config-and-keyring-post-cloud-init.tar" > "$out/raw/apt-config-and-keyring-post-cloud-init.sha256"
apt-config dump > "$out/apt-config-post-cloud-init.txt"
# A successful cloud-init status does not authenticate the package index chain.
test "$(id -u probe)" = 1000
test "$(dpkg-query -W -f='${Version}' base-files)" = 13ubuntu10.4
test "$(dpkg-query -W -f='${Version}' apt)" = 2.8.3
test "$(dpkg --print-architecture)" = amd64
test -z "$(dpkg --print-foreign-architectures)"
test -z "$(apt-mark showhold)"
python3 - <<'PY'
import pathlib
root = pathlib.Path('/etc/apt')
main = root / 'sources.list'
if main.exists() and any(x.strip() and not x.lstrip().startswith('#') for x in main.read_text().splitlines()):
    raise ValueError('Unexpected active sources.list')
parts = root / 'sources.list.d'
active = sorted(x for x in parts.iterdir() if x.suffix in ('.list', '.sources'))
if active != [parts / 'ubuntu.sources']:
    raise ValueError('Additional source files are not admitted')
paragraphs = []
for block in (parts / 'ubuntu.sources').read_text().split('\n\n'):
    values = {}
    for line in block.splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        key, sep, value = line.partition(':')
        if not sep or key in values: raise ValueError('Malformed source stanza')
        values[key] = value.strip()
    if values: paragraphs.append(values)
common = {'Types':'deb', 'Components':'main restricted universe multiverse',
          'Signed-By':'/usr/share/keyrings/ubuntu-archive-keyring.gpg', 'Snapshot':'20260726T000000Z'}
expected = [dict(common, URIs='http://archive.ubuntu.com/ubuntu', Suites='noble noble-updates'),
            dict(common, URIs='http://security.ubuntu.com/ubuntu', Suites='noble-security')]
if paragraphs != expected: raise ValueError('Guest sources differ from the exact signed baseline')
PY
GUEST
record "$active" passed "$limit"
# Save initial raw evidence before spending the acquisition/install budget.
guest "$(budget 60)" 'sudo tar -C /home/probe -cf - 3417-package-provenance' > "$evidence/initial-provenance.tar"

active=signed-update-and-package-plan
limit=$(budget 600)
record "$active" started "$limit"
guest_script "$limit" > "$evidence/signed-update.log" 2>&1 <<'GUEST'
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
out=/home/probe/3417-package-provenance
packages=(ubuntu-desktop-minimal flatpak xdg-desktop-portal-gnome xdg-desktop-portal-gtk dbus-user-session openssh-server acl auditd python3-pyatspi)
printf '%s\n' "${packages[@]}" > "$out/requested-packages.txt"
# Any index download error fails admission; never silently reuse stale indexes.
apt-get -o APT::Update::Error-Mode=any -o Acquire::AllowInsecureRepositories=false \
  -o Acquire::AllowDowngradeToInsecureRepositories=false -o APT::Get::AllowUnauthenticated=false \
  update 2>&1 | tee "$out/apt-update.txt"
apt-get -o APT::Get::IndexTargets::Format= indextargets > "$out/index-targets.txt"
cp /var/lib/apt/lists/*InRelease "$out/raw/"
for suite in noble noble-updates noble-security; do
  mapfile -t signed < <(find "$out/raw" -maxdepth 1 -type f -name "*_dists_${suite}_InRelease")
  test "${#signed[@]}" = 1
  gpgv --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg \
    --output "$out/verified/$suite.Release" "${signed[0]}" > "$out/verified/$suite.gpgv.txt" 2>&1
done
python3 - <<'PY'
import hashlib, json, pathlib, re, subprocess
out = pathlib.Path('/home/probe/3417-package-provenance')
releases = {}
for suite in ('noble','noble-updates','noble-security'):
    checksums = {}; section = False
    for line in (out/'verified'/f'{suite}.Release').read_text().splitlines():
        if line == 'SHA256:': section = True; continue
        if section and not line.startswith(' '): section = False
        if section:
            sha, size, name = line.split()
            if not re.fullmatch('[0-9a-f]{64}', sha) or name in checksums: raise ValueError('Release SHA256 record')
            checksums[name] = (sha, int(size))
    if not checksums: raise ValueError('No authenticated Release SHA256 records')
    releases[suite] = checksums
receipts = []; combined = bytearray(); seen = set()
for block in (out/'index-targets.txt').read_text().split('\n\n'):
    fields = {}
    for line in block.splitlines():
        key, sep, value = line.partition(':')
        if sep: fields[key] = value.strip()
    if fields.get('Identifier') != 'Packages': continue
    if fields.get('Trusted') != 'yes': raise ValueError('APT did not admit the signed index as trusted')
    uri = fields.get('URI','')
    match = re.fullmatch(r'https://snapshot\.ubuntu\.com/ubuntu/20260726T000000Z/dists/(noble(?:-updates|-security)?)/(.+)', uri)
    if not match: raise ValueError('Unexpected index URI: '+uri)
    suite, uri_key = match.groups(); key = fields.get('MetaKey','')
    if uri_key != key or not re.fullmatch(r'(main|restricted|universe|multiverse)/binary-amd64/Packages', key):
        raise ValueError('Unexpected Packages target')
    name = fields.get('Filename',''); path = pathlib.Path(name)
    if path.parent != pathlib.Path('/var/lib/apt/lists') or path.is_symlink() or not path.is_file():
        raise ValueError('Unsafe/missing cached index')
    identity = (suite,key)
    if identity in seen: raise ValueError('Duplicate index target')
    seen.add(identity)
    data = subprocess.check_output(['/usr/lib/apt/apt-helper','cat-file',str(path)])
    observed = (hashlib.sha256(data).hexdigest(), len(data))
    if releases[suite].get(key) != observed: raise ValueError('Signed index integrity mismatch: '+uri)
    target = out/'verified'/f'{suite}-{key.replace("/","_")}'
    target.write_bytes(data)
    combined.extend(data); combined.extend(b'\n\n')
    receipts.append(dict(uri=uri, suite=suite, metaKey=key, cachedFilename=name, sha256=observed[0], size=observed[1]))
expected = {(s,f'{c}/binary-amd64/Packages') for s in releases for c in ('main','restricted','universe','multiverse')}
if seen != expected: raise ValueError('Missing or extra signed component index')
(out/'Packages.concat').write_bytes(combined)
(out/'verified/index-chain.json').write_text(json.dumps(receipts,indent=2)+'\n')
PY
apt-cache policy "${packages[@]}" base-files apt > "$out/package-policy.txt"
# An empty dedicated cache makes both resolver plans independent of cache seeding.
apt-get --print-uris -y -o Dir::Cache::archives=/var/tmp/3417-plan-empty install "${packages[@]}" > "$out/apt-print-uris.txt" 2>&1
cat > "$out/fingerprint.sh" <<'STATE'
#!/bin/bash
set -euo pipefail
export LC_ALL=C
sha256sum /var/lib/dpkg/status /usr/share/keyrings/ubuntu-archive-keyring.gpg
find /etc/apt /var/lib/apt/lists -type f ! -name lock ! -path '*/partial/*' -print0 | sort -z | xargs -0 -r sha256sum
apt-config dump
apt-mark showhold
dpkg-query -W
STATE
bash "$out/fingerprint.sh" > "$out/state-before.txt"
tar -C /home/probe -cf /home/probe/3417-package-provenance.tar 3417-package-provenance
chmod 0644 /home/probe/3417-package-provenance.tar
GUEST
record "$active" passed "$limit"
copy "$(budget 120)" probe@127.0.0.1:/home/probe/3417-package-provenance.tar "$evidence/signed-provenance.tar"
tar -C "$evidence" -xf "$evidence/signed-provenance.tar"
inputs="$evidence/3417-package-provenance"

active=host-exact-archive-prefetch
limit=$(budget 1200)
record "$active" started "$limit"
timeout --signal=TERM --kill-after=10s "$limit" node "$scripts/3417-package-cache.cjs" download \
  --uris "$inputs/apt-print-uris.txt" --packages "$inputs/Packages.concat" --output "$cache" \
  > "$evidence/host-prefetch.jsonl" 2> "$evidence/host-prefetch-errors.txt"
retain_cache_receipts
record "$active" passed "$limit"

active=transfer-and-guest-cache-admission
limit=$(budget 300)
record "$active" started "$limit"
phase_end=$(( $(date +%s) + limit ))
phase_left() { local left=$((phase_end - $(date +%s))); (( left > 0 )); echo "$left"; }
# Bundle only validated regular package entries as bare cache basenames.
node - "$cache/validated-manifest.json" "$evidence/bare-files.txt" <<'NODE'
const fs = require('node:fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const names = manifest.files.map(x => x.filename);
if (!names.length || new Set(names).size !== names.length || names.some(x => !/^[A-Za-z0-9][A-Za-z0-9.+_%:~-]*\.deb$/.test(x))) throw Error('Unsafe bundle member');
fs.writeFileSync(process.argv[3], names.join('\n')+'\n', {flag:'wx'});
NODE
timeout "$(phase_left)" tar -C "$cache/archives" -cf "$vm/package-cache.tar" \
  --verbatim-files-from -T "$evidence/bare-files.txt"
manifest_hash=$(timeout "$(phase_left)" sha256sum "$cache/validated-manifest.json" | cut -d' ' -f1)
archive_hash=$(timeout "$(phase_left)" sha256sum "$vm/package-cache.tar" | cut -d' ' -f1)
printf '%s  validated-manifest.json\n%s  package-cache.tar\n' "$manifest_hash" "$archive_hash" > "$evidence/transfer-hashes.txt"
copy "$(phase_left)" "$vm/package-cache.tar" "$cache/validated-manifest.json" "$scripts/3417-guest-cache.py" probe@127.0.0.1:/home/probe/3417-package-input/
guest_script "$(phase_left)" > "$evidence/guest-cache-admission.log" 2>&1 <<GUEST
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
out=/home/probe/3417-package-provenance
packages=(ubuntu-desktop-minimal flatpak xdg-desktop-portal-gnome xdg-desktop-portal-gtk dbus-user-session openssh-server acl auditd python3-pyatspi)
bash "\$out/fingerprint.sh" > "\$out/state-recheck.txt"
cmp "\$out/state-before.txt" "\$out/state-recheck.txt"
apt-get --print-uris -y -o Dir::Cache::archives=/var/tmp/3417-plan-empty install "\${packages[@]}" > "\$out/apt-print-uris-recheck.txt" 2>&1
cmp "\$out/apt-print-uris.txt" "\$out/apt-print-uris-recheck.txt"
python3 /home/probe/3417-package-input/3417-guest-cache.py \
 /home/probe/3417-package-input/validated-manifest.json /home/probe/3417-package-input/package-cache.tar \
 '$manifest_hash' '$archive_hash'
GUEST
record "$active" passed "$limit"

active=ordinary-apt-install
limit=$(budget 1200)
record "$active" started "$limit"
guest_script "$limit" > "$evidence/ordinary-install.log" 2>&1 <<'GUEST'
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
out=/home/probe/3417-package-provenance
# No --no-download, --ignore-missing, direct dpkg, or reduced recommends policy.
# Any fallback fetch is observable in this bounded normal-install output.
bash "$out/fingerprint.sh" > "$out/state-pre-install.txt"
cmp "$out/state-before.txt" "$out/state-pre-install.txt"
packages=(ubuntu-desktop-minimal flatpak xdg-desktop-portal-gnome xdg-desktop-portal-gtk dbus-user-session openssh-server acl auditd python3-pyatspi)
apt-get -y install "${packages[@]}" 2>&1 | tee "$out/apt-install.txt"
dpkg-query -W > "$out/dpkg-query-after.txt"
dpkg-query -W -f='${Package}\t${Architecture}\t${Version}\t${db:Status-Status}\n' > "$out/dpkg-package-outcomes.tsv"
cp /var/lib/dpkg/status "$out/dpkg-status-after"
dpkg --audit > "$out/dpkg-audit-after.txt"
test ! -s "$out/dpkg-audit-after.txt"
test "$(dpkg-query -W -f='${Version}' base-files)" = 13ubuntu10.4
printf 'normal-install-complete\n' > "$out/install-pass.txt"
tar -C /home/probe -cf /home/probe/3417-package-provenance-after.tar 3417-package-provenance
chmod 0644 /home/probe/3417-package-provenance-after.tar
GUEST
record "$active" passed "$limit"
copy "$(budget 120)" probe@127.0.0.1:/home/probe/3417-package-provenance-after.tar "$evidence/installed-provenance.tar"
active=package-preparation-complete
record "$active" passed
# Caller continues original Flatpak/runtime provenance and GNOME readiness gates.
