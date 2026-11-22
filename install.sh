#!/usr/bin/env bash
# Installs a Frontseat fleet: the hub, its spoke and tenant zero, from a
# release of this repository (the fleet-v<version> tags).
#
# One installer, one profile per kind of cluster. Today: k3s, a single
# Linux server that this script turns into the cluster (aws and azure
# come next, on a cluster the platform already runs).
#
#   curl -fsSL https://raw.githubusercontent.com/frontseat-dev/frontseat-releases/main/install.sh -o install.sh
#   sudo bash install.sh --zone fleet.example.com --operator you@example.com \
#     --data-disk /dev/disk/by-id/nvme-<model>_<serial> --wipe-data-disk \
#     --registry-token ~/github-pull --github-oauth ~/github-oauth
#
# Run it again to upgrade (--version) or to change the site; what it was
# told before is kept in /etc/frontseat. `install.sh --help` lists it all.
set -euo pipefail

REPO=frontseat-dev/frontseat-releases
ETC=/etc/frontseat
DATA=/var/lib/frontseat
VG=frontseat

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Installs a Frontseat fleet (hub, spoke and tenant zero) on this machine.

Where and what:
  --profile NAME          the kind of cluster: k3s (default; aws and azure later)
  --version VERSION       the fleet release (default: the latest fleet-v* release)
  --bundle FILE           install from a bundle already on this machine, not a download

The site (kept in /etc/frontseat/site.yaml; needed on the first run):
  --zone ZONE             the DNS zone the fleet answers under: login.ZONE,
                          hub.ZONE, and NAME.ZONE / *.NAME.ZONE per tenant
  --operator EMAIL        an operator, by the email they sign in with
                          (repeatable; the first owns tenant zero)

Storage (one of; the fleet's volumes, the build CAS among them, stay off
the operating system's disk):
  --data-disk DEVICE      a whole disk for the fleet, best by /dev/disk/by-id (NVMe
                          names can swap between boots): LVM volume group "frontseat",
                          a data volume at /var/lib/frontseat and a thin pool for
                          cache volumes
  --wipe-data-disk        erase what DEVICE holds today (required when it holds anything)
  --data-percent N        the data volume's share of the disk, the rest the pool (default 50)
  --data-dir DIR          a directory on a disk other than the OS's, already mounted;
                          cache volumes are then full copies (no thin pool)
  --allow-os-disk         with neither: keep everything on the OS disk (a trial)

Credentials (copied to /etc/frontseat/credentials, mode 600; needed once):
  --registry-token FILE   a token that reads ghcr.io/frontseat-dev's packages
  --github-oauth FILE     the GitHub OAuth app people sign in with: client id, then secret
  --runner-app-key FILE   the frontseat-runners GitHub App's private key (optional)
  --ca-cert FILE          the site's CA (PEM) the fleet's certificates are signed by;
  --ca-key FILE           without them, the installer makes one

  --no-kata               don't run CI runners in Kata VMs, even where /dev/kvm exists
  -h, --help              this
EOF
}

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "needs $1${2:+ ($2)}"; }

profile=k3s version="" bundle="" zone="" operators=()
data_disk="" wipe=false data_percent=50 data_dir="" allow_os_disk=false
registry_token="" github_oauth="" runner_key="" ca_cert="" ca_key="" kata=auto
while (($#)); do
  case "$1" in
    --profile) profile="${2:?}"; shift ;;
    --version) version="${2:?}"; version="${version#fleet-}"; version="${version#v}"; shift ;;
    --bundle) bundle="${2:?}"; shift ;;
    --zone) zone="${2:?}"; shift ;;
    --operator) operators+=("${2:?}"); shift ;;
    --data-disk) data_disk="${2:?}"; shift ;;
    --wipe-data-disk) wipe=true ;;
    --data-percent) data_percent="${2:?}"; shift ;;
    --data-dir) data_dir="${2:?}"; shift ;;
    --allow-os-disk) allow_os_disk=true ;;
    --registry-token) registry_token="${2:?}"; shift ;;
    --github-oauth) github_oauth="${2:?}"; shift ;;
    --runner-app-key) runner_key="${2:?}"; shift ;;
    --ca-cert) ca_cert="${2:?}"; shift ;;
    --ca-key) ca_key="${2:?}"; shift ;;
    --no-kata) kata=false ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option $1" ;;
  esac
  shift
