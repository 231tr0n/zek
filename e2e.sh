#!/usr/bin/env bash
#
# e2e - end-to-end tests for the zek image.
#
# Builds nothing: point it at an image that already exists (make build).
# Every test creates its own cluster (e2e-<test>), asserts, then destroys it.
#
# Usage:
#   ./e2e.sh [flags] [test ...]   run the given tests, or all of them
#
# Tests:
#   single-node    1 master, 0 workers: the smallest cluster still works
#   multi-master   3 masters + 1 worker: HA init/join behind the LB, 3 etcd
#                  members, quorum survives docker stop/start of a master,
#                  and `zek down`/`up` restarts the HA cluster incl. the LB
#   multi-worker   1 master + 2 workers: every node's kubelet/containerd
#                  work (hostNetwork DaemonSet lands on all 3 nodes)
#   flannel        install flannel, nodes go Ready, coredns rolls out,
#                  cross-node pod-to-pod ping, ClusterIP service routing
#                  and cluster DNS
#   cilium         same with cilium (cilium CLI downloaded on demand,
#                  version matched to the cluster's k8s release)
#   smoke          the zek.sh surface: status, logs, kubectl exec (the
#                  `--` delimiter), every flag form + env precedence +
#                  loud error paths (zek + entrypoint), --subnet/--master-ip
#                  functional, up shorthand vs fixed topology, --timeout
#                  failing fast, clean recreating the worker (new Node UID)
#                  with --image/--dns/--pod-cidr/--mounts, and destroy
#                  removing the containers and network
#   persistence    flannel + a workload, then recovery from: docker
#                  stop/start of every node at once, a stopped worker, a
#                  restarted master, a kubelet crash (supervisor restart),
#                  a missing failSwapOn key and `zek down`/`up` - same
#                  nodes (UIDs), workload Ready again after each cycle
#   recovery       crash-recovery paths: a NO_HOST_MODULES node, an
#                  interrupted worker join, lost join credentials, a
#                  kubectl wait for the config, and two interrupted
#                  control-plane inits (each wipes and re-inits)
#
# Tests run in parallel: ZEK_E2E_JOBS tests at a time (each owns its own
# cluster, subnet and scratch files). Failures never abort the pool - all
# requested tests run, then diagnostics and the verdict are printed.
#
# Flags (anywhere among the test names; each has an env twin and the flag
# wins when both are set; value flags take --flag value or --flag=value):
#   --image IMAGE            image under test (ZEK_IMAGE, default zek:latest)
#   --timeout SECONDS        per-wait budget inside zek.sh (ZEK_TIMEOUT,
#                            default 600)
#   --e2e-timeout SECONDS    budget for kubectl waits (ZEK_E2E_TIMEOUT,
#                            default 1200; large image pulls on a slow day
#                            can eat 10+ minutes)
#   --e2e-tests LIST         comma separated test list (ZEK_E2E_TESTS; same
#                            as the args)
#   --e2e-jobs N             tests to run in parallel (ZEK_E2E_JOBS,
#                            default 2; 1 = serial)
#   --e2e-keep-on-fail       leave the failed cluster running for debugging
#                            (ZEK_E2E_KEEP_ON_FAIL=1)
#   --cilium-version VER     cilium version to install (CILIUM_VERSION;
#                            default: match the cluster's k8s version against
#                            cilium's tested list, else newest stable release)
#
# Env: the env twin of every flag above - ZEK_IMAGE, ZEK_TIMEOUT,
#      ZEK_E2E_TIMEOUT, ZEK_E2E_TESTS, ZEK_E2E_JOBS, ZEK_E2E_KEEP_ON_FAIL,
#      CILIUM_VERSION.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ALL_TESTS=(single-node multi-master multi-worker flannel cilium smoke persistence recovery)

export ZEK_IMAGE="${ZEK_IMAGE:-zek:latest}"
export ZEK_TIMEOUT="${ZEK_TIMEOUT:-600}"
ZEK_E2E_TIMEOUT="${ZEK_E2E_TIMEOUT:-1200}"
ZEK_E2E_JOBS="${ZEK_E2E_JOBS:-2}"
# Optional override; when empty the cilium test resolves a release that
# matches the cluster's k8s version (resolve_cilium_version below).
CILIUM_VERSION="${CILIUM_VERSION:-}"
READY_POLL=10

log() { printf '\n[e2e] %s\n' "$*"; }
die() {
	printf '[e2e] ERROR: %s\n' "$*" >&2
	exit 1
}
fail() {
	printf '\n[e2e] FAIL: %s\n' "$*" >&2
	exit 1
}

usage() {
	die "usage: $0 [--image img] [--timeout s] [--e2e-timeout s] [--e2e-tests list] [--e2e-jobs n] [--e2e-keep-on-fail] [--cilium-version v] [single-node|multi-master|multi-worker|flannel|cilium|smoke|persistence|recovery]..."
}

# --- flag parsing and test selection ----------------------------------------
# Everything that is not a flag is a test name (validated below against
# ALL_TESTS).
requested=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--image)
		[[ $# -ge 2 ]] || die "--image needs a value"
		ZEK_IMAGE="$2"
		shift 2
		;;
	--image=*) ZEK_IMAGE="${1#*=}" && shift ;;
	--timeout)
		[[ $# -ge 2 ]] || die "--timeout needs a value"
		ZEK_TIMEOUT="$2"
		shift 2
		;;
	--timeout=*) ZEK_TIMEOUT="${1#*=}" && shift ;;
	--e2e-timeout)
		[[ $# -ge 2 ]] || die "--e2e-timeout needs a value"
		ZEK_E2E_TIMEOUT="$2"
		shift 2
		;;
	--e2e-timeout=*) ZEK_E2E_TIMEOUT="${1#*=}" && shift ;;
	--e2e-tests)
		[[ $# -ge 2 ]] || die "--e2e-tests needs a value"
		ZEK_E2E_TESTS="$2"
		shift 2
		;;
	--e2e-tests=*) ZEK_E2E_TESTS="${1#*=}" && shift ;;
	--e2e-jobs)
		[[ $# -ge 2 ]] || die "--e2e-jobs needs a value"
		ZEK_E2E_JOBS="$2"
		shift 2
		;;
	--e2e-jobs=*) ZEK_E2E_JOBS="${1#*=}" && shift ;;
	--cilium-version)
		[[ $# -ge 2 ]] || die "--cilium-version needs a value"
		CILIUM_VERSION="$2"
		shift 2
		;;
	--cilium-version=*) CILIUM_VERSION="${1#*=}" && shift ;;
	--e2e-keep-on-fail)
		ZEK_E2E_KEEP_ON_FAIL=1
		shift
		;;
	*)
		requested+=("$1")
		shift
		;;
	esac
