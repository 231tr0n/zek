#!/usr/bin/env bash
#
# zek - manage zek Kubernetes clusters on the local Docker daemon.
#
# `up` creates the cluster on the first run and reconciles it afterwards:
# with no size flags it restarts the existing nodes, and with --workers/
# --masters it adds or removes nodes to match the requested counts (node
# names and addresses of surviving nodes never change - `clean` recreates a
# worker with a fresh netns). `down` stops it and `destroy` removes it. Several
# clusters can coexist - the --cluster flag (or ZEK_CLUSTER) selects one,
# and every zek container and the network are prefixed with the cluster name.
#
# All state lives on the node containers' own writable layer: the cluster
# survives docker stop/start, docker restart and host reboots, and is gone
# once the containers are removed (destroy, docker rm, ...).
#
# Usage:
#   ./zek.sh [flags] up [--workers N] [--masters M]
#                               first run: create the cluster with N workers
#                               (default 1) and M masters (default 1; M>1
#                               starts the HA load balancer). --lb starts
#                               that load balancer with a single master too.
#                               A bare number (up 2) is a shorthand for
#                               --workers 2. Later runs restart the existing
#                               nodes and, when a size flag or its env twin
#                               is set, add/remove nodes to reach that count.
#                               Workers scale at any time; masters only while
#                               the cluster has a load balancer (M>1 or
#                               --lb; without one the count is locked).
#   ./zek.sh [flags] down       stop every node container (state is kept)
#   ./zek.sh [flags] clean <name>
#                               evict a worker and recreate it with a fresh
#                               netns (drops any CNI iptables/ipsets/bpf residue)
#   ./zek.sh [flags] status     show node containers, their health, and
#                               cluster nodes
#   ./zek.sh [flags] kubectl <args...>
#                               run kubectl against the cluster (may be
#                               piped manifests)
#   ./zek.sh [flags] logs <name>
#                               tail a node container's logs
#   ./zek.sh [flags] destroy    remove the cluster's containers (before any
#                               other container on its network) and the network
#
#   Global flags go before the command. Flags that take a value have an env
#   twin and can be written as --flag value or --flag=value; when both are
#   set the flag wins:
#   --version               print the zek.sh version
#   --latest                use the latest tag of the selected image
#                           repository (ZEK_LATEST=1; by default, the
#                           release-pinned image's repository)
#   --lb                    create the load balancer even in a cluster with
#                           one master, so control-plane nodes can be added
#                           later (ZEK_LB=1; creation-time only)
#   --cluster NAME          cluster to operate on (ZEK_CLUSTER, default zek)
#   --timeout SECONDS       bound for Kubernetes waits (control plane up,
#                           nodes registered, credentials published);
#                           default 600 (ZEK_TIMEOUT; small container/LB
#                           retry budgets are fixed)
#   --image IMAGE           node image (ZEK_IMAGE, default: release-pinned
#                           GHCR image; see DEFAULT_IMAGE)
#   --subnet CIDR           cluster subnet (ZEK_SUBNET, default: first free
#                           172.20.X.0/24)
#   --master-ip IP          first master's IP (ZEK_MASTER_IP, default
#                           <subnet>.2)
#   --dns IP                upstream DNS for the node containers (ZEK_DNS)
#   --pod-cidr CIDR         pod subnet passed to kubeadm (ZEK_POD_CIDR,
#                           default 10.244.0.0/16)
#   --mounts SPEC           extra host bind mounts for the nodes: a
#                           space-separated list of
#                           host-path:container-path[:options] (ZEK_MOUNTS)
#   up-only flags: --workers N (ZEK_WORKERS), --masters M (ZEK_MASTERS).
#
# Env overrides: ZEK_LATEST and ZEK_LB (0/1; same as --latest/--lb) and the
# value flags: ZEK_CLUSTER, ZEK_TIMEOUT, ZEK_IMAGE, ZEK_SUBNET,
# ZEK_MASTER_IP, ZEK_DNS, ZEK_POD_CIDR, ZEK_MOUNTS, ZEK_WORKERS,
# ZEK_MASTERS.
set -euo pipefail

log() { echo "[zek] $*" >&2; }
warn() { echo "[zek] WARNING: $*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

# Shape-check an IPv4 value before it reaches docker (network create,
# --dns) or shell arithmetic (master octet + index). Empty passes (the
# caller's default applies); anything else must be four decimal octets
# 0-255, with a canonical /1-32 prefix required for cidr and forbidden for
# addr.
# A typo dies here - called as a plain statement, before any container
# exists - instead of mid-create leaving partial state behind.
require_ipv4() { # <value> cidr|addr <label>
	if [[ -z $1 ]]; then
		return 0
	fi
	local value=$1 kind=$2 label=$3
	local hint
	case "${kind}" in
		cidr)
			hint="expected an IPv4 CIDR like 172.20.0.0/24"
			[[ ${value} == */* ]] || die "invalid ${label} '${value}' (${hint})"
			;;
		addr)
			hint="expected an IPv4 address like 10.0.0.1"
			[[ ${value} != */* ]] || die "invalid ${label} '${value}' (${hint})"
			;;
		*) die "internal error in require_ipv4: unknown kind '${kind}'" ;;
	esac
	[[ ${value} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
		|| die "invalid ${label} '${value}' (${hint})"
	if [[ ${value} == */* ]]; then
		local prefix=${value##*/}
		# docker reads /08 as /8; reject the ambiguous spelling instead
		# of silently creating a much larger network. /0 is not a usable
		# cluster network either (docker replaces it with its default
		# pool), so require 1-32.
		[[ ${prefix} != 0[0-9]* ]] || die "invalid ${label} '${value}' (${hint})"
		((10#${prefix} >= 1 && 10#${prefix} <= 32)) || die "invalid ${label} '${value}' (${hint})"
	fi
	local -a parts=()
	local octet
	IFS=. read -r -a parts <<< "${value%%/*}"
	for octet in "${parts[@]}"; do
		# The test below rejects leading zeros outright (docker's IP
		# parser does too); 10#... below just keeps the arithmetic
		# decimal instead of octal.
		[[ ${octet} != 0[0-9]* ]] \
			|| die "invalid ${label} '${value}' (${hint})"
		((10#${octet} <= 255)) || die "invalid ${label} '${value}' (${hint})"
	done
	if [[ ${kind} == cidr ]]; then
		# A CIDR whose address is not the network address (10.0.0.5/24)
		# makes the network/gateway/broadcast math wrong, and docker
		# rejects it only later with an unrelated message.
		local net_int mask
		net_int=$(((10#${parts[0]} << 24) | (10#${parts[1]} << 16) | (\
			10#${parts[2]} << 8) | 10#${parts[3]}))
		mask=$(((0xFFFFFFFF << (32 - 10#${value##*/})) & 0xFFFFFFFF))
		(((net_int & mask) == net_int)) \
			|| die "invalid ${label} '${value}' (expected the network address, e.g. 10.0.0.0/24)"
	fi
}

# Script release version, independent of the pinned image version. Bump this
# when cutting a zek.sh release; --version prints it.
ZEK_VERSION="0.3.0"
# Image a released zek.sh uses by default. The version pair is pinned so the
# script does not silently move to different Alpine/Kubernetes versions.
# ZEK_IMAGE/--image override it, e.g. ZEK_IMAGE=zek:latest for a local build.
DEFAULT_IMAGE="ghcr.io/231tr0n/zek:3.24.4-v1.37.2-latest"

# latest_image <image> - replace the tag (or digest) with :latest, keeping
# the repository and any registry port. --latest uses this on the effective
# IMAGE, so a custom --image/ZEK_IMAGE repository still selects its own
# latest tag.
latest_image() {
	local image=${1%%@*}
	if [[ ${image##*/} == *:* ]]; then
		image=${image%:*}
	fi
	printf '%s:latest\n' "${image}"
}

# Settings: environment first (each value flag's env twin), then the flags
# parsed below override them (flag > env > default), then everything is
# validated.
CLUSTER="${ZEK_CLUSTER:-zek}"
WAIT_TIMEOUT="${ZEK_TIMEOUT:-600}"
IMAGE="${ZEK_IMAGE:-${DEFAULT_IMAGE}}"
# Boolean settings: environment first, flags below override it. They are
# validated after the flag loop so a flag can override a bad env value
# (flag > env), and --latest is applied after every --image so the flag
# order does not change which repository it tags.
LATEST="${ZEK_LATEST:-0}"
# --lb requests an LB for a cluster created with a single master, so
# control-plane nodes can be added later. Creation-time only: retrofitting
# one would have to move the kubeadm endpoint, which an existing cluster
# cannot do.
LB="${ZEK_LB:-0}"
SUBNET="${ZEK_SUBNET:-}"
MASTER_IP="${ZEK_MASTER_IP:-}"
DNS="${ZEK_DNS:-}"
# Empty here means "let entrypoint.sh default kubeadm to 10.244.0.0/16".
POD_CIDR="${ZEK_POD_CIDR:-}"
MOUNTS="${ZEK_MOUNTS:-}"
# ZEK_WORKERS is the env twin of --workers. Both worker/master values
# are validated against the *effective* value in cmd_up, after the flags
# below may have overridden them - flag > env must hold even for invalid
# env values. Named ENV_* (not DEFAULT_*): they come from the
# environment, and cmd_up's flags override them. The *presence* flags are
# what make an existing cluster scale: a bare `up` must restart the
# current topology, while an explicitly set env value means "reconcile to
# this count".
ENV_WORKERS="${ZEK_WORKERS:-1}"
ENV_MASTERS="${ZEK_MASTERS:-1}"
WORKERS_ENV_SET=0
[[ -n ${ZEK_WORKERS:-} ]] && WORKERS_ENV_SET=1
MASTERS_ENV_SET=0
[[ -n ${ZEK_MASTERS:-} ]] && MASTERS_ENV_SET=1

# Join credentials published by the first master (read_join_credentials):
# declared here so `set -u` never sees an implicit global.
CRED_ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--cluster)
			shift
			[[ -n ${1:-} ]] || die "--cluster needs a cluster name (check --cluster/ZEK_CLUSTER)"
			CLUSTER="$1"
			shift
			;;
		--cluster=*)
			CLUSTER="${1#*=}"
			[[ -n ${CLUSTER} ]] || die "--cluster needs a cluster name (check --cluster/ZEK_CLUSTER)"
			shift
			;;
		--timeout)
			shift
			[[ -n ${1:-} ]] || die "--timeout needs a number of seconds (check --timeout/ZEK_TIMEOUT)"
			WAIT_TIMEOUT="$1"
			shift
			;;
		--timeout=*)
			WAIT_TIMEOUT="${1#*=}"
			[[ -n ${WAIT_TIMEOUT} ]] || die "--timeout needs a number of seconds (check --timeout/ZEK_TIMEOUT)"
			shift
			;;
		--latest)
			LATEST=1
			shift
			;;
		--lb)
			LB=1
			shift
			;;
		--image)
			shift
			[[ -n ${1:-} ]] || die "--image needs a value (check --image/ZEK_IMAGE)"
			IMAGE="$1"
			shift
			;;
		--image=*)
			IMAGE="${1#*=}"
			[[ -n ${IMAGE} ]] || die "--image needs a value (check --image/ZEK_IMAGE)"
			shift
			;;
		--subnet)
			shift
			[[ -n ${1:-} ]] || die "--subnet needs a value (check --subnet/ZEK_SUBNET)"
			SUBNET="$1"
			shift
			;;
		--subnet=*)
			SUBNET="${1#*=}"
			[[ -n ${SUBNET} ]] || die "--subnet needs a value (check --subnet/ZEK_SUBNET)"
			shift
			;;
		--master-ip)
			shift
			[[ -n ${1:-} ]] || die "--master-ip needs a value (check --master-ip/ZEK_MASTER_IP)"
			MASTER_IP="$1"
			shift
			;;
		--master-ip=*)
			MASTER_IP="${1#*=}"
			[[ -n ${MASTER_IP} ]] || die "--master-ip needs a value (check --master-ip/ZEK_MASTER_IP)"
			shift
			;;
		--dns)
			shift
			[[ -n ${1:-} ]] || die "--dns needs a value (check --dns/ZEK_DNS)"
			DNS="$1"
			shift
			;;
		--dns=*)
			DNS="${1#*=}"
			[[ -n ${DNS} ]] || die "--dns needs a value (check --dns/ZEK_DNS)"
			shift
			;;
		--pod-cidr)
			shift
			[[ -n ${1:-} ]] || die "--pod-cidr needs a value (check --pod-cidr/ZEK_POD_CIDR)"
			POD_CIDR="$1"
			shift
			;;
		--pod-cidr=*)
			POD_CIDR="${1#*=}"
			[[ -n ${POD_CIDR} ]] || die "--pod-cidr needs a value (check --pod-cidr/ZEK_POD_CIDR)"
			shift
			;;
		--mounts)
			shift
			[[ -n ${1:-} ]] || die "--mounts needs a value (check --mounts/ZEK_MOUNTS)"
			MOUNTS="$1"
			shift
			;;
		--mounts=*)
			MOUNTS="${1#*=}"
			[[ -n ${MOUNTS} ]] || die "--mounts needs a value (check --mounts/ZEK_MOUNTS)"
			shift
			;;
		--version)
			printf 'zek %s\n' "${ZEK_VERSION}"
			exit 0
			;;
		*) break ;;
	esac
