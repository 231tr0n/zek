#!/usr/bin/env bash
#
# zek - manage zek Kubernetes clusters on the local Docker daemon.
#
# A cluster is created in one shot with a fixed topology: `up` creates it
# on the first run and only restarts the same containers afterwards (nodes
# are never added or removed while the cluster exists), `down` stops it,
# `destroy` removes it. Several clusters can coexist - the -c flag (or
# ZEK_CLUSTER) selects one, and every container and network is prefixed
# with the cluster name.
#
# All state lives on the node containers' own writable layer: the cluster
# survives docker stop/start, docker restart and host reboots, and is gone
# once the containers are removed (destroy, docker rm, ...).
#
# Usage:
#   ./zek.sh [-c NAME] [-t SECONDS] up [--workers N] [--masters M]
#                               first run: create the cluster with N workers
#                               (default 1) and M masters (default 1; M>1
#                               starts the HA load balancer). A bare number
#                               (up 2) is a shorthand for --workers 2. Later
#                               runs just restart the existing nodes.
#   ./zek.sh [-c NAME] [-t SECONDS] down
#                               stop every node container (state is kept)
#   ./zek.sh [-c NAME] clean <name>
#                               evict a worker and recreate it with a fresh
#                               netns (drops any CNI iptables/ipsets/bpf residue)
#   ./zek.sh [-c NAME] status    show node containers and cluster nodes
#   ./zek.sh [-c NAME] kubectl <args...>
#                               run kubectl against the cluster (may be
#                               piped manifests)
#   ./zek.sh [-c NAME] logs <name>
#                               tail a node container's logs
#   ./zek.sh [-c NAME] destroy   remove the cluster's containers and network
#
#   -t, --timeout SECONDS  bound for every internal wait (control plane up,
#                          nodes registered, credentials published); default
#                          600, override with ZEK_TIMEOUT.
#
# Env overrides: ZEK_CLUSTER, ZEK_TIMEOUT, ZEK_IMAGE, ZEK_SUBNET,
#                ZEK_MASTER_IP, ZEK_DNS, POD_CIDR, ZEK_NODES (default --workers)
set -euo pipefail

log() { echo "[zek] $*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

CLUSTER="${ZEK_CLUSTER:-zek}"
WAIT_TIMEOUT="${ZEK_TIMEOUT:-600}"
while [ $# -gt 0 ]; do
	case "$1" in
	-c | --cluster)
		shift
		[ $# -gt 0 ] || die "-c needs a cluster name"
		CLUSTER="$1"
		shift
		;;
	-c=* | --cluster=*) CLUSTER="${1#*=}" && shift ;;
	-t | --timeout)
		shift
		[ $# -gt 0 ] || die "-t needs a number of seconds"
		WAIT_TIMEOUT="$1"
		shift
		;;
	-t=* | --timeout=*) WAIT_TIMEOUT="${1#*=}" && shift ;;
	*) break ;;
	esac
