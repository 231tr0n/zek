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
#                  members, quorum survives docker stop/start of a master
#   multi-worker   1 master + 2 workers: every node's kubelet/containerd
#                  work (hostNetwork DaemonSet lands on all 3 nodes)
#   flannel        install flannel, nodes go Ready, coredns rolls out,
#                  cross-node pod-to-pod ping
#   cilium         same with cilium (cilium CLI downloaded on demand,
#                  version matched to the cluster's k8s release)
#   smoke          status, logs and clean: the info commands produce
#                  output, and evict+recreate of a worker (fresh netns)
#                  rejoins with a new node identity
#   persistence    flannel + a workload, then recovery from: docker
#                  stop/start of every node at once, a stopped worker, a
#                  restarted master and `zek down`/`up` - same nodes
#                  (UIDs), workload Ready again after each cycle
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

ALL_TESTS=(single-node multi-master multi-worker flannel cilium smoke persistence)

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
	die "usage: $0 [--image img] [--timeout s] [--e2e-timeout s] [--e2e-tests list] [--e2e-jobs n] [--e2e-keep-on-fail] [--cilium-version v] [single-node|multi-master|multi-worker|flannel|cilium|smoke|persistence]..."
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
apiVersion: v1
kind: Pod
metadata:
  name: net-a
spec:
  nodeSelector:
    kubernetes.io/hostname: ${c}-worker-1
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.36
    command: [sleep, "600"]
EOF
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: net-b
spec:
  nodeSelector:
    kubernetes.io/hostname: ${c}-master-1
  tolerations:
  - operator: Exists
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.36
    command: [sleep, "600"]
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
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: e2e-hostcheck
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: e2e-hostcheck
  template:
    metadata:
      labels:
        app: e2e-hostcheck
    spec:
      hostNetwork: true
      tolerations:
      - operator: Exists
      containers:
      - name: check
        image: busybox:1.36
        command: [sleep, "3600"]
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
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

test_persistence() {
	local c=$1 uids web
	up "${c}" 1 1
	log "${c}: installing flannel + workload"
	apply_flannel "${c}"
	wait_nodes_ready "${c}"
	zk "${c}" kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: busybox:1.36
        command: [sleep, "3600"]
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
	zk "${c}" up
	assert_state "zek down/up"
}

test_single_node() {
	local c=$1
	# The smallest cluster: one master, zero workers.
	up "${c}" 0 1
	assert_cmd "${c}: node count" 1 node_count "${c}"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

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
	# clean: evict + recreate the worker with a pristine netns; it rejoins
	# with a fresh kubelet identity (new Node UID). No CNI is installed,
	# so the new node comes back NotReady like every node before a CNI -
	# "rejoined" means registered again, not Ready.
	before=$(node_uids "${c}")
	log "${c}: clean ${c}-worker-1 (evict + pristine netns)"
	zk "${c}" clean "${c}-worker-1"
	wait_for "${c}: worker-1 re-registered after clean" "${ZEK_E2E_TIMEOUT}" \
		node_count_is "${c}" 2
	after=$(node_uids "${c}")
	[[ ${before} != "${after}" ]] || fail "${c}: node UIDs unchanged after clean"
	wait_for "${c}: control plane readyz after clean" 120 readyz_ok "${c}"
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
