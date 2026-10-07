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
#   single-node    1 master, 0 workers: the smallest cluster still works,
#                  kubeadm's null kube-proxy conntrack limits were
#                  rewritten to numbers (patch_kube_proxy, both maxPerCore
#                  and min), node internals (containerd native/unpack,
#                  CNI dirs, bpffs, cgroupns/cgroup-driver, resolv,
#                  credentials), the preloaded kubeadm images are
#                  actually in the containerd store (import ran on first
#                  init), and the image HEALTHCHECK reads the local
#                  daemons: healthy at rest (while NotReady without a
#                  CNI), unhealthy when containerd dies (docker keeps
#                  the container running) and healthy again after the
#                  restart, while a kubelet kill is healed by the
#                  supervisor inside the probe window so the verdict
#                  stays healthy
#   multi-master   3 masters + 1 worker: HA init/join behind the LB, all
#                  control-plane static pods (apiserver, etcd, scheduler,
#                  controller-manager) Running on every master, apiserver
#                  logs and a port-forward streaming through the LB, the
#                  LB container's HEALTHCHECK (haproxy stats page) turns
#                  healthy, 3 etcd members with one backend line each,
#                  quorum survives one stopped master and breaks on two,
#                  an interrupted join on a second master recovers
#                  without republishing credentials, the LB is reused
#                  after a failed create, and `zek down`/`up` restarts
#                  the HA cluster incl. the LB
#   multi-worker   1 master + 2 workers: every node's kubelet/containerd
#                  work (hostNetwork DaemonSet lands on all 3 nodes), the
#                  inotify instance quota was raised for big clusters, each
#                  node's InternalIP is its docker IP on the cluster
#                  network, and no pressure conditions are raised
#   flannel        install flannel, nodes go Ready, coredns rolls out,
#                  cross-node pod-to-pod ping, ClusterIP service routing,
#                  cluster DNS and external DNS forwarding
#   cilium         same with cilium (cilium CLI downloaded on demand,
#                  version matched to the cluster's k8s release)
#   smoke          the zek.sh surface: status (healthy/starting/-
#                  here, unhealthy in single-node, plus the unreachable
#                  control plane), logs, kubectl exec (the `--` delimiter
#                  and stdin with -i), every flag in both spellings + env
#                  precedence + loud error paths (host/network/gateway/
#                  broadcast/outside IPs, subnet reuse, size bounds, trailing
#                  args, e2e selection incl. ZEK_TIMEOUT, entrypoint flags
#                  incl. node `--` and the kubectl wait timeout),
#                  --subnet/--master-ip/--pod-cidr functional, up
#                  shorthand vs fixed topology (workers and masters),
#                  --timeout failing fast, clean recreating the worker
#                  (new Node UID) with --image/--dns/--pod-cidr/--mounts,
#                  and destroy removing the containers and network
#   persistence    flannel + a workload pinned to the single worker, then
#                  recovery from: docker stop/start of every node at once,
#                  a stopped worker, a restarted master, `zek down`/`up`,
#                  a kubelet crash (supervisor restart) and a missing or
#                  wrong failSwapOn key - same nodes (UIDs), workload Ready
#                  and coredns rolled out again after each cycle
#   recovery       crash-recovery paths: a NO_HOST_MODULES node, an
#                  interrupted worker join, lost master credentials (the
#                  republish), a kubectl wait for the config, and two
#                  interrupted control-plane inits (each wipes and
#                  re-inits; an interrupted control-plane join is covered
#                  in multi-master)
#
# Tests run in parallel: ZEK_E2E_JOBS tests at a time (each owns its own
# cluster, subnet and scratch files). Failures never abort the pool - all
# requested tests run, then diagnostics and the verdict are printed.
# ZEK_E2E_JOBS/ZEK_E2E_TIMEOUT/ZEK_TIMEOUT are validated before the
# stale-cluster sweep runs, so a bad value dies without destroying
# anything.
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
#                            as the args; cannot be combined with positional
#                            test names)
#   --e2e-jobs N             tests to run in parallel (ZEK_E2E_JOBS,
#                            default 2; 1 = serial)
#   --e2e-keep-on-fail       leave the failed cluster running for debugging
#                            (ZEK_E2E_KEEP_ON_FAIL=1; bare or =1)
#   --cilium-version VER     cilium version to install (ZEK_CILIUM_VERSION;
#                            default: match the cluster's k8s version
#                            against cilium's tested list, else newest
#                            stable release)
#
# Env: the env twin of every flag above - ZEK_IMAGE, ZEK_TIMEOUT,
#      ZEK_E2E_TIMEOUT, ZEK_E2E_TESTS, ZEK_E2E_JOBS, ZEK_E2E_KEEP_ON_FAIL,
#      ZEK_CILIUM_VERSION.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ALL_TESTS=(single-node multi-master multi-worker flannel cilium smoke persistence recovery)

export ZEK_IMAGE="${ZEK_IMAGE:-zek:latest}"
export ZEK_TIMEOUT="${ZEK_TIMEOUT:-600}"
ZEK_E2E_TIMEOUT="${ZEK_E2E_TIMEOUT:-1200}"
ZEK_E2E_JOBS="${ZEK_E2E_JOBS:-2}"
# Optional override; when empty the cilium test resolves a release that
# matches the cluster's k8s version (resolve_cilium_version below).
ZEK_CILIUM_VERSION="${ZEK_CILIUM_VERSION:-}"
# Bound for the node-Ready polls (nodes_ready_quick): long enough to ride
# out a readiness flip, short enough that wait_for's 2s retries re-check.
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
e2e_tests_set=0
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
			e2e_tests_set=1
			shift 2
			;;
		--e2e-tests=*)
			ZEK_E2E_TESTS="${1#*=}"
			e2e_tests_set=1
			shift
			;;
		--e2e-jobs)
			[[ $# -ge 2 ]] || die "--e2e-jobs needs a value"
			ZEK_E2E_JOBS="$2"
			shift 2
			;;
		--e2e-jobs=*) ZEK_E2E_JOBS="${1#*=}" && shift ;;
		--cilium-version)
			[[ $# -ge 2 ]] || die "--cilium-version needs a value"
			ZEK_CILIUM_VERSION="$2"
			shift 2
			;;
		--cilium-version=*) ZEK_CILIUM_VERSION="${1#*=}" && shift ;;
		--e2e-keep-on-fail | --e2e-keep-on-fail=1)
			ZEK_E2E_KEEP_ON_FAIL=1
			shift
			;;
		--e2e-keep-on-fail=*) die "--e2e-keep-on-fail is a boolean; use --e2e-keep-on-fail (or --e2e-keep-on-fail=1)" ;;
		*)
			requested+=("$1")
			shift
			;;
	esac