done
[[ -n ${ZEK_IMAGE} ]] || die "--image needs a value"
if [[ ${#requested[@]} -eq 0 ]]; then
	if [[ -n ${ZEK_E2E_TESTS:-} ]]; then
		IFS=',' read -ra requested <<<"${ZEK_E2E_TESTS}"
	else
		requested=("${ALL_TESTS[@]}")
	fi
fi
for t in "${requested[@]}"; do
	case " ${ALL_TESTS[*]} " in
	*" ${t} "*) ;;
	*) usage ;;
	esac
done

docker image inspect "${ZEK_IMAGE}" >/dev/null 2>&1 ||
	die "image ${ZEK_IMAGE} not found (run: make build)"

# --- scratch space for downloaded CLIs and kubeconfigs ----------------------
WORK_DIR=$(mktemp -d)
BIN_DIR="${WORK_DIR}/bin"
mkdir -p "${BIN_DIR}"
PATH="${BIN_DIR}:${PATH}"
export PATH

# --- helpers ----------------------------------------------------------------
zk() { ./zek.sh --cluster "$1" "${@:2}"; }

up() { # cluster workers masters
	zk "$1" up --workers "$2" --masters "$3"
}

destroy() { ./zek.sh --cluster "$1" destroy >/dev/null 2>&1 || true; }

# A static-IP start can race the previous endpoint's cleanup and fail
# with "Address already in use"; retry before giving up - same race and
# retry as start_node in zek.sh.
start_containers() { # name...
	local out
	for _ in {1..10}; do
		if out=$(docker start "$@" 2>&1); then
			return 0
		fi
		sleep 2
	done
	printf '%s\n' "${out}" >&2
	return 1
}

running_count() { docker ps --format '{{.Names}}' -f "network=$1-net" | wc -l; }

cluster_containers() { docker ps -a --format '{{.Names}}' -f "network=$1-net"; }

assert_eq() { # desc want got
	[[ $2 == "$3" ]] || fail "$1: want '$2', got '$3'"
}

assert_cmd() { # desc want cmd args... (runs cmd, fails hard if it errors)
	local desc=${1} want=${2} got
	shift 2
	got=$("$@") || fail "${desc}: '$*' failed"
	assert_eq "${desc}" "${want}" "${got}"
}

# Every loud-error promise in the scripts: the command must fail AND its
# merged output must name the problem, so a silent failure or a wrong
# message both get caught.
assert_die() { # desc want-substring cmd args...
	local desc=${1} want=${2} got
	shift 2
	if got=$("$@" 2>&1); then
		fail "${desc}: expected an error, got success: ${got}"
	fi
	[[ ${got} == *"${want}"* ]] ||
		fail "${desc}: want an error mentioning '${want}', got: ${got}"
}

wait_for() { # desc timeout-secs func args...
	local desc=$1 timeout=$2 deadline
	shift 2
	deadline=$((SECONDS + timeout))
	until "$@" >/dev/null 2>&1; do
		[[ ${SECONDS} -lt ${deadline} ]] || fail "timed out after ${timeout}s waiting for: ${desc}"
		# Readiness flips land within seconds, so 2s is enough (a 5s gap
		# used to add dead time to every wait in the suite).
		sleep 2
	done
	log "ok: ${desc}"
}

readyz_ok() { zk "$1" kubectl get --raw='/readyz' 2>/dev/null | grep -qx ok; }

nodes_ready_quick() {
	zk "$1" kubectl wait --for=condition=Ready node --all \
		--timeout="${READY_POLL}s" >/dev/null 2>&1
}

wait_nodes_ready() {
	wait_for "all nodes Ready on $1" "${ZEK_E2E_TIMEOUT}" nodes_ready_quick "$1"
}

node_status_is() { # cluster node want(True|False)
	local got
	# shellcheck disable=SC2310
	got=$(zk "$1" kubectl get node "$2" \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || return 1
	# A dead kubelet's node flips Ready=Unknown after the grace period and
	# stays there, so wanting False means "anything but Ready".
	if [[ $3 == False ]]; then
		[[ ${got} != True ]]
	else
		[[ ${got} == "$3" ]]
	fi
}

node_count() { zk "$1" kubectl get nodes --no-headers | wc -l; }

node_count_is() { # cluster want
	local got
	got=$(node_count "$1")
	[[ ${got} -eq $2 ]]
}

ready_false_count() {
	# shellcheck disable=SC2310
	zk "$1" kubectl get nodes \
		-o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
		grep -c False || true
}

node_uids() {
	zk "$1" kubectl get nodes \
		-o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}{"\n"}{end}' | sort
}

ns_pod_count() { # cluster 'name-regex'
	# shellcheck disable=SC2310
	zk "$1" kubectl -n kube-system get pods --no-headers | grep -cE "$2" || true
}

pod_phase() { # cluster pod-name
	# No stderr suppression: a missing/broken pod must surface
	# kubectl's error next to the assertion failure that follows.
	zk "$1" kubectl -n kube-system get pod "$2" -o jsonpath='{.status.phase}'
}

# Terminal phase of the default-namespace service test pod: either
# outcome ends the wait - the log assertions that follow decide.
svc_test_done() { # cluster
	local phase
	# shellcheck disable=SC2310
	phase=$(zk "$1" kubectl get pod svc-test -o jsonpath='{.status.phase}' 2>/dev/null) ||
		return 1
	[[ ${phase} == Succeeded || ${phase} == Failed ]]
}

container_running() {
	local state
	state=$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) || state=false
	[[ ${state} == true ]]
}

# Is the apiserver inside a master container serving? (no CNI needed)
master_readyz() { # cluster master-index
	docker exec "${1}-master-${2}" curl -skf https://127.0.0.1:6443/readyz 2>/dev/null |
		grep -qx ok
}

# Is the kubelet process alive inside the node container?
kubelet_running() { # container
	docker exec "$1" pgrep -x kubelet >/dev/null 2>&1
}

# The supervisor's restart marker: proves the crash-recovery loop ran,
# not just that a kubelet happens to be up.
supervisor_restarted() { # container
	docker logs "$1" 2>&1 | grep -q "kubelet exited, restarting"
}

# The kubelet config carries failSwapOn: false (appended by the
# supervisor when kubeadm's file lacks the key).
kubelet_failswapon() { # container
	docker exec "$1" grep -q '^failSwapOn:[[:space:]]*false' /var/lib/kubelet/config.yaml
}

# Container log contains a fixed string (our [zek] markers).
log_has() { # container text
	docker logs "$1" 2>&1 | grep -qF "$2"
}

# The master published a complete credential set (admin.conf is last).
creds_published() { # cluster
	docker exec "${1}-master-1" test -f /etc/cluster/admin.conf
}

# Fill CLONE_ARGS with docker run args reproducing container $1's host
# config, for cloning a node with small overrides. Derived from the live
# container via docker inspect, so it tracks zek.sh's NODE_ARGS
# automatically instead of duplicating them in the test.
node_clone_args() { # container
	CLONE_ARGS=()
	local c=$1 priv cgroupns net bind tmp dns
	priv=$(docker inspect -f '{{.HostConfig.Privileged}}' "${c}")
	[[ ${priv} == true ]] && CLONE_ARGS+=(--privileged)
	cgroupns=$(docker inspect -f '{{.HostConfig.CgroupnsMode}}' "${c}")
	[[ -n ${cgroupns} ]] && CLONE_ARGS+=(--cgroupns "${cgroupns}")
	net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "${c}")
	CLONE_ARGS+=(--network "${net}")
	for bind in $(docker inspect -f '{{range .HostConfig.Binds}}{{.}} {{end}}' "${c}"); do
		CLONE_ARGS+=(-v "${bind}")
	done
	for tmp in $(docker inspect -f '{{range $k, $v := .HostConfig.Tmpfs}}{{$k}} {{end}}' "${c}"); do
		CLONE_ARGS+=(--tmpfs "${tmp}")
	done
	for dns in $(docker inspect -f '{{range .HostConfig.DNS}}{{.}} {{end}}' "${c}"); do
		CLONE_ARGS+=(--dns "${dns}")
	done
}

web_info() {
	zk "$1" kubectl -n default get pod -l app=web \
		-o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}@{.spec.nodeName}{"\n"}{end}'
}

kubeconfig() { # cluster -> prints path to its admin.conf
	local out="${WORK_DIR}/kubeconfig-$1.conf"
	docker exec "$1-master-1" cat /etc/kubernetes/admin.conf >"${out}" ||
		die "cannot read admin.conf from $1-master-1"
	printf '%s\n' "${out}"
}

wait_coredns() {
	zk "$1" kubectl -n kube-system rollout status deploy/coredns \
		--timeout="${ZEK_E2E_TIMEOUT}s"
}