done

case "$profile" in
  k3s) ;;
  aws|eks|azure|aks) die "the $profile profile is not released yet; k3s is" ;;
  *) die "no profile $profile (k3s)" ;;
esac

# --- Preflight -------------------------------------------------------------

[[ "$(uname -s)" == Linux ]] || die "the k3s profile installs on Linux"
((EUID == 0)) || die "run as root (sudo bash install.sh ...)"
case "$(uname -m)" in
  x86_64) arch=amd64 isa=x86-64 ;;
  aarch64|arm64) arch=arm64 isa=aarch64 ;;
  *) die "no build for $(uname -m)" ;;
esac
for c in curl tar sha256sum openssl systemctl findmnt lsblk; do need "$c"; done
[[ -n "$data_disk" && -n "$data_dir" ]] && die "--data-disk or --data-dir, not both"
[[ "$data_percent" =~ ^[0-9]+$ ]] && ((data_percent >= 10 && data_percent <= 90)) \
  || die "--data-percent is a number from 10 to 90"
if [[ -n "$ca_cert" || -n "$ca_key" ]]; then
  [[ -f "$ca_cert" && -f "$ca_key" ]] || die "--ca-cert and --ca-key go together, both files"
fi

mkdir -p "$ETC" "$ETC/credentials" "$ETC/ca"
chmod 700 "$ETC" "$ETC/credentials" "$ETC/ca"

# Debian and Ubuntu: what the steps below need, when it is missing.
apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  command -v apt-get >/dev/null || die "needs the packages ${missing[*]}"
  say "Installing ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

# --- The release -----------------------------------------------------------

lib="$DATA"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -z "$bundle" ]]; then
  if [[ -z "$version" ]]; then
    version="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" \
      | sed -n 's/^ *"tag_name": *"fleet-v\([^"]*\)".*/\1/p' | head -1)"
    [[ -n "$version" ]] || die "no fleet release found in $REPO"
  fi
  say "Downloading Frontseat fleet $version"
  base="https://github.com/$REPO/releases/download/fleet-v$version"
  curl -fsSL -o "$work/frontseat-fleet-$version.tar.gz" "$base/frontseat-fleet-$version.tar.gz"
  curl -fsSL -o "$work/checksums.txt" "$base/checksums.txt"
  (cd "$work" && grep " frontseat-fleet-$version.tar.gz\$" checksums.txt | sha256sum -c --quiet -) \
    || die "frontseat-fleet-$version.tar.gz does not match the release's checksums.txt"
  bundle="$work/frontseat-fleet-$version.tar.gz"
fi
[[ -f "$bundle" ]] || die "no bundle at $bundle"
tar -C "$work" -xzf "$bundle"
src="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'frontseat-fleet-*' | head -1)"
[[ -n "$src" && -f "$src/versions.env" ]] || die "$bundle is not a fleet bundle"
# shellcheck disable=SC1091
. "$src/versions.env"
version="$FRONTSEAT_VERSION"

# --- Storage: the data disk ------------------------------------------------

# The disks / is on, through any LVM, LUKS or RAID between them.
root_disks="$(lsblk -snlo NAME,TYPE "$(findmnt -nvo SOURCE /)" 2>/dev/null | awk '$2 == "disk" {print $1}')"
[[ -n "$root_disks" ]] || die "can't tell which disk / is on"