done
# An explicit --e2e-tests (flag or env) with positional tests is
# ambiguous (which one wins?); an empty one would silently run the whole
# suite instead of the requested list. Die before anything runs.
if [[ ${e2e_tests_set} -eq 1 ]]; then
	[[ -n ${ZEK_E2E_TESTS} ]] || die "--e2e-tests needs a non-empty value"
	[[ ${#requested[@]} -eq 0 ]] \
		|| die "--e2e-tests and positional test names are mutually exclusive"
elif [[ -n ${ZEK_E2E_TESTS+x} ]]; then
	# Set-but-empty would silently run the whole suite below; die like the
	# flag form. Unset runs all tests.
	[[ -n ${ZEK_E2E_TESTS} ]] || die "ZEK_E2E_TESTS needs a non-empty value"
	[[ ${#requested[@]} -eq 0 ]] \
		|| die "ZEK_E2E_TESTS and positional test names are mutually exclusive"
fi
# Numeric bounds before anything with side effects: the stale-cluster
# sweep destroys clusters, and the scratch dir (below) needs the EXIT
# trap armed first, so a bad value must die here - not after the sweep.
[[ ${ZEK_E2E_JOBS} =~ ^[1-9][0-9]*$ ]] \
	|| die "ZEK_E2E_JOBS must be an integer >= 1 (got '${ZEK_E2E_JOBS}')"
[[ ${ZEK_E2E_TIMEOUT} =~ ^[1-9][0-9]*$ ]] \
	|| die "ZEK_E2E_TIMEOUT must be an integer >= 1 (got '${ZEK_E2E_TIMEOUT}')"
[[ ${ZEK_TIMEOUT} =~ ^[1-9][0-9]*$ ]] \
	|| die "ZEK_TIMEOUT must be an integer >= 1 (got '${ZEK_TIMEOUT}')"
[[ -n ${ZEK_IMAGE} ]] || die "--image needs a value (check --image/ZEK_IMAGE)"
if [[ ${#requested[@]} -eq 0 ]]; then
	if [[ -n ${ZEK_E2E_TESTS:-} ]]; then
		IFS=',' read -ra requested <<< "${ZEK_E2E_TESTS}"
	else
		requested=("${ALL_TESTS[@]}")
	fi
fi
# Validate names and reject duplicates: two jobs with the same test would
# fight over one cluster name, subnet and containers.
declare -A seen_tests=()
for test_name in "${requested[@]}"; do
	case " ${ALL_TESTS[*]} " in
		*" ${test_name} "*) ;;
		*) usage ;;
	esac
	[[ -z ${seen_tests[${test_name}]:-} ]] || die "test '${test_name}' requested twice"
	seen_tests[${test_name}]=1
done

docker image inspect "${ZEK_IMAGE}" > /dev/null 2>&1 \
	|| die "image ${ZEK_IMAGE} not found (run: make build)"

# --- scratch space for downloaded CLIs and kubeconfigs ----------------------
WORK_DIR=$(mktemp -d)
BIN_DIR="${WORK_DIR}/bin"
mkdir -p "${BIN_DIR}"
PATH="${BIN_DIR}:${PATH}"
export PATH

# Arm the scratch-dir trap before anything else can die: cluster
# lifecycle and failure diagnostics live in each job's own EXIT trap
# (job_exit below); the top-level trap only owns the scratch dir.
# Leaked clusters from a hard crash are swept by the stale-cluster pass
# at the start of the next run.
cleanup() {
	local st=$?
	trap - EXIT
	rm -rf "${WORK_DIR}"
	exit "${st}"
}
trap cleanup EXIT

# --- helpers ----------------------------------------------------------------
# zk <cluster> <args...> - ./zek.sh pinned to a cluster.
zk() { ./zek.sh --cluster "$1" "${@:2}"; }

up() { # cluster workers masters
	zk "$1" up --workers "$2" --masters "$3"
}

# || true: the sweep and the per-job cleanup call this for clusters that
# may not exist; a genuinely failed destroy leaves containers for the next
# sweep to report. The smoke test asserts a real destroy separately.
destroy() { ./zek.sh --cluster "$1" destroy > /dev/null 2>&1 || true; }

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
	[[ ${got} == *"${want}"* ]] \
		|| fail "${desc}: want an error mentioning '${want}', got: ${got}"
}

wait_for() { # desc timeout-secs func args...
	local desc=$1 timeout=$2 deadline
	shift 2
	deadline=$((SECONDS + timeout))
	until "$@" > /dev/null 2>&1; do
		[[ ${SECONDS} -lt ${deadline} ]] || fail "timed out after ${timeout}s waiting for: ${desc}"
		# Readiness flips land within seconds, so 2s is enough (a 5s gap
		# used to add dead time to every wait in the suite).
		sleep 2
	done
	log "ok: ${desc}"
}

readyz_ok() { zk "$1" kubectl get --raw='/readyz' 2> /dev/null | grep -qx ok; }

nodes_ready_quick() {
	zk "$1" kubectl wait --for=condition=Ready node --all \
		--timeout="${READY_POLL}s" > /dev/null 2>&1
}

wait_nodes_ready() {
	wait_for "all nodes Ready on $1" "${ZEK_E2E_TIMEOUT}" nodes_ready_quick "$1"
}

node_status_is() { # cluster node want(True|False)
	local got
	# First of the many disabled warnings in this file: these predicates
	# call zk/kubectl inside $( ), where errexit does not propagate, and
	# the tool flags every such call as a possibly-hidden failure.
	# Each site is handled explicitly (|| return 1, or the caller's
	# wait_for/assert_eq decides), so the directive is intentional here
	# and repeated per site the same way.
	# shellcheck disable=SC2310
	got=$(zk "$1" kubectl get node "$2" \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null) || return 1
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
		-o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
		| grep -c False || true
}

# Kubelet's pressure alarms (Memory/Disk/PID) are False on every node.
# An empty or partially-reported condition set - kubelet still starting
# up, API still settling - does not count, so wait_for polls this.
pressure_clear() {
	local got line
	# shellcheck disable=SC2310
	got=$(zk "$1" kubectl get nodes \
		-o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="MemoryPressure")].status} {.status.conditions[?(@.type=="DiskPressure")].status} {.status.conditions[?(@.type=="PIDPressure")].status}{"\n"}{end}' \
		2> /dev/null) || return 1
	# One line per node, each exactly "False False False"; an empty
	# capture reads as a single empty line and fails the match.
	while IFS= read -r line; do
		[[ ${line} == "False False False" ]] || return 1
	done <<< "${got}"
}

# A DaemonSet is fully rolled out: every scheduled pod reports Ready.
# desiredNumberScheduled is 0 only while the DS object is still settling,
# so a zero never counts as ready.
ds_ready() { # cluster ds-name
	local want ready
	# shellcheck disable=SC2310
	want=$(zk "$1" kubectl -n kube-system get ds "$2" \
		-o jsonpath='{.status.desiredNumberScheduled}' 2> /dev/null) || return 1
	# shellcheck disable=SC2310
	ready=$(zk "$1" kubectl -n kube-system get ds "$2" \
		-o jsonpath='{.status.numberReady}' 2> /dev/null) || return 1
	[[ -n ${want} && ${want} != 0 && ${ready} == "${want}" ]]
}

# The detached kubectl port-forward started by test_multi_master is
# answering: wget through it must return the pod's page (the forward
# runs inside the given container, so the fetch happens there too).
pf_serves() { # container
	docker exec "$1" wget -qO- --timeout=10 http://127.0.0.1:8090/ \
		2> /dev/null | grep -q pf-ok
}

# podCIDR of smoke's throwaway e2e-fn master: the controller-manager
# stamps spec.podCIDR onto the node seconds after it registers, so this
# is polled (wait_for) instead of read once. e2e-fn's name is fixed by
# test_smoke.
fn_pod_cidr() {
	docker exec e2e-fn-master-1 env KUBECONFIG=/etc/kubernetes/admin.conf \
		kubectl get node e2e-fn-master-1 -o jsonpath='{.spec.podCIDR}' \
		2> /dev/null
}
# fn_pod_cidr_is assumes a /16 cluster CIDR (the allocator hands out
# /24 node slices; e2e-fn always uses a /16).
fn_pod_cidr_is() { # want-cluster-cidr
	local got
	got=$(fn_pod_cidr)
	# spec.podCIDR is the node's own slice carved out of the cluster
	# CIDR, never the flag value verbatim: the allocator hands out the
	# lowest free block (/24 for the default IPv4 node mask), and
	# e2e-fn's single node is the first, so it gets "$1"'s first /24.
	[[ ${got} == "${1%.*}.0/24" ]]
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
	phase=$(zk "$1" kubectl get pod svc-test -o jsonpath='{.status.phase}' 2> /dev/null) \
		|| return 1
	[[ ${phase} == Succeeded || ${phase} == Failed ]]
}

container_running() {
	local state
	state=$(docker inspect -f '{{.State.Running}}' "$1" 2> /dev/null) || state=false
	[[ ${state} == true ]]
}

# The image's HEALTHCHECK verdict (docker ps cannot format .State.Health).
# Assigned before the comparison: the file's pattern for a failed probe -
# an empty capture simply compares false and wait_for retries.
docker_health() { # container -> healthy|unhealthy|starting|empty
	docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2> /dev/null
}

healthy_is() { # container
	local got
	got=$(docker_health "$1")
	[[ ${got} == healthy ]]
}

unhealthy_is() { # container
	local got
	got=$(docker_health "$1")
	[[ ${got} == unhealthy ]]
}

# containerd is no longer running inside the container (pkill sends the
# signal; this waits for the process to actually be gone before a restart
# would race the dying one for the socket).
containerd_gone() { # container
	! docker exec "$1" pgrep -x containerd > /dev/null 2>&1
}

# The container stopped (any exit code); polling avoids racing its setup.
# A permanently missing container never satisfies this (inspect fails),
# so it only fits containers known to exist.
container_exited() { # container
	local state
	state=$(docker inspect -f '{{.State.Running}}' "$1" 2> /dev/null) || return 1
	[[ ${state} == false ]]
}

# A node container's resolv.conf carries the given nameserver line.
nodns_applied() { # container ip
	docker exec "$1" grep -q "^nameserver $2$" /etc/resolv.conf 2> /dev/null
}

# Is the apiserver inside a master container serving? (no CNI needed)
master_readyz() { # cluster master-index
	docker exec "${1}-master-${2}" curl -skf https://127.0.0.1:6443/readyz 2> /dev/null \
		| grep -qx ok
}

# Is the kubelet process alive inside the node container? Command line,
# not comm: gcompat runs the glibc kubelet through musl's loader, so comm
# reads ld-musl-x86_64. and a comm match never finds it (matching that
# loader name would instead hit every glibc binary: kubectl, kubeadm, ...).
kubelet_running() { # container
	docker exec "$1" pgrep -f "/usr/local/bin/kubelet" > /dev/null 2>&1
}

# The kubelet config carries failSwapOn: false - the supervisor rewrites
# a wrong value and appends the key when kubeadm's file lacks it, right
# before every kubelet start (ensure_kubelet_config).
kubelet_failswapon() { # container
	docker exec "$1" grep -q '^failSwapOn:[[:space:]]*false' /var/lib/kubelet/config.yaml
}

# Container log contains a fixed string (our [zek] markers). grep -c
# reads the whole log: `grep -q` exits at the match, and under pipefail a
# still-streaming docker logs then dies with a spurious SIGPIPE 141 that
# fails the check even though the marker was there.
log_has() { # container text
	docker logs "$1" 2>&1 | grep -cF "$2" > /dev/null
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
	local container=$1 priv cgroupns net bind tmp dns
	priv=$(docker inspect -f '{{.HostConfig.Privileged}}' "${container}")
	[[ ${priv} == true ]] && CLONE_ARGS+=(--privileged)
	cgroupns=$(docker inspect -f '{{.HostConfig.CgroupnsMode}}' "${container}")
	[[ -n ${cgroupns} ]] && CLONE_ARGS+=(--cgroupns "${cgroupns}")
	net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "${container}")
	CLONE_ARGS+=(--network "${net}")
	for bind in $(docker inspect -f '{{range .HostConfig.Binds}}{{.}} {{end}}' "${container}"); do
		CLONE_ARGS+=(-v "${bind}")
	done
	for tmp in $(docker inspect -f '{{range $k, $v := .HostConfig.Tmpfs}}{{$k}} {{end}}' "${container}"); do
		CLONE_ARGS+=(--tmpfs "${tmp}")
	done
	for dns in $(docker inspect -f '{{range .HostConfig.DNS}}{{.}} {{end}}' "${container}"); do
		CLONE_ARGS+=(--dns "${dns}")
	done
}

web_info() {
	zk "$1" kubectl -n default get pod -l app=web \
		-o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}@{.spec.nodeName}{"\n"}{end}'
}

kubeconfig() { # cluster -> prints path to its admin.conf
	local out="${WORK_DIR}/kubeconfig-$1.conf"
	docker exec "$1-master-1" cat /etc/kubernetes/admin.conf > "${out}" \
		|| die "cannot read admin.conf from $1-master-1"
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
	zk "${c}" kubectl apply -f - > /dev/null << EOF
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
	zk "${c}" kubectl apply -f - > /dev/null << EOF
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
	zk "${c}" kubectl exec net-a -- ping -c 3 "${ip_b}" > /dev/null \
		|| fail "${c}: cross-node ping net-a -> net-b failed"
	log "ping ${ip_b} -> ${ip_a}"
	# shellcheck disable=SC2310
	zk "${c}" kubectl exec net-b -- ping -c 3 "${ip_a}" > /dev/null \
		|| fail "${c}: cross-node ping net-b -> net-a failed"
	zk "${c}" kubectl delete pod net-a net-b --wait=false > /dev/null
}

# Service + cluster DNS: kube-proxy's ClusterIP path in front of a pod,
# and coredns (rolled out before this runs) answering for both the
# service name and kubernetes.default.svc.cluster.local - 10.96.0.1,
# the first IP of kubeadm's default service subnet (the entrypoint only
# overrides podSubnet). The test pod resolves e2e-svc through coredns
# and reaches svc-a through the ClusterIP, so a pass needs DNS +
# kube-proxy + the overlay datapath together. The final lookup of a
# public name proves coredns's upstream forwarding: it fails if the
# node's resolv.conf points at the docker stub 127.0.0.11 (the bug
# ensure_resolv_conf removes) or the forwarders are broken in any other
# way.
svccheck() {
	local c=$1 out
	zk "${c}" kubectl apply -f - > /dev/null << EOF
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
	zk "${c}" kubectl apply -f - > /dev/null << EOF
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
	# The retry loops ride out endpoint-sync lag and slow upstream DNS;
	# 15 x (fast failure + 2s) bounds each dead end at ~75s instead of
	# the full e2e budget. The in-cluster lookup uses the FQDN: busybox
	# nslookup does not expand the pod's search list for a 1-dot name
	# (it behaves as if ndots were 1, so kubernetes.default is sent
	# literally and always NXDOMAINs). Short names with the search list
	# are covered by the wget above, which resolves through getaddrinfo
	# like real clients do. A marker line names a failed external lookup:
	# the retry loop makes the pod exit 0 either way, the assertions on
	# the log decide.
	zk "${c}" kubectl apply -f - > /dev/null << EOF
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
        "i=0; until wget -qO- http://e2e-svc/; do i=\$((i+1)); [ \$i -ge 15 ] && exit 1; sleep 2; done; nslookup kubernetes.default.svc.cluster.local; i=0; until nslookup kubernetes.io; do i=\$((i+1)); [ \$i -ge 15 ] && echo external-dns-failed && break; sleep 2; done",
      ],
    }],
  },
}
EOF
	wait_for "${c}: service test pod finished" 120 svc_test_done "${c}"
	# shellcheck disable=SC2310
	out=$(zk "${c}" kubectl logs svc-test 2> /dev/null) || out=""
	[[ ${out} == *pong* ]] \
		|| fail "${c}: ClusterIP service did not serve pong: ${out}"
	# Only a successful answer prints an Address line for 10.96.0.1;
	# the resolver's own header "Address: 10.96.0.10:53" shares the
	# prefix, hence the [^0-9] guard.
	[[ ${out} =~ Address:[[:space:]]+10\.96\.0\.1[^0-9] ]] \
		|| fail "${c}: kubernetes.default did not resolve through CoreDNS: ${out}"
	[[ ${out} != *external-dns-failed* ]] \
		|| fail "${c}: external DNS (kubernetes.io) failed through CoreDNS: ${out}"
	zk "${c}" kubectl delete pod svc-a svc-test --wait=false > /dev/null
	zk "${c}" kubectl delete service e2e-svc --wait=false > /dev/null
}