done
[[ "$CLUSTER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] ||
	die "invalid cluster name '$CLUSTER' (letters, digits, '-' and '_' only)"
[[ "$WAIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] ||
	die "invalid timeout '$WAIT_TIMEOUT' (expected seconds >= 1)"

IMAGE="${ZEK_IMAGE:-zek:latest}"
NET_NAME="${CLUSTER}-net"
MASTER_NAME="${CLUSTER}-master-1"
LB_NAME="${CLUSTER}-lb"
WORKER_COUNT="${ZEK_NODES:-1}"

NODE_ARGS=(
	--privileged --cgroupns=host
	--network "$NET_NAME"
	--restart unless-stopped
	-v /lib/modules:/lib/modules:ro
	-v /sys/fs/cgroup:/sys/fs/cgroup:rw
	--tmpfs /run --tmpfs /tmp
)
[ -n "${ZEK_DNS:-}" ] && NODE_ARGS+=(--dns "$ZEK_DNS")
[ -n "${POD_CIDR:-}" ] && NODE_ARGS+=(--env "POD_CIDR=$POD_CIDR")

net_exists() { docker network inspect "$NET_NAME" >/dev/null 2>&1; }
ensure_net() { net_exists || docker network create --driver bridge --subnet "$1" "$NET_NAME" >/dev/null; }

# First free 172.20.X.0/24 (or $ZEK_SUBNET when set) so parallel clusters
# never share a subnet.
pick_subnet() {
	[ -n "${ZEK_SUBNET:-}" ] && {
		echo "$ZEK_SUBNET"
		return
	}
	local i cand all
	all="$(docker network ls -q | while read -r n; do
		docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' "$n"
	done)"
	for i in $(seq 0 254); do
		cand="172.20.$i.0/24"
		grep -qx "$cand" <<<"$all" || {
			echo "$cand"
			return
		}
	done
	die "no free 172.20.X.0/24 subnet left for cluster $CLUSTER"
}

node_exists() { docker inspect --type container "$1" >/dev/null 2>&1; }

# Containers of this cluster (running or stopped).
cluster_names() { docker ps -a --format '{{.Names}}' -f network="$NET_NAME" 2>/dev/null || true; }

# Masters are named <cluster>-master-1, <cluster>-master-2, ...; workers are
# <cluster>-worker-N.
count_masters() { cluster_names | grep -cE "^${CLUSTER}-master-[0-9]+$" || true; }
count_workers() { cluster_names | grep -cE "^${CLUSTER}-worker-[0-9]+$" || true; }
worker_names() { cluster_names | grep -E "^${CLUSTER}-worker-[0-9]+$" || true; }

# Every node is a container on the cluster's network running an entrypoint
# role. All state lives on the container's own writable layer: it survives
# stop/start and reboots and is dropped when the container is removed.
run_node() {
	local name="$1" role="$2"
	shift 2
	docker run -d --name "$name" --hostname "$name" \
		"${NODE_ARGS[@]}" "$@" "$IMAGE" "$role"
}

# Run kubectl against the cluster via the first master's container.
kube() {
	local tty_flag=-i
	[ -t 0 ] && tty_flag=""
	docker exec "$tty_flag" "$MASTER_NAME" /entrypoint.sh kubectl "$@"
}

# Every internal wait is bounded by WAIT_TIMEOUT (-t/--timeout, default
# ZEK_TIMEOUT or 600s) so a broken cluster fails fast instead of hanging.
wait_for_cluster_conf() {
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for the control plane of $CLUSTER to come up (timeout ${WAIT_TIMEOUT}s)"
	while [ "$SECONDS" -lt "$deadline" ]; do
		kube get nodes >/dev/null 2>&1 && {
			log "control plane is up"
			return 0
		}
		sleep 2
	done
	die "control plane API not reachable after ${WAIT_TIMEOUT}s (see: ./zek.sh -c $CLUSTER logs $MASTER_NAME)"
}

# Wait until a control-plane node actually serves: its kube-apiserver and
# etcd static pods are Running.
wait_for_master_ready() {
	local name="$1" phase deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for the control plane on $name (timeout ${WAIT_TIMEOUT}s)"
	while [ "$SECONDS" -lt "$deadline" ]; do
		phase="$(kube -n kube-system get pod "kube-apiserver-$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
		if [ "$phase" = Running ]; then
			phase="$(kube -n kube-system get pod "etcd-$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
			[ "$phase" = Running ] && return 0
		fi
		sleep 2
	done
	die "control plane on $name not ready after ${WAIT_TIMEOUT}s"
}

wait_for_nodes() {
	local want="$1" have=0 deadline=$((SECONDS + WAIT_TIMEOUT))
	log "waiting for $want node(s) to register (timeout ${WAIT_TIMEOUT}s)"
	while [ "$SECONDS" -lt "$deadline" ]; do
		have=$(kube get nodes --no-headers 2>/dev/null | wc -l || true)
		[ "$have" -ge "$want" ] && return 0
		sleep 2
	done
	die "expected $want nodes after ${WAIT_TIMEOUT}s, saw $have"
}

# The first master publishes the join credentials (token, CA hash, API
# endpoint, certificate key) under /etc/cluster on its own layer; they are
# handed to joining nodes as env vars. The files appear a moment after the
# API starts answering, so wait for them.
read_join_credentials() {
	local token="" ca="" ep="" key="" deadline=$((SECONDS + WAIT_TIMEOUT))
	while [ "$SECONDS" -lt "$deadline" ]; do
		token="$(docker exec "$MASTER_NAME" cat /etc/cluster/token 2>/dev/null)" &&
			ca="$(docker exec "$MASTER_NAME" cat /etc/cluster/ca-hash 2>/dev/null)" &&
			ep="$(docker exec "$MASTER_NAME" cat /etc/cluster/api-endpoint 2>/dev/null)" &&
			key="$(docker exec "$MASTER_NAME" cat /etc/cluster/cert-key 2>/dev/null)" &&
			break
		sleep 2
	done
	[ -n "$token" ] && [ -n "$ca" ] && [ -n "$ep" ] && [ -n "$key" ] ||
		die "join credentials not published by $MASTER_NAME after ${WAIT_TIMEOUT}s"
	CRED_ARGS=(
		--env "JOIN_TOKEN=$token"
		--env "JOIN_CA_HASH=$ca"
		--env "JOIN_API_ENDPOINT=$ep"
		--env "JOIN_CERT_KEY=$key"
	)
}

# Static IP of master $1 (1-based): the first sits at ZEK_MASTER_IP
# (default <subnet>.2), following ones increment the last octet.
master_node_ip() {
	local base="${MASTER_IP%.*}" last="${MASTER_IP##*.}"
	echo "$base.$((last + $1 - 1))"
}

create_cluster() {
	local workers="$1" masters="$2"

	NET_SUBNET="$(pick_subnet)"
	local prefix="${NET_SUBNET%.*}"
	MASTER_IP="${ZEK_MASTER_IP:-${prefix}.2}"
	local lb_ip="${prefix}.10"
	ensure_net "$NET_SUBNET"

	local endpoint="${MASTER_IP}:6443" i backends=""
	if [ "$masters" -gt 1 ]; then
		endpoint="${lb_ip}:6443"
		for i in $(seq 1 "$masters"); do
			backends="${backends:+$backends }$(master_node_ip "$i")"
		done
		log "creating $LB_NAME ($lb_ip) in front of: $backends"
		run_node "$LB_NAME" lb --ip "$lb_ip" --env "LB_BACKENDS=$backends"
	fi

	log "creating $MASTER_NAME ($MASTER_IP)"
	run_node "$MASTER_NAME" master --ip "$MASTER_IP" --env "API_ENDPOINT=$endpoint"
	wait_for_cluster_conf
	read_join_credentials

	for i in $(seq 2 "$masters"); do
		log "creating ${CLUSTER}-master-$i ($(master_node_ip "$i")) as control-plane"
		run_node "${CLUSTER}-master-$i" master --ip "$(master_node_ip "$i")" \
			--env MASTER_JOIN=1 "${CRED_ARGS[@]}"
		wait_for_master_ready "${CLUSTER}-master-$i"
		wait_for_nodes "$i"
	done

	for i in $(seq 1 "$workers"); do
		run_node "${CLUSTER}-worker-$i" worker "${CRED_ARGS[@]}"
	done
	wait_for_nodes "$((masters + workers))"

	log "cluster $CLUSTER up: $masters master(s) + $workers worker(s). Nodes report NotReady until you install a CNI."
}

# The topology is fixed at creation time: restart exactly the containers
# that exist (load balancer first, then masters, then workers), warning
# when the requested sizes differ from what was created.
restart_cluster() {
	local workers="$1" masters="$2" workers_set="$3" masters_set="$4"
	local have_m have_w
	have_m="$(count_masters)"
	have_w="$(count_workers)"
	if { [ "$workers_set" = 1 ] && [ "$workers" != "$have_w" ]; } ||
		{ [ "$masters_set" = 1 ] && [ "$masters" != "$have_m" ]; }; then
		log "cluster $CLUSTER already exists with $have_m master(s) and $have_w worker(s); topology is fixed, ignoring --masters/--workers"
	fi

	log "restarting cluster $CLUSTER"
	if node_exists "$LB_NAME"; then
		log "starting $LB_NAME"
		docker start "$LB_NAME" >/dev/null
	fi
	local i=1 name
	while :; do
		name="${CLUSTER}-master-$i"
		node_exists "$name" || break
		log "starting $name"
		docker start "$name" >/dev/null
		i=$((i + 1))
	done
	while read -r name; do
		[ -n "$name" ] || continue
		log "starting $name"
		docker start "$name" >/dev/null
	done < <(worker_names)

	wait_for_cluster_conf
	wait_for_nodes "$((have_m + have_w))"
	log "cluster $CLUSTER up: $have_m master(s) + $have_w worker(s). Nodes report NotReady until you install a CNI."
}

cmd_up() {
	local workers="" masters="" workers_set=0 masters_set=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--workers | -w)
			[ $# -ge 2 ] || die "--workers needs a value"
			workers="$2"
			workers_set=1
			shift 2
			;;
		--masters | -m)
			[ $# -ge 2 ] || die "--masters needs a value"
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
			workers="$1"
			workers_set=1
			shift
			;;
		*) usage ;;
		esac
	done
	[ -z "$workers" ] || [[ "$workers" =~ ^[0-9]+$ ]] || die "--workers must be a number"
	[ -z "$masters" ] || { [[ "$masters" =~ ^[0-9]+$ ]] && [ "$masters" -ge 1 ]; } ||
		die "--masters must be a number >= 1"
	workers="${workers:-$WORKER_COUNT}"
	masters="${masters:-1}"

	if node_exists "$MASTER_NAME"; then
		restart_cluster "$workers" "$masters" "$workers_set" "$masters_set"
	else
		create_cluster "$workers" "$masters"
	fi
}

cmd_down() {
	local names name
	mapfile -t names < <(docker ps --format '{{.Names}}' -f network="$NET_NAME")
	[ "${#names[@]}" -gt 0 ] || {
		log "cluster $CLUSTER is not running"
		return 0
	}
	for name in "${names[@]}"; do
		log "stopping $name"
		docker stop "$name" >/dev/null
	done
	log "cluster $CLUSTER stopped (state preserved; restart with up)"
}

# Evict a worker: drain it and drop its Node object. Tolerates an unreachable
# control plane (drain/delete may fail) - the container is removed regardless.
evict_worker() {
	local name="$1"
	kube drain "$name" --ignore-daemonsets --delete-emptydir-data --force \
		>/dev/null 2>&1 || true
	kube delete node "$name" >/dev/null 2>&1 ||
		log "node object not removed (control plane unreachable?); continuing"
}

cmd_clean() {
	local name="$1"
	[[ "$name" =~ ^${CLUSTER}-master-[0-9]+$ ]] &&
		die "cannot clean $name (control-plane node); use destroy"
	[[ "$name" =~ ^${CLUSTER}-worker-[0-9]+$ ]] ||
		die "$name is not a worker of cluster $CLUSTER"
	node_exists "$name" || die "no container named $name"

	# A node's netns lives on its container; a fresh container is the only
	# guaranteed way to drop CNI residue (iptables chains, ipsets, bpf pins,
	# interfaces) left behind by an in-place uninstall.
	log "recreating $name with a pristine netns (drops CNI residue)"
	evict_worker "$name"
	docker rm -f "$name" >/dev/null
	read_join_credentials
	run_node "$name" worker "${CRED_ARGS[@]}"
	log "$name recreated; it is rejoining the cluster"
}

cmd_status() {
	net_exists || die "no cluster named $CLUSTER (create it with: $0 -c $CLUSTER up)"
	local running=0 name state
	while IFS=$'\t' read -r name state; do
		printf '%-25s %s\n' "$name" "$state"
		[ "$state" = running ] && running=$((running + 1))
	done < <(docker ps -a --format '{{.Names}}\t{{.State}}' -f network="$NET_NAME")
	[ "$running" = 0 ] && {
		log "cluster $CLUSTER is stopped"
		return 0
	}
	echo
	kube get nodes -o wide || log "control plane not reachable"
}

cmd_destroy() {
	local names had=0
	mapfile -t names < <(cluster_names)
	if [ "${#names[@]}" -gt 0 ]; then
		docker rm -f "${names[@]}" >/dev/null
		had=1
	fi
	if net_exists; then
		docker network rm "$NET_NAME" >/dev/null
		had=1
	fi
	[ "$had" = 1 ] || {
		log "no cluster named $CLUSTER"
		return 0
	}
	log "removed cluster $CLUSTER (containers + network $NET_NAME)"
}

usage() {
	die "usage: $0 [-c cluster] [-t seconds] {up [--workers N] [--masters M]|down|clean <name>|status|kubectl <args>|logs <name>|destroy}"
}

case "${1:-}" in
up)
	shift
	cmd_up "$@"
	;;
down) cmd_down ;;
clean)
	[ $# -lt 2 ] && usage
	cmd_clean "$2"
	;;
status) cmd_status ;;
kubectl)
	shift
	kube "$@"
	;;
logs)
	[ $# -lt 2 ] && usage
	docker logs -f "$2"
	;;
destroy) cmd_destroy ;;
*) usage ;;
esac