storage_disk() {
  local dev name
  dev="$(readlink -f "$1")"
  [[ -b "$dev" ]] || die "$1 is not a block device"
  [[ "$(lsblk -dno TYPE "$dev")" == disk ]] || die "$dev is not a whole disk"
  name="$(lsblk -dno NAME "$dev")"
  ! grep -qx "$name" <<<"$root_disks" || die "$dev holds the operating system (/)"
  apt_install lvm2 thin-provisioning-tools
  modprobe dm_thin_pool

  if vgs "$VG" >/dev/null 2>&1; then
    pvs --noheadings -o pv_name,vg_name | grep -q "^ *$dev  *$VG\$" \
      || die "volume group $VG already exists on another disk"
    say "Data disk $dev already holds volume group $VG"
  else
    if lsblk -no MOUNTPOINTS "$dev" | grep -q .; then
      die "$dev has mounted filesystems or active swap; unmount them first"
    fi
    if [[ -n "$(lsblk -no FSTYPE,PTTYPE "$dev" | tr -d ' \n')" ]]; then
      $wipe || { lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev" >&2;
                 die "$dev is not empty; --wipe-data-disk erases it"; }
    fi
    say "Making $dev the data disk (volume group $VG)"
    local p
    for p in $(lsblk -lnpo NAME "$dev" | tail -n +2 | tac); do wipefs -qa "$p"; done
    wipefs -qa "$dev"
    pvcreate -qy "$dev"
    vgcreate -q "$VG" "$dev"
    lvcreate -qy -n data -l "${data_percent}%VG" "$VG"
    mkfs.ext4 -q -L frontseat-data "/dev/$VG/data"
    # The rest is TopoLVM's: a thin pool, its metadata out of the 5% left.
    lvcreate -qy --type thin-pool -n cache -l 95%FREE "$VG"
  fi

  mkdir -p "$DATA"
  local uuid
  uuid="$(blkid -s UUID -o value "/dev/$VG/data")"
  grep -q "UUID=$uuid" /etc/fstab \
    || echo "UUID=$uuid $DATA ext4 defaults,noatime 0 2  # frontseat data" >>/etc/fstab
  findmnt -n "$DATA" >/dev/null || mount "$DATA"
  cache_driver=topolvm
}

storage_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || die "no directory $dir"
  [[ "$(stat -c %d "$dir")" != "$(stat -c %d /)" ]] \
    || die "$dir is on the operating system's disk; give a directory on another disk"
  lib="$dir/frontseat"
  cache_driver=hostpath
}

if [[ -n "$data_disk" ]]; then
  storage_disk "$data_disk"
elif [[ -n "$data_dir" ]]; then
  storage_dir "$data_dir"
elif vgs "$VG" >/dev/null 2>&1; then
  # A run before this one made the data disk.
  findmnt -n "$DATA" >/dev/null || mount "$DATA"
  cache_driver=topolvm
elif [[ -f "$ETC/host.yaml" ]] && grep -q '^  dataDir:' "$ETC/host.yaml"; then
  lib="$(sed -n 's/^  dataDir: "\(.*\)\/csi-hostpath"$/\1/p' "$ETC/host.yaml")"
  cache_driver=hostpath
elif $allow_os_disk; then
  cache_driver=hostpath
else
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS >&2
  die "where do the fleet's volumes go? --data-disk (a disk other than $(echo $root_disks)) or --data-dir; --allow-os-disk for a trial"
fi
mkdir -p "$lib/storage" "$lib/bin"

# --- The site --------------------------------------------------------------