apply_flannel() {
	local manifest
	manifest=$(curl -fsSL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml) \
		|| die "flannel manifest download failed"
	# "configured/created" on stdout repeats what we log ourselves; only
	# kubectl's errors (stderr) are worth keeping in the output.
	zk "$1" kubectl apply -f - > /dev/null <<< "${manifest}"
}

machine_arch=$(uname -m)
case "${machine_arch}" in
	x86_64) ARCH=amd64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	*) die "unsupported architecture: ${machine_arch}" ;;
esac

ensure_cilium() {
	command -v cilium > /dev/null 2>&1 && return 0
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
	local version_json
	# shellcheck disable=SC2310
	version_json=$(zk "$1" kubectl get --raw=/version 2> /dev/null) || version_json=""
	printf '%s\n' "${version_json}" | jq -r 'if .gitVersion then (.gitVersion | split(".")[1]) else empty end' 2> /dev/null
}

resolve_cilium_version() { # k8s-minor (maybe empty) -> vX.Y.Z or empty
	local minor="${1:-}" releases tag tag_minor tested_minors fallback newest_tested prev_minor=""
	local -a tested_list=()
	# One page of 100 reaches back for years (patch releases outnumber
	# minors by far); strict x.y.z keeps rc tags out; API order is
	# newest-first.
	releases=$(curl -fsSL --max-time 30 \
		'https://api.github.com/repos/cilium/cilium/releases?per_page=100' 2> /dev/null \
		| jq -r '.[] | .tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' 2> /dev/null) || releases=""
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
			"https://raw.githubusercontent.com/cilium/cilium/${tag}/Documentation/network/kubernetes/requirements.rst" 2> /dev/null \
			| sed -nE 's/^\* (1\.[0-9]+)$/\1/p') || tested_minors=""
		[[ -n ${tested_minors} ]] || continue
		mapfile -t tested_list <<< "${tested_minors}"
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
	done <<< "${releases}"
	printf '%s\n' "${fallback}"
}

diag() {
	local c=$1 container list
	log "================ diagnostics for ${c} ================"
	./zek.sh --cluster "${c}" status || true
	./zek.sh --cluster "${c}" kubectl get pods -A -o wide || true
	# Scheduler inputs: together with a FailedScheduling event these settle
	# "Insufficient cpu" questions offline (allocatable vs requests).
	./zek.sh --cluster "${c}" kubectl get nodes -o \
		custom-columns='NODE:.metadata.name,CAP-CPU:.status.capacity.cpu,ALLOC-CPU:.status.allocatable.cpu' || true
	./zek.sh --cluster "${c}" kubectl get pods -A -o \
		custom-columns='NS:.metadata.namespace,POD:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,CPU-LIM:.spec.containers[*].resources.limits.cpu' || true
	./zek.sh --cluster "${c}" kubectl get events -A --sort-by=.lastTimestamp 2> /dev/null \
		| tail -50 || true
	# shellcheck disable=SC2310
	list=$(cluster_containers "${c}") || list=""
	while IFS= read -r container; do
		[[ -n ${container} ]] || continue
		log "----- last 30 log lines of ${container} -----"
		docker logs --tail 30 "${container}" 2>&1 | tail -30 || true
	done <<< "${list}"
	log "=============== end diagnostics for ${c} ================"
}

# --- tests ------------------------------------------------------------------

test_multi_master() {
	local c=$1 i out lb_ip
	up "${c}" 1 3
	assert_cmd "${c}: node count" 4 node_count "${c}"
	assert_cmd "${c}: etcd members" 3 ns_pod_count "${c}" '^etcd-'
	for i in 1 2 3; do
		assert_cmd "${c}: apiserver on master-${i}" Running pod_phase "${c}" "kube-apiserver-${c}-master-${i}"
		assert_cmd "${c}: etcd on master-${i}" Running pod_phase "${c}" "etcd-${c}-master-${i}"
	done
	# shellcheck disable=SC2310
	container_running "${c}-lb" || fail "${c}: load balancer is not running"
	# The lb branch of the image HEALTHCHECK: haproxy's stats page.
	wait_for "${c}: load balancer healthy" 120 healthy_is "${c}-lb"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
	# The other control-plane static pods, once the API serves: kubeadm
	# starts them (leader-elected) on every control-plane node.
	for i in 1 2 3; do
		assert_cmd "${c}: scheduler on master-${i}" Running pod_phase "${c}" "kube-scheduler-${c}-master-${i}"
		assert_cmd "${c}: controller-manager on master-${i}" Running pod_phase "${c}" "kube-controller-manager-${c}-master-${i}"
	done
	# kubectl's server is the LB (control-plane-endpoint), so this streams
	# through it: kubectl -> LB -> apiserver -> master kubelet -> log file.
	log "${c}: apiserver logs stream through the load balancer"
	# shellcheck disable=SC2310
	out=$(zk "${c}" kubectl logs --tail=5 -n kube-system \
		"kube-apiserver-${c}-master-1" 2>&1) \
		|| fail "${c}: kubectl logs through the LB failed: ${out}"
	[[ -n ${out} ]] || fail "${c}: apiserver logs through the LB were empty"

	# A long-lived stream through the same LB path: port-forward's SPDY
	# upgrade rides haproxy, and a gap with no traffic at all must not
	# kill the connection (the config's 7-day client/server idle window
	# exists exactly for these streams - an idle cut below the gap here
	# is a regression). The pod is hostNetwork (this test installs no
	# CNI) with an Exists toleration so it can land on any node,
	# NotReady included.
	log "${c}: port-forward streams through the load balancer"
	zk "${c}" kubectl apply -f - > /dev/null << EOF
---
{
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: "e2e-pf",
  },
  spec: {
    hostNetwork: true,
    tolerations: [{
      operator: "Exists",
    }],
    restartPolicy: "Never",
    containers: [{
      name: "web",
      image: "busybox:1.36",
      command: [
        "sh",
        "-c",
        "mkdir -p /www && echo pf-ok > /www/index.html && exec httpd -f -p 80 -h /www",
      ],
    }],
  },
}
EOF
	zk "${c}" kubectl wait --for=condition=Ready pod/e2e-pf \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	# kubectl runs inside the master container: bind the forward to all
	# interfaces there and fetch it with a docker exec wget from the same
	# container (-d keeps the forward alive detached; it is polled, so
	# startup latency does not matter).
	docker exec -d "${c}-master-1" env KUBECONFIG=/etc/kubernetes/admin.conf \
		kubectl port-forward --address 0.0.0.0 pod/e2e-pf 8090:80
	wait_for "${c}: port-forward serves through the LB" 60 \
		pf_serves "${c}-master-1"
	# Idle through the LB: the forward and its haproxy connection sit
	# open with zero traffic, then must answer on the same connection.
	sleep 8
	wait_for "${c}: port-forward survives an 8s idle gap" 60 \
		pf_serves "${c}-master-1"
	docker exec "${c}-master-1" pkill -f "port-forward" 2> /dev/null || true
	zk "${c}" kubectl delete pod e2e-pf --wait=false > /dev/null

	# 3 etcd members: stopping one leaves 2 of 3 - a quorum, so the API
	# keeps serving; a second stop would not.
	log "${c}: HA - stop master-3, the cluster must keep serving"
	docker stop "${c}-master-3" > /dev/null
	wait_for "${c}: API serves with master-3 stopped (etcd quorum)" 120 readyz_ok "${c}"
	start_containers "${c}-master-3"
	wait_for "${c}: apiserver on master-3 serving again" 300 master_readyz "${c}" 3
	wait_for "${c}: control plane readyz after restart" 120 readyz_ok "${c}"

	# Losing 2 of 3 breaks quorum: readyz must stop answering (proving
	# the single-stop survival above was quorum, not luck), then both
	# masters rejoin and the cluster serves again.
	log "${c}: HA - stop master-2 and master-3, quorum must break"
	docker stop "${c}-master-2" "${c}-master-3" > /dev/null
	sleep 30
	# shellcheck disable=SC2310
	if zk "${c}" kubectl get --raw='/readyz' 2> /dev/null | grep -qx ok; then
		fail "${c}: API still readyz without etcd quorum"
	fi
	start_containers "${c}-master-2" "${c}-master-3"
	wait_for "${c}: apiserver on master-2 serving again" 300 master_readyz "${c}" 2
	wait_for "${c}: apiserver on master-3 serving again" 300 master_readyz "${c}" 3
	wait_for "${c}: control plane readyz after quorum restore" 120 readyz_ok "${c}"

	log "${c}: zek down + up restarts the HA cluster incl. the load balancer"
	zk "${c}" down
	assert_cmd "${c}: down stops everything" 0 running_count "${c}"
	zk "${c}" up
	wait_for "${c}: control plane readyz after down/up" 120 readyz_ok "${c}"
	assert_cmd "${c}: node count after down/up" 4 node_count "${c}"
	# shellcheck disable=SC2310
	container_running "${c}-lb" || fail "${c}: load balancer not running after down/up"
	# The LB config carries the long-lived stream timeouts port-forward
	# needs; assert them on the live file, not just via the stream above.
	docker exec "${c}-lb" grep -q "timeout client 604800s" /etc/haproxy/haproxy.cfg \
		|| fail "${c}: haproxy.cfg misses the 7-day client timeout"
	docker exec "${c}-lb" grep -q "option tcp-check" /etc/haproxy/haproxy.cfg \
		|| fail "${c}: haproxy.cfg misses option tcp-check"
	# One backend server line per master, on 6443 with health checks.
	assert_cmd "${c}: haproxy backend servers" 3 \
		docker exec "${c}-lb" sh -c 'grep -cE "^[[:space:]]*server cp[0-9]+ " /etc/haproxy/haproxy.cfg'

	# Interrupted control-plane join on a second master: kubelet.conf
	# gone, certs left behind. The same reset as an interrupted init must
	# wipe and re-join (the container keeps its JOIN_* env across restarts).
	log "${c}: interrupted control-plane join on master-2 recovers"
	docker exec "${c}-master-2" rm -f /etc/kubernetes/kubelet.conf
	docker restart "${c}-master-2" > /dev/null
	wait_for "${c}: interrupted join detected on master-2" 60 log_has "${c}-master-2" \
		"interrupted control-plane setup detected; resetting partial state"
	wait_for "${c}: apiserver on master-2 serving again" 300 master_readyz "${c}" 2
	wait_for "${c}: control plane readyz after join recovery" 120 readyz_ok "${c}"
	assert_cmd "${c}: node count after join recovery" 4 node_count "${c}"
	# A joining master must never rotate the published credentials on
	# resume: nothing of the set may exist on its layer, and its logs
	# must not show a republish.
	docker exec "${c}-master-2" test ! -f /etc/cluster/token \
		|| fail "${c}: join-master published credentials it must not rotate"
	# shellcheck disable=SC2310
	if log_has "${c}-master-2" "republishing"; then
		fail "${c}: join-master republished credentials on resume"
	fi

	# LB reuse after a failed create: with the nodes gone but the network
	# and LB left behind, the next up must reuse the LB instead of failing
	# on a duplicate container or subnet.
	log "${c}: LB reused after a failed create"
	lb_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${c}-lb")
	docker rm -f "${c}-master-1" "${c}-master-2" "${c}-master-3" "${c}-worker-1" > /dev/null
	# shellcheck disable=SC2310
	out=$(zk "${c}" up --workers 1 --masters 3 2>&1) || fail "${c}: up after failed create failed: ${out}"
	[[ ${out} == *"reusing ${c}-lb"* ]] \
		|| fail "${c}: up did not reuse the load balancer: ${out}"
	assert_cmd "${c}: LB kept its IP after reuse" "${lb_ip}" \
		docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${c}-lb"
	wait_for "${c}: control plane readyz after LB reuse" 120 readyz_ok "${c}"
	assert_cmd "${c}: node count after LB reuse" 4 node_count "${c}"
}

