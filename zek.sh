#!/usr/bin/env bash
#
# zek - manage a zek Kubernetes cluster on the local Docker daemon.
#
# All state lives on the node containers' own writable layer: the cluster
# survives docker stop/start, docker restart and host reboots, and is gone
# once the containers are removed (docker rm, docker compose down, ...).
#
# Usage:
#   ./zek.sh up [N]             create/start the cluster with the master and N workers (default 1)
#   ./zek.sh down               stop every node container (state is kept)
#   ./zek.sh add [name]         start a new worker (auto-named zek-master-worker-N if omitted)
#   ./zek.sh del <name>         evict and remove a worker and its container
#   ./zek.sh clean <name>       evict a worker and recreate it with a fresh netns
#                               (drops any CNI iptables/ipsets/bpf residue)
#   ./zek.sh status             show node containers and cluster nodes
#   ./zek.sh kubectl <args...>  run kubectl against the cluster (may be piped manifests)
#   ./zek.sh logs <name>        tail a node container's logs
#   ./zek.sh destroy            remove all node containers and the network
#
# Env overrides: ZEK_IMAGE, ZEK_NET, ZEK_SUBNET, ZEK_MASTER_IP, ZEK_MASTER,
#               ZEK_DNS, POD_CIDR, ZEK_NODES
set -euo pipefail

IMAGE="${ZEK_IMAGE:-zek:latest}"
NET_NAME="${ZEK_NET:-zek-net}"
NET_SUBNET="${ZEK_SUBNET:-172.20.0.0/24}"
MASTER_IP="${ZEK_MASTER_IP:-172.20.0.2}"
MASTER_NAME="${ZEK_MASTER:-zek-master}"
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

log() { echo "[zek] $*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

net_exists() { docker network inspect "$NET_NAME" >/dev/null 2>&1; }
ensure_net() {
	net_exists || docker network create --driver bridge --subnet "$NET_SUBNET" "$NET_NAME" >/dev/null
}

node_exists() { docker inspect --type container "$1" >/dev/null 2>&1; }

# Every node is a container on the network running an entrypoint role. All
# state lives on the container's own writable layer: it survives stop/start
# and reboots and is dropped when the container is removed.
run_node() {
	local name="$1" role="$2"
	shift 2
	docker run -d --name "$name" --hostname "$name" \
		"${NODE_ARGS[@]}" "$@" "$IMAGE" "$role"
}

start_or_create() {
	local name="$1" role="$2"
	shift 2
	if node_exists "$name"; then
		log "$name exists; $(docker inspect -f '{{.State.Status}}' "$name") -- starting"
		docker start "$name" >/dev/null
	else
		log "starting $name ($role)"
		run_node "$name" "$role" "$@"
	fi
}

# Run kubectl against the cluster via the master container.
kube() {
	local tty_flag=-i
	[ -t 0 ] && tty_flag=""
	docker exec "$tty_flag" "$MASTER_NAME" /entrypoint.sh kubectl "$@"
}

wait_for_cluster_conf() {
	log "waiting for the control plane to come up"
	for _ in $(seq 1 300); do
		kube get nodes >/dev/null 2>&1 && {
			log "control plane is up"
			return 0
		}
		sleep 2
	done
	die "control plane API not reachable (see: ./zek.sh logs $MASTER_NAME)"
}

# The master publishes the join credentials (token, CA hash, IP) under
# /etc/cluster on its own layer; a fresh worker needs them as env vars. These
# helpers emit alternating --env/KEY=VALUE argv pairs so docker receives the
# flag and its value as two separate tokens.
join_credentials() {
	local token ca ip
	token="$(docker exec "$MASTER_NAME" cat /etc/cluster/token)" || die "cannot read the join token from $MASTER_NAME"
	ca="$(docker exec "$MASTER_NAME" cat /etc/cluster/ca-hash)" || die "cannot read the CA hash from $MASTER_NAME"
	ip="$(docker exec "$MASTER_NAME" cat /etc/cluster/master-ip)" || die "cannot read the master IP from $MASTER_NAME"
	printf 'JOIN_TOKEN=%s\nJOIN_CA_HASH=%s\nJOIN_MASTER_IP=%s\n' "$token" "$ca" "$ip"
}

worker_env_args() {
	local creds=() c
	mapfile -t creds < <(join_credentials)
	for c in "${creds[@]}"; do printf -- '--env\n%s\n' "$c"; done
}

next_worker_name() {
	local max=0 name number
	while read -r name; do
		case "$name" in
		"${MASTER_NAME}-worker-"*) number="${name##*-worker-}" ;;
		*) continue ;;
		esac
		[ -n "$number" ] && [ "${number//[^0-9]/}" = "$number" ] &&
			[ "$number" -gt "$max" ] && max="$number"
	done < <(docker ps -a --format '{{.Names}}' -f network="$NET_NAME")
	echo "${MASTER_NAME}-worker-$((max + 1))"
}