# Two busybox pods pinned to different nodes, pinged across the overlay.
# The second pod rides the master (with a toleration for the
# control-plane taint, like the hostcheck DaemonSet below) so a cluster
# with a single worker still proves cross-node routing - the overlay
# tunnel is between node netns and does not care about node roles.
netcheck() {
	local c=$1 ip_a ip_b
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
---
{
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: "net-a",
  },
  spec: {
    nodeSelector: {
      kubernetes.io/hostname: "${c}-worker-1",
    },
    restartPolicy: "Never",
    containers: [{
      name: "app",
      image: "busybox:1.36",
      command: [
        "sleep",
        "600",
      ],
    }],
  },
}
EOF
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
---
{
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: "net-b",
  },
  spec: {
    nodeSelector: {
      kubernetes.io/hostname: "${c}-master-1",
    },
    tolerations: [{
      operator: "Exists",
    }],
    restartPolicy: "Never",
    containers: [{
      name: "app",
      image: "busybox:1.36",
      command: [
        "sleep",
        "600",
      ],
    }],
  },
}
EOF
	zk "${c}" kubectl wait --for=condition=Ready pod/net-a pod/net-b \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	ip_a=$(zk "${c}" kubectl get pod net-a -o jsonpath='{.status.podIP}')
	ip_b=$(zk "${c}" kubectl get pod net-b -o jsonpath='{.status.podIP}')
	log "ping ${ip_a} -> ${ip_b}"
	# shellcheck disable=SC2310
	zk "${c}" kubectl exec net-a -- ping -c 3 "${ip_b}" >/dev/null ||
		fail "${c}: cross-node ping net-a -> net-b failed"
	log "ping ${ip_b} -> ${ip_a}"
	# shellcheck disable=SC2310
	zk "${c}" kubectl exec net-b -- ping -c 3 "${ip_a}" >/dev/null ||
		fail "${c}: cross-node ping net-b -> net-a failed"
	zk "${c}" kubectl delete pod net-a net-b --wait=false >/dev/null
}

# Service + cluster DNS: kube-proxy's ClusterIP path in front of a pod,
# and coredns (rolled out before this runs) answering for both the
# service name and kubernetes.default - 10.96.0.1, the first IP of
# kubeadm's default service subnet (the entrypoint only overrides
# podSubnet). The test pod resolves e2e-svc through coredns and reaches
# svc-a through the ClusterIP, so a pass needs DNS + kube-proxy + the
# overlay datapath together.
svccheck() {
	local c=$1 out
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
---
{
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: "svc-a",
    labels: {
      app: "e2e-svc-a",
    },
  },
  spec: {
    restartPolicy: "Never",
    containers: [{
      name: "app",
      image: "busybox:1.36",
      command: [
        "sh",
        "-c",
        "mkdir -p /www && echo pong > /www/index.html && httpd -f -p 8080 -h /www",
      ],
    }],
  },
}
EOF
	zk "${c}" kubectl wait --for=condition=Ready pod/svc-a \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
---
{
  apiVersion: "v1",
  kind: "Service",
  metadata: {
    name: "e2e-svc",
  },
  spec: {
    selector: {
      app: "e2e-svc-a",
    },
    ports: [{
      port: 80,
      targetPort: 8080,
    }],
  },
}
EOF
	# The retry loop rides out endpoint-sync lag; 15 x (fast wget failure
	# + 2s) bounds a dead service at ~75s instead of the full e2e budget.
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
---
{
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: "svc-test",
  },
  spec: {
    restartPolicy: "Never",
    containers: [{
      name: "app",
      image: "busybox:1.36",
      command: [
        "sh",
        "-c",
        "i=0; until wget -qO- http://e2e-svc/; do i=\$((i+1)); [ \$i -ge 15 ] && exit 1; sleep 2; done; nslookup kubernetes.default",
      ],
    }],
  },
}
EOF
	wait_for "${c}: service test pod finished" 120 svc_test_done "${c}"
	# shellcheck disable=SC2310
	out=$(zk "${c}" kubectl logs svc-test 2>/dev/null) || out=""
	[[ ${out} == *pong* ]] ||
		fail "${c}: ClusterIP service did not serve pong: ${out}"
	[[ ${out} == *10.96.0.1* ]] ||
		fail "${c}: kubernetes.default did not resolve to 10.96.0.1: ${out}"
	zk "${c}" kubectl delete pod svc-a svc-test --wait=false >/dev/null
	zk "${c}" kubectl delete service e2e-svc --wait=false >/dev/null
}

apply_flannel() {
	local manifest
	manifest=$(curl -fsSL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml) ||
		die "flannel manifest download failed"
	# "configured/created" on stdout repeats what we log ourselves; only
	# kubectl's errors (stderr) are worth keeping in the output.
	zk "$1" kubectl apply -f - >/dev/null <<<"${manifest}"
}

machine=$(uname -m)
case "${machine}" in
x86_64) ARCH=amd64 ;;
aarch64 | arm64) ARCH=arm64 ;;
*) die "unsupported architecture: ${machine}" ;;
esac