test_multi_worker() {
	local c=$1 inotify_limit
	up "${c}" 2 1
	assert_cmd "${c}: node count" 3 node_count "${c}"
	assert_cmd "${c}: nodes NotReady but kubelets reporting" 3 ready_false_count "${c}"

	# entrypoint.sh raises the host-wide per-uid inotify instance quota
	# (default 128) to >=1024 before starting the kubelet; without it big
	# clusters run out of watch instances. The quota is a host kernel
	# setting, so any node container can read it.
	inotify_limit=$(docker exec "${c}-master-1" \
		cat /proc/sys/fs/inotify/max_user_instances)
	[[ ${inotify_limit} =~ ^[0-9]+$ && ${inotify_limit} -ge 1024 ]] \
		|| fail "${c}: inotify max_user_instances is '${inotify_limit}', want >= 1024"

	# hostNetwork pods need no CNI, so this DaemonSet proves kubelet +
	# containerd work on every node even before a CNI is installed.
	log "${c}: hostNetwork DaemonSet on all 3 nodes"
	zk "${c}" kubectl apply -f - > /dev/null << EOF
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

	# Kubelet raises Memory/Disk/PID Pressure when a node runs out of
	# memory, disk or PIDs; every condition must be False (kubelet starts
	# reporting them within its first status updates, so poll).
	wait_for "${c}: no pressure conditions on any node" 120 pressure_clear "${c}"

	# Node InternalIP = the container's address on the cluster network
	# (node_ip picks the node netns's first global IPv4): kube-proxy,
	# NodePort routing and every CNI key off it.
	local node want_ip nodes
	nodes=$(zk "${c}" kubectl get nodes -o name)
	while read -r node; do
		[[ -n ${node} ]] || continue
		node=${node#node/}
		want_ip=$(docker inspect -f \
			'{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${node}")
		assert_cmd "${c}: InternalIP of ${node}" "${want_ip}" \
			zk "${c}" kubectl get node "${node}" \
			-o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
	done <<< "${nodes}"

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
	local c=$1 kubeconfig_path ver minor out
	up "${c}" 1 1
	assert_cmd "${c}: node count" 2 node_count "${c}"
	kubeconfig_path=$(kubeconfig "${c}")
	# Resolve after `up`: the pick depends on the k8s the cluster
	# actually runs. An explicit ZEK_CILIUM_VERSION wins over matching.
	ver=${ZEK_CILIUM_VERSION}
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
	if ! out=$(KUBECONFIG="${kubeconfig_path}" cilium install "${install_args[@]}" 2>&1); then
		printf '%s\n' "${out}" >&2
		fail "${c}: cilium install failed"
	fi
	# Image pulls of the ~260MB cilium images can eat most of the CLI's
	# default 5m wait; use the same budget as every other kubectl wait.
	# --interactive=false keeps the captured failure output readable.
	if ! out=$(KUBECONFIG="${kubeconfig_path}" cilium status --wait --interactive=false \
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

# Host reboot/shutdown is covered by design + proxy: all state lives on
# the containers' writable layer (no volumes), RestartPolicy is
# unless-stopped (asserted in single-node), so a reboot is equivalent to
# `docker stop all` + daemon restart - exactly what the full stop/start
# and `zek down`/`up` cycles below exercise. No test reboots the host
# (it would kill the parallel jobs).
test_persistence() {
	local c=$1 uids web
	up "${c}" 1 1
	log "${c}: installing flannel + workload"
	apply_flannel "${c}"
	wait_nodes_ready "${c}"
	zk "${c}" kubectl apply -f - > /dev/null << EOF
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
	# The deployment has no toleration, so with a control-plane taint in
	# place the only eligible node is the worker; landing elsewhere means
	# the taint is gone (a regression every later step would hide).
	[[ ${web} == *"@${c}-worker-1" ]] \
		|| fail "${c}: web pod must sit on the worker, got '${web}'"

	assert_state() { # what
		# recovery first (the API may be down right after a restart),
		# then the identity checks that must not change
		wait_for "${c}: readyz after $1" 300 readyz_ok "${c}"
		wait_nodes_ready "${c}"
		# coredns must be rolled out again too: the workload only needs
		# the overlay, but a restart that breaks cluster DNS would pass
		# every check below.
		wait_coredns "${c}"
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
		mapfile -t names <<< "${list}"
	fi
	# Sanity check before the mass stop: `up 1 1` must really have
	# created the master + worker pair this test is about.
	[[ ${#names[@]} -ge 2 ]] || fail "${c}: expected >=2 containers, got ${#names[@]}"
	docker stop "${names[@]}" > /dev/null
	assert_cmd "${c}: all containers stopped" 0 running_count "${c}"
	# Start in dependency-safe order (lb, masters, workers) like zek's
	# own restart: workers use dynamic IPs, so a worker starting first
	# can claim a stopped master's static address and leave the master
	# failing with "Address already in use".
	local role candidate
	local -a wave=()
	for role in lb master worker; do
		wave=()
		for candidate in "${names[@]}"; do
			if [[ ${candidate} == *-"${role}" || ${candidate} == *-"${role}"-[0-9]* ]]; then
				wave+=("${candidate}")
			fi
		done
		if [[ ${#wave[@]} -gt 0 ]]; then
			start_containers "${wave[@]}"
		fi
	done
	assert_state "full stop/start"

	log "${c}: docker stop + start a single worker"
	docker stop "${c}-worker-1" > /dev/null
	wait_for "${c}: worker-1 reports NotReady" 300 node_status_is "${c}" \
		"${c}-worker-1" False
	start_containers "${c}-worker-1"
	wait_for "${c}: worker-1 back to Ready" "${ZEK_E2E_TIMEOUT}" node_status_is "${c}" \
		"${c}-worker-1" True
	assert_state "worker restart"

	log "${c}: docker restart the master"
	docker restart "${c}-master-1" > /dev/null
	assert_state "master restart"

	log "${c}: zek down + zek up"
	zk "${c}" down
	assert_cmd "${c}: down stops everything" 0 running_count "${c}"
	# The stop ran each container's cleanup trap; the log line is the only
	# host-visible proof (sysctl/module restore is best-effort and shared
	# with parallel jobs). Polled rather than checked once: docker logs
	# can lag the stop by a beat.
	wait_for "${c}: master-1 logged its cleanup" 30 log_has "${c}-master-1" \
		"shutting down"
	zk "${c}" up
	assert_state "zek down/up"

	log "${c}: kubelet crash on worker-1 - the supervisor restarts it"
	# shellcheck disable=SC2310
	kubelet_running "${c}-worker-1" \
		|| fail "${c}: kubelet not running before the crash"
	docker exec "${c}-worker-1" pkill -f "/usr/local/bin/kubelet"
	wait_for "${c}: kubelet running again" 60 kubelet_running "${c}-worker-1"
	# The supervisor's own restart marker proves the crash-recovery loop
	# ran - not just that a kubelet happens to be up again (entrypoint's
	# log line; polled because docker logs can lag the restart).
	wait_for "${c}: supervisor logged the restart" 60 log_has "${c}-worker-1" \
		"kubelet exited, restarting"
	wait_nodes_ready "${c}"
	wait_for "${c}: control plane readyz after kubelet crash" 120 readyz_ok "${c}"
	assert_state "kubelet crash"

	log "${c}: kubelet config without failSwapOn - the supervisor re-adds it"
	# Delete only the key: the supervisor's ensure_kubelet_config rewrites
	# a wrong value and appends the key when it is missing, right before
	# every kubelet start.
	docker exec "${c}-worker-1" sed -i '/^failSwapOn:/d' /var/lib/kubelet/config.yaml
	docker exec "${c}-worker-1" pkill -f "/usr/local/bin/kubelet"
	wait_for "${c}: kubelet running again after config edit" 60 kubelet_running "${c}-worker-1"
	wait_for "${c}: failSwapOn restored" 60 kubelet_failswapon "${c}-worker-1"
	wait_nodes_ready "${c}"
	assert_state "failSwapOn re-add"

	log "${c}: kubelet config with a wrong failSwapOn - the supervisor rewrites it"
	docker exec "${c}-worker-1" sed -i 's/^failSwapOn:.*/failSwapOn: true/' /var/lib/kubelet/config.yaml
	docker exec "${c}-worker-1" pkill -f "/usr/local/bin/kubelet"
	wait_for "${c}: kubelet running again after wrong value" 60 kubelet_running "${c}-worker-1"
	wait_for "${c}: failSwapOn rewritten" 60 kubelet_failswapon "${c}-worker-1"
	wait_nodes_ready "${c}"
	assert_state "failSwapOn rewrite"
}

test_single_node() {
	local c=$1 images out shared_mnt apiserver_cmd master_ip
	# The smallest cluster: one master, zero workers.
	up "${c}" 0 1
	assert_cmd "${c}: node count" 1 node_count "${c}"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
	# patch_kube_proxy rewrites kubeadm's null conntrack limits
	# (maxPerCore and min) to numbers on every init; a null would leave
	# kube-proxy at whatever the runtime default is.
	zk "${c}" kubectl -n kube-system get cm kube-proxy \
		-o jsonpath='{.data.config\.conf}' > "${WORK_DIR}/kube-proxy.conf"
	grep -qE '^  maxPerCore: [0-9]+$' "${WORK_DIR}/kube-proxy.conf" \
		|| fail "${c}: kube-proxy maxPerCore is still null (patch_kube_proxy did not run)"
	grep -qE '^  min: 0$' "${WORK_DIR}/kube-proxy.conf" \
		|| fail "${c}: kube-proxy min is still null (patch_kube_proxy did not run)"
	# The patched ConfigMap must reach running pods: after the rollout
	# restart every scheduled kube-proxy pod reports Ready.
	wait_for "${c}: kube-proxy DaemonSet rolled out" "${ZEK_E2E_TIMEOUT}" \
		ds_ready "${c}" kube-proxy
	# Node internals entrypoint.sh sets up on every start: assert the
	# wiring directly instead of inferring it from a running pod.
	log "${c}: node internals (containerd, CNI dirs, mounts, cgroup, DNS)"
	docker exec "${c}-master-1" grep -q "snapshotter = 'native'" /etc/containerd/config.toml \
		|| fail "${c}: containerd snapshotter is not native"
	docker exec "${c}-master-1" grep -q "unpack_config" /etc/containerd/config.toml \
		|| fail "${c}: containerd unpack_config missing (native unpack)"
	docker exec "${c}-master-1" grep -q "bin_dirs" /etc/containerd/config.toml \
		|| fail "${c}: containerd bin_dirs missing (CNI search path)"
	docker exec "${c}-master-1" test -L /etc/kubernetes \
		|| fail "${c}: /etc/kubernetes is not a symlink to the writable layer"
	assert_cmd "${c}: CNI net.d mode" "777" \
		docker exec "${c}-master-1" stat -c %a /etc/cni/net.d
	assert_cmd "${c}: CNI bin mode" "777" \
		docker exec "${c}-master-1" stat -c %a /opt/cni/bin
	docker exec "${c}-master-1" grep -q " /sys/fs/bpf " /proc/mounts \
		|| fail "${c}: bpffs not mounted at /sys/fs/bpf"
	# Mount propagation for eBPF CNIs: /, /sys and /run must be shared
	# (make-rshared), or pod mount requests are rejected. Propagation
	# lives in mountinfo only (/proc/mounts has no such column), matched
	# on the exact mountpoint field plus a shared peer group.
	for shared_mnt in / /sys /run; do
		docker exec "${c}-master-1" awk -v mnt="${shared_mnt}" '$5 == mnt && / shared:[0-9]+/ { found=1 } END { exit !found }' /proc/self/mountinfo \
			|| fail "${c}: ${shared_mnt} is not a shared mount"
	done
	assert_cmd "${c}: cgroupns mode" "host" \
		docker inspect -f '{{.HostConfig.CgroupnsMode}}' "${c}-master-1"
	docker exec "${c}-master-1" sh -c 'ps -o args= | grep -q "cgroup-driver=cgroupfs"' \
		|| fail "${c}: kubelet is not running with --cgroup-driver=cgroupfs"
	assert_cmd "${c}: restart policy" "unless-stopped" \
		docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${c}-master-1"
	# resolv.conf must not point at docker's stub loopback (coredns uses
	# dnsPolicy Default and would forward to itself and loop).
	docker exec "${c}-master-1" sh -c '! grep -q "^nameserver 127\\." /etc/resolv.conf' \
		|| fail "${c}: resolv.conf still points at a loopback stub"
	# Published credentials: complete set, 64-hex token material, endpoint.
	docker exec "${c}-master-1" test -s /etc/cluster/token \
		|| fail "${c}: published token missing"
	docker exec "${c}-master-1" grep -qE '^[0-9a-f]{64}$' /etc/cluster/ca-hash \
		|| fail "${c}: published ca-hash is not 64 hex chars"
	docker exec "${c}-master-1" grep -qE '^[0-9a-f]{64}$' /etc/cluster/cert-key \
		|| fail "${c}: published cert-key is not 64 hex chars"
	docker exec "${c}-master-1" grep -q ':6443$' /etc/cluster/api-endpoint \
		|| fail "${c}: published api-endpoint does not end in :6443"
	docker exec "${c}-master-1" test -s /etc/cluster/admin.conf \
		|| fail "${c}: published admin.conf missing"
	# The kubeadm init CLI flags landed observably: our advertise address
	# in the apiserver static pod spec, and our control-plane endpoint
	# (which kubeadm consumes into kubeconfigs and certificate SANs
	# rather than the pod command line) as the admin.conf server.
	# shellcheck disable=SC2310
	apiserver_cmd=$(zk "${c}" kubectl -n kube-system get pod "kube-apiserver-${c}-master-1" \
		-o jsonpath='{.spec.containers[0].command}' 2> /dev/null) || apiserver_cmd=""
	master_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${c}-master-1")
	[[ ${apiserver_cmd} == *"--advertise-address=${master_ip}"* ]] \
		|| fail "${c}: static pod misses our advertise address: ${apiserver_cmd}"
	assert_cmd "${c}: admin.conf points at the endpoint" "https://${master_ip}:6443" \
		docker exec "${c}-master-1" grep -Eo 'https://[^[:space:]]+' /etc/kubernetes/admin.conf
	# The image build preloaded the kubeadm images into containerd; a
	# silent import failure would turn every init into a live pull, which
	# only shows on an offline host. The import runs during init/join,
	# after node_setup and before kubeadm init, so the store is complete
	# once `up` returns.
	images=$(docker exec "${c}-master-1" ctr -n k8s.io images ls 2> /dev/null) || images=""
	for img in kube-apiserver etcd coredns kube-proxy pause; do
		[[ ${images} == *"${img}"* ]] \
			|| fail "${c}: preloaded image '${img}' missing from the containerd store"
	done
	# The import logs a WARNING per failed tarball instead of dying.
	# shellcheck disable=SC2310
	if log_has "${c}-master-1" "failed to import"; then
		fail "${c}: the kubeadm image preload logged a failure"
	fi
	# The image HEALTHCHECK reads the local daemons (containerd's process
	# plus kubelet's healthz - the cluster state it must NOT use: this
	# node is NotReady without a CNI). Flip it off and back: unhealthy
	# is advisory metadata, so docker keeps the container running, and
	# the verdict recovers with the daemon.
	wait_for "${c}: master container healthy" 120 healthy_is "${c}-master-1"
	log "${c}: killing containerd must turn the HEALTHCHECK unhealthy"
	docker exec "${c}-master-1" pkill -x containerd \
		|| fail "${c}: pkill -x containerd failed"
	wait_for "${c}: containerd gone" 30 containerd_gone "${c}-master-1"
	wait_for "${c}: master unhealthy after containerd died" 120 \
		unhealthy_is "${c}-master-1"
	# shellcheck disable=SC2310
	container_running "${c}-master-1" \
		|| fail "${c}: docker stopped the unhealthy container"
	# ...and status renders the same verdict docker inspect reports.
	# shellcheck disable=SC2310
	out=$(zk "${c}" status 2>&1) || fail "${c}: status failed: ${out}"
	grep -E "^${c}-master-1[[:space:]]+running[[:space:]]+unhealthy$" \
		<<< "${out}" > /dev/null \
		|| fail "${c}: status misses the unhealthy verdict for ${c}-master-1: ${out}"
	log "${c}: restarting containerd must turn the HEALTHCHECK healthy"
	# The same command entrypoint.sh runs in start_containerd (its config
	# edits already live in the file), detached so the exec does not hold
	# the probe loop's hand.
	docker exec -d "${c}-master-1" sh -c \
		'containerd > /var/log/containerd.log 2>&1 &'
	wait_for "${c}: master healthy after the containerd restart" 120 \
		healthy_is "${c}-master-1"
	# Health tracks daemons, not the cluster: without a CNI the node is
	# NotReady yet the container is healthy. Killing kubelet alone must
	# NOT flip the verdict: the supervisor restarts it in seconds, well
	# inside the HEALTHCHECK's 3-strike (~30s) window, so a transient
	# blip stays healthy by design. A persistent outage is what turns
	# it unhealthy (proven above with containerd, which nothing restarts).
	wait_for "${c}: node NotReady without a CNI" 60 node_status_is "${c}" \
		"${c}-master-1" False
	wait_for "${c}: still healthy while NotReady" 120 healthy_is "${c}-master-1"
	log "${c}: killing kubelet must leave the HEALTHCHECK healthy"
	docker exec "${c}-master-1" pkill -f "/usr/local/bin/kubelet" \
		|| fail "${c}: pkill kubelet failed"
	wait_for "${c}: supervisor logged the restart" 60 log_has "${c}-master-1" \
		"kubelet exited, restarting"
	wait_for "${c}: kubelet supervised back" 60 kubelet_running "${c}-master-1"
	wait_for "${c}: still healthy after the kubelet restart" 120 \
		healthy_is "${c}-master-1"
}

# The zek.sh surface no other test reaches: kubectl exec's `--`, flag
# forms and env precedence, the loud error paths, the up spellings, the
# --timeout bound, clean's docker wiring, and a destroy that is asserted
# instead of merely invoked (the per-job destroy swallows its exit).
test_smoke() {
	local c=$1 before after out role apiserver_cmd
	up "${c}" 1 1
	# status prints the HEALTHCHECK verdict as its own column, so the
	# master's first successful probe has to land before the read.
	wait_for "${c}: master container healthy" 120 healthy_is "${c}-master-1"
	# status: lists the node containers and the cluster nodes; merge
	# stderr so a failing status lands in the FAIL line instead of
	# being lost in the shared output (the entrypoint logs to stderr).
	# shellcheck disable=SC2310
	out=$(zk "${c}" status 2>&1) || fail "${c}: status failed: ${out}"
	[[ ${out} == *"${c}-master-1"* ]] || fail "${c}: status misses ${c}-master-1"
	# Pin the health column itself: name, state and verdict in order,
	# so a status that drops or reorders it stops passing silently.
	grep -E "^${c}-master-1[[:space:]]+running[[:space:]]+healthy$" \
		<<< "${out}" > /dev/null \
		|| fail "${c}: status misses the health verdict for ${c}-master-1"
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
	zk "${c}" kubectl apply -f - > /dev/null << EOF
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
	out=$(zk "${c}" kubectl exec e2e-exec -- echo exec-ok 2>&1) \
		|| fail "${c}: kubectl exec -- failed: ${out}"
	[[ ${out} == exec-ok ]] \
		|| fail "${c}: exec output: want 'exec-ok', got '${out}'"
	# stdin exec: -i must carry the pipe through zek and the entrypoint
	# (no -t, so no CR translation on the round trip).
	# shellcheck disable=SC2310
	out=$(printf 'stdin-ok\n' | zk "${c}" kubectl exec -i e2e-exec -- cat 2>&1) \
		|| fail "${c}: kubectl exec -i failed: ${out}"
	[[ ${out} == stdin-ok ]] \
		|| fail "${c}: stdin exec: want 'stdin-ok', got '${out}'"
	zk "${c}" kubectl delete pod/e2e-exec --wait=false > /dev/null

	# Every value flag parses on a command that touches nothing (status
	# only reads docker/kubectl); all eight reappear in --flag=value form
	# in the next call.
	out=$(./zek.sh --cluster "${c}" --timeout=600 --image "${ZEK_IMAGE}" \
		--subnet 172.20.254.0/24 --master-ip 172.20.254.2 --dns 1.1.1.1 \
		--pod-cidr 10.245.0.0/16 --mounts "${WORK_DIR}:/e2e-mount" \
		status 2>&1) || fail "${c}: flag parse failed: ${out}"
	[[ ${out} == *"${c}-master-1"* ]] \
		|| fail "${c}: status misses ${c}-master-1 after flag parse"
	# The same eight in the --flag=value spelling, all on one command.
	out=$(./zek.sh --cluster="${c}" --timeout=600 --image="${ZEK_IMAGE}" \
		--subnet=172.20.254.0/24 --master-ip=172.20.254.2 --dns=1.1.1.1 \
		--pod-cidr=10.245.0.0/16 --mounts="${WORK_DIR}:/e2e-mount" \
		status 2>&1) || fail "${c}: --flag=value parse failed: ${out}"
	[[ ${out} == *"${c}-master-1"* ]] \
		|| fail "${c}: status misses ${c}-master-1 after --flag=value parse"
	# Flag beats env - the precedence every flag shares - and the env
	# twin alone is honored when no flag is given.
	if ! out=$(env ZEK_CLUSTER=e2e-nope ./zek.sh --cluster "${c}" status 2>&1); then
		fail "${c}: --cluster must beat ZEK_CLUSTER: ${out}"
	fi
	[[ ${out} == *"${c}-master-1"* ]] \
		|| fail "${c}: --cluster won over ZEK_CLUSTER but ran: ${out}"

	# --subnet/--master-ip/--pod-cidr must really shape the network, the
	# master and the node spec kube-proxy and the CNI read, not just
	# parse: a throwaway cluster is created with explicit values and
	# inspected before it is destroyed again.
	log "${c}: --subnet/--master-ip/--pod-cidr reach docker and the node"
	local fn_subnet=172.20.250.0/24 fn_master_ip=172.20.250.2 fn_pod_cidr=10.246.0.0/16
	local actual_subnet actual_ip
	./zek.sh --cluster e2e-fn --subnet "${fn_subnet}" --master-ip "${fn_master_ip}" \
		--pod-cidr "${fn_pod_cidr}" up --workers 0 --masters 1
	actual_subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' e2e-fn-net)
	actual_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' e2e-fn-master-1)
	# The controller-manager stamps spec.podCIDR onto the node object
	# seconds after registration; fn_pod_cidr_is polls for the value.
	wait_for "${c}: --pod-cidr reached the node spec" 120 \
		fn_pod_cidr_is "${fn_pod_cidr}"
	./zek.sh --cluster e2e-fn destroy > /dev/null 2>&1 || true
	assert_eq "${c}: --subnet reached the network" "${fn_subnet}" "${actual_subnet}"
	assert_eq "${c}: --master-ip reached the master" "${fn_master_ip}" "${actual_ip}"

	# Loud error paths; none of these may touch the cluster.
	assert_die "${c}: --cluster without a value" "--cluster needs a cluster name" \
		./zek.sh --cluster
	assert_die "${c}: short flags are gone" "usage:" ./zek.sh -c "${c}" status
	assert_die "${c}: invalid mount" "invalid mount" \
		./zek.sh --mounts bad status
	assert_die "${c}: invalid --subnet" "invalid subnet" \
		./zek.sh --subnet garbage status
	assert_die "${c}: invalid --master-ip" "invalid master IP" \
		./zek.sh --master-ip 999.1.1.1 status
	assert_die "${c}: invalid --dns" "invalid DNS IP" \
		./zek.sh --dns 1.2.3.4/24 status
	assert_die "${c}: invalid --pod-cidr" "invalid pod CIDR" \
		./zek.sh --pod-cidr garbage status
	assert_die "${c}: prefix above 32" "invalid subnet" \
		./zek.sh --subnet 172.20.0.0/33 status
	assert_die "${c}: leading-zero octet" "invalid subnet" \
		./zek.sh --subnet 172.020.0.0/24 status
	assert_die "${c}: master colliding with the LB IP" "load balancer's IP" \
		env ZEK_MASTERS=9 ./zek.sh --cluster "${c}-lbcol" up
	assert_die "${c}: duplicate test names" "requested twice" \
		./e2e.sh smoke smoke
	assert_die "${c}: --e2e-tests plus positional tests" "mutually exclusive" \
		./e2e.sh --e2e-tests smoke smoke
	assert_die "${c}: ZEK_E2E_TESTS plus positional tests" "mutually exclusive" \
		env ZEK_E2E_TESTS=smoke ./e2e.sh smoke
	assert_die "${c}: empty --e2e-tests" "--e2e-tests needs a non-empty value" \
		./e2e.sh --e2e-tests=
	# The numeric bounds are checked before the stale sweep destroys
	# anything, so these die with zero side effects.
	assert_die "${c}: ZEK_E2E_JOBS below 1" "ZEK_E2E_JOBS must be an integer" \
		env ZEK_E2E_JOBS=0 ./e2e.sh
	assert_die "${c}: non-numeric ZEK_E2E_JOBS" "ZEK_E2E_JOBS must be an integer" \
		env ZEK_E2E_JOBS=two ./e2e.sh
	assert_die "${c}: ZEK_E2E_TIMEOUT below 1" "ZEK_E2E_TIMEOUT must be an integer" \
		env ZEK_E2E_TIMEOUT=0 ./e2e.sh
	assert_die "${c}: empty --image" "--image needs a value" \
		./zek.sh --image= status
	assert_die "${c}: invalid --timeout" "invalid timeout" \
		./zek.sh --timeout abc status
	assert_die "${c}: invalid cluster name" "invalid cluster name" \
		./zek.sh --cluster "bad name" status
	# The up-only numbers are validated in cmd_up after the flag > env
	# merge, so a bad env twin must die there (with no cluster touched)
	# and name both spellings in the message.
	assert_die "${c}: invalid ZEK_WORKERS" "invalid workers 'abc'" \
		env ZEK_WORKERS=abc ./zek.sh --cluster "${c}-nope" up
	assert_die "${c}: invalid ZEK_MASTERS" "invalid masters '0'" \
		env ZEK_MASTERS=0 ./zek.sh --cluster "${c}-nope" up
	assert_die "${c}: invalid ZEK_POD_CIDR env" "invalid pod CIDR" \
		env ZEK_POD_CIDR=garbage ./zek.sh status
	assert_die "${c}: ZEK_CLUSTER selects the cluster" \
		"no cluster named e2e-nope" env ZEK_CLUSTER=e2e-nope ./zek.sh status
	assert_die "${c}: clean refuses a control-plane node" "cannot clean" \
		./zek.sh --cluster "${c}" clean "${c}-master-1"

	# The remaining loud promises: missing flag values, non-numeric
	# sizes, clean's name checks and the usage paths. None of these may
	# touch the cluster.
	assert_die "${c}: --timeout without a value" "needs a number of seconds" \
		./zek.sh --timeout
	for flag in --subnet --master-ip --dns --pod-cidr --mounts; do
		assert_die "${c}: ${flag} without a value" "needs a value" ./zek.sh "${flag}"
	done
	assert_die "${c}: --workers non-numeric" "invalid workers 'abc'" \
		zk "${c}" up --workers abc
	assert_die "${c}: --masters non-numeric" "invalid masters 'abc'" \
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
	# Host-address validation (require_host_ip): every address docker would
	# allocate is checked before the network exists, so none of these may
	# create anything (throwaway -nope cluster).
	assert_die "${c}: master on the network address" "is the network address" \
		./zek.sh --cluster "${c}-nope" --subnet 172.20.250.0/24 --master-ip 172.20.250.0 up
	assert_die "${c}: master on the gateway" "is the gateway" \
		./zek.sh --cluster "${c}-nope" --subnet 172.20.250.0/24 --master-ip 172.20.250.1 up
	assert_die "${c}: master on the broadcast" "is the broadcast address" \
		./zek.sh --cluster "${c}-nope" --subnet 172.20.250.0/24 --master-ip 172.20.250.255 up
	assert_die "${c}: master outside the subnet" "is outside the cluster subnet" \
		./zek.sh --cluster "${c}-nope" --subnet 172.20.250.0/24 --master-ip 172.20.251.2 up
	# Reusing an existing network with a disagreeing --subnet must die
	# instead of deriving container IPs from the wrong subnet: simulate a
	# retry after a failed create (network exists, master does not).
	docker network create --driver bridge --subnet 172.20.253.0/24 "${c}-mismatch-net" > /dev/null \
		|| fail "${c}: cannot create mismatch network (subnet taken?)"
	assert_die "${c}: --subnet mismatch on reuse" "uses subnet" \
		./zek.sh --cluster "${c}-mismatch" --subnet 172.20.254.0/24 up --workers 0 --masters 1
	docker network rm "${c}-mismatch-net" > /dev/null 2>&1 || true
	# A --subnet overlapping a *different* live network dies at create
	# time instead of overlapping it (nothing of ours is created first).
	docker network create --driver bridge --subnet 172.21.0.0/16 "${c}-overlap-helper" > /dev/null \
		|| fail "${c}: cannot create overlap helper network (subnet taken?)"
	assert_die "${c}: overlapping --subnet" "cannot create network" \
		./zek.sh --cluster "${c}-overlap" --subnet 172.21.5.0/24 up --workers 0 --masters 1
	docker network rm "${c}-overlap-helper" > /dev/null 2>&1 || true
	# Up-only size bounds: range, leading zeros (octal trap) and empty.
	assert_die "${c}: --workers out of range" "out of range" \
		zk "${c}" up --workers 65
	assert_die "${c}: --masters out of range" "out of range" \
		zk "${c}" up --masters 65
	assert_die "${c}: --workers negative" "invalid workers '-1'" \
		zk "${c}" up --workers -1
	assert_die "${c}: --masters zero" "invalid masters '0'" \
		zk "${c}" up --masters 0
	assert_die "${c}: --workers leading zero" "invalid workers '08'" \
		zk "${c}" up --workers 08
	assert_die "${c}: --workers empty" "--workers needs a value" \
		zk "${c}" up --workers=
	assert_die "${c}: --masters empty" "--masters needs a value" \
		zk "${c}" up --masters=
	assert_die "${c}: --workers without a value" "--workers needs a value" \
		zk "${c}" up --workers
	assert_die "${c}: --masters without a value" "--masters needs a value" \
		zk "${c}" up --masters
	assert_die "${c}: duplicate bare number" "may appear once" \
		zk "${c}" up 1 2
	assert_die "${c}: --image without a value" "--image needs a value" \
		./zek.sh --image
	# Trailing arguments on commands that take none must die instead of
	# silently operating on the default cluster.
	assert_die "${c}: destroy with a trailing arg" "usage:" \
		./zek.sh --cluster "${c}" destroy extra
	assert_die "${c}: status with a trailing arg" "usage:" \
		zk "${c}" status extra
	assert_die "${c}: down with a trailing arg" "usage:" \
		zk "${c}" down extra
	assert_die "${c}: up flag after the command" "usage:" \
		zk "${c}" up --cluster foo
	assert_die "${c}: unknown command" "usage:" ./zek.sh bogus-command
	assert_die "${c}: logs on a missing container" "No such container" \
		./zek.sh --cluster "${c}" logs "${c}-worker-99"
	assert_die "${c}: kubectl with no cluster" "No such container" \
		./zek.sh --cluster "${c}-nope" kubectl get nodes
	# e2e.sh's own bounds: bad ZEK_TIMEOUT dies before the stale sweep,
	# empty ZEK_E2E_TESTS dies like the flag form, and the boolean only
	# accepts bare/=1.
	assert_die "${c}: bad ZEK_TIMEOUT" "ZEK_TIMEOUT must be an integer" \
		env ZEK_TIMEOUT=abc ./e2e.sh smoke
	assert_die "${c}: empty ZEK_E2E_TESTS" "needs a non-empty value" \
		env ZEK_E2E_TESTS= ./e2e.sh
	assert_die "${c}: --e2e-keep-on-fail=2" "is a boolean" \
		./e2e.sh --e2e-keep-on-fail=2 smoke
	assert_die "${c}: --cilium-version without a value" "needs a value" \
		./e2e.sh --cilium-version
	# e2e.sh's own --flag=value spellings die the same loud deaths (all
	# before the stale sweep, so none of these touch any cluster) - plus
	# an unknown test name, which is a usage error, not a test.
	assert_die "${c}: --timeout= form" "must be an integer" ./e2e.sh --timeout=abc smoke
	assert_die "${c}: --e2e-timeout= form" "must be an integer" ./e2e.sh --e2e-timeout=0 smoke
	assert_die "${c}: --e2e-jobs= form" "must be an integer" \
		env ZEK_E2E_JOBS=2 ./e2e.sh --e2e-jobs=two smoke
	assert_die "${c}: --image= form" "not found" ./e2e.sh --image=x-nope smoke
	assert_die "${c}: --e2e-tests= plus positional" "mutually exclusive" \
		./e2e.sh --e2e-tests=smoke smoke
	assert_die "${c}: unknown test name" "usage:" ./e2e.sh bogus-test

	# The entrypoint's own flag surface (PR#4): every value flag must
	# die without a value, every flag must parse on the kubectl role,
	# --kubeconfig must work, `--` must forward and no args must drop
	# into an interactive shell.
	log "${c}: entrypoint flag surface"
	for flag in --cluster-dir --node-name --pod-cidr --node-dns --api-endpoint \
		--join-token --join-ca-hash --join-api-endpoint --join-cert-key \
		--lb-backends --kubeconfig; do
		assert_die "${c}: entrypoint ${flag} without a value" "needs a value" \
			docker exec "${c}-master-1" /entrypoint.sh kubectl "${flag}"
	done
	assert_die "${c}: entrypoint rejects an unknown role" "usage:" \
		docker exec "${c}-master-1" /entrypoint.sh bogus
	# Booleans accept bare and =1, reject any other value, and the node
	# roles reject stray arguments (only kubectl passes things through).
	assert_die "${c}: entrypoint --master-join=2" "is a boolean" \
		docker exec "${c}-master-1" /entrypoint.sh master --master-join=2
	assert_die "${c}: entrypoint --no-host-modules=0" "is a boolean" \
		docker exec "${c}-master-1" /entrypoint.sh worker --no-host-modules=0
	assert_die "${c}: entrypoint unknown argument on master" "unknown argument" \
		docker exec "${c}-master-1" /entrypoint.sh master --bogus-flag
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl \
		--pod-cidr 10.246.0.0/16 --node-name recovery-ignore \
		--node-dns 1.1.1.1 --api-endpoint 127.0.0.1:6443 \
		--master-join --join-token t --join-ca-hash h \
		--join-api-endpoint 127.0.0.1:6443 --join-cert-key k \
		--lb-backends "1.2.3.4 5.6.7.8" --no-host-modules \
		get nodes 2>&1) \
		|| fail "${c}: entrypoint flag twins did not parse: ${out}"
	# The same eleven value flags in --flag=value spelling, plus the two
	# booleans as =1 (kubectl needs --kubeconfig here so it does not wait
	# for a cluster-dir admin.conf).
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl \
		--cluster-dir=/tmp/e2e-eq --node-name=e2e-eq \
		--pod-cidr=10.246.0.0/16 --node-dns=1.1.1.1 \
		--api-endpoint=127.0.0.1:6443 --join-token=t --join-ca-hash=h \
		--join-api-endpoint=127.0.0.1:6443 --join-cert-key=k \
		--lb-backends="1.2.3.4 5.6.7.8" \
		--master-join=1 --no-host-modules=1 \
		--kubeconfig=/etc/cluster/admin.conf get nodes 2>&1) \
		|| fail "${c}: entrypoint --flag=value parse failed: ${out}"
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl \
		--kubeconfig /etc/cluster/admin.conf get nodes 2>&1) \
		|| fail "${c}: entrypoint --kubeconfig failed: ${out}"
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl -- get nodes 2>&1) \
		|| fail "${c}: entrypoint -- forwarding failed: ${out}"
	out=$(docker exec "${c}-master-1" /entrypoint.sh kubectl < /dev/null 2>&1) \
		|| fail "${c}: entrypoint kubectl with no args failed: ${out}"
	# The KUBECONFIG env twin works like --kubeconfig above.
	out=$(docker exec -e KUBECONFIG=/etc/cluster/admin.conf "${c}-master-1" /entrypoint.sh kubectl get nodes 2>&1) \
		|| fail "${c}: entrypoint KUBECONFIG env twin failed: ${out}"
	# Flag beats env: the env points at an empty dir (a 1s wait, then a
	# death), while the flag points at the real config - success proves
	# the flag won, the same merge shape every flag shares.
	out=$(docker exec -e CLUSTER_DIR=/tmp/e2e-empty -e WAIT_TIMEOUT=1 "${c}-master-1" /entrypoint.sh kubectl --cluster-dir /etc/cluster get nodes 2>&1) \
		|| fail "${c}: entrypoint flag must beat CLUSTER_DIR env: ${out}"
	# `--` on a node role must not silently swallow trailing args. One
	# shared guard covers every non-kubectl role, so loop them instead
	# of repeating the same assertion three times.
	for role in master worker lb; do
		assert_die "${c}: entrypoint ${role} -- args" "unknown argument" \
			docker exec "${c}-master-1" /entrypoint.sh "${role}" -- --foo
	done
	# The lb role dies without backends before touching haproxy.
	assert_die "${c}: entrypoint lb without backends" "LB_BACKENDS must list" \
		docker exec "${c}-master-1" /entrypoint.sh lb
	# run_kubectl waits for a missing admin.conf but dies on timeout: an
	# empty cluster dir with a 1s budget fails fast instead of hanging.
	assert_die "${c}: entrypoint kubectl wait timeout" "no admin.conf found" \
		docker exec -e WAIT_TIMEOUT=1 "${c}-master-1" /entrypoint.sh kubectl --cluster-dir /tmp/e2e-empty get nodes
	# A worker without join credentials dies loudly after node_setup (not
	# inside kubeadm): clone the live worker's host config so the probe
	# tracks zek.sh's NODE_ARGS instead of duplicating them.
	log "${c}: worker without join credentials dies"
	node_clone_args "${c}-worker-1"
	docker run -d --name "${c}-worker-nocreds" --hostname "${c}-worker-nocreds" \
		--restart=no "${CLONE_ARGS[@]}" \
		"${ZEK_IMAGE}" worker > /dev/null
	wait_for "${c}: creds-less worker exits" 180 container_exited "${c}-worker-nocreds"
	assert_cmd "${c}: creds-less worker exit code" 1 \
		docker inspect -f '{{.State.ExitCode}}' "${c}-worker-nocreds"
	docker logs "${c}-worker-nocreds" 2>&1 | grep -qF "worker join needs" \
		|| fail "${c}: creds-less worker logged the wrong error"
	docker rm -f "${c}-worker-nocreds" > /dev/null
	# A worker with a bad token fails inside kubeadm join instead: the
	# run_logged wrapper surfaces the kubeadm log, then dies.
	log "${c}: worker with a bad token fails the join"
	join_hash=$(docker exec "${c}-master-1" cat /etc/cluster/ca-hash)
	join_endpoint=$(docker exec "${c}-master-1" cat /etc/cluster/api-endpoint)
	docker run -d --name "${c}-worker-badjoin" --hostname "${c}-worker-badjoin" \
		--restart=no "${CLONE_ARGS[@]}" \
		-e JOIN_TOKEN=fake-token -e "JOIN_CA_HASH=${join_hash}" \
		-e "JOIN_API_ENDPOINT=${join_endpoint}" \
		"${ZEK_IMAGE}" worker > /dev/null
	wait_for "${c}: bad-token worker exits" 180 container_exited "${c}-worker-badjoin"
	assert_cmd "${c}: bad-token worker exit code" 1 \
		docker inspect -f '{{.State.ExitCode}}' "${c}-worker-badjoin"
	docker logs "${c}-worker-badjoin" 2>&1 | grep -qF "kubeadm join failed" \
		|| fail "${c}: bad-token worker did not surface the kubeadm log"
	docker rm -f "${c}-worker-badjoin" > /dev/null
	# NODE_DNS overrides the resolv.conf parsing: the same creds-less
	# worker rewrote resolv.conf during node_setup before it died.
	log "${c}: NODE_DNS reaches resolv.conf"
	docker run -d --name "${c}-worker-nodns" --hostname "${c}-worker-nodns" \
		--restart=no "${CLONE_ARGS[@]}" \
		-e NODE_DNS=9.9.9.9 \
		"${ZEK_IMAGE}" worker > /dev/null
	wait_for "${c}: NODE_DNS reached resolv.conf" 30 nodns_applied "${c}-worker-nodns" 9.9.9.9
	docker rm -f "${c}-worker-nodns" > /dev/null

	# Every up spelling: --flag=value, the ZEK_WORKERS/ZEK_MASTERS
	# defaults, and the bare-number shorthand - which must warn and leave
	# the fixed topology alone (still 1 master + 1 worker, no containers
	# added).
	# shellcheck disable=SC2310
	out=$(zk "${c}" up --workers=1 --masters=1 2>&1) \
		|| fail "${c}: up --flag=value failed: ${out}"
	out=$(env ZEK_WORKERS=1 ZEK_MASTERS=1 ./zek.sh --cluster "${c}" up 2>&1) \
		|| fail "${c}: up with ZEK_WORKERS/ZEK_MASTERS failed: ${out}"
	# shellcheck disable=SC2310
	out=$(zk "${c}" up 2 2>&1) \
		|| fail "${c}: up <n> shorthand failed: ${out}"
	[[ ${out} == *"topology is fixed"* ]] \
		|| fail "${c}: up 2 must warn that the topology is fixed: ${out}"
	assert_cmd "${c}: node count after up 2" 2 node_count "${c}"
	assert_cmd "${c}: containers after up 2" 2 running_count "${c}"
	# A differing --masters must warn the same way and leave the topology.
	# shellcheck disable=SC2310
	out=$(zk "${c}" up --masters 2 2>&1) \
		|| fail "${c}: up --masters 2 failed: ${out}"
	[[ ${out} == *"topology is fixed"* ]] \
		|| fail "${c}: up --masters 2 must warn that the topology is fixed: ${out}"
	assert_cmd "${c}: node count after up --masters 2" 2 node_count "${c}"
	assert_cmd "${c}: containers after up --masters 2" 2 running_count "${c}"
	# The bare-number shorthand with 0: same warn, same untouched topology.
	# shellcheck disable=SC2310
	out=$(zk "${c}" up 0 2>&1) \
		|| fail "${c}: up 0 shorthand failed: ${out}"
	[[ ${out} == *"topology is fixed"* ]] \
		|| fail "${c}: up 0 must warn that the topology is fixed: ${out}"

	# --timeout must kill a doomed up fast instead of hanging (the
	# README's fail-fast claim), and a plain up must recover after.
	log "${c}: --timeout 1 dies on a downed cluster instead of hanging"
	zk "${c}" down
	assert_cmd "${c}: down stops everything" 0 running_count "${c}"
	# shellcheck disable=SC2310
	out=$(zk "${c}" status 2>&1) || fail "${c}: status on a stopped cluster failed: ${out}"
	[[ ${out} == *"is stopped"* ]] \
		|| fail "${c}: status on a stopped cluster: ${out}"
	# docker runs no probes on a stopped container, so the health column
	# must read `-` instead of the last verdict it had while running.
	grep -E "^${c}-master-1[[:space:]]+exited[[:space:]]+-$" \
		<<< "${out}" > /dev/null \
		|| fail "${c}: status on a stopped cluster misses the '-' health column: ${out}"
	# shellcheck disable=SC2310
	out=$(zk "${c}" down 2>&1) || fail "${c}: second down failed: ${out}"
	[[ ${out} == *"is not running"* ]] \
		|| fail "${c}: second down: ${out}"
	if out=$(./zek.sh --cluster "${c}" --timeout 1 up 2>&1); then
		fail "${c}: 'up --timeout 1' should have died: ${out}"
	fi
	[[ ${out} == *"API not reachable after 1s"* ]] \
		|| fail "${c}: wrong error from the doomed up: ${out}"
	# The doomed attempt started the containers before dying; a plain up
	# (600s budget) finishes what --timeout 1 interrupted.
	zk "${c}" up
	wait_for "${c}: control plane readyz after timeout" 120 readyz_ok "${c}"
	assert_cmd "${c}: node count after timeout recovery" 2 node_count "${c}"

	# clean on a stopped cluster: evict tolerates the dead control plane
	# (drain/delete fail open), and the credential read - which needs a
	# live master - dies on its bound instead of hanging. A throwaway
	# cluster: the failed clean removes the worker before dying, so it
	# must not run on this test's own cluster. env -u drops this job's
	# pre-allocated ZEK_SUBNET (it names *this* cluster's subnet, which
	# would overlap); the throwaway scans for its own free one instead.
	log "${c}: clean on a stopped cluster dies bounded"
	env -u ZEK_SUBNET ./zek.sh --cluster e2e-dclean up --workers 1 --masters 1
	env -u ZEK_SUBNET ./zek.sh --cluster e2e-dclean down > /dev/null
	assert_die "${c}: clean needs live credentials" "join credentials not published" \
		env -u ZEK_SUBNET ./zek.sh --cluster e2e-dclean --timeout 1 clean e2e-dclean-worker-1
	./zek.sh --cluster e2e-dclean destroy > /dev/null 2>&1 || true

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
	# The recreated worker cannot be healthy this early - the fresh
	# container runs no kubelet until kubeadm join has written its
	# config - so its probes fail inside the health start period and
	# status must render the running/starting verdict.
	# shellcheck disable=SC2310
	out=$(zk "${c}" status 2>&1) || fail "${c}: status after clean failed: ${out}"
	grep -E "^${c}-worker-1[[:space:]]+running[[:space:]]+starting$" \
		<<< "${out}" > /dev/null \
		|| fail "${c}: status misses the starting verdict for ${c}-worker-1: ${out}"
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

	# status with the API down: containers running but the control plane
	# unreachable must report `control plane not reachable`, not fail.
	log "${c}: status reports an unreachable control plane"
	docker stop "${c}-master-1" > /dev/null
	# shellcheck disable=SC2310
	out=$(zk "${c}" status 2>&1) || fail "${c}: status with the API down failed: ${out}"
	[[ ${out} == *"control plane not reachable"* ]] \
		|| fail "${c}: status misses the unreachable verdict: ${out}"
	start_containers "${c}-master-1"
	wait_for "${c}: control plane readyz after master restart" 120 readyz_ok "${c}"
	assert_cmd "${c}: node count after master restart" 2 node_count "${c}"

	# destroy: containers and network must really be gone - the pass-path
	# destroy in job_exit hides its exit status, so assert it here.
	log "${c}: destroy removes the containers and the network"
	out=$(./zek.sh --cluster "${c}" destroy 2>&1) \
		|| fail "${c}: destroy failed: ${out}"
	assert_cmd "${c}: containers after destroy" "" cluster_containers "${c}"
	if docker network inspect "${c}-net" > /dev/null 2>&1; then
		fail "${c}: network ${c}-net survived destroy"
	fi
	out=$(./zek.sh --cluster "${c}" destroy 2>&1) \
		|| fail "${c}: second destroy failed: ${out}"
	[[ ${out} == *"no cluster named"* ]] \
		|| fail "${c}: second destroy: ${out}"
}

test_recovery() {
	local c=$1 join_token join_hash join_endpoint bg_pid out
	up "${c}" 1 1

	# A node started with NO_HOST_MODULES=1 must still join: the host
	# already has the modules (every other node loaded them), so the
	# preflight skip changes nothing observable - what matters is that
	# the flag path runs cleanly end to end.
	log "${c}: NO_HOST_MODULES=1 node joins and leaves cleanly"
	join_token=$(docker exec "${c}-master-1" cat /etc/cluster/token)
	join_hash=$(docker exec "${c}-master-1" cat /etc/cluster/ca-hash)
	join_endpoint=$(docker exec "${c}-master-1" cat /etc/cluster/api-endpoint)
	# Clone the existing worker's host config (network, volumes, tmpfs,
	# privileged, cgroupns, ...) so the test tracks zek.sh's NODE_ARGS
	# instead of duplicating them; only env and restart are overridden.
	node_clone_args "${c}-worker-1"
	docker run -d --name "${c}-worker-nhm" --hostname "${c}-worker-nhm" \
		--restart=no "${CLONE_ARGS[@]}" \
		-e NO_HOST_MODULES=1 \
		-e "JOIN_TOKEN=${join_token}" -e "JOIN_CA_HASH=${join_hash}" \
		-e "JOIN_API_ENDPOINT=${join_endpoint}" \
		"${ZEK_IMAGE}" worker > /dev/null
	wait_for "${c}: NO_HOST_MODULES node registered" "${ZEK_E2E_TIMEOUT}" \
		node_count_is "${c}" 3
	# Polled, not a single check: the node object lands while the kubelet
	# may still be mid-startup or between supervisor restarts.
	wait_for "${c}: NO_HOST_MODULES node kubelet running" 60 kubelet_running \
		"${c}-worker-nhm"
	docker rm -f "${c}-worker-nhm" > /dev/null
	zk "${c}" kubectl delete node "${c}-worker-nhm" --wait=false > /dev/null
	wait_for "${c}: NO_HOST_MODULES node removed" "${ZEK_E2E_TIMEOUT}" \
		node_count_is "${c}" 2

	# Interrupted worker join: kubelet.conf gone, certs left behind.
	# The entrypoint must reset and rejoin.
	log "${c}: interrupted worker join recovers"
	docker exec "${c}-worker-1" rm -f /etc/kubernetes/kubelet.conf
	docker restart "${c}-worker-1" > /dev/null
	wait_for "${c}: interrupted join detected" 60 log_has "${c}-worker-1" \
		"interrupted join detected; resetting partial state"
	wait_for "${c}: worker-1 kubelet running again" 60 kubelet_running "${c}-worker-1"
	wait_for "${c}: control plane readyz after worker rejoin" 120 readyz_ok "${c}"
	assert_cmd "${c}: both nodes still registered" 2 node_count "${c}"

	# Lost credentials: admin.conf deleted, master restarted. The resume
	# path must republish the whole set.
	log "${c}: credential republish after losing admin.conf"
	docker exec "${c}-master-1" rm -f /etc/cluster/admin.conf
	docker restart "${c}-master-1" > /dev/null
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
	bg_pid=$!
	out=$(timeout 30 docker exec "${c}-master-1" /entrypoint.sh kubectl get nodes 2>&1) \
		|| fail "${c}: kubectl did not wait for the config: ${out}"
	wait "${bg_pid}" 2> /dev/null || true
	assert_cmd "${c}: nodes listed after the wait" 2 node_count "${c}"

	# Interrupted control-plane init: kubelet.conf present, completion
	# markers gone. The entrypoint must wipe and re-init. With ctr hidden
	# the image import must warn and skip (the images are already in the
	# store from the first init).
	log "${c}: interrupted control-plane init recovers (ctr hidden)"
	docker exec "${c}-master-1" sh -c 'mv "$(command -v ctr)" /ctr.hidden'
	docker exec "${c}-master-1" rm -f /etc/cluster/init-complete \
		/etc/cluster/admin.conf /etc/cluster/token
	docker restart "${c}-master-1" > /dev/null
	wait_for "${c}: interrupted init detected" 60 log_has "${c}-master-1" \
		"interrupted control-plane init/join detected; resetting partial state"
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
	docker restart "${c}-master-1" > /dev/null
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
		printf 'passed\n' > "${WORK_DIR}/result.${JOB_TEST}"
		destroy "${JOB_CLUSTER}"
		log "======== test ${JOB_TEST}: PASSED ========"
	else
		printf 'failed\n' > "${WORK_DIR}/result.${JOB_TEST}"
		log "======== test ${JOB_TEST}: FAILED ========"
		# Buffer diagnostics per test: parallel failures would interleave
		# into an unreadable mix; the parent prints them serially. A
		# broken cluster can make parts of diag fail - never block the
		# cleanup below on it.
		# shellcheck disable=SC2310
		diag "${JOB_CLUSTER}" > "${WORK_DIR}/diag.${JOB_TEST}" 2>&1 || true
		if [[ ${ZEK_E2E_KEEP_ON_FAIL:-0} -eq 1 ]]; then
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
stale=$(docker ps -a --format '{{.Names}}' \
	| sed -E 's/-(master|worker)-[0-9]+$//; s/-lb$//' \
	| grep -E '^e2e-' | sort -u || true)
if [[ -n ${stale} ]]; then
	while IFS= read -r leftover; do
		[[ -n ${leftover} ]] || continue
		log "removing leftover cluster ${leftover}"
		destroy "${leftover}"
	done <<< "${stale}"
fi

# Resolve tool downloads once up front: parallel jobs must not race the
# extraction into the shared BIN_DIR. A failed download must not abort the
# suite before it starts - the affected test fails on the missing binary
# and every other test still runs.
case " ${requested[*]} " in
	*" cilium "*)
		# errexit is off as the left side of ||; ensure_cilium returns 1
		# explicitly on every download step instead.
		# shellcheck disable=SC2310
		ensure_cilium \
			|| printf '\n[e2e] WARNING: cilium CLI download failed; the cilium test will fail\n' >&2
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
for test_name in "${requested[@]}"; do
	while ((running >= ZEK_E2E_JOBS)); do
		wait -n 2> /dev/null || true
		running=$((running - 1))
	done
	if [[ -n ${subnets[idx]:-} ]]; then
		run_test "${test_name}" "${subnets[idx]}" &
	else
		run_test "${test_name}" &
	fi
	idx=$((idx + 1))
	running=$((running + 1))
done
while ((running > 0)); do
	wait -n 2> /dev/null || true
	running=$((running - 1))
done

# Diagnostics first (in test order), then the verdict: every requested
# test ran, so report all failures, not just the first one.
failed=()
for test_name in "${requested[@]}"; do
	if [[ -f ${WORK_DIR}/diag.${test_name} ]]; then
		log "----- diagnostics for failed test ${test_name} -----"
		cat "${WORK_DIR}/diag.${test_name}"
		log "----- end diagnostics for ${test_name} -----"
	fi
	result=""
	if [[ -f ${WORK_DIR}/result.${test_name} ]]; then
		result=$(cat "${WORK_DIR}/result.${test_name}")
	fi
	[[ ${result} == passed ]] || failed+=("${test_name}")
done
if [[ ${#failed[@]} -gt 0 ]]; then
	die "failed tests: ${failed[*]}"
fi

log "all tests passed: ${requested[*]}"