if [[ -n "$zone" ]]; then
  ((${#operators[@]})) || die "--zone needs at least one --operator"
  {
    echo "# The site, as install.sh was told it. Edit and run install.sh again."
    echo "profile:"
    echo "  dnsZone: \"$zone\""
    echo "hub:"
    echo "  spokes:"
    echo "    - name: k3s"
    echo "      dnsZone: \"$zone\""
    echo "      externalHttpsPort: \"443\""
    echo "  loginURL: \"https://login.$zone\""
    echo "  portalURL: \"https://hub.$zone\""
    echo "  operators:"
    for o in "${operators[@]}"; do echo "    - \"$o\""; done
    echo "  mail:"
    echo "    from: \"noreply@$zone\""
  } >"$ETC/site.yaml"
fi
[[ -f "$ETC/site.yaml" ]] || die "first run: --zone and --operator are needed"
zone="$(sed -n 's/^  dnsZone: "\(.*\)"$/\1/p' "$ETC/site.yaml" | head -1)"
login="https://login.$zone"

put() { install -m 600 "$1" "$ETC/credentials/$2"; }
[[ -z "$registry_token" ]] || put "$registry_token" github-pull
[[ -z "$github_oauth" ]] || put "$github_oauth" github-oauth
[[ -z "$runner_key" ]] || put "$runner_key" github-runner-app.pem
[[ -s "$ETC/credentials/github-pull" ]] || die "first run: --registry-token is needed"
[[ "$(grep -c . "$ETC/credentials/github-oauth" 2>/dev/null)" == 2 ]] \
  || die "first run: --github-oauth is needed (a file: client id, then secret)"

# The CA every certificate of the fleet is signed by, and the API server
# checks the realm's with.
if [[ -n "$ca_cert" ]]; then
  install -m 644 "$ca_cert" "$ETC/ca/rootCA.pem"
  install -m 600 "$ca_key" "$ETC/ca/rootCA-key.pem"
elif [[ ! -f "$ETC/ca/rootCA.pem" ]]; then
  say "Making the site's CA"
  openssl req -x509 -new -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -subj "/O=Frontseat/CN=Frontseat $zone CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$ETC/ca/rootCA-key.pem" -out "$ETC/ca/rootCA.pem" 2>/dev/null
  chmod 600 "$ETC/ca/rootCA-key.pem"
fi
if command -v update-ca-certificates >/dev/null; then
  install -m 644 "$ETC/ca/rootCA.pem" /usr/local/share/ca-certificates/frontseat.crt
  update-ca-certificates >/dev/null 2>&1
fi

# --- The node --------------------------------------------------------------

# The seccomp profile a sandboxing box runs under, and on a host with
# AppArmor, the profile it runs under in place of containerd's default.
install -D -m 644 "$src/node/seccomp/bubblewrap.json" /var/lib/kubelet/seccomp/frontseat/bubblewrap.json
apparmor=false
if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" == Y ]]; then
  apt_install apparmor
  install -m 644 "$src/node/apparmor/frontseat-bubblewrap" /etc/apparmor.d/frontseat-bubblewrap
  apparmor_parser -r /etc/apparmor.d/frontseat-bubblewrap
  apparmor=true
fi
[[ "$kata" == auto ]] && { [[ -c /dev/kvm ]] && kata=true || kata=false; }
fuse=false; [[ -c /dev/fuse ]] && fuse=true

{
  echo "# This host, as install.sh found it. Rewritten on every run."
  echo "profile:"
  echo "  isa: $isa"
  echo "  apparmor: $apparmor"
  echo "  kata: $kata"
  echo "  devices:"
  echo "    fuse: $fuse"
  if [[ "$cache_driver" == hostpath ]]; then
    echo "  cache:"
    echo "    driver: hostpath"
    echo "    class: cache-hostpath"
    echo "    deviceClass: \"\""
    echo "csiHostpath:"
    echo "  dataDir: \"$lib/csi-hostpath\""
  fi
} >"$ETC/host.yaml"

install -m 644 "$src/fleet/profiles/audit-policy.yaml" "$ETC/audit-policy.yaml"

# --- k3s -------------------------------------------------------------------

# Traefik off (Envoy Gateway is the edge); volumes on the data disk; the
# API server takes the realm's sign-in and records what people do.
mkdir -p /etc/rancher/k3s
cat >"$work/k3s.yaml" <<EOF
# Written by Frontseat's install.sh.
disable: [traefik]
write-kubeconfig-mode: "0600"
default-local-storage-path: $lib/storage
kube-apiserver-arg:
  - oidc-issuer-url=$login/realms/frontseat
  - oidc-client-id=hub-api
  - oidc-ca-file=$ETC/ca/rootCA.pem
  - oidc-username-claim=email
  - oidc-username-prefix=realm:
  - oidc-groups-claim=groups
  - oidc-groups-prefix=realm:
  - audit-policy-file=$ETC/audit-policy.yaml
  - audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log
  - audit-log-maxage=30
  - audit-log-maxbackup=10
  - audit-log-maxsize=100
EOF
k3s_changed=false
# k3s starts only once the data disk is mounted: without it, the volumes
# would go to the OS disk's empty mount point.
if findmnt -n "$DATA" >/dev/null && [[ "$lib" == "$DATA" ]]; then
  mkdir -p /etc/systemd/system/k3s.service.d
  printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA" >"$work/k3s-data.conf"
  cmp -s "$work/k3s-data.conf" /etc/systemd/system/k3s.service.d/frontseat-data.conf \
    || { install -m 644 "$work/k3s-data.conf" /etc/systemd/system/k3s.service.d/frontseat-data.conf; systemctl daemon-reload; }
fi

# The API server checks a person's token with the realm at login.<zone>,
# from the host: the host resolves the hub's names to itself, whatever
# the site's DNS says yet.
ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
[[ -n "$ip" ]] || die "no IPv4 address to reach this host by"
sed -i '/# frontseat$/d' /etc/hosts
echo "$ip login.$zone hub.$zone # frontseat" >>/etc/hosts

cmp -s "$work/k3s.yaml" /etc/rancher/k3s/config.yaml || { install -m 600 "$work/k3s.yaml" /etc/rancher/k3s/config.yaml; k3s_changed=true; }

if [[ "$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')" != "$K3S_VERSION" ]]; then
  say "Installing k3s $K3S_VERSION"
  curl -fsSL -o "$work/k3s-install.sh" "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION//+/%2B}/install.sh"
  INSTALL_K3S_VERSION="$K3S_VERSION" sh "$work/k3s-install.sh" server
elif $k3s_changed; then
  say "Restarting k3s with its new configuration"
  systemctl restart k3s
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
say "Waiting for the node"
for _ in $(seq 60); do kubectl get nodes >/dev/null 2>&1 && break; sleep 5; done
kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null

# --- The fleet -------------------------------------------------------------

fetch_tool() {
  local name="$1" ver="$2" url="$3" sums="$4" file="$5" member="$6"
  [[ -x "$lib/bin/$name-$ver" ]] && return 0
  curl -fsSL -o "$work/$file" "$url/$file"
  curl -fsSL -o "$work/$name.sums" "$sums"
  (cd "$work" && grep " $file\$" "$name.sums" | sha256sum -c --quiet -) \
    || die "$file does not match its checksum"
  tar -C "$work" -xzf "$work/$file" "$member"
  install -m 755 "$work/$member" "$lib/bin/$name-$ver"
}
fetch_tool helm "$HELM_VERSION" https://get.helm.sh \
  "https://get.helm.sh/helm-v$HELM_VERSION-linux-$arch.tar.gz.sha256sum" \
  "helm-v$HELM_VERSION-linux-$arch.tar.gz" "linux-$arch/helm"
fetch_tool helmfile "$HELMFILE_VERSION" "https://github.com/helmfile/helmfile/releases/download/v$HELMFILE_VERSION" \
  "https://github.com/helmfile/helmfile/releases/download/v$HELMFILE_VERSION/helmfile_${HELMFILE_VERSION}_checksums.txt" \
  "helmfile_${HELMFILE_VERSION}_linux_$arch.tar.gz" helmfile
mkdir -p "$work/path"
ln -sf "$lib/bin/helm-$HELM_VERSION" "$work/path/helm"
ln -sf "$lib/bin/helmfile-$HELMFILE_VERSION" "$work/path/helmfile"
export PATH="$work/path:$PATH"

export HELM_REGISTRY_CONFIG="$ETC/credentials/registry.json"
helm registry login ghcr.io --username frontseat --password-stdin <"$ETC/credentials/github-pull" >/dev/null

say "Installing Frontseat fleet $version"
export CAROOT="$ETC/ca" FRONTSEAT_CONFIG="$ETC/credentials"
helmfile -f "$src/fleet/deploy/helmfile.yaml" -e k3s \
  --state-values-file "$src/release.yaml" \
  --state-values-file "$ETC/host.yaml" \
  --state-values-file "$ETC/site.yaml" \
  sync

echo "$version" >"$ETC/version"
cat <<EOF

Frontseat fleet $version is installed.

  DNS     point $zone, *.$zone and *.zero.$zone (each tenant's *.NAME.$zone) at $ip
  CA      browsers trust $ETC/ca/rootCA.pem
  GitHub  the OAuth app's callback: $login/realms/frontseat/broker/github/endpoint
  Hub     https://hub.$zone   (sign in with GitHub as an operator)
  Login   $login   (admin: Secret keycloak-admin in fleet)
  Mail    the realm's mail lands in the hub's Mailpit: kubectl port-forward -n fleet svc/mailpit 8025
  Data    $lib ($cache_driver cache volumes)

kubectl here: KUBECONFIG=$KUBECONFIG
EOF