wait_for_nodes() {
	local want="$1" have
	for _ in $(seq 1 150); do
		have=$(kube get nodes --no-headers 2>/dev/null | wc -l)
		[ "$have" -ge "$want" ] && return 0
		sleep 2
	done
	die "timed out: expected $want nodes, saw $have"
}

cmd_up() {
	ensure_net
	start_or_create "$MASTER_NAME" master --ip "$MASTER_IP"
	wait_for_cluster_conf

	local worker_count="${1:-$WORKER_COUNT}" i je=()
	mapfile -t je < <(worker_env_args)
	for i in $(seq 1 "$worker_count"); do
		start_or_create "${MASTER_NAME}-worker-$i" worker "${je[@]}"
	done
	wait_for_nodes $((1 + worker_count))

	log "cluster up: master + $worker_count worker(s). Nodes report NotReady until you install a CNI."
}

cmd_down() {
	[ -n "$(docker ps -q -f network="$NET_NAME" 2>/dev/null)" ] || {
		log "no nodes running"
		exit 0
	}
	local names name
	mapfile -t names < <(docker ps --format '{{.Names}}' -f network="$NET_NAME")
	for name in "${names[@]}"; do
		log "stopping $name"
		docker stop "$name" >/dev/null
	done
	log "cluster stopped (state preserved; start again with up)"
}

cmd_add() {
	ensure_net
	local name="${1:-$(next_worker_name)}" je=()
	node_exists "$name" && die "node $name already exists"
	mapfile -t je < <(worker_env_args)
	run_node "$name" worker "${je[@]}"
	log "worker $name started"
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

cmd_del() {
	local name="$1"
	[ "$name" = "$MASTER_NAME" ] && die "refusing to delete the master ($MASTER_NAME); use destroy"
	node_exists "$name" || die "no container named $name"

	log "evicting $name from the cluster"
	evict_worker "$name"
	docker rm -f "$name" >/dev/null
	log "removed $name"
}

cmd_clean() {
	local name="$1" je=()
	[ "$name" = "$MASTER_NAME" ] && die "cannot clean the master ($MASTER_NAME); use destroy + up (etcd lives on its layer)"
	node_exists "$name" || die "no container named $name"

	# A node's netns lives on its container; a fresh container is the only
	# guaranteed way to drop CNI residue (iptables chains, ipsets, bpf pins,
	# interfaces) left behind by an in-place uninstall.
	log "recreating $name with a pristine netns (drops CNI residue)"
	evict_worker "$name"
	docker rm -f "$name" >/dev/null
	mapfile -t je < <(worker_env_args)
	run_node "$name" worker "${je[@]}"
	log "$name recreated; it is rejoining the cluster"
}

cmd_status() {
	local running=0 name state
	while IFS=$'\t' read -r name state; do
		printf '%-20s %s\n' "$name" "$state"
		[ "$state" = running ] && running=$((running + 1))
	done < <(docker ps -a --format '{{.Names}}\t{{.State}}' -f network="$NET_NAME")
	[ "$running" = 0 ] && {
		log "cluster is stopped"
		return 0
	}
	echo
	kube get nodes -o wide || log "control plane not reachable"
}

cmd_destroy() {
	local names
	mapfile -t names < <(docker ps -a --format '{{.Names}}' -f network="$NET_NAME")
	[ "${#names[@]}" -gt 0 ] && docker rm -f "${names[@]}" >/dev/null
	net_exists && docker network rm "$NET_NAME" >/dev/null
	log "removed containers and network $NET_NAME"
}

usage() {
	die "usage: $0 {up [N]|down|add [name]|del <name>|clean <name>|status|kubectl <args>|logs <name>|destroy}"
}

case "${1:-}" in
up)
	shift
	cmd_up "${1:-$WORKER_COUNT}"
	;;
down) cmd_down ;;
add)
	shift
	cmd_add "${1:-}"
	;;
del)
	[ $# -lt 2 ] && usage
	cmd_del "$2"
	;;
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