ensure_cilium() {
	command -v cilium >/dev/null 2>&1 && return 0
	local url tag
	log "downloading cilium CLI"
	# Explicit returns (this may run with errexit suppressed, as the left
	# side of ||) so a failed download fails the caller, not the suite.
	url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
		https://github.com/cilium/cilium-cli/releases/latest) || return 1
	tag=${url##*/}
	curl -fsSL -o "${WORK_DIR}/cilium.tar.gz" \
		"https://github.com/cilium/cilium-cli/releases/download/${tag}/cilium-linux-${ARCH}.tar.gz" || return 1
	tar -xzf "${WORK_DIR}/cilium.tar.gz" -C "${BIN_DIR}" || return 1
	rm -f "${WORK_DIR}/cilium.tar.gz"
}

# --- cilium <-> kubernetes version matching ---------------------------------
# cilium-cli carries no compatibility metadata: `cilium install
# --list-versions` is just chart versions, its default is simply the
# newest chart, and the chart's kubeVersion constraint is a floor
# (">= 1.21.0-0"), not a tested range. The only place cilium records
# which k8s versions it e2e-tests is the tag's
# Documentation/network/kubernetes/requirements.rst - a bullet list of
# "* 1.33" minors. So ask the cluster which k8s it runs, walk stable
# cilium releases newest-first and take the first that lists that minor.
# Stop early once the cluster's k8s is newer than a release's newest
# tested version (older releases only tested older k8s) and fall back to
# the newest release - the docs say k8s newer than the list "depends on
# the backward compatibility offered by Kubernetes". Any network failure
# falls back to empty = plain `cilium install` (the CLI's own default).

k8s_minor() { # cluster -> e.g. 37, empty when unknown
	local v
	# shellcheck disable=SC2310
	v=$(zk "$1" kubectl get --raw=/version 2>/dev/null) || v=""
	printf '%s\n' "${v}" | sed -nE 's/.*"gitVersion": *"v1\.([0-9]+)\..*/\1/p'
}

resolve_cilium_version() { # k8s-minor (maybe empty) -> vX.Y.Z or empty
	local minor="${1:-}" releases tag tag_minor tested_minors fallback newest_tested prev_minor=""
	local -a tested_list=()
	# One page of 100 reaches back for years (patch releases outnumber
	# minors by far); strict x.y.z keeps rc tags out; API order is
	# newest-first.
	releases=$(curl -fsSL --max-time 30 \
		'https://api.github.com/repos/cilium/cilium/releases?per_page=100' 2>/dev/null |
		sed -nE 's/.*"tag_name": *"v([0-9]+\.[0-9]+\.[0-9]+)".*/v\1/p') || releases=""
	[[ -n ${releases} ]] || return 0
	fallback=$(printf '%s\n' "${releases}" | head -1)
	[[ -n ${minor} ]] || {
		printf '%s\n' "${fallback}"
		return 0
	}
	while IFS= read -r tag; do
		[[ -n ${tag} ]] || continue
		tag_minor=${tag#v}
		tag_minor=${tag_minor%.*}
		# Every patch of a minor ships the same requirements doc -
		# fetch it once per minor, not once per patch tag.
		if [[ ${tag_minor} == "${prev_minor}" ]]; then
			continue
		fi
		prev_minor=${tag_minor}
		# The tested-minor bullets of that release's requirements.rst
		# (tags with a different doc layout parse empty and are skipped).
		tested_minors=$(curl -fsSL --max-time 30 \
			"https://raw.githubusercontent.com/cilium/cilium/${tag}/Documentation/network/kubernetes/requirements.rst" 2>/dev/null |
			sed -nE 's/^\* (1\.[0-9]+)$/\1/p') || tested_minors=""
		[[ -n ${tested_minors} ]] || continue
		mapfile -t tested_list <<<"${tested_minors}"
		case " ${tested_list[*]} " in
		*" 1.${minor} "*)
			printf '%s\n' "${tag}"
			return 0
			;;
		*) ;;
		esac
		# Cluster k8s newer than this release's newest tested version ->
		# no older release lists it either (the lists only move forward).
		newest_tested=$(printf '%s\n' "${tested_list[@]}" | sort -V | tail -1)
		if [[ -n ${newest_tested} ]] && ((10#${minor} > 10#${newest_tested#*.})); then
			break
		fi
	done <<<"${releases}"
	printf '%s\n' "${fallback}"
}

diag() {
	local c=$1 n list
	log "================ diagnostics for ${c} ================"
	./zek.sh --cluster "${c}" status || true
	./zek.sh --cluster "${c}" kubectl get pods -A -o wide || true
	# Scheduler inputs: together with a FailedScheduling event these settle
	# "Insufficient cpu" questions offline (allocatable vs requests).
	./zek.sh --cluster "${c}" kubectl get nodes -o \
		custom-columns='NODE:.metadata.name,CAP-CPU:.status.capacity.cpu,ALLOC-CPU:.status.allocatable.cpu' || true
	./zek.sh --cluster "${c}" kubectl get pods -A -o \
		custom-columns='NS:.metadata.namespace,POD:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,CPU-LIM:.spec.containers[*].resources.limits.cpu' || true
	./zek.sh --cluster "${c}" kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null |
		tail -50 || true
	# shellcheck disable=SC2310
	list=$(cluster_containers "${c}") || list=""
	while IFS= read -r n; do
		[[ -n ${n} ]] || continue
		log "----- last 30 log lines of ${n} -----"
		docker logs --tail 30 "${n}" 2>&1 | tail -30 || true
	done <<<"${list}"
	log "=============== end diagnostics for ${c} ================"
}

# Cluster lifecycle and failure diagnostics live in each job's own EXIT
# trap (job_exit below); the top-level trap only owns the scratch dir.
# Leaked clusters from a hard crash are swept by the stale-cluster pass
# at the start of the next run.
cleanup() {
	local st=$?
	trap - EXIT
	rm -rf "${WORK_DIR}"
	exit "${st}"
}
trap cleanup EXIT

# --- tests ------------------------------------------------------------------

test_multi_master() {
	local c=$1 i
	up "${c}" 1 3
	assert_cmd "${c}: node count" 4 node_count "${c}"
	assert_cmd "${c}: etcd members" 3 ns_pod_count "${c}" '^etcd-'
	for i in 1 2 3; do
		assert_cmd "${c}: apiserver on master-${i}" Running pod_phase "${c}" "kube-apiserver-${c}-master-${i}"
		assert_cmd "${c}: etcd on master-${i}" Running pod_phase "${c}" "etcd-${c}-master-${i}"
	done
	# shellcheck disable=SC2310
	container_running "${c}-lb" || fail "${c}: load balancer is not running"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"

	log "${c}: HA - stop master-3, the cluster must keep serving"
	docker stop "${c}-master-3" >/dev/null
	wait_for "${c}: API serves with master-3 stopped (etcd quorum)" 120 readyz_ok "${c}"
	start_containers "${c}-master-3"
	wait_for "${c}: apiserver on master-3 serving again" 300 master_readyz "${c}" 3
	wait_for "${c}: control plane readyz after restart" 120 readyz_ok "${c}"

	log "${c}: zek down + up restarts the HA cluster incl. the load balancer"
	zk "${c}" down
	assert_cmd "${c}: down stops everything" 0 running_count "${c}"
	zk "${c}" up
	wait_for "${c}: control plane readyz after down/up" 120 readyz_ok "${c}"
	assert_cmd "${c}: node count after down/up" 4 node_count "${c}"
	# shellcheck disable=SC2310
	container_running "${c}-lb" || fail "${c}: load balancer not running after down/up"
}

test_multi_worker() {
	local c=$1
	up "${c}" 2 1
	assert_cmd "${c}: node count" 3 node_count "${c}"
	assert_cmd "${c}: nodes NotReady but kubelets reporting" 3 ready_false_count "${c}"

	# hostNetwork pods need no CNI, so this DaemonSet proves kubelet +
	# containerd work on every node even before a CNI is installed.
	log "${c}: hostNetwork DaemonSet on all 3 nodes"
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
---
{
  apiVersion: "apps/v1",
  kind: "DaemonSet",
  metadata: {
    name: "e2e-hostcheck",
    namespace: "kube-system",
  },
  spec: {
    selector: {
      matchLabels: {
        app: "e2e-hostcheck",
      },
    },
    template: {
      metadata: {
        labels: {
          app: "e2e-hostcheck",
        },
      },
      spec: {
        hostNetwork: true,
        tolerations: [{
          operator: "Exists",
        }],
        containers: [{
          name: "check",
          image: "busybox:1.36",
          command: [
            "sleep",
            "3600",
          ],
        }],
      },
    },
  },
}
EOF
	zk "${c}" kubectl -n kube-system rollout status ds/e2e-hostcheck \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

test_flannel() {
	local c=$1
	up "${c}" 1 1
	assert_cmd "${c}: node count" 2 node_count "${c}"
	log "${c}: installing flannel"
	apply_flannel "${c}"
	wait_nodes_ready "${c}"
	wait_coredns "${c}"
	netcheck "${c}"
	svccheck "${c}"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

test_cilium() {
	local c=$1 kc ver minor out
	up "${c}" 1 1
	assert_cmd "${c}: node count" 2 node_count "${c}"
	kc=$(kubeconfig "${c}")
	# Resolve after `up`: the pick depends on the k8s the cluster
	# actually runs. An explicit CILIUM_VERSION wins over matching.
	ver=${CILIUM_VERSION}
	if [[ -z ${ver} ]]; then
		minor=$(k8s_minor "${c}")
		ver=$(resolve_cilium_version "${minor}")
	fi
	log "${c}: installing cilium ${ver:-<cli default>}"
	# Capture the CLI output: install prints progress and `status --wait`
	# redraws an ASCII logo via ANSI escapes - only failures are worth
	# putting in the log.
	local -a install_args=()
	[[ -n ${ver} ]] && install_args=(--version "${ver}")
	if ! out=$(KUBECONFIG="${kc}" cilium install "${install_args[@]}" 2>&1); then
		printf '%s\n' "${out}" >&2
		fail "${c}: cilium install failed"
	fi
	# Image pulls of the ~260MB cilium images can eat most of the CLI's
	# default 5m wait; use the same budget as every other kubectl wait.
	# --interactive=false keeps the captured failure output readable.
	if ! out=$(KUBECONFIG="${kc}" cilium status --wait --interactive=false \
		--wait-duration="${ZEK_E2E_TIMEOUT}s" 2>&1); then
		printf '%s\n' "${out}" >&2
		fail "${c}: cilium not ready"
	fi
	wait_nodes_ready "${c}"
	wait_coredns "${c}"
	netcheck "${c}"
	svccheck "${c}"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

test_persistence() {
	local c=$1 uids web
	up "${c}" 1 1
	log "${c}: installing flannel + workload"
	apply_flannel "${c}"
	wait_nodes_ready "${c}"
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
---
{
  apiVersion: "apps/v1",
  kind: "Deployment",
  metadata: {
    name: "web",
  },
  spec: {
    replicas: 1,
    selector: {
      matchLabels: {
        app: "web",
      },
    },
    template: {
      metadata: {
        labels: {
          app: "web",
        },
      },
      spec: {
        containers: [{
          name: "web",
          image: "busybox:1.36",
          command: [
            "sleep",
            "3600",
          ],
        }],
      },
    },
  },
}
EOF
	zk "${c}" kubectl rollout status deploy/web --timeout="${ZEK_E2E_TIMEOUT}s"
	uids=$(node_uids "${c}")
	web=$(web_info "${c}")
	[[ -n ${web} ]] || fail "${c}: web pod not found"

	assert_state() { # what
		# recovery first (the API may be down right after a restart),
		# then the identity checks that must not change
		wait_for "${c}: readyz after $1" 300 readyz_ok "${c}"
		wait_nodes_ready "${c}"
		zk "${c}" kubectl rollout status deploy/web --timeout="${ZEK_E2E_TIMEOUT}s"
		assert_cmd "${c}: node UIDs after ${1}" "${uids}" node_uids "${c}"
		assert_cmd "${c}: web pod after ${1}" "${web}" web_info "${c}"
	}

	log "${c}: docker stop + start every node at once"
	local -a names=()
	local list
	# shellcheck disable=SC2310
	list=$(cluster_containers "${c}") || fail "${c}: cannot list containers"
	if [[ -n ${list} ]]; then
		mapfile -t names <<<"${list}"
	fi
	# Sanity check before the mass stop: `up 1 1` must really have
	# created the master + worker pair this test is about.
	[[ ${#names[@]} -ge 2 ]] || fail "${c}: expected >=2 containers, got ${#names[@]}"
	docker stop "${names[@]}" >/dev/null
	assert_cmd "${c}: all containers stopped" 0 running_count "${c}"
	# Start in dependency-safe order (lb, masters, workers) like zek's
	# own restart: workers use dynamic IPs, so a worker starting first
	# can claim a stopped master's static address and leave the master
	# failing with "Address already in use".
	local role n
	local -a wave=()
	for role in lb master worker; do
		wave=()
		for n in "${names[@]}"; do
			if [[ ${n} == *-"${role}" || ${n} == *-"${role}"-[0-9]* ]]; then
				wave+=("${n}")
			fi
		done
		if [[ ${#wave[@]} -gt 0 ]]; then
			start_containers "${wave[@]}"
		fi
	done
	assert_state "full stop/start"

	log "${c}: docker stop + start a single worker"
	docker stop "${c}-worker-1" >/dev/null
	wait_for "${c}: worker-1 reports NotReady" 300 node_status_is "${c}" \
		"${c}-worker-1" False
	start_containers "${c}-worker-1"
	wait_for "${c}: worker-1 back to Ready" "${ZEK_E2E_TIMEOUT}" node_status_is "${c}" \
		"${c}-worker-1" True
	assert_state "worker restart"

	log "${c}: docker restart the master"
	docker restart "${c}-master-1" >/dev/null
	assert_state "master restart"

	log "${c}: zek down + zek up"
	zk "${c}" down
	assert_cmd "${c}: down stops everything" 0 running_count "${c}"
	# The stop ran each container's cleanup trap; the log line is the only
	# host-visible proof (sysctl/module restore is best-effort and shared
	# with parallel jobs).
	docker logs "${c}-master-1" 2>&1 | grep -q "shutting down" ||
		fail "${c}: master-1 never logged its cleanup"
	zk "${c}" up
	assert_state "zek down/up"

	log "${c}: kubelet crash on worker-1 - the supervisor restarts it"
	docker exec "${c}-worker-1" pgrep -x kubelet >/dev/null 2>&1 ||
		fail "${c}: kubelet not running before the crash"
	docker exec "${c}-worker-1" pkill -x kubelet
	wait_for "${c}: kubelet running again" 60 kubelet_running "${c}-worker-1"
	wait_for "${c}: supervisor logged the restart" 60 supervisor_restarted "${c}-worker-1"
	wait_nodes_ready "${c}"
	wait_for "${c}: control plane readyz after kubelet crash" 120 readyz_ok "${c}"

	log "${c}: kubelet config without failSwapOn - the supervisor re-adds it"
	docker exec "${c}-worker-1" sed -i '/^failSwapOn:/d' /var/lib/kubelet/config.yaml
	docker exec "${c}-worker-1" pkill -x kubelet
	wait_for "${c}: kubelet running again after config edit" 60 kubelet_running "${c}-worker-1"
	wait_for "${c}: failSwapOn restored" 60 kubelet_failswapon "${c}-worker-1"
	wait_nodes_ready "${c}"
}

test_single_node() {
	local c=$1
	# The smallest cluster: one master, zero workers.
	up "${c}" 0 1
	assert_cmd "${c}: node count" 1 node_count "${c}"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

# The zek.sh surface no other test reaches: kubectl exec's `--`, flag
# forms and env precedence, the loud error paths, the up spellings, the
# --timeout bound, clean's docker wiring, and a destroy that is asserted
# instead of merely invoked (the per-job destroy swallows its exit).
test_smoke() {
	local c=$1 before after out
	up "${c}" 1 1
	# status: lists the node containers and the cluster nodes; merge
	# stderr so a failing status lands in the FAIL line instead of
	# being lost in the shared output (the entrypoint logs to stderr).
	# shellcheck disable=SC2310
	out=$(zk "${c}" status 2>&1) || fail "${c}: status failed: ${out}"
	[[ ${out} == *"${c}-master-1"* ]] || fail "${c}: status misses ${c}-master-1"
	# logs follows the container (-f), so bound it; the entrypoint's own
	# [zek] lines must come through. timeout execs a binary (zk is a
	# shell function) and its group kill is what actually stops
	# docker logs -f. The entrypoint logs to stderr, so merge both
	# streams into the capture.
	out=$(timeout 5 ./zek.sh --cluster "${c}" logs "${c}-master-1" 2>&1 || true)
	[[ ${out} == *"[zek]"* ]] || fail "${c}: logs gave no [zek] output"

	# kubectl exec needs the `--` delimiter to survive zek and the
	# entrypoint; netcheck only proves that inside the CNI tests, so
	# guard it here too. A hostNetwork pod needs no CNI in this test.
	log "${c}: kubectl exec -- on a hostNetwork pod"
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
---
{
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: "e2e-exec",
  },
  spec: {
    nodeSelector: {
      kubernetes.io/hostname: "${c}-master-1",
    },
    hostNetwork: true,
    tolerations: [{
      operator: "Exists",
    }],
    restartPolicy: "Never",
    containers: [{
      name: "app",
      image: "busybox:1.36",
      command: [
        "sleep",
        "600",
      ],
    }],
  },
}
EOF
	zk "${c}" kubectl wait --for=condition=Ready pod/e2e-exec \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	# shellcheck disable=SC2310
	out=$(zk "${c}" kubectl exec e2e-exec -- echo exec-ok 2>&1) ||
		fail "${c}: kubectl exec -- failed: ${out}"
	[[ ${out} == exec-ok ]] ||
		fail "${c}: exec output: want 'exec-ok', got '${out}'"
	zk "${c}" kubectl delete pod/e2e-exec --wait=false >/dev/null

	# Every value flag parses - both spellings - on a command that
	# touches nothing (status only reads docker/kubectl).
	out=$(./zek.sh --cluster "${c}" --timeout=600 --image "${ZEK_IMAGE}" \
		--subnet 172.20.254.0/24 --master-ip 172.20.254.2 --dns 1.1.1.1 \
		--pod-cidr 10.245.0.0/16 --mounts "${WORK_DIR}:/e2e-mount" \
		status 2>&1) || fail "${c}: flag parse failed: ${out}"
	[[ ${out} == *"${c}-master-1"* ]] ||
		fail "${c}: status misses ${c}-master-1 after flag parse"
	# Flag beats env - the precedence every flag shares - and the env
	# twin alone is honored when no flag is given.
	if ! out=$(env ZEK_CLUSTER=e2e-nope ./zek.sh --cluster "${c}" status 2>&1); then
		fail "${c}: --cluster must beat ZEK_CLUSTER: ${out}"
	fi
	[[ ${out} == *"${c}-master-1"* ]] ||
		fail "${c}: --cluster won over ZEK_CLUSTER but ran: ${out}"

	# --subnet/--master-ip must really shape the network and the master,
	# not just parse: a throwaway cluster is created with explicit values
	# and inspected before it is destroyed again.
	log "${c}: --subnet/--master-ip reach the network and the master"
	local sub=172.20.250.0/24 mip=172.20.250.2 got_sub got_ip
	./zek.sh --cluster e2e-fn --subnet "${sub}" --master-ip "${mip}" \
		--workers 0 --masters 1 up
	got_sub=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' e2e-fn-net)
	got_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' e2e-fn-master-1)
	./zek.sh --cluster e2e-fn destroy >/dev/null 2>&1 || true
	assert_eq "${c}: --subnet reached the network" "${sub}" "${got_sub}"
	assert_eq "${c}: --master-ip reached the master" "${mip}" "${got_ip}"

	# Loud error paths; none of these may touch the cluster.
	assert_die "${c}: --cluster without a value" "--cluster needs a cluster name" \
		./zek.sh --cluster
	assert_die "${c}: short flags are gone" "usage:" ./zek.sh -c "${c}" status
	assert_die "${c}: invalid mount" "invalid mount" \
		./zek.sh --mounts bad status
	assert_die "${c}: empty --image" "--image needs a value" \
		./zek.sh --image= status
	assert_die "${c}: invalid --timeout" "invalid timeout" \
		./zek.sh --timeout abc status
	assert_die "${c}: invalid cluster name" "invalid cluster name" \
		./zek.sh --cluster "bad name" status
	assert_die "${c}: invalid ZEK_NODES" "invalid ZEK_NODES" \
		env ZEK_NODES=abc ./zek.sh status
	assert_die "${c}: invalid ZEK_MASTERS" "invalid ZEK_MASTERS" \
		env ZEK_MASTERS=0 ./zek.sh status
	assert_die "${c}: ZEK_CLUSTER selects the cluster" \
		"no cluster named e2e-nope" env ZEK_CLUSTER=e2e-nope ./zek.sh status
	assert_die "${c}: clean refuses a control-plane node" "cannot clean" \
		./zek.sh --cluster "${c}" clean "${c}-master-1"

	# The remaining loud promises: missing flag values, non-numeric
	# sizes, clean's name checks and the usage paths. None of these may
	# touch the cluster.
	assert_die "${c}: --timeout without a value" "needs a number of seconds" \
		./zek.sh --timeout
	for f in --subnet --master-ip --dns --pod-cidr --mounts; do
		assert_die "${c}: ${f} without a value" "needs a value" ./zek.sh "${f}"
	done
	assert_die "${c}: --workers non-numeric" "--workers must be a number" \
		zk "${c}" up --workers abc
	assert_die "${c}: --masters non-numeric" "--masters must be a number >= 1" \
		zk "${c}" up --masters abc
	assert_die "${c}: clean rejects an unknown name" "is not a worker of cluster" \
		./zek.sh --cluster "${c}" clean not-a-node
	assert_die "${c}: clean rejects a missing container" "no container named" \
		./zek.sh --cluster "${c}" clean "${c}-worker-99"
	assert_die "${c}: clean without a name" "usage:" \
		./zek.sh --cluster "${c}" clean
	assert_die "${c}: logs without a name" "usage:" \
		./zek.sh --cluster "${c}" logs
	assert_die "${c}: up with an unknown argument" "usage:" \
		zk "${c}" up foo

	# The entrypoint's own flag surface (PR#4): every value flag must
	# die without a value, every flag must parse on the kubectl role,
	# --kubeconfig must work, `--` must forward and no args must drop
	# into an interactive shell.
	log "${c}: entrypoint flag surface"
	for f in --cluster-dir --node-name --pod-cidr --node-dns --api-endpoint \
		--join-token --join-ca-hash --join-api-endpoint --join-cert-key \
		--lb-backends --kubeconfig; do
		assert_die "${c}: entrypoint ${f} without a value" "needs a value" \
			docker exec "${c}-master-1" /entrypoint.sh kubectl "${f}"
	done
	assert_die "${c}: entrypoint rejects an unknown role" "usage:" \
		docker exec "${c}-master-1" /entrypoint.sh bogus
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl \
		--pod-cidr 10.246.0.0/16 --node-name recovery-ignore \
		--node-dns 1.1.1.1 --api-endpoint 127.0.0.1:6443 \
		--master-join --join-token t --join-ca-hash h \
		--join-api-endpoint 127.0.0.1:6443 --join-cert-key k \
		--lb-backends "1.2.3.4 5.6.7.8" --no-host-modules \
		get nodes 2>&1) ||
		fail "${c}: entrypoint flag twins did not parse: ${out}"
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl \
		--kubeconfig /etc/cluster/admin.conf get nodes 2>&1) ||
		fail "${c}: entrypoint --kubeconfig failed: ${out}"
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl -- get nodes 2>&1) ||
		fail "${c}: entrypoint -- forwarding failed: ${out}"
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl </dev/null 2>&1) ||
		fail "${c}: entrypoint kubectl with no args failed: ${out}"

	# Every up spelling: --flag=value, the ZEK_NODES/ZEK_MASTERS
	# defaults, and the bare-number shorthand - which must warn and leave
	# the fixed topology alone (still 1 master + 1 worker, no containers
	# added).
	# shellcheck disable=SC2310
	out=$(zk "${c}" up --workers=1 --masters=1 2>&1) ||
		fail "${c}: up --flag=value failed: ${out}"
	out=$(env ZEK_NODES=1 ZEK_MASTERS=1 ./zek.sh --cluster "${c}" up 2>&1) ||
		fail "${c}: up with ZEK_NODES/ZEK_MASTERS failed: ${out}"
	# shellcheck disable=SC2310
	out=$(zk "${c}" up 2 2>&1) ||
		fail "${c}: up <n> shorthand failed: ${out}"
	[[ ${out} == *"topology is fixed"* ]] ||
		fail "${c}: up 2 must warn that the topology is fixed: ${out}"
	assert_cmd "${c}: node count after up 2" 2 node_count "${c}"
	assert_cmd "${c}: containers after up 2" 2 running_count "${c}"

	# --timeout must kill a doomed up fast instead of hanging (the
	# README's fail-fast claim), and a plain up must recover after.
	log "${c}: --timeout 1 dies on a downed cluster instead of hanging"
	zk "${c}" down
	assert_cmd "${c}: down stops everything" 0 running_count "${c}"
	# shellcheck disable=SC2310
	out=$(zk "${c}" status 2>&1) || fail "${c}: status on a stopped cluster failed: ${out}"
	[[ ${out} == *"is stopped"* ]] ||
		fail "${c}: status on a stopped cluster: ${out}"
	# shellcheck disable=SC2310
	out=$(zk "${c}" down 2>&1) || fail "${c}: second down failed: ${out}"
	[[ ${out} == *"is not running"* ]] ||
		fail "${c}: second down: ${out}"
	if out=$(./zek.sh --cluster "${c}" --timeout 1 up 2>&1); then
		fail "${c}: 'up --timeout 1' should have died: ${out}"
	fi
	[[ ${out} == *"API not reachable after 1s"* ]] ||
		fail "${c}: wrong error from the doomed up: ${out}"
	# The doomed attempt started the containers before dying; a plain up
	# (600s budget) finishes what --timeout 1 interrupted.
	zk "${c}" up
	wait_for "${c}: control plane readyz after timeout" 120 readyz_ok "${c}"
	assert_cmd "${c}: node count after timeout recovery" 2 node_count "${c}"

	# clean: evict + recreate the worker with a pristine netns; it rejoins
	# with a fresh kubelet identity (new Node UID). No CNI is installed,
	# so the new node comes back NotReady like every node before a CNI -
	# "rejoined" means registered again, not Ready. The flags ride along
	# because they are the ones that reach docker run for the new
	# container - assert the wiring, not just the exit status.
	before=$(node_uids "${c}")
	log "${c}: clean ${c}-worker-1 with --image/--dns/--pod-cidr/--mounts"
	# shellcheck disable=SC2310
	out=$(zk "${c}" --image "${ZEK_IMAGE}" --dns 1.1.1.1 \
		--pod-cidr 10.245.0.0/16 --mounts "${WORK_DIR}:/e2e-mount" \
		clean "${c}-worker-1" 2>&1) || fail "${c}: clean failed: ${out}"
	wait_for "${c}: worker-1 re-registered after clean" "${ZEK_E2E_TIMEOUT}" \
		node_count_is "${c}" 2
	assert_cmd "${c}: --image on the recreated worker" "${ZEK_IMAGE}" \
		docker inspect -f '{{.Config.Image}}' "${c}-worker-1"
	assert_cmd "${c}: --dns on the recreated worker" '["1.1.1.1"]' \
		docker inspect -f '{{json .HostConfig.DNS}}' "${c}-worker-1"
	assert_cmd "${c}: POD_CIDR env on the recreated worker" "10.245.0.0/16" \
		docker exec "${c}-worker-1" printenv POD_CIDR
	assert_cmd "${c}: --mounts on the recreated worker" "ok" \
		docker inspect \
		-f '{{range .Mounts}}{{if eq .Destination "/e2e-mount"}}ok{{end}}{{end}}' \
		"${c}-worker-1"
	after=$(node_uids "${c}")
	[[ ${before} != "${after}" ]] || fail "${c}: node UIDs unchanged after clean"
	wait_for "${c}: control plane readyz after clean" 120 readyz_ok "${c}"

	# destroy: containers and network must really be gone - the pass-path
	# destroy in job_exit hides its exit status, so assert it here.
	log "${c}: destroy removes the containers and the network"
	out=$(./zek.sh --cluster "${c}" destroy 2>&1) ||
		fail "${c}: destroy failed: ${out}"
	assert_cmd "${c}: containers after destroy" "" cluster_containers "${c}"
	if docker network inspect "${c}-net" >/dev/null 2>&1; then
		fail "${c}: network ${c}-net survived destroy"
	fi
	out=$(./zek.sh --cluster "${c}" destroy 2>&1) ||
		fail "${c}: second destroy failed: ${out}"
	[[ ${out} == *"no cluster named"* ]] ||
		fail "${c}: second destroy: ${out}"
}

test_recovery() {
	local c=$1 token ca_hash endpoint bg out
	up "${c}" 1 1

	# A node started with NO_HOST_MODULES=1 must still join: the host
	# already has the modules (every other node loaded them), so the
	# preflight skip changes nothing observable - what matters is that
	# the flag path runs cleanly end to end.
	log "${c}: NO_HOST_MODULES=1 node joins and leaves cleanly"
	token=$(docker exec "${c}-master-1" cat /etc/cluster/token)
	ca_hash=$(docker exec "${c}-master-1" cat /etc/cluster/ca-hash)
	endpoint=$(docker exec "${c}-master-1" cat /etc/cluster/api-endpoint)
	# Clone the existing worker's host config (network, volumes, tmpfs,
	# privileged, cgroupns, ...) so the test tracks zek.sh's NODE_ARGS
	# instead of duplicating them; only env and restart are overridden.
	node_clone_args "${c}-worker-1"
	docker run -d --name "${c}-worker-nhm" --hostname "${c}-worker-nhm" \
		--restart=no "${CLONE_ARGS[@]}" \
		-e NO_HOST_MODULES=1 \
		-e "JOIN_TOKEN=${token}" -e "JOIN_CA_HASH=${ca_hash}" \
		-e "JOIN_API_ENDPOINT=${endpoint}" \
		"${ZEK_IMAGE}" worker >/dev/null
	wait_for "${c}: NO_HOST_MODULES node registered" "${ZEK_E2E_TIMEOUT}" \
		node_count_is "${c}" 3
	docker exec "${c}-worker-nhm" pgrep -x kubelet >/dev/null 2>&1 ||
		fail "${c}: NO_HOST_MODULES node has no kubelet"
	docker rm -f "${c}-worker-nhm" >/dev/null
	zk "${c}" kubectl delete node "${c}-worker-nhm" --wait=false >/dev/null
	wait_for "${c}: NO_HOST_MODULES node removed" "${ZEK_E2E_TIMEOUT}" \
		node_count_is "${c}" 2

	# Interrupted worker join: kubelet.conf gone, certs left behind.
	# The entrypoint must reset and rejoin.
	log "${c}: interrupted worker join recovers"
	docker exec "${c}-worker-1" rm -f /etc/kubernetes/kubelet.conf
	docker restart "${c}-worker-1" >/dev/null
	wait_for "${c}: interrupted join detected" 60 log_has "${c}-worker-1" \
		"interrupted join detected; resetting partial state"
	wait_for "${c}: worker-1 kubelet running again" 60 kubelet_running "${c}-worker-1"
	wait_for "${c}: control plane readyz after worker rejoin" 120 readyz_ok "${c}"
	assert_cmd "${c}: both nodes still registered" 2 node_count "${c}"

	# Lost credentials: admin.conf deleted, master restarted. The resume
	# path must republish the whole set.
	log "${c}: credential republish after losing admin.conf"
	docker exec "${c}-master-1" rm -f /etc/cluster/admin.conf
	docker restart "${c}-master-1" >/dev/null
	wait_for "${c}: republishing detected" 60 log_has "${c}-master-1" \
		"published credentials incomplete; republishing"
	wait_for "${c}: credentials republished" 120 creds_published "${c}"
	wait_for "${c}: control plane readyz after republish" 120 readyz_ok "${c}"

	# run_kubectl waits for a missing admin.conf instead of dying. The
	# timeout bounds the worst case: the restore lands after 3s, so a
	# successful wait finishes in seconds and a failed restore fails
	# here instead of hanging for run_kubectl's full 600s.
	log "${c}: kubectl waits for the cluster config to appear"
	docker exec "${c}-master-1" rm -f /etc/cluster/admin.conf
	(
		sleep 3
		docker exec "${c}-master-1" cp /etc/kubernetes/admin.conf /etc/cluster/admin.conf
	) &
	bg=$!
	out=$(timeout 30 docker exec "${c}-master-1" /entrypoint.sh kubectl get nodes 2>&1) ||
		fail "${c}: kubectl did not wait for the config: ${out}"
	wait "${bg}" 2>/dev/null || true
	assert_cmd "${c}: nodes listed after the wait" 2 node_count "${c}"

	# Interrupted control-plane init: kubelet.conf present, completion
	# markers gone. The entrypoint must wipe and re-init. With ctr hidden
	# the image import must warn and skip (the images are already in the
	# store from the first init).
	log "${c}: interrupted control-plane init recovers (ctr hidden)"
	docker exec "${c}-master-1" sh -c 'mv "$(command -v ctr)" /ctr.hidden'
	docker exec "${c}-master-1" rm -f /etc/cluster/init-complete \
		/etc/cluster/admin.conf /etc/cluster/token
	docker restart "${c}-master-1" >/dev/null
	wait_for "${c}: interrupted init detected" 60 log_has "${c}-master-1" \
		"interrupted control-plane init detected; resetting partial state"
	wait_for "${c}: ctr-missing warning" 60 log_has "${c}-master-1" \
		"ctr not installed; skipping kubeadm image preload"
	wait_for "${c}: credentials republished after re-init" 180 creds_published "${c}"
	wait_for "${c}: control plane readyz after re-init" 300 readyz_ok "${c}"
	# The re-init wiped etcd: the worker's Node object is gone and its
	# certs are stale - clean it so it rejoins the new cluster.
	wait_for "${c}: only the master registered" 60 node_count_is "${c}" 1
	zk "${c}" clean "${c}-worker-1"
	wait_for "${c}: worker rejoined after re-init" "${ZEK_E2E_TIMEOUT}" \
		node_count_is "${c}" 2
	wait_for "${c}: control plane readyz after worker rejoin" 120 readyz_ok "${c}"

	# Interrupted control-plane setup: certs written, kubelet.conf not.
	# Same wipe-and-reinit, different branch.
	log "${c}: interrupted control-plane setup recovers"
	docker exec "${c}-master-1" rm -f /etc/kubernetes/kubelet.conf
	docker restart "${c}-master-1" >/dev/null
	wait_for "${c}: interrupted setup detected" 60 log_has "${c}-master-1" \
		"interrupted control-plane setup detected; resetting partial state"
	wait_for "${c}: credentials republished after second re-init" 180 creds_published "${c}"
	wait_for "${c}: control plane readyz after second re-init" 300 readyz_ok "${c}"
	wait_for "${c}: only the master registered" 60 node_count_is "${c}" 1
	zk "${c}" clean "${c}-worker-1"
	wait_for "${c}: worker rejoined after second re-init" "${ZEK_E2E_TIMEOUT}" \
		node_count_is "${c}" 2
	wait_for "${c}: control plane readyz after final rejoin" 120 readyz_ok "${c}"
}

# --- parallel runner --------------------------------------------------------
# Every test runs in a background subshell with its own EXIT trap, so
# ZEK_E2E_JOBS tests can run at once: cluster lifecycle, failure
# diagnostics and the result file are private to the job. JOB_* are
# deliberately not `local` - the EXIT trap reads them after run_test's
# body has finished.

job_exit() {
	local st=$?
	trap - EXIT
	if ((st == 0)); then
		printf 'passed\n' >"${WORK_DIR}/result.${JOB_TEST}"
		destroy "${JOB_CLUSTER}"
		log "======== test ${JOB_TEST}: PASSED ========"
	else
		printf 'failed\n' >"${WORK_DIR}/result.${JOB_TEST}"
		log "======== test ${JOB_TEST}: FAILED ========"
		# Buffer diagnostics per test: parallel failures would interleave
		# into an unreadable mix; the parent prints them serially. A
		# broken cluster can make parts of diag fail - never block the
		# cleanup below on it.
		# shellcheck disable=SC2310
		diag "${JOB_CLUSTER}" >"${WORK_DIR}/diag.${JOB_TEST}" 2>&1 || true
		if [[ ${ZEK_E2E_KEEP_ON_FAIL:-0} == 1 ]]; then
			log "keeping ${JOB_CLUSTER} running (ZEK_E2E_KEEP_ON_FAIL=1)"
		else
			destroy "${JOB_CLUSTER}"
		fi
	fi
	exit "${st}"
}

run_test() { # test [subnet]
	JOB_TEST=$1
	JOB_CLUSTER="e2e-${JOB_TEST}"
	if [[ -n ${2:-} ]]; then
		# Pre-assigned by the parent: pick_subnet inside zek.sh scans
		# live networks and would race between parallel `up` calls.
		ZEK_SUBNET=$2
		export ZEK_SUBNET
	fi
	trap job_exit EXIT
	log "======== test ${JOB_TEST} (cluster ${JOB_CLUSTER}) ========"
	"test_${JOB_TEST//-/_}" "${JOB_CLUSTER}"
}

# One free 172.20.X.0/24 per test, allocated before any cluster exists.
# pick_subnet (zek.sh) sees the same free candidates from every parallel
# `up`, so without this the second docker network create fails with an
# address-space overlap error.
alloc_subnets() { # want -> fills subnets
	local want=$1 used="" net subnet i candidate
	for net in $(docker network ls -q); do
		for subnet in $(docker network inspect \
			-f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${net}"); do
			used="${used} ${subnet}"
		done
	done
	subnets=()
	for i in $(seq 0 254); do
		candidate="172.20.${i}.0/24"
		case " ${used} " in
		*" ${candidate} "*) ;;
		*)
			subnets+=("${candidate}")
			if [[ ${#subnets[@]} -ge ${want} ]]; then
				return 0
			fi
			;;
		esac
	done
	die "not enough free 172.20.X.0/24 subnets for ${want} parallel tests"
}

# --- runner -----------------------------------------------------------------
# Drop leftovers of earlier runs first: `up` would otherwise restart a stale
# cluster (topology fixed at creation) instead of creating a fresh one.
stale=$(docker ps -a --format '{{.Names}}' |
	sed -E 's/-(master|worker)-[0-9]+$//; s/-lb$//' |
	grep -E '^e2e-' | sort -u || true)
if [[ -n ${stale} ]]; then
	while IFS= read -r c; do
		[[ -n ${c} ]] || continue
		log "removing leftover cluster ${c}"
		destroy "${c}"
	done <<<"${stale}"
fi

[[ ${ZEK_E2E_JOBS} =~ ^[1-9][0-9]*$ ]] ||
	die "ZEK_E2E_JOBS must be an integer >= 1 (got '${ZEK_E2E_JOBS}')"

# Resolve tool downloads once up front: parallel jobs must not race the
# extraction into the shared BIN_DIR. A failed download must not abort the
# suite before it starts - the affected test fails on the missing binary
# and every other test still runs.
case " ${requested[*]} " in
*" cilium "*)
	# errexit is off as the left side of ||; ensure_cilium returns 1
	# explicitly on every download step instead.
	# shellcheck disable=SC2310
	ensure_cilium ||
		printf '\n[e2e] WARNING: cilium CLI download failed; the cilium test will fail\n' >&2
	;;
*) ;;
esac

subnets=()
if [[ ${ZEK_E2E_JOBS} -gt 1 ]]; then
	alloc_subnets "${#requested[@]}"
fi

# Job pool: launch, then reap one job whenever the pool is full.
# A failure never aborts the pool - results are collected at the end.
running=0 idx=0
for t in "${requested[@]}"; do
	while ((running >= ZEK_E2E_JOBS)); do
		wait -n 2>/dev/null || true
		running=$((running - 1))
	done
	if [[ -n ${subnets[idx]:-} ]]; then
		run_test "${t}" "${subnets[idx]}" &
	else
		run_test "${t}" &
	fi
	idx=$((idx + 1))
	running=$((running + 1))
done
while ((running > 0)); do
	wait -n 2>/dev/null || true
	running=$((running - 1))
done

# Diagnostics first (in test order), then the verdict: every requested
# test ran, so report all failures, not just the first one.
failed=()
for t in "${requested[@]}"; do
	if [[ -f ${WORK_DIR}/diag.${t} ]]; then
		log "----- diagnostics for failed test ${t} -----"
		cat "${WORK_DIR}/diag.${t}"
		log "----- end diagnostics for ${t} -----"
	fi
	result=""
	if [[ -f ${WORK_DIR}/result.${t} ]]; then
		result=$(cat "${WORK_DIR}/result.${t}")
	fi
	[[ ${result} == passed ]] || failed+=("${t}")
done
if [[ ${#failed[@]} -gt 0 ]]; then
	die "failed tests: ${failed[*]}"
fi

log "all tests passed: ${requested[*]}"
