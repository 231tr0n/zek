#!/usr/bin/env bash
#
# zek - manage zek Kubernetes clusters on the local Docker daemon.
#
# A cluster is created in one shot with a fixed topology: `up` creates it
# on the first run and only restarts the same containers afterwards (node
# names and sizes never change - `clean` replaces a worker in place), `down`
# stops it, `destroy` removes it. Several clusters can coexist - the
# --cluster flag (or ZEK_CLUSTER) selects one, and every container and
# network is prefixed with the cluster name.
#
# All state lives on the node containers' own writable layer: the cluster
# survives docker stop/start, docker restart and host reboots, and is gone
# once the containers are removed (destroy, docker rm, ...).
#
# Usage:
#   ./zek.sh [flags] up [--workers N] [--masters M]
#                               first run: create the cluster with N workers
#                               (default 1) and M masters (default 1; M>1
#                               starts the HA load balancer). A bare number
#                               (up 2) is a shorthand for --workers 2. Later
#                               runs just restart the existing nodes.
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
#   ./zek.sh [flags] destroy    remove the cluster's containers and network
#
#   Global flags go before the command. Every one has an env twin and can
#   be written as --flag value or --flag=value; when both are set the flag
#   wins:
#   --cluster NAME          cluster to operate on (ZEK_CLUSTER, default zek)
#   --timeout SECONDS       bound for every internal wait (control plane up,
#                           nodes registered, credentials published);
#                           default 600 (ZEK_TIMEOUT)
#   --image IMAGE           node image (ZEK_IMAGE, default zek:latest)
#   --subnet CIDR           cluster subnet (ZEK_SUBNET, default: first free
#                           172.20.X.0/24)
#   --master-ip IP          first master's IP (ZEK_MASTER_IP, default
#                           <subnet>.2)
#   --dns IP                upstream DNS for the node containers (ZEK_DNS)
#   --pod-cidr CIDR         pod subnet passed to kubeadm (ZEK_POD_CIDR or
#                           POD_CIDR, default 10.244.0.0/16)
#   --mounts SPEC           extra host bind mounts for the nodes: a
#                           space-separated list of
#                           host-path:container-path[:options] (ZEK_MOUNTS)
#   up-only flags: --workers N (ZEK_NODES), --masters M (ZEK_MASTERS).
#
# Env overrides: the env twin of every flag above - ZEK_CLUSTER,
#                ZEK_TIMEOUT, ZEK_IMAGE, ZEK_SUBNET, ZEK_MASTER_IP, ZEK_DNS,
#                ZEK_POD_CIDR (or POD_CIDR), ZEK_MOUNTS, ZEK_NODES,
#                ZEK_MASTERS.
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
# 0-255, with a /0-32 prefix required for cidr and forbidden for addr.
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
		*) die "require_ipv4: unknown kind '${kind}'" ;;
	esac
	[[ ${value} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
		|| die "invalid ${label} '${value}' (${hint})"
	[[ ${value} != */* ]] || ((10#${value##*/} <= 32)) \
		|| die "invalid ${label} '${value}' (${hint})"
	local -a parts=()
	local octet
	IFS=. read -r -a parts <<< "${value%%/*}"
	for octet in "${parts[@]}"; do
		# The test above rejects leading zeros outright (docker's IP
		# parser does too); 10#... below just keeps the arithmetic
		# decimal instead of octal.
		[[ ${octet} != 0[0-9]* ]] \
			|| die "invalid ${label} '${value}' (${hint})"
		((10#${octet} <= 255)) || die "invalid ${label} '${value}' (${hint})"
	done
}

# Settings: environment first (each flag's env twin), then the flags parsed
# below override them (flag > env > default), then everything is validated.
CLUSTER="${ZEK_CLUSTER:-zek}"
WAIT_TIMEOUT="${ZEK_TIMEOUT:-600}"
IMAGE="${ZEK_IMAGE:-zek:latest}"
SUBNET="${ZEK_SUBNET:-}"
MASTER_IP="${ZEK_MASTER_IP:-}"
DNS="${ZEK_DNS:-}"
# ZEK_POD_CIDR is the flag's env twin; POD_CIDR is a compatibility alias.
# Empty here means "let entrypoint.sh default kubeadm to 10.244.0.0/16".
POD_CIDR="${ZEK_POD_CIDR:-${POD_CIDR:-}}"
MOUNTS="${ZEK_MOUNTS:-}"
# ZEK_NODES counts workers only (historic name); masters are ZEK_MASTERS.
# Both are validated against the *effective* value in cmd_up, after the
# flags below may have overridden them - flag > env must hold even for
# invalid env values.
DEFAULT_WORKERS="${ZEK_NODES:-1}"
DEFAULT_MASTERS="${ZEK_MASTERS:-1}"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--cluster)
			shift
			[[ $# -gt 0 ]] || die "--cluster needs a cluster name"
			CLUSTER="$1"
			shift
			;;
		--cluster=*) CLUSTER="${1#*=}" && shift ;;
		--timeout)
			shift
			[[ $# -gt 0 ]] || die "--timeout needs a number of seconds"
			WAIT_TIMEOUT="$1"
			shift
			;;
		--timeout=*) WAIT_TIMEOUT="${1#*=}" && shift ;;
		--image)
			shift
			[[ $# -gt 0 ]] || die "--image needs a value"
			IMAGE="$1"
			shift
			;;
		--image=*) IMAGE="${1#*=}" && shift ;;
		--subnet)
			shift
			[[ $# -gt 0 ]] || die "--subnet needs a value"
			SUBNET="$1"
			shift
			;;
		--subnet=*) SUBNET="${1#*=}" && shift ;;
		--master-ip)
			shift
			[[ $# -gt 0 ]] || die "--master-ip needs a value"
			MASTER_IP="$1"
			shift
			;;
		--master-ip=*) MASTER_IP="${1#*=}" && shift ;;
		--dns)
			shift
			[[ $# -gt 0 ]] || die "--dns needs a value"
			DNS="$1"
			shift
			;;
		--dns=*) DNS="${1#*=}" && shift ;;
		--pod-cidr)
			shift
			[[ $# -gt 0 ]] || die "--pod-cidr needs a value"
			POD_CIDR="$1"
			shift
			;;
		--pod-cidr=*) POD_CIDR="${1#*=}" && shift ;;
		--mounts)
			shift
			[[ $# -gt 0 ]] || die "--mounts needs a value"
			MOUNTS="$1"
			shift
			;;
		--mounts=*) MOUNTS="${1#*=}" && shift ;;
		*) break ;;
	esac
done
[[ ${CLUSTER} =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] \
	|| die "invalid cluster name '${CLUSTER}' (letters, digits, '-' and '_' only)"
[[ ${WAIT_TIMEOUT} =~ ^[1-9][0-9]*$ ]] \
	|| die "invalid timeout '${WAIT_TIMEOUT}' (expected seconds >= 1)"
[[ -n ${IMAGE} ]] || die "--image needs a value"
require_ipv4 "${SUBNET}" cidr subnet
require_ipv4 "${MASTER_IP}" addr "master IP"
require_ipv4 "${DNS}" addr "DNS IP"
require_ipv4 "${POD_CIDR}" cidr "pod CIDR"

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
# dies before any container is created.
mount_entries=()
[[ -n ${MOUNTS} ]] && read -r -a mount_entries <<< "${MOUNTS}"
for m in "${mount_entries[@]}"; do
	[[ ${m} =~ ^[^:]+:/[^:]+(:[^:]*)?$ ]] \
		|| die "invalid mount '${m}' (expected host-path:container-path[:options])"
	NODE_ARGS+=(-v "${m}")
done

net_exists() { docker network inspect "${NET_NAME}" > /dev/null 2>&1; }
net_subnet_of() {
	docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' \
		"${NET_NAME}" 2> /dev/null
}
ensure_net() {
	# First of the many disabled warnings in this file: this call sits on
	# the left of `if`, where errexit does not propagate, and the tool
	# flags every such call as a possibly-hidden failure. net_exists is a
	# predicate whose failure is exactly the branch being taken, so the
	# directive is intentional here and repeated per site the same way.
	# shellcheck disable=SC2310
	if net_exists; then
		# The existing network belongs to this cluster; reusing its subnet
		# makes a retry after a failed create work. An explicit --subnet
		# that disagrees would silently derive wrong container IPs later,
		# so refuse it instead.
		local have
		have=$(net_subnet_of)
		[[ -z ${SUBNET} || ${SUBNET} == "${have}" ]] \
			|| die "cluster ${CLUSTER} uses subnet ${have}, not --subnet ${SUBNET}; pass --subnet ${have} or destroy the cluster"
		return 0
	fi
	docker network create --driver bridge --subnet "$1" "${NET_NAME}" > /dev/null \
		|| die "cannot create network ${NET_NAME} with subnet $1 (address space overlapping another network? pass --subnet)"
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
	# Collect the occupied subnets word by word through plain assignments:
	# no quotes or line breaks nested inside $(...), which also keeps
	# GitHub's syntax highlighter from derailing.
	local i net nets subnets subnet candidate used_subnets=""
	nets="$(docker network ls -q)"
	for net in ${nets}; do
		subnets="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${net}")"
		for subnet in ${subnets}; do
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
	die "no free 172.20.X.0/24 subnet left for cluster ${CLUSTER}"
}

node_exists() { docker inspect --type container "$1" > /dev/null 2>&1; }

# Containers of this cluster (running or stopped).
cluster_names() { docker ps -a --format '{{.Names}}' -f network="${NET_NAME}" 2> /dev/null || true; }

# Masters are named <cluster>-master-1, <cluster>-master-2, ...; workers are
# <cluster>-worker-N. The `|| true` on each helper: grep -c exits 1 when
# nothing matches (and the pipeline can fail when docker goes away), and
# these run inside $(...) assignments under pipefail - a bare failure would
# abort the whole script instead of yielding an empty/zero count.
count_masters() {
	# shellcheck disable=SC2310
	cluster_names | grep -cE "^${CLUSTER}-master-[0-9]+$" || true
}
count_workers() {
	# shellcheck disable=SC2310
	cluster_names | grep -cE "^${CLUSTER}-worker-[0-9]+$" || true
}
worker_names() {
	# shellcheck disable=SC2310
	cluster_names | grep -E "^${CLUSTER}-worker-[0-9]+$" || true
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

# A static-IP start can race the previous endpoint's cleanup and fail
# with "Address already in use"; retry before giving up.
start_node() { # name
	local out
	for _ in {1..10}; do
		if out=$(docker start "$1" 2>&1); then
			return 0
		fi
		sleep 2
	done
	printf '%s\n' "${out}" >&2
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
	docker exec "${exec_flags[@]}" "${MASTER_NAME}" /entrypoint.sh kubectl "$@"
}

# Every internal wait is bounded by WAIT_TIMEOUT (--timeout, default
# ZEK_TIMEOUT or 600s) so a broken cluster fails fast instead of hanging.
wait_for_api() {
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for the API of ${CLUSTER} to answer (timeout ${WAIT_TIMEOUT}s)"
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		# shellcheck disable=SC2310
		kube get nodes > /dev/null 2>&1 && {
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
		phase="$(kube -n kube-system get pod "kube-apiserver-${name}" -o jsonpath='{.status.phase}' 2> /dev/null || true)"
		if [[ ${phase} == Running ]]; then
			# shellcheck disable=SC2310
			phase="$(kube -n kube-system get pod "etcd-${name}" -o jsonpath='{.status.phase}' 2> /dev/null || true)"
			[[ ${phase} == Running ]] && return 0
		fi
		sleep 2
	done
	die "control plane on ${name} not ready after ${WAIT_TIMEOUT}s"
}

wait_for_nodes() {
	local want="$1" have=0 deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for ${want} node(s) to register (timeout ${WAIT_TIMEOUT}s)"
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		# shellcheck disable=SC2310
		have=$(kube get nodes --no-headers 2> /dev/null | wc -l || true)
		[[ ${have} -ge ${want} ]] && return 0
		sleep 2
	done
	die "expected ${want} nodes after ${WAIT_TIMEOUT}s, saw ${have}"
}

# The first master publishes the join credentials (token, CA hash, API
# endpoint, certificate key) under /etc/cluster on its own layer; they are
# handed to joining nodes as env vars. The files appear a moment after the
# API starts answering, so wait for them - joiners then start immediately,
# while kubeadm's uploaded control-plane certificates are still fresh.
read_join_credentials() {
	local token="" ca_hash="" endpoint="" cert_key="" deadline=$((SECONDS + WAIT_TIMEOUT))
	while [[ ${SECONDS} -lt ${deadline} ]]; do
		token="$(docker exec "${MASTER_NAME}" cat /etc/cluster/token 2> /dev/null)" \
			&& ca_hash="$(docker exec "${MASTER_NAME}" cat /etc/cluster/ca-hash 2> /dev/null)" \
			&& endpoint="$(docker exec "${MASTER_NAME}" cat /etc/cluster/api-endpoint 2> /dev/null)" \
			&& cert_key="$(docker exec "${MASTER_NAME}" cat /etc/cluster/cert-key 2> /dev/null)" \
			&& break
		sleep 2
	done
	[[ -n ${token} ]] && [[ -n ${ca_hash} ]] && [[ -n ${endpoint} ]] && [[ -n ${cert_key} ]] \
		|| die "join credentials not published by ${MASTER_NAME} after ${WAIT_TIMEOUT}s"
	CRED_ARGS=(
		--env "JOIN_TOKEN=${token}"
		--env "JOIN_CA_HASH=${ca_hash}"
		--env "JOIN_API_ENDPOINT=${endpoint}"
		--env "JOIN_CERT_KEY=${cert_key}"
	)
}

# Static IP of master $1 (1-based): the first sits at --master-ip
# (ZEK_MASTER_IP, default <subnet>.2), following ones increment the last
# octet.
master_node_ip() {
	local base="${MASTER_IP%.*}" last_octet="${MASTER_IP##*.}"
	echo "${base}.$((last_octet + $1 - 1))"
}

# Decimal 32-bit form of a dotted-quad IPv4 address.
ip_to_int() {
	local octet ipn=0
	local -a o=()
	IFS=. read -r -a o <<< "$1"
	for octet in "${o[@]}"; do
		ipn=$((ipn << 8 | 10#${octet}))
	done
	echo "${ipn}"
}

# True when IPv4 $1 sits inside CIDR $2 (both dotted-quad IPv4).
ip_in_cidr() { # <ip> <cidr>
	local cidr=$2
	local prefix=${cidr##*/}
	local ipn netn mask
	ipn=$(ip_to_int "$1")
	netn=$(ip_to_int "${cidr%/*}")
	mask=$(((0xFFFFFFFF << (32 - 10#${prefix})) & 0xFFFFFFFF))
	(((ipn & mask) == (netn & mask)))
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
	# shellcheck disable=SC2310
	ip_in_cidr "${ip}" "${cidr}" \
		|| die "${label} ${ip} is outside the cluster subnet ${cidr} (check --subnet/--master-ip)"
	ipn=$(ip_to_int "${ip}")
	netn=$(ip_to_int "${cidr%/*}")
	mask=$(((0xFFFFFFFF << (32 - 10#${prefix})) & 0xFFFFFFFF))
	gateway=$((netn + 1))
	broadcast=$((netn | (~mask & 0xFFFFFFFF)))
	if ((ipn == netn)); then
		die "${label} ${ip} is the network address of ${cidr}"
	fi
	if ((ipn == gateway)); then
		die "${label} ${ip} is the gateway of ${cidr}"
	fi
	if ((ipn == broadcast)); then
		die "${label} ${ip} is the broadcast address of ${cidr}"
	fi
	return 0
}

create_cluster() {
	local workers="$1" masters="$2"
	local net_subnet subnet_prefix lb_ip endpoint ip i backends=""
	local have_net=0

	# Reuse this cluster's own network when it exists (retry after a
	# failed create): its subnet is authoritative for every container IP
	# derived below. An explicit --subnet that disagrees dies instead of
	# silently deriving addresses from the wrong subnet later.
	# shellcheck disable=SC2310
	if net_exists; then
		have_net=1
		net_subnet=$(net_subnet_of)
		[[ -z ${SUBNET} || ${SUBNET} == "${net_subnet}" ]] \
			|| die "cluster ${CLUSTER} uses subnet ${net_subnet}, not --subnet ${SUBNET}; pass --subnet ${net_subnet} or destroy the cluster"
	else
		net_subnet="$(pick_subnet)"
	fi
	subnet_prefix="${net_subnet%.*}"
	MASTER_IP="${MASTER_IP:-${subnet_prefix}.2}"
	lb_ip="${subnet_prefix}.10"
	endpoint="${MASTER_IP}:6443"
	if [[ ${masters} -gt 1 ]]; then
		endpoint="${lb_ip}:6443"
	fi
	# Every address docker will be asked to allocate is validated against
	# the subnet before the network exists: docker only rejects
	# out-of-range/gateway/broadcast IPs at `docker run --ip`, which would
	# fail after the network (and LB) were created and leave an `up` that
	# can never retry without destroy. The masters walk up from
	# --master-ip while the LB owns <subnet>.10, so a master landing on
	# .10 dies here too.
	for i in $(seq 1 "${masters}"); do
		ip=$(master_node_ip "${i}")
		require_host_ip "${ip}" "${net_subnet}" "master ${i}"
		if [[ ${masters} -gt 1 ]]; then
			[[ ${ip} != "${lb_ip}" ]] \
				|| die "master ${i} would get IP ${ip}, which is the load balancer's IP (${lb_ip}); change --master-ip or lower --masters"
			backends="${backends:+${backends} }${ip}"
		fi
	done
	if [[ ${masters} -gt 1 ]]; then
		require_host_ip "${lb_ip}" "${net_subnet}" "load balancer"
	fi
	if [[ ${have_net} == 0 ]]; then
		ensure_net "${net_subnet}"
	fi
	if [[ ${masters} -gt 1 ]]; then
		# A load balancer left behind by an earlier failed create is
		# reused and started: its geometry is fixed for this subnet, so
		# its backends are still correct.
		# shellcheck disable=SC2310
		if node_exists "${LB_NAME}"; then
			log "reusing ${LB_NAME} (${lb_ip}) from an earlier failed create"
			start_node "${LB_NAME}"
		else
			log "creating ${LB_NAME} (${lb_ip}) in front of: ${backends}"
			run_node "${LB_NAME}" lb --ip "${lb_ip}" --env "LB_BACKENDS=${backends}"
		fi
	fi

	log "creating ${MASTER_NAME} (${MASTER_IP})"
	run_node "${MASTER_NAME}" master --ip "${MASTER_IP}" --env "API_ENDPOINT=${endpoint}"
	wait_for_api
	read_join_credentials

	local master_ip
	for i in $(seq 2 "${masters}"); do
		master_ip=$(master_node_ip "${i}")
		log "creating ${CLUSTER}-master-${i} (${master_ip}) as control-plane"
		run_node "${CLUSTER}-master-${i}" master --ip "${master_ip}" \
			--env MASTER_JOIN=1 "${CRED_ARGS[@]}"
		wait_for_master_ready "${CLUSTER}-master-${i}"
		wait_for_nodes "${i}"
	done

	for i in $(seq 1 "${workers}"); do
		run_node "${CLUSTER}-worker-${i}" worker "${CRED_ARGS[@]}"
	done
	wait_for_nodes "$((masters + workers))"

	log "cluster ${CLUSTER} up: ${masters} master(s) + ${workers} worker(s). Nodes report NotReady until you install a CNI."
}

# The topology is fixed at creation time: restart exactly the containers
# that exist (load balancer first, then masters, then workers), warning
# when the requested sizes differ from what was created.
restart_cluster() {
	local workers="$1" masters="$2" workers_set="$3" masters_set="$4"
	local have_masters have_workers
	have_masters="$(count_masters)"
	have_workers="$(count_workers)"
	if { [[ ${workers_set} == 1 ]] && [[ ${workers} != "${have_workers}" ]]; } \
		|| { [[ ${masters_set} == 1 ]] && [[ ${masters} != "${have_masters}" ]]; }; then
		warn "cluster ${CLUSTER} already exists with ${have_masters} master(s) and ${have_workers} worker(s); topology is fixed, ignoring --masters/--workers"
	fi

	log "restarting cluster ${CLUSTER}"
	# shellcheck disable=SC2310
	if node_exists "${LB_NAME}"; then
		log "starting ${LB_NAME}"
		start_node "${LB_NAME}"
	fi
	local i=1 name worker_list
	while :; do
		name="${CLUSTER}-master-${i}"
		# shellcheck disable=SC2310
		node_exists "${name}" || break
		log "starting ${name}"
		start_node "${name}"
		i=$((i + 1))
	done
	worker_list=$(worker_names)
	while read -r name; do
		[[ -n ${name} ]] || continue
		log "starting ${name}"
		start_node "${name}"
	done <<< "${worker_list}"

	wait_for_api
	wait_for_nodes "$((have_masters + have_workers))"
	log "cluster ${CLUSTER} up: ${have_masters} master(s) + ${have_workers} worker(s). Nodes report NotReady until you install a CNI."
}

cmd_up() {
	local workers="" masters="" workers_set=0 masters_set=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--workers)
				[[ $# -ge 2 ]] || die "--workers needs a value"
				workers="$2"
				workers_set=1
				shift 2
				;;
			--masters)
				[[ $# -ge 2 ]] || die "--masters needs a value"
				masters="$2"
				masters_set=1
				shift 2
				;;
			--workers=*)
				workers="${1#*=}"
				workers_set=1
				shift
				;;
			--masters=*)
				masters="${1#*=}"
				masters_set=1
				shift
				;;
			[0-9]*)
				[[ ${workers_set} == 0 ]] \
					|| die "unexpected argument '$1' (a bare number is a --workers shorthand; it may appear once)"
				workers="$1"
				workers_set=1
				shift
				;;
			*) usage ;;
		esac
	done
	if [[ ${workers_set} == 1 && -z ${workers} ]]; then
		die "--workers needs a value"
	fi
	if [[ ${masters_set} == 1 && -z ${masters} ]]; then
		die "--masters needs a value"
	fi
	workers="${workers:-${DEFAULT_WORKERS}}"
	masters="${masters:-${DEFAULT_MASTERS}}"
	# Validate the effective values (flag > env) here, after the merge, so
	# a bad ZEK_NODES/ZEK_MASTERS is always overridable by a valid flag.
	# Bounds are checked by string length first: bash arithmetic would
	# silently wrap a 20-digit literal and `seq 1 <huge>` eats the disk.
	# No leading zeros either - $((08)) is a hard arithmetic error later.
	[[ ${workers} =~ ^(0|[1-9][0-9]*)$ ]] \
		|| die "invalid workers '${workers}' (expected a plain number 0-64; check --workers/ZEK_NODES)"
	[[ ${masters} =~ ^[1-9][0-9]*$ ]] \
		|| die "invalid masters '${masters}' (expected a number 1-64; check --masters/ZEK_MASTERS)"
	{ [[ ${#workers} -le 3 ]] && ((10#${workers} <= 64)); } \
		|| die "workers ${workers} out of range (0-64)"
	{ [[ ${#masters} -le 3 ]] && ((10#${masters} <= 64)); } \
		|| die "masters ${masters} out of range (1-64)"

	# shellcheck disable=SC2310
	if node_exists "${MASTER_NAME}"; then
		restart_cluster "${workers}" "${masters}" "${workers_set}" "${masters_set}"
	else
		create_cluster "${workers}" "${masters}"
	fi
}

cmd_down() {
	local -a names=()
	local name list
	list=$(docker ps --format '{{.Names}}' -f network="${NET_NAME}") || list=""
	[[ -n ${list} ]] && mapfile -t names <<< "${list}"
	[[ ${#names[@]} -gt 0 ]] || {
		log "cluster ${CLUSTER} is not running"
		return 0
	}
	for name in "${names[@]}"; do
		log "stopping ${name}"
		docker stop "${name}" > /dev/null
	done
	log "cluster ${CLUSTER} stopped (state preserved; restart with up)"
}

# Evict a worker: drain it and drop its Node object. Tolerates an unreachable
# control plane (drain/delete may fail) - the container is removed regardless.
evict_worker() {
	local name="$1"
	# shellcheck disable=SC2310
	kube drain "${name}" --ignore-daemonsets --delete-emptydir-data --force \
		> /dev/null 2>&1 || true
	# shellcheck disable=SC2310
	kube delete node "${name}" > /dev/null 2>&1 \
		|| log "node object not removed (control plane unreachable?); continuing"
}

cmd_clean() {
	local name="$1"
	[[ ${name} =~ ^${CLUSTER}-master-[0-9]+$ ]] \
		&& die "cannot clean ${name} (control-plane node); use destroy"
	[[ ${name} =~ ^${CLUSTER}-worker-[0-9]+$ ]] \
		|| die "${name} is not a worker of cluster ${CLUSTER}"
	# shellcheck disable=SC2310
	node_exists "${name}" || die "no container named ${name}"

	# A node's netns lives on its container; a fresh container is the only
	# guaranteed way to drop CNI residue (iptables chains, ipsets, bpf pins,
	# interfaces) left behind by an in-place uninstall.
	log "recreating ${name} with a pristine netns (drops CNI residue)"
	evict_worker "${name}"
	docker rm -f "${name}" > /dev/null
	read_join_credentials
	run_node "${name}" worker "${CRED_ARGS[@]}"
	log "${name} recreated; it is rejoining the cluster"
}

cmd_status() {
	# shellcheck disable=SC2310
	net_exists || die "no cluster named ${CLUSTER} (create it with: $0 --cluster ${CLUSTER} up)"
	local running=0 name state status health rows
	rows=$(docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' -f network="${NET_NAME}") || rows=""
	while IFS=$'\t' read -r name state status; do
		[[ -n ${name} ]] || continue
		# docker ps cannot format .State.Health (State is a plain string
		# there), but the HEALTHCHECK verdict rides the end of .Status
		# for a running container - and only the starting one carries a
		# "health: " prefix (`Up 3 seconds (health: starting)` vs
		# `Up 25 seconds (unhealthy)`). `-` marks a container docker is
		# not probing (stopped/created) or one without a healthcheck.
		health=-
		if [[ ${status} =~ \((healthy|unhealthy)\)$ ]]; then
			health=${BASH_REMATCH[1]}
		elif [[ ${status} =~ \(health:[[:space:]]starting\)$ ]]; then
			health=starting
		fi
		printf '%-25s %-8s %s\n' "${name}" "${state}" "${health}"
		[[ ${state} == running ]] && running=$((running + 1))
	done <<< "${rows}"
	[[ ${running} == 0 ]] && {
		log "cluster ${CLUSTER} is stopped"
		return 0
	}
	echo
	# shellcheck disable=SC2310
	kube get nodes -o wide || log "control plane not reachable"
}

cmd_destroy() {
	local -a names=()
	local list removed=0
	list=$(cluster_names)
	[[ -n ${list} ]] && mapfile -t names <<< "${list}"
	if [[ ${#names[@]} -gt 0 ]]; then
		docker rm -f "${names[@]}" > /dev/null
		removed=1
	fi
	# shellcheck disable=SC2310
	if net_exists; then
		docker network rm "${NET_NAME}" > /dev/null
		removed=1
	fi
	[[ ${removed} == 1 ]] || {
		log "no cluster named ${CLUSTER}"
		return 0
	}
	log "removed cluster ${CLUSTER} (containers + network ${NET_NAME})"
}

usage() {
	die "usage: $0 [--cluster name] [--timeout seconds] [--image img] [--subnet cidr] [--master-ip ip] [--dns ip] [--pod-cidr cidr] [--mounts 'src:dst ...'] {up [--workers N] [--masters M]|down|clean <name>|status|kubectl <args>|logs <name>|destroy}"
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