done
case "${LATEST}" in
	0) ;;
	1) ;;
	*) die "invalid ZEK_LATEST '${LATEST}' (expected 0 or 1; same as --latest)" ;;
esac
case "${LB}" in
	0) ;;
	1) ;;
	*) die "invalid ZEK_LB '${LB}' (expected 0 or 1; same as --lb)" ;;
esac
# Resolve the image last: --latest selects the latest tag of whichever
# repository --image/ZEK_IMAGE chose, regardless of their order.
[[ -n ${IMAGE} ]] || die "--image needs a value (check --image/ZEK_IMAGE)"
[[ ${LATEST} -eq 1 ]] && IMAGE=$(latest_image "${IMAGE}")
[[ ${CLUSTER} =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] \
	|| die "invalid cluster name '${CLUSTER}' (letters, digits, '-' and '_' only; check --cluster/ZEK_CLUSTER)"
{ [[ ${WAIT_TIMEOUT} =~ ^[1-9][0-9]*$ ]] && [[ ${#WAIT_TIMEOUT} -le 5 ]] \
	&& ((10#${WAIT_TIMEOUT} <= 86400)); } \
	|| die "invalid timeout '${WAIT_TIMEOUT}' (expected 1-86400 seconds; check --timeout/ZEK_TIMEOUT)"
require_ipv4 "${SUBNET}" cidr "subnet (--subnet/ZEK_SUBNET)"
require_ipv4 "${MASTER_IP}" addr "master IP (--master-ip/ZEK_MASTER_IP)"
require_ipv4 "${DNS}" addr "DNS IP (--dns/ZEK_DNS)"
require_ipv4 "${POD_CIDR}" cidr "pod CIDR (--pod-cidr/ZEK_POD_CIDR)"

NET_NAME="${CLUSTER}-net"
MASTER_NAME="${CLUSTER}-master-1"
LB_NAME="${CLUSTER}-lb"

# What a kubelet needs inside a container: --privileged and the host's
# /lib/modules plus --cgroupns=host (cgroup writes land on the host's
# hierarchy; see README "Notes"), /sys/fs/cgroup rw for the kubelet, /run
# and /tmp as tmpfs so node state stays per-container. --dns and POD_CIDR
# are the optional user inputs from --dns/--pod-cidr.
NODE_ARGS=(
	--privileged --cgroupns=host
	--network "${NET_NAME}"
	--restart unless-stopped
	-v /lib/modules:/lib/modules:ro
	-v /sys/fs/cgroup:/sys/fs/cgroup:rw
	--tmpfs /run --tmpfs /tmp
	# The kubectl role's wait for the published config is bounded by the
	# same --timeout every host-side wait uses.
	--env "WAIT_TIMEOUT=${WAIT_TIMEOUT}"
)
[[ -n ${DNS} ]] && NODE_ARGS+=(--dns "${DNS}")
[[ -n ${POD_CIDR} ]] && NODE_ARGS+=(--env "POD_CIDR=${POD_CIDR}")
# Extra host bind mounts (ZEK_MOUNTS/--mounts): a space-separated list of
# host-path:container-path[:options] entries, each validated here so a typo
# dies before any container is created. Space-separated on purpose (it
# rides a single env var/flag value); paths containing spaces are not
# supported - use a symlink without spaces instead.
mount_entries=()
[[ -n ${MOUNTS} ]] && read -r -a mount_entries <<< "${MOUNTS}"
for mount_spec in "${mount_entries[@]}"; do
	[[ ${mount_spec} =~ ^[^:]+:/[^:]+(:[^:]*)?$ ]] \
		|| die "invalid mount '${mount_spec}' (expected host-path:container-path[:options]; check --mounts/ZEK_MOUNTS)"
	NODE_ARGS+=(-v "${mount_spec}")
done

net_exists() { docker network inspect "${NET_NAME}" > /dev/null 2>&1; }
# The network's IPv4 subnet (docker can list more than one IPAM config when
# IPv6 is enabled; node addresses are IPv4 only).
net_subnet_of() {
	docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' \
		"${NET_NAME}" 2> /dev/null \
		| awk -F/ 'NF && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }' || true
}
# An existing network's subnet must be the requested --subnet: silently
# deriving container addresses from a different subnet later would move a
# node off its static address and certificate. Empty --subnet always passes.
require_subnet() { # <existing-subnet>
	[[ -z ${SUBNET} || ${SUBNET} == "$1" ]] \
		|| die "cluster ${CLUSTER} uses subnet $1, not --subnet ${SUBNET}; pass --subnet $1 or destroy the cluster"
}

ensure_net() {
	local new_subnet=$1
	# First of the many disabled warnings in this file: this call sits on
	# the left of `if`, where errexit does not propagate, and the tool
	# flags every such call as a possibly-hidden failure. net_exists is a
	# predicate whose failure is exactly the branch being taken, so the
	# directive is intentional here and repeated per site the same way.
	# shellcheck disable=SC2310
	if net_exists; then
		# The existing network belongs to this cluster; reusing its subnet
		# makes a retry after a failed create work.
		local existing_subnet
		existing_subnet=$(net_subnet_of)
		require_subnet "${existing_subnet}"
		return 0
	fi
	docker network create --driver bridge --subnet "${new_subnet}" "${NET_NAME}" > /dev/null \
		|| die "cannot create network ${NET_NAME} with subnet ${new_subnet} (address space overlapping another network? pass --subnet/ZEK_SUBNET)"
	# Never derive node addresses from a subnet docker silently replaced
	# with its default pool.
	local actual_subnet
	actual_subnet=$(net_subnet_of)
	if [[ ${actual_subnet} != "${new_subnet}" ]]; then
		docker network rm "${NET_NAME}" > /dev/null 2>&1 || true
		die "docker created network ${NET_NAME} with subnet ${actual_subnet:-none}, not ${new_subnet}"
	fi
}

# First free 172.20.X.0/24 (or --subnet/ZEK_SUBNET when set) so parallel
# clusters never share a subnet. The scan is not atomic: two concurrent
# `up` calls can pick the same candidate, so when creating clusters in
# parallel pass a distinct subnet per cluster (e2e.sh pre-allocates them).
pick_subnet() {
	[[ -n ${SUBNET} ]] && {
		echo "${SUBNET}"
		return
	}
	# Collect the occupied subnets word by word: the `for X in ${list}`
	# splits are intentional word-splitting, while command arguments
	# inside $(...) stay quoted (which also keeps GitHub's syntax
	# highlighter from derailing).
	local i net_id net_list subnet_list subnet candidate used_subnets=""
	net_list="$(docker network ls -q)"
	for net_id in ${net_list}; do
		subnet_list="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${net_id}")"
		for subnet in ${subnet_list}; do
			used_subnets="${used_subnets} ${subnet}"
		done
	done
	for i in $(seq 0 254); do
		candidate="172.20.${i}.0/24"
		case " ${used_subnets} " in
			*" ${candidate} "*) ;;
			*)
				echo "${candidate}"
				return
				;;
		esac
	done
	die "no free 172.20.X.0/24 subnet left for cluster ${CLUSTER} (pass --subnet/ZEK_SUBNET explicitly)"
}

node_exists() { docker inspect --type container "$1" > /dev/null 2>&1; }

# True when this cluster was created with a load balancer (more than one
# master, or --lb). The container is the normal evidence; master-1 also
# carries a creation-time marker so the answer stays correct while the
# cluster is stopped and after the LB container was removed.
cluster_has_lb() {
	# shellcheck disable=SC2310
	if node_exists "${LB_NAME}"; then
		return 0
	fi
	# Clusters created before the marker existed are treated as LB-backed
	# when they have more than one master: the alternative would lock a
	# multi-master cluster's control plane.
	local masters
	masters=$(count_masters)
	if [[ ${masters} -gt 1 ]]; then
		return 0
	fi
	# Capture the env first: piping a large inspect payload into `grep -q`
	# can SIGPIPE the producer under pipefail and misclassify the cluster.
	local envs
	envs=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${MASTER_NAME}" 2> /dev/null) || return 1
	[[ ${envs} == *$'\nZEK_LB_ENDPOINT='* || ${envs} == ZEK_LB_ENDPOINT=* ]]
}

# Containers attached to this cluster's network (running or stopped).
network_container_names() { docker ps -a --format '{{.Names}}' -f network="${NET_NAME}" 2> /dev/null || true; }

# Running containers zek owns for this cluster: the node names and the load
# balancer. A node detached from the network is still included by name;
# containers a user attached to the network (NFS server, registry, ...) are
# not, so `down` never takes an external service down with the cluster.
running_owned_container_names() {
	docker ps --format '{{.Names}}' 2> /dev/null \
		| grep -E "^${CLUSTER}-(master-[0-9]+|worker-[0-9]+|lb)$" \
		| sort -u || true
}

# Masters are named <cluster>-master-1, <cluster>-master-2, ...; workers are
# <cluster>-worker-N. Names are sorted by index (sort -V) so starts are in
# dependency order and reconcile removes the highest index first. The
# `|| true` keeps an empty match (or a docker failure) from aborting the
# script under pipefail, which needs an empty/zero result here.
role_names() { # master|worker
	# Deliberately not network_container_names: a node temporarily detached
	# from the cluster network must still count as existing, or scaling
	# would mistake it for a missing node. The name pattern is the
	# cluster's own namespace.
	docker ps -a --format '{{.Names}}' 2> /dev/null \
		| grep -E "^${CLUSTER}-$1-[0-9]+$" | sort -V || true
}
master_names() { role_names master; }
worker_names() { role_names worker; }
count_role_names() { # master|worker
	local names
	names=$(role_names "$1")
	if [[ -z ${names} ]]; then
		echo 0
	else
		grep -c . <<< "${names}"
	fi
}
count_masters() { count_role_names master; }
count_workers() { count_role_names worker; }
all_node_names() {
	master_names
	worker_names
}

# Containers zek created for this cluster: the node names (including nodes
# detached from the network) plus the load balancer. Other containers a user
# attached to the network (NFS server, registry, ...) are deliberately not
# included: teardown must not remove an external service before the nodes.
owned_container_names() {
	all_node_names
	# shellcheck disable=SC2310
	if node_exists "${LB_NAME}"; then
		printf '%s\n' "${LB_NAME}"
	fi
}

# Every address currently held on the cluster network, for allocation: the
# network's containers plus zek's own containers, so a node temporarily
# detached from the network still reserves its address. Docker container
# names are unique, so sort -u is the deduplication.
network_address_holders() {
	local network_list owned_list
	network_list=$(network_container_names)
	owned_list=$(owned_container_names)
	printf '%s\n%s\n' "${network_list}" "${owned_list}" | sed '/^$/d' | sort -u
}

# Lowest index not used by a container of this role. Normally this is the
# next one after the highest, but filling a hole keeps scaling safe if a
# middle container was removed by hand.
next_node_index() { # master|worker
	local role=$1 index=1
	# shellcheck disable=SC2310
	while node_exists "${CLUSTER}-${role}-${index}"; do
		index=$((index + 1))
	done
	printf '%s\n' "${index}"
}

# The address a container was created with (IPAMConfig survives stop/start,
# while a stopped container's live IPAddress reads back empty). Falls back to
# the live address for containers not created with an explicit --ip.
node_address() { # container
	local address
	address=$(docker inspect -f \
		"{{with index .NetworkSettings.Networks \"${NET_NAME}\"}}{{.IPAMConfig.IPv4Address}}{{end}}" \
		"$1" 2> /dev/null) || address=""
	if [[ -z ${address} || ${address} == "invalid IP" ]]; then
		address=$(docker inspect -f \
			"{{with index .NetworkSettings.Networks \"${NET_NAME}\"}}{{.IPAddress}}{{end}}" \
			"$1" 2> /dev/null) || address=""
	fi
	# A stopped container without a static request reports this sentinel
	# instead of an empty address.
	if [[ ${address} == "invalid IP" ]]; then
		address=""
	fi
	printf '%s\n' "${address}"
}

# Every address currently reserved on the cluster network, including stopped
# containers and non-node containers a user attached: growing the topology
# must never hand a new node an address that is already taken.
used_node_ips() {
	local name container_list
	# network_address_holders covers the network's containers, the cluster's
	# named nodes (even when detached) and the LB.
	container_list=$(network_address_holders)
	while read -r name; do
		[[ -n ${name} ]] || continue
		node_address "${name}"
	done <<< "${container_list}"
}

# Free usable host addresses for a new node near MASTER_IP, one per line in
# allocation order: existing reservations and the LB's address (non-empty
# $2) are skipped, and candidates outside a narrower or offset --subnet are
# ignored. $3 limits the output (allocation needs only the first).
free_node_ips() { # <subnet> <lb-ip> [max]
	local subnet=$1 lb_ip=$2 max=${3:-254} prefix="${MASTER_IP%.*}" used ip candidate count=0
	used=" $(used_node_ips | tr '\n' ' ') "
	for candidate in $(seq 2 254); do
		ip="${prefix}.${candidate}"
		[[ ${ip} == "${lb_ip}" ]] && continue
		case " ${used} " in
			*" ${ip} "*) continue ;;
			*) ;;
		esac
		# The master's prefix spans a whole /24, but --subnet may be
		# narrower or offset: skip candidates outside its host range
		# instead of dying on the first one.
		# shellcheck disable=SC2310
		is_usable_host_ip "${ip}" "${subnet}" || continue
		printf '%s\n' "${ip}"
		count=$((count + 1))
		[[ ${count} -ge ${max} ]] && return 0
	done
	return 0
}

# First free address alloc_node_ip can hand out.
alloc_node_ip() { # <subnet> <lb-ip>
	local ips first
	ips=$(free_node_ips "$1" "$2" 1)
	[[ -n ${ips} ]] \
		|| die "no free host address left near ${MASTER_IP} for another node (destroy and recreate the cluster with a different --master-ip)"
	first=${ips%%$'\n'*}
	printf '%s\n' "${first}"
}

# Number of addresses alloc_node_ip could hand out before it runs out. A
# scale operation checks this first so it cannot die halfway through,
# leaving a partially changed topology behind.
count_free_node_ips() { # <subnet> <lb-ip>
	free_node_ips "$1" "$2" | wc -l
}

# Every node is a container on the cluster's network running an entrypoint
# role.
run_node() {
	local name="$1" role="$2"
	shift 2
	# docker run -d prints the container id on stdout; nobody consumes it
	# and it just pollutes the logs.
	docker run -d --name "${name}" --hostname "${name}" \
		"${NODE_ARGS[@]}" "$@" "${IMAGE}" "${role}" > /dev/null
}

# Create a node, retrying the same way: a removed container's static
# endpoint can still be held by docker's async cleanup for a moment.
run_node_retry() { # name role [args...]
	local name=$1 i out last=""
	shift
	for i in {1..10}; do
		# shellcheck disable=SC2310
		if out=$(run_node "${name}" "$@" 2>&1); then
			return 0
		fi
		last=${out}
		# Drop whatever the failed attempt left behind (a run can fail
		# after creating the container), then retry only the static-IP
		# cleanup race; a bad image, mount or name is deterministic.
		docker rm -f "${name}" > /dev/null 2>&1 || true
		[[ ${last} == *"Address already in use"* ]] || break
		sleep 2
	done
	printf '%s\n' "${last}" >&2
	log "failed to create ${name} after ${i} attempt(s)"
	return 1
}

# A static-IP start can race the previous endpoint's cleanup and fail
# with "Address already in use"; retry 10 times with a 2s gap (a fixed
# budget outside --timeout: the containers exist already, so this only
# waits out docker's own cleanup) before giving up.
start_node() { # name
	local name=$1 out
	for _ in {1..10}; do
		if out=$(docker start "${name}" 2>&1); then
			return 0
		fi
		sleep 2
	done
	log "failed to start ${name} after 10 tries: ${out}"
	return 1
}

# Run kubectl against the cluster via the first master's container.
kube() {
	# -i always: stdin must be forwarded for piped manifests (even when a
	# terminal sits on the other end). A pty is added only when both ends
	# are one, so interactive `kubectl exec ... bash` gets a real terminal
	# while captured or piped output stays free of CR line endings (the
	# e2e assertions compare such output).
	local -a exec_flags=(-i)
	[[ -t 0 && -t 1 ]] && exec_flags+=(-t)
	docker exec "${exec_flags[@]}" --env "WAIT_TIMEOUT=${WAIT_TIMEOUT}" \
		"${MASTER_NAME}" /entrypoint.sh kubectl "$@"
}

# Every internal wait is bounded by WAIT_TIMEOUT (--timeout, default
# ZEK_TIMEOUT or 600s) so a broken cluster fails fast instead of hanging.
wait_for_api() {
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for the API of ${CLUSTER} to answer (timeout ${WAIT_TIMEOUT}s)"
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		# shellcheck disable=SC2310
		kube --request-timeout=10s get nodes > /dev/null 2>&1 && {
			log "control plane is up"
			return 0
		}
		sleep 2
	done
	die "control plane API not reachable after ${WAIT_TIMEOUT}s (see: ./zek.sh --cluster ${CLUSTER} logs ${MASTER_NAME})"
}

# Wait until a control-plane node actually serves: its kube-apiserver and
# etcd static pods are Running.
wait_for_master_ready() {
	local name="$1" phase deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for the control plane on ${name} (timeout ${WAIT_TIMEOUT}s)"
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		# shellcheck disable=SC2310
		phase="$(kube --request-timeout=10s -n kube-system get pod "kube-apiserver-${name}" -o jsonpath='{.status.phase}' 2> /dev/null || true)"
		if [[ ${phase} == Running ]]; then
			# shellcheck disable=SC2310
			phase="$(kube --request-timeout=10s -n kube-system get pod "etcd-${name}" -o jsonpath='{.status.phase}' 2> /dev/null || true)"
			[[ ${phase} == Running ]] && return 0
		fi
		sleep 2
	done
	die "control plane on ${name} not ready after ${WAIT_TIMEOUT}s (see: ./zek.sh --cluster ${CLUSTER} logs ${name}; check --timeout/ZEK_TIMEOUT)"
}

wait_for_nodes() {
	local want="$1" have=0 deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for ${want} node(s) to register (timeout ${WAIT_TIMEOUT}s)"
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		# shellcheck disable=SC2310
		have=$(kube --request-timeout=10s get nodes --no-headers 2> /dev/null | wc -l || true)
		[[ ${have} -ge ${want} ]] && return 0
		sleep 2
	done
	die "expected ${want} nodes after ${WAIT_TIMEOUT}s, saw ${have} (check --timeout/ZEK_TIMEOUT)"
}

# Scaling can remove nodes, so unlike creation it must wait for the exact
# count - a lingering Node object from a removed node would otherwise make
# the "at least N" wait above pass too early.
wait_for_node_total() {
	local want="$1" have=0 deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for exactly ${want} node(s) (timeout ${WAIT_TIMEOUT}s)"
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		# shellcheck disable=SC2310
		have=$(kube --request-timeout=10s get nodes --no-headers 2> /dev/null | wc -l || true)
		[[ ${have} -eq ${want} ]] && return 0
		sleep 2
	done
	die "expected exactly ${want} nodes after ${WAIT_TIMEOUT}s, saw ${have} (check --timeout/ZEK_TIMEOUT)"
}

# kubeadm's uploaded control-plane certificates live in a secret with a
# two-hour TTL. The token created at creation time never expires, but a
# master added later than that needs a fresh certificate key, so re-upload
# the certificates (with a key we generate, exactly like publish does) and
# update the published copy before reading the join credentials.
refresh_cert_key() {
	local cert_key
	cert_key=$(docker exec "${MASTER_NAME}" openssl rand -hex 32) \
		|| die "cannot generate a new certificate key on ${MASTER_NAME}"
	docker exec "${MASTER_NAME}" kubeadm init phase upload-certs --upload-certs \
		--certificate-key "${cert_key}" --kubeconfig /etc/kubernetes/admin.conf \
		> /dev/null 2>&1 \
		|| die "cannot refresh the control-plane join certificate key on ${MASTER_NAME}"
	docker exec "${MASTER_NAME}" sh -c "printf '%s' '${cert_key}' > /etc/cluster/cert-key" \
		|| die "cannot publish the refreshed certificate key on ${MASTER_NAME}"
}

# The first master publishes the join credentials (token, CA hash, API
# endpoint, certificate key) under /etc/cluster on its own layer; they are
# handed to joining nodes as env vars. The files appear a moment after the
# API starts answering, so wait for them - joiners then start immediately,
# while kubeadm's uploaded control-plane certificates are still fresh.
read_join_credentials() {
	local join_token="" join_ca_hash="" join_api_endpoint="" join_cert_key=""
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		join_token="$(docker exec "${MASTER_NAME}" cat /etc/cluster/token 2> /dev/null)" \
			&& join_ca_hash="$(docker exec "${MASTER_NAME}" cat /etc/cluster/ca-hash 2> /dev/null)" \
			&& join_api_endpoint="$(docker exec "${MASTER_NAME}" cat /etc/cluster/api-endpoint 2> /dev/null)" \
			&& join_cert_key="$(docker exec "${MASTER_NAME}" cat /etc/cluster/cert-key 2> /dev/null)" \
			&& break
		sleep 2
	done
	[[ -n ${join_token} ]] && [[ -n ${join_ca_hash} ]] && [[ -n ${join_api_endpoint} ]] && [[ -n ${join_cert_key} ]] \
		|| die "join credentials not published by ${MASTER_NAME} after ${WAIT_TIMEOUT}s (is the master running? check --timeout/ZEK_TIMEOUT)"
	CRED_ARGS=(
		--env "JOIN_TOKEN=${join_token}"
		--env "JOIN_CA_HASH=${join_ca_hash}"
		--env "JOIN_API_ENDPOINT=${join_api_endpoint}"
		--env "JOIN_CERT_KEY=${join_cert_key}"
	)
}

# Static IP of master $1 (1-based): the first sits at --master-ip
# (ZEK_MASTER_IP, default <subnet>.2), following ones increment the last
# octet.
master_node_ip() { # 1-based master index
	local master_idx=$1 subnet_prefix="${MASTER_IP%.*}" base_octet="${MASTER_IP##*.}"
	echo "${subnet_prefix}.$((base_octet + master_idx - 1))"
}

# Static IP of worker $1 (1-based) in a cluster with $2 masters: workers
# follow the masters (the address right after the last one), so no worker
# can land on a master and every node's address is fixed for the life of
# the cluster. Without --ip a node would come from docker's dynamic pool -
# and a dynamic address is not stable across a host reboot (docker
# reallocates from the pool in its own order), which moves a node under its
# kubelet/apiserver certificates and Node object. $3 is the cluster subnet
# and $4 the load balancer's own address: the address is validated exactly
# like a master's, and when the cluster has an LB ($5) a worker that would
# take the LB's address dies before anything is created.
worker_node_ip() { # <1-based worker index> <masters> <subnet> <lb-ip> <use-lb>
	local worker_idx=$1 masters=$2 subnet=$3 lb_ip=$4 use_lb=$5
	# $(( )) reads its operands as variable names, so a non-numeric base
	# would die later as a bare unbound-variable error; shape-check it.
	require_ipv4 "${MASTER_IP}" addr "master IP (--master-ip/ZEK_MASTER_IP)"
	local subnet_prefix="${MASTER_IP%.*}" base_octet="${MASTER_IP##*.}"
	local addr="${subnet_prefix}.$((base_octet + masters + worker_idx - 1))"
	require_host_ip "${addr}" "${subnet}" "worker ${worker_idx}"
	if [[ ${use_lb} -eq 1 && ${addr} == "${lb_ip}" ]]; then
		die "worker ${worker_idx} would get IP ${addr}, which is the load balancer's IP (${lb_ip}); lower --workers/ZEK_WORKERS or change --master-ip/ZEK_MASTER_IP"
	fi
	echo "${addr}"
}

# The load balancer's own address on the cluster network (a cluster with
# more than one master, or a single master created with --lb): <subnet>.10.
# Masters (walking up from --master-ip) and workers (following the masters)
# both have to stay off it when it is in use.
lb_node_ip() { # <subnet>
	echo "${1%.*}.10"
}

# Decimal 32-bit form of a dotted-quad IPv4 address.
ip_to_int() { # <ip>
	local addr=$1 octet ipn=0
	local -a octets=()
	IFS=. read -r -a octets <<< "${addr}"
	for octet in "${octets[@]}"; do
		ipn=$((ipn << 8 | 10#${octet}))
	done
	echo "${ipn}"
}

# True when IPv4 $1 sits inside CIDR $2 (both dotted-quad IPv4).
ip_in_cidr() { # <ip> <cidr>
	local ip=$1 cidr=$2
	local prefix=${cidr##*/}
	local ipn netn mask
	ipn=$(ip_to_int "${ip}")
	netn=$(ip_to_int "${cidr%/*}")
	mask=$(((0xFFFFFFFF << (32 - 10#${prefix})) & 0xFFFFFFFF))
	(((ipn & mask) == (netn & mask)))
}

# True when $1 is a usable host address inside CIDR $2 (in range and not
# the network, gateway or broadcast address). Non-fatal counterpart of
# require_host_ip, used to count free addresses before a scale operation.
is_usable_host_ip() { # <ip> <cidr>
	local ip=$1 cidr=$2
	local prefix=${cidr##*/}
	local ipn netn mask gateway broadcast
	# shellcheck disable=SC2310
	ip_in_cidr "${ip}" "${cidr}" || return 1
	ipn=$(ip_to_int "${ip}")
	netn=$(ip_to_int "${cidr%/*}")
	mask=$(((0xFFFFFFFF << (32 - 10#${prefix})) & 0xFFFFFFFF))
	gateway=$((netn + 1))
	broadcast=$((netn | (~mask & 0xFFFFFFFF)))
	((ipn != netn && ipn != gateway && ipn != broadcast))
}

# Die unless $1 is a usable host address inside CIDR $2: in range and not
# the network, gateway (first host) or broadcast address. Checked here,
# before the network exists - docker only rejects those addresses at
# `docker run --ip`, which would fail after the network (and LB) were
# created and leave them orphaned behind an `up` that can never retry.
require_host_ip() { # <ip> <cidr> <label>
	local ip=$1 cidr=$2 label=$3
	local prefix=${cidr##*/}
	local ipn netn mask gateway broadcast
	# Reject an impossible dotted quad (e.g. an octet that overflowed the
	# master+index arithmetic on a subnet wider than /24) before the CIDR
	# math can map it to some other valid address.
	require_ipv4 "${ip}" addr "${label}"
	# shellcheck disable=SC2310
	ip_in_cidr "${ip}" "${cidr}" \
		|| die "${label} ${ip} is outside the cluster subnet ${cidr} (check --subnet/ZEK_SUBNET and --master-ip/ZEK_MASTER_IP)"
	ipn=$(ip_to_int "${ip}")
	netn=$(ip_to_int "${cidr%/*}")
	mask=$(((0xFFFFFFFF << (32 - 10#${prefix})) & 0xFFFFFFFF))
	gateway=$((netn + 1))
	broadcast=$((netn | (~mask & 0xFFFFFFFF)))
	if ((ipn == netn)); then
		die "${label} ${ip} is the network address of ${cidr} (check --subnet/ZEK_SUBNET and --master-ip/ZEK_MASTER_IP)"
	fi
	if ((ipn == gateway)); then
		die "${label} ${ip} is the gateway of ${cidr} (check --subnet/ZEK_SUBNET and --master-ip/ZEK_MASTER_IP)"
	fi
	if ((ipn == broadcast)); then
		die "${label} ${ip} is the broadcast address of ${cidr} (check --subnet/ZEK_SUBNET and --master-ip/ZEK_MASTER_IP)"
	fi
	return 0
}

create_cluster() {
	local workers="$1" masters="$2"
	local net_subnet subnet_base lb_ip api_endpoint master_addr i backends="" use_lb=0
	local -a worker_addrs=()

	# Reuse this cluster's own network when it exists (retry after a
	# failed create): its subnet is authoritative for every container IP
	# derived below. An explicit --subnet that disagrees dies instead of
	# silently deriving addresses from the wrong subnet later.
	# shellcheck disable=SC2310
	if net_exists; then
		net_subnet=$(net_subnet_of)
		require_subnet "${net_subnet}"
	else
		net_subnet="$(pick_subnet)"
	fi
	NET_SUBNET="${net_subnet}"
	subnet_base="${net_subnet%.*}"
	MASTER_IP="${MASTER_IP:-${subnet_base}.2}"
	# The load balancer's reserved address on the cluster network. At
	# creation masters/workers must avoid it whenever the LB is being
	# created: multiple masters always need one, and --lb asks for one
	# even with a single master so the control plane can grow later.
	lb_ip="$(lb_node_ip "${net_subnet}")"
	[[ ${masters} -gt 1 || ${LB} -eq 1 ]] && use_lb=1
	api_endpoint="${MASTER_IP}:6443"
	[[ ${use_lb} -eq 1 ]] && api_endpoint="${lb_ip}:6443"
	# Every address docker will be asked to allocate is validated against
	# the subnet before the network exists: docker only rejects
	# out-of-range/gateway/broadcast IPs at `docker run --ip`, which would
	# fail after the network (and LB) were created and leave an `up` that
	# can never retry without destroy. The masters walk up from
	# --master-ip while the LB owns <subnet>.10, so a master landing on
	# .10 dies here too.
	for i in $(seq 1 "${masters}"); do
		master_addr=$(master_node_ip "${i}")
		require_host_ip "${master_addr}" "${net_subnet}" "master ${i}"
		if [[ ${use_lb} -eq 1 ]]; then
			[[ ${master_addr} != "${lb_ip}" ]] \
				|| die "master ${i} would get IP ${master_addr}, which is the load balancer's IP (${lb_ip}); change --master-ip/ZEK_MASTER_IP or lower --masters/ZEK_MASTERS"
			backends="${backends:+${backends} }${master_addr}"
		fi
	done
	if [[ ${use_lb} -eq 1 ]]; then
		require_host_ip "${lb_ip}" "${net_subnet}" "load balancer"
	fi
	# Workers follow the masters: their addresses are derived and validated
	# here too, before the network exists. A worker that only fails its
	# validation when its `docker run` comes up would leave the cluster
	# half-created (master and LB exist, so the next `up` would reconcile
	# and could miss the missing workers).
	for i in $(seq 1 "${workers}"); do
		worker_addrs+=("$(worker_node_ip "${i}" "${masters}" "${net_subnet}" "${lb_ip}" "${use_lb}")")
	done
	ensure_net "${net_subnet}"
	if [[ ${use_lb} -eq 1 ]]; then
		# ensure_lb reuses a container left behind by an earlier failed
		# create and recreates one whose backend list or address no longer
		# matches.
		# shellcheck disable=SC2310
		if node_exists "${LB_NAME}"; then
			log "reusing ${LB_NAME} (${lb_ip}) from an earlier failed create"
		fi
		ensure_lb "${backends}"
	else
		# A failed create can leave an LB behind; a cluster created
		# without one has its master count locked, so it must not carry
		# one into the new cluster.
		remove_lb
	fi

	log "creating ${MASTER_NAME} (${MASTER_IP})"
	local -a master_env=(--env "API_ENDPOINT=${api_endpoint}")
	# Creation-time LB marker read by cluster_has_lb (stopped containers
	# and recovery after a removed LB container). Never set on a no-LB
	# cluster, so the endpoint on a cluster whose master happens to use
	# <subnet>.10 is not mistaken for an LB.
	[[ ${use_lb} -eq 1 ]] && master_env+=(--env "ZEK_LB_ENDPOINT=${lb_ip}:6443")
	run_node_retry "${MASTER_NAME}" master --ip "${MASTER_IP}" "${master_env[@]}"
	wait_for_api
	read_join_credentials

	for i in $(seq 2 "${masters}"); do
		master_addr=$(master_node_ip "${i}")
		log "creating ${CLUSTER}-master-${i} (${master_addr}) as control-plane"
		run_node_retry "${CLUSTER}-master-${i}" master --ip "${master_addr}" \
			--env MASTER_JOIN=1 "${CRED_ARGS[@]}"
		wait_for_master_ready "${CLUSTER}-master-${i}"
		wait_for_nodes "${i}"
	done

	for i in $(seq 1 "${workers}"); do
		log "creating ${CLUSTER}-worker-${i} (${worker_addrs[i - 1]})"
		run_node_retry "${CLUSTER}-worker-${i}" worker --ip "${worker_addrs[i - 1]}" "${CRED_ARGS[@]}"
	done
	wait_for_nodes "$((masters + workers))"

	log "cluster ${CLUSTER} up: ${masters} master(s) + ${workers} worker(s). Nodes report NotReady until you install a CNI."
}

# Start every container that exists, in dependency-safe order: load
# balancer first (every kubeconfig may point at it), then masters in index
# order, then workers. e2e asserts this order (multi-master-recovery,
# persistence-2).
start_existing_nodes() {
	local name node_list
	log "restarting cluster ${CLUSTER}"
	# shellcheck disable=SC2310
	if node_exists "${LB_NAME}"; then
		log "starting ${LB_NAME}"
		start_node "${LB_NAME}"
	fi
	# all_node_names is masters in index order, then workers.
	node_list=$(all_node_names)
	while read -r name; do
		[[ -n ${name} ]] || continue
		log "starting ${name}"
		start_node "${name}"
	done <<< "${node_list}"
}

# Backends of the load balancer: the address each master was created
# with, whether it is running or not (haproxy health-checks them).
lb_backends() {
	local name address master_list backends=""
	master_list=$(master_names)
	while read -r name; do
		[[ -n ${name} ]] || continue
		address=$(node_address "${name}")
		[[ -n ${address} ]] || die "cannot determine the address of ${name} (was the container removed while scaling?)"
		backends="${backends:+${backends} }${address}"
	done <<< "${master_list}"
	printf '%s\n' "${backends}"
}

# The backend list baked into the running LB container's environment.
lb_env_backends() {
	docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${LB_NAME}" 2> /dev/null \
		| sed -n 's/^LB_BACKENDS=//p' || true
}

# Create the LB, or recreate it when its backend list or its address
# changed. A recreate is how a live haproxy picks up an added/removed master
# without teaching the entrypoint a reload protocol; the fixed --ip keeps the
# endpoint stable. The retry waits out docker's endpoint cleanup for the same
# address.
ensure_lb() { # <space separated backends>
	local backends=$1 lb_ip current current_ip
	lb_ip=$(lb_node_ip "${NET_SUBNET}")
	# shellcheck disable=SC2310
	if node_exists "${LB_NAME}"; then
		current=$(lb_env_backends)
		current_ip=$(node_address "${LB_NAME}")
		# Reuse only when the container still sits on its own reserved
		# address; a manually disconnected/recreated LB must be rebuilt
		# rather than started where the endpoint cannot reach it.
		if [[ ${current} == "${backends}" ]] && [[ ${current_ip} == "${lb_ip}" ]]; then
			start_node "${LB_NAME}"
			return 0
		fi
		if [[ ${current} != "${backends}" ]]; then
			log "updating ${LB_NAME} backends to: ${backends}"
		else
			log "recreating ${LB_NAME} on ${lb_ip} (was ${current_ip:-an unknown address})"
		fi
		docker rm -f "${LB_NAME}" > /dev/null
	else
		log "creating ${LB_NAME} (${lb_ip}) in front of: ${backends}"
	fi
	# shellcheck disable=SC2310
	if ! run_node_retry "${LB_NAME}" lb --ip "${lb_ip}" --env "LB_BACKENDS=${backends}"; then
		die "cannot start ${LB_NAME} with backends: ${backends}"
	fi
}

remove_lb() {
	# shellcheck disable=SC2310
	node_exists "${LB_NAME}" || return 0
	log "removing ${LB_NAME}"
	docker rm -f "${LB_NAME}" > /dev/null
}

# Reconcile an existing cluster to the requested sizes. Only an explicitly
# set size (flag, bare number or the flag's env twin) changes that role;
# the other role keeps its current count. Additions get the first free
# address, removals drop the highest index, so every surviving node keeps
# its name and address.
reconcile_cluster() {
	local workers="$1" masters="$2" workers_set="$3" masters_set="$4"
	local existing_masters existing_workers desired_masters desired_workers
	local name address i idx lb_ip backends worker_list master_list
	local add_masters=0 add_workers=0 needed free reserve_lb_ip="" has_lb=0
	local -a current_workers=() current_masters=()
	existing_masters=$(count_masters)
	existing_workers=$(count_workers)
	desired_masters=${existing_masters}
	desired_workers=${existing_workers}
	[[ ${masters_set} -eq 1 ]] && desired_masters=${masters}
	[[ ${workers_set} -eq 1 ]] && desired_workers=${workers}

	NET_SUBNET=$(net_subnet_of)
	[[ -n ${NET_SUBNET} ]] || die "cannot determine the subnet of ${NET_NAME}; is the cluster intact? (destroy and recreate it)"
	require_subnet "${NET_SUBNET}"
	# The live cluster's own addresses are authoritative; --master-ip is a
	# creation-time default and must not move an existing cluster's base.
	# A master detached from the network loses its IPAMConfig (docker
	# removes the network entry), so fall back to the creation default
	# instead of refusing to start it - starting it is exactly what lets
	# the retry/timing path behave normally while its address is held.
	MASTER_IP=$(node_address "${MASTER_NAME}")
	MASTER_IP="${MASTER_IP:-${NET_SUBNET%.*}.2}"
	lb_ip=$(lb_node_ip "${NET_SUBNET}")
	# An LB-backed cluster keeps that identity even while the LB container
	# is missing (master-1 carries a creation-time marker), so the
	# recovery path below can recreate it. Local `has_lb` keeps the
	# guards and the allocation precheck consistent.
	# shellcheck disable=SC2310
	if cluster_has_lb; then
		has_lb=1
	fi
	# --lb is a creation-time choice: retrofitting one would have to move
	# the cluster's kubeadm endpoint and the apiserver certificate SANs
	# built for it, which an existing cluster cannot do.
	if [[ ${LB} -eq 1 ]] && [[ ${has_lb} -eq 0 ]]; then
		die "cannot add a load balancer to an existing cluster (--lb/ZEK_LB only applies at creation); destroy it and recreate with --lb to make its control plane scalable"
	fi
	# Master scaling is gated on the LB: it is the cluster's stable
	# endpoint. Without one only a single master is possible, so its
	# master count is locked; every multi-master cluster has an LB, which
	# also keeps a cluster from reaching multiple masters without one.
	# Workers are unrestricted.
	if [[ ${desired_masters} -ne ${existing_masters} ]] && [[ ${has_lb} -eq 0 ]]; then
		die "cannot scale masters without a load balancer: only one master is possible in a cluster without an LB; recreate it with --lb or --masters N to make its control plane scalable"
	fi
	# A narrow or offset subnet can put the derived LB address outside its
	# usable host range; refuse before adding nodes or creating the LB,
	# which would otherwise die halfway through the scale.
	if [[ ${desired_masters} -gt 1 ]]; then
		require_host_ip "${lb_ip}" "${NET_SUBNET}" "load balancer"
	fi
	# Keep the LB's address out of the allocator while the cluster has an
	# LB (a missing one is recreated at .10 before any node is added). A
	# no-LB cluster may legitimately use .10.
	reserve_lb_ip=""
	if [[ ${has_lb} -eq 1 ]]; then
		reserve_lb_ip=${lb_ip}
	fi
	# Refuse an impossible scale before adding anything: a failure halfway
	# through leaves a partially changed topology behind.
	if [[ ${desired_masters} -gt ${existing_masters} ]]; then
		add_masters=$((desired_masters - existing_masters))
	fi
	if [[ ${desired_workers} -gt ${existing_workers} ]]; then
		add_workers=$((desired_workers - existing_workers))
	fi
	needed=$((add_masters + add_workers))
	if [[ ${needed} -gt 0 ]]; then
		free=$(count_free_node_ips "${NET_SUBNET}" "${reserve_lb_ip}")
		[[ ${free} -ge ${needed} ]] \
			|| die "not enough free addresses for ${needed} new node(s): only ${free} usable in ${NET_SUBNET} (lower --workers/--masters or recreate the cluster with a different --master-ip)"
	fi
	start_existing_nodes
	# Kubeconfigs of an LB-backed cluster (HA, or --lb with one master)
	# point at the LB, so it has to be serving before the API wait. This
	# also recreates an LB container that was removed.
	if [[ ${desired_masters} -gt 1 ]] || [[ ${has_lb} -eq 1 ]]; then
		backends=$(lb_backends)
		ensure_lb "${backends}"
	fi
	wait_for_api
	wait_for_nodes "$((existing_masters + existing_workers))"

	# Add masters before workers: the LB and the control plane are what a
	# newly joined worker talks to. New masters join through the endpoint
	# published at creation, which is still serving.
	if [[ ${desired_masters} -gt ${existing_masters} ]]; then
		# The uploaded certificate secret expires after two hours; refresh
		# it so a master added long after creation can still join.
		refresh_cert_key
		read_join_credentials
		for i in $(seq 1 $((desired_masters - existing_masters))); do
			idx=$(next_node_index master)
			name="${CLUSTER}-master-${idx}"
			address=$(alloc_node_ip "${NET_SUBNET}" "${reserve_lb_ip}")
			log "adding ${name} (${address}) as control-plane"
			run_node_retry "${name}" master --ip "${address}" \
				--env MASTER_JOIN=1 "${CRED_ARGS[@]}"
			wait_for_master_ready "${name}"
		done
	fi
	if [[ ${desired_workers} -gt ${existing_workers} ]]; then
		[[ ${#CRED_ARGS[@]} -gt 0 ]] || read_join_credentials
		for i in $(seq 1 $((desired_workers - existing_workers))); do
			idx=$(next_node_index worker)
			name="${CLUSTER}-worker-${idx}"
			address=$(alloc_node_ip "${NET_SUBNET}" "${reserve_lb_ip}")
			log "adding ${name} (${address})"
			run_node_retry "${name}" worker --ip "${address}" "${CRED_ARGS[@]}"
		done
	fi

	worker_list=$(worker_names)
	if [[ -n ${worker_list} ]]; then
		mapfile -t current_workers <<< "${worker_list}"
	fi
	while [[ ${#current_workers[@]} -gt ${desired_workers} ]]; do
		idx=$((${#current_workers[@]} - 1))
		name=${current_workers[idx]}
		remove_worker "${name}"
		unset 'current_workers[idx]'
	done
	master_list=$(master_names)
	if [[ -n ${master_list} ]]; then
		mapfile -t current_masters <<< "${master_list}"
	fi
	while [[ ${#current_masters[@]} -gt ${desired_masters} ]]; do
		idx=$((${#current_masters[@]} - 1))
		name=${current_masters[idx]}
		remove_master "${name}"
		unset 'current_masters[idx]'
	done

	# Backends only change with the master set. Scaling down to one master
	# keeps the LB (the early ensure_lb above started or recreated it); this
	# final pass shrinks its backends to master-1 so the cluster can grow
	# back later.
	if [[ ${desired_masters} -ne ${existing_masters} ]]; then
		backends=$(lb_backends)
		ensure_lb "${backends}"
	fi

	wait_for_api
	wait_for_node_total "$((desired_masters + desired_workers))"
	log "cluster ${CLUSTER} up: ${desired_masters} master(s) + ${desired_workers} worker(s). Nodes report NotReady until you install a CNI."
}

cmd_up() {
	local workers="" masters="" workers_set=0 masters_set=0 node_list
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--workers)
				[[ $# -ge 2 ]] || die "--workers needs a value (check --workers/ZEK_WORKERS)"
				[[ -n ${2:-} ]] || die "--workers needs a value (check --workers/ZEK_WORKERS)"
				workers="$2"
				workers_set=1
				shift 2
				;;
			--masters)
				[[ $# -ge 2 ]] || die "--masters needs a value (check --masters/ZEK_MASTERS)"
				[[ -n ${2:-} ]] || die "--masters needs a value (check --masters/ZEK_MASTERS)"
				masters="$2"
				masters_set=1
				shift 2
				;;
			--workers=*)
				workers="${1#*=}"
				[[ -n ${workers} ]] || die "--workers needs a value (check --workers/ZEK_WORKERS)"
				workers_set=1
				shift
				;;
			--masters=*)
				masters="${1#*=}"
				[[ -n ${masters} ]] || die "--masters needs a value (check --masters/ZEK_MASTERS)"
				masters_set=1
				shift
				;;
			[0-9]*)
				[[ ${workers_set} -eq 0 ]] \
					|| die "unexpected argument '$1' (a bare number is a --workers shorthand; it may appear once)"
				workers="$1"
				workers_set=1
				shift
				;;
			*) usage ;;
		esac
	done
	# An env twin that was actually set is an explicit topology request too;
	# leaving both unset is what makes a later `up` only restart.
	if [[ ${workers_set} -eq 0 && ${WORKERS_ENV_SET} -eq 1 ]]; then
		workers_set=1
	fi
	if [[ ${masters_set} -eq 0 && ${MASTERS_ENV_SET} -eq 1 ]]; then
		masters_set=1
	fi
	workers="${workers:-${ENV_WORKERS}}"
	masters="${masters:-${ENV_MASTERS}}"
	# Validate the effective values (flag > env) here, after the merge, so
	# a bad ZEK_WORKERS/ZEK_MASTERS is always overridable by a valid flag.
	# Bounds are checked by string length first: bash arithmetic would
	# silently wrap a 20-digit literal and `seq 1 <huge>` eats the disk.
	# No leading zeros either - $((08)) is a hard arithmetic error later.
	[[ ${workers} =~ ^(0|[1-9][0-9]*)$ ]] \
		|| die "invalid workers '${workers}' (expected a plain number 0-64; check --workers/ZEK_WORKERS)"
	[[ ${masters} =~ ^[1-9][0-9]*$ ]] \
		|| die "invalid masters '${masters}' (expected a number 1-64; check --masters/ZEK_MASTERS)"
	{ [[ ${#workers} -le 3 ]] && ((10#${workers} <= 64)); } \
		|| die "workers ${workers} out of range (0-64; check --workers/ZEK_WORKERS)"
	{ [[ ${#masters} -le 3 ]] && ((10#${masters} <= 64)); } \
		|| die "masters ${masters} out of range (1-64; check --masters/ZEK_MASTERS)"
	if ((10#${masters} > 1 && 10#${masters} % 2 == 0)); then
		warn "an even master count (${masters}) adds no etcd failure tolerance over $((10#${masters} - 1)); use an odd count"
	fi

	# shellcheck disable=SC2310
	if node_exists "${MASTER_NAME}"; then
		reconcile_cluster "${workers}" "${masters}" "${workers_set}" "${masters_set}"
	else
		node_list=$(all_node_names)
		[[ -z ${node_list} ]] \
			|| die "found node containers without ${MASTER_NAME} (${node_list//$'\n'/, }); run destroy first"
		create_cluster "${workers}" "${masters}"
	fi
}

cmd_down() {
	local -a names=()
	local name container_list
	container_list=$(running_owned_container_names)
	if [[ -n ${container_list} ]]; then
		mapfile -t names <<< "${container_list}"
	fi
	if [[ ${#names[@]} -eq 0 ]]; then
		log "cluster ${CLUSTER} is not running"
		return 0
	fi
	for name in "${names[@]}"; do
		log "stopping ${name}"
		docker stop "${name}" > /dev/null
	done
	log "cluster ${CLUSTER} stopped (state preserved; restart with up)"
}

# Drain a node's workloads. Tolerates an unreachable control plane (that is
# exactly what lets a broken worker still be removed).
drain_node() {
	local name="$1"
	# shellcheck disable=SC2310
	kube drain "${name}" --ignore-daemonsets --delete-emptydir-data --force \
		--timeout="${WAIT_TIMEOUT}s" > /dev/null 2>&1 || true
}

# Delete a Node object, retrying. The container must already be gone: a
# still-running kubelet re-registers its Node within seconds, so deleting
# first would leave the old object behind. --ignore-not-found makes an
# already-absent node a success, and the loop rides out the brief API/leader
# disturbance right after a stacked-etcd member is removed.
delete_node() {
	local name="$1" deadline=$((SECONDS + WAIT_TIMEOUT))
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		# shellcheck disable=SC2310
		if kube --request-timeout=10s delete node "${name}" --ignore-not-found > /dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	log "node object ${name} not removed (control plane unreachable?); continuing"
}

# Remove a worker from the topology: drain it, delete its container (which
# stops the kubelet first), then drop its Node object. reconcile_cluster
# picks the highest index, so surviving workers keep their names/addresses.
remove_worker() {
	local name="$1"
	log "removing ${name}"
	drain_node "${name}"
	docker rm -f "${name}" > /dev/null
	delete_node "${name}"
}

# Drop a stacked-etcd member from a surviving control-plane node. etcdctl
# ships in the etcd static-pod image, so this needs no extra binary on the
# host or in the node image. Returns non-zero when the API/etcd is not
# reachable so remove_master can fall back to kubeadm reset.
remove_etcd_member() { # <survivor> <leaving-master>
	local survivor=$1 target=$2 member_id listed=0
	local -a etcdctl=(
		etcdctl
		--endpoints=https://127.0.0.1:2379
		--cacert=/etc/kubernetes/pki/etcd/ca.crt
		--cert=/etc/kubernetes/pki/etcd/server.crt
		--key=/etc/kubernetes/pki/etcd/server.key
	)
	for _ in {1..5}; do
		# shellcheck disable=SC2310
		if member_id=$(kube -n kube-system exec "etcd-${survivor}" -- "${etcdctl[@]}" \
			member list 2> /dev/null \
			| awk -F', ' -v name="${target}" '$3 == name { print $1 }'); then
			listed=1
			break
		fi
		sleep 1
	done
	[[ ${listed} -eq 1 ]] || return 1
	# No matching name means the member is already gone.
	[[ -n ${member_id} ]] || return 0
	for _ in {1..5}; do
		# shellcheck disable=SC2310
		if kube -n kube-system exec "etcd-${survivor}" -- "${etcdctl[@]}" \
			member remove "${member_id}" > /dev/null; then
			return 0
		fi
		sleep 1
	done
	return 1
}

# Remove a control-plane node: drain it, take its etcd member out of the
# stacked cluster, then delete its container and Node object. master-1 is
# never removed - the published credentials and the kubectl path live there.
remove_master() {
	local name="$1" survivor="${CLUSTER}-master-1"
	[[ ${name} != "${survivor}" ]] \
		|| die "refusing to remove ${survivor} (the published cluster credentials live there)"
	log "removing ${name}"
	drain_node "${name}"
	# shellcheck disable=SC2310
	if ! remove_etcd_member "${survivor}" "${name}"; then
		warn "could not remove the etcd member for ${name} from ${survivor}; resetting ${name}"
		docker exec "${name}" timeout "${WAIT_TIMEOUT}" kubeadm reset --force --ignore-preflight-errors=all \
			> /dev/null 2>&1 \
			|| warn "kubeadm reset on ${name} failed; its etcd member may need manual removal"
	fi
	# Delete the container before the Node object so a still-running kubelet
	# cannot recreate the Node (and its mirror pods) after the deletion.
	docker rm -f "${name}" > /dev/null
	delete_node "${name}"
}

cmd_clean() {
	local name="$1" worker_addr
	[[ ${name} =~ ^${CLUSTER}-master-[0-9]+$ ]] \
		&& die "cannot clean ${name} (control-plane node); use destroy"
	[[ ${name} =~ ^${CLUSTER}-worker-[0-9]+$ ]] \
		|| die "${name} is not a worker of cluster ${CLUSTER}"
	# shellcheck disable=SC2310
	node_exists "${name}" || die "no container named ${name}"

	# The recreated worker gets the address it already had, not a fresh one
	# from docker's dynamic pool: the address is what the kubelet registered
	# with and what every certificate and EndpointSlice refers to. Reading
	# the old container's IPAMConfig is also what keeps `clean` correct after
	# the topology was scaled (the role-index address formula only describes
	# the initial creation). A container not created with --ip falls back to
	# that formula, using master-1's requested address as the base.
	worker_addr=$(node_address "${name}")
	if [[ -z ${worker_addr} ]]; then
		local masters net_subnet lb_ip master_addr="" use_lb=0
		net_subnet=$(net_subnet_of)
		[[ -n ${net_subnet} ]] || die "cannot determine the subnet of ${NET_NAME}; is the cluster intact? (destroy and recreate it)"
		# shellcheck disable=SC2310
		if node_exists "${MASTER_NAME}"; then
			master_addr=$(node_address "${MASTER_NAME}")
		fi
		MASTER_IP="${master_addr:-${MASTER_IP:-${net_subnet%.*}.2}}"
		lb_ip=$(lb_node_ip "${net_subnet}")
		# shellcheck disable=SC2310
		if cluster_has_lb; then
			use_lb=1
		fi
		masters=$(count_masters)
		worker_addr=$(worker_node_ip "${name##*-}" "${masters}" "${net_subnet}" "${lb_ip}" "${use_lb}")
		# The formula describes the initial topology; after a scale it can
		# point at another node. Refuse before deleting the worker.
		local other other_addr container_list
		container_list=$(network_address_holders)
		while read -r other; do
			[[ -n ${other} && ${other} != "${name}" ]] || continue
			other_addr=$(node_address "${other}")
			[[ ${other_addr} != "${worker_addr}" ]] \
				|| die "cannot recreate ${name}: ${worker_addr} is used by ${other}; recreate the cluster instead"
		done <<< "${container_list}"
	fi

	# A node's netns lives on its container; a fresh container is the only
	# guaranteed way to drop CNI residue (iptables chains, ipsets, bpf pins,
	# interfaces) left behind by an in-place uninstall.
	log "recreating ${name} with a pristine netns (drops CNI residue)"
	drain_node "${name}"
	docker rm -f "${name}" > /dev/null
	delete_node "${name}"
	read_join_credentials
	run_node_retry "${name}" worker --ip "${worker_addr}" "${CRED_ARGS[@]}"
	log "${name} recreated (${worker_addr}); it is rejoining the cluster"
}

cmd_status() {
	local running_total=0 name container_list state health
	# Only zek's own containers: a user's NFS server or registry on the
	# cluster network is not a node and must not be counted as one.
	container_list=$(owned_container_names)
	# A cluster normally has its network, but a partially cleaned-up one may
	# still have containers to report.
	# shellcheck disable=SC2310
	if [[ -z ${container_list} ]] && ! net_exists; then
		die "no cluster named ${CLUSTER} (create it with: $0 --cluster ${CLUSTER} up)"
	fi
	while read -r name; do
		[[ -n ${name} ]] || continue
		state=$(docker inspect -f '{{.State.Status}}' "${name}" 2> /dev/null) || continue
		# Docker stops probing a stopped/created container, so it shows no
		# health verdict; a running container without a healthcheck does
		# not have .State.Health either.
		health=-
		if [[ ${state} == running ]]; then
			health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "${name}" 2> /dev/null) || health=-
		fi
		printf '%-25s %-8s %s\n' "${name}" "${state}" "${health}"
		if [[ ${state} == running || ${state} == restarting ]]; then
			running_total=$((running_total + 1))
		fi
	done <<< "${container_list}"
	if [[ ${running_total} -eq 0 ]]; then
		log "cluster ${CLUSTER} is stopped"
		return 0
	fi
	echo
	# shellcheck disable=SC2310
	kube get nodes -o wide || log "control plane not reachable"
}

cmd_destroy() {
	local -a names=()
	local name container_list containers_removed=0 network_removed=0
	# Remove zek's own containers first, while any user-attached service on
	# the network (an NFS server backing PVCs, a registry, ...) is still
	# running. A node with a live mount on a server that has already gone
	# away cannot be killed: `docker rm -f` fails with "did not receive an
	# exit event" and the network namespace never tears down. If a node
	# cannot be removed, stop before touching the rest so the external
	# service stays available for a retry.
	container_list=$(owned_container_names)
	if [[ -n ${container_list} ]]; then
		mapfile -t names <<< "${container_list}"
	fi
	for name in "${names[@]}"; do
		log "removing ${name}"
		if ! docker rm -f "${name}" > /dev/null; then
			die "failed to remove ${name}; left ${NET_NAME} and the remaining containers intact (restart any external storage server, then retry destroy)"
		fi
		containers_removed=1
	done
	# With every node gone, the remaining network containers (a user's NFS
	# server, registry, ...) can be removed safely. They would otherwise
	# keep the network from being removed.
	names=()
	container_list=$(network_container_names)
	if [[ -n ${container_list} ]]; then
		mapfile -t names <<< "${container_list}"
	fi
	for name in "${names[@]}"; do
		log "removing ${name} (attached to ${NET_NAME})"
		if ! docker rm -f "${name}" > /dev/null; then
			die "failed to remove ${name}; left ${NET_NAME} and the remaining containers intact"
		fi
		containers_removed=1
	done
	# shellcheck disable=SC2310
	if net_exists; then
		if ! docker network rm "${NET_NAME}" > /dev/null; then
			die "failed to remove network ${NET_NAME}; containers may still be attached (inspect with: docker network inspect ${NET_NAME})"
		fi
		network_removed=1
	fi
	if [[ ${containers_removed} -eq 0 && ${network_removed} -eq 0 ]]; then
		log "no cluster named ${CLUSTER}"
		return 0
	fi
	if [[ ${network_removed} -eq 1 && ${containers_removed} -eq 1 ]]; then
		log "removed cluster ${CLUSTER} (containers + network ${NET_NAME})"
	elif [[ ${network_removed} -eq 1 ]]; then
		log "removed cluster ${CLUSTER} (network ${NET_NAME}; no containers left)"
	else
		log "removed cluster ${CLUSTER} (containers; network ${NET_NAME} was already gone)"
	fi
}

usage() {
	die "usage: $0 [--version] [--latest] [--lb] [--cluster name] [--timeout seconds] [--image img] [--subnet cidr] [--master-ip ip] [--dns ip] [--pod-cidr cidr] [--mounts 'src:dst ...'] {up [--workers N] [--masters M]|down|clean <name>|status|kubectl <args>|logs <name>|destroy}"
}

# Global flags are only parsed before the command (see the header), so a
# trailing argument on a command that takes none is a mistake - e.g.
# `destroy --cluster prod` would otherwise destroy the default cluster.
case "${1:-}" in
	up)
		shift
		cmd_up "$@"
		;;
	down)
		[[ $# -eq 1 ]] || usage
		cmd_down
		;;
	clean)
		[[ $# -eq 2 ]] || usage
		cmd_clean "$2"
		;;
	status)
		[[ $# -eq 1 ]] || usage
		cmd_status
		;;
	kubectl)
		shift
		kube "$@"
		;;
	logs)
		[[ $# -eq 2 ]] || usage
		docker logs -f "$2"
		;;
	destroy)
		[[ $# -eq 1 ]] || usage
		cmd_destroy
		;;
	*) usage ;;
esac
