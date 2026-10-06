# Zek — Kubernetes Node Container

A Docker image that bundles **kubeadm**, **kubelet**, **kubectl**, **containerd** and **haproxy** so you can run real Kubernetes cluster nodes as containers. Designed for testing, development, and CI.

One image, four roles:

| Role      | Purpose                                                                        |
| --------- | ------------------------------------------------------------------------------ |
| `master`  | Control-plane node: `kubeadm init` or `kubeadm join --control-plane` + kubelet |
| `worker`  | Worker node: `kubeadm join` + kubelet                                          |
| `lb`      | haproxy in front of the masters (only used with `--masters > 1`)               |
| `kubectl` | `kubectl` client for the cluster                                               |

Clusters are managed with `./zek.sh`. A cluster is created in one shot with a **fixed topology**: `up` creates it on the first run and only restarts the same containers afterwards — nodes are never added or removed while the cluster exists. Several clusters can run side by side.

No CNI is installed automatically. Once the nodes are up you install your own (flannel, cilium, ...); until then nodes report `NotReady`, which is expected.

## Build

```sh
make build    # tags zek:<alpine>-<k8s>-<commit>, zek:<alpine>-<k8s>-latest and :latest
```

Each build is tagged `<alpine>-<k8s>-<commit>` where the version pair is pinned
in the Makefile (`ALPINE_VERSION`, `KUBERNETES_VERSION`) and the last component
is the short git commit SHA (suffixed `-dirty` when the working tree has
uncommitted changes), so every machine building the same commit produces the
same tag and no state needs to be shared. `:latest` is re-pointed at each new
build so default usage keeps working. `make build-nocache` re-runs the image
preload step. Neither version is hard-coded in the Dockerfile. To build with
raw docker, substitute the versions pinned in the Makefile:

```sh
docker build --build-arg ALPINE_VERSION=<alpine-version> \
  --build-arg KUBERNETES_VERSION=<k8s-version> -t zek:latest .
```

## Upgrading Kubernetes

Versions are pinned in the Makefile (`KUBERNETES_VERSION`,
`ALPINE_VERSION`); bump them and `make build` fetches the new binaries and
preloads the matching kubeadm images. A few release-coupled spots cannot be
updated by the build — check them when the bump fails or behaves oddly:

- `kubeadm init`/`kubeadm join` in `entrypoint.sh` run on CLI flags only —
  there are no config documents, so no `kubeadm.k8s.io` API version to pin.
  Check the release notes if init/join start rejecting a flag, and
  re-check the kubelet `--cgroup-driver` flag the supervisor passes:
  kubelet deprecates CLI flags over time (as it did `--fail-swap-on`).
- Two soft couplings break without failing the build: the kube-proxy
  conntrack keys patched in `patch_kube_proxy`, and containerd's
  `bin_dirs`/`unpack_config` tweaks in `start_containerd`. If a new release
  renames those knobs the cluster still comes up, but the workaround stops
  applying — verify your workload if you see the old symptoms again.
- kubeadm/kubelet are glibc builds run through `gcompat` on Alpine; a
  release needing newer glibc symbols fails loudly at startup in the node
  logs (rebuild is the fix).

Smoke-test the bump end-to-end with
`./zek.sh up --masters 2 --workers 1`: it exercises `kubeadm init`, a
control-plane join (certificate key), a worker join, the load balancer and
the published credentials in one run.

## Quick start

```sh
./zek.sh up --workers 2 --masters 1    # create: 1 master + 2 workers
./zek.sh status                        # node containers (state + health) + cluster nodes
./zek.sh kubectl get nodes
./zek.sh down                          # stop everything (state is kept)
./zek.sh up                            # restart the same topology
./zek.sh destroy                       # remove the containers and network
```

`up [--workers N] [--masters M]` creates the cluster on the first run
(defaults: 1 worker, 1 master; a bare number — `up 2` — is a shorthand for
`--workers 2`). On later runs the size flags are ignored — the topology was
fixed at creation — and a warning is printed if they differ from what
exists.

Every wait in zek.sh is bounded by `--timeout SECONDS` (default 600,
override with `ZEK_TIMEOUT`), so a broken cluster fails fast instead of
hanging:

```sh
./zek.sh --timeout 120 up   # give up after 2 minutes
ZEK_TIMEOUT=120 ./zek.sh up # same, via environment
```

### Multiple clusters

```sh
./zek.sh --cluster prod up --workers 2 --masters 3
./zek.sh --cluster dev  up --workers 1
./zek.sh --cluster prod kubectl get nodes     # or: ZEK_CLUSTER=prod ./zek.sh kubectl get nodes
./zek.sh --cluster dev  destroy               # only this cluster; prod keeps running
```

The `--cluster` flag (or `ZEK_CLUSTER`, default `zek`) selects the cluster for
every command. All containers and the Docker network carry the cluster name as
prefix (`prod-master-1`, `prod-worker-1`, `prod-lb`, `prod-net`). Each cluster
gets its own subnet — the first free `172.20.X.0/24`, scanned from the live
docker networks so concurrent clusters running with defaults don't collide. A
race or an explicit `--subnet`/`ZEK_SUBNET` that is already in use fails the
network create loudly instead of overlapping.

### Flags and environment

Every setting exists twice: as a flag and as an environment variable. The
flag wins when both are set. Global flags go before the command
(`./zek.sh --image zek:dev up`); `--workers`/`--masters` follow `up`.

| Variable        | Flag          | Effect                                                                    |
| --------------- | ------------- | ------------------------------------------------------------------------- |
| `ZEK_CLUSTER`   | `--cluster`   | Cluster name (default `zek`)                                              |
| `ZEK_TIMEOUT`   | `--timeout`   | Wait budget in seconds (default `600`)                                    |
| `ZEK_IMAGE`     | `--image`     | Node image (default `zek:latest`)                                         |
| `ZEK_WORKERS`   | `--workers`   | Workers for the first `up` (default `1`, `0` allowed: control-plane only) |
| `ZEK_MASTERS`   | `--masters`   | Masters for the first `up` (default `1`)                                  |
| `ZEK_SUBNET`    | `--subnet`    | Explicit subnet instead of the first free `172.20.X.0/24`                 |
| `ZEK_MASTER_IP` | `--master-ip` | First master's IP (default `<subnet>.2`)                                  |
| `ZEK_DNS`       | `--dns`       | Upstream DNS for the node containers                                      |
| `ZEK_POD_CIDR`  | `--pod-cidr`  | Pod subnet passed to kubeadm (default `10.244.0.0/16`)                    |
| `ZEK_MOUNTS`    | `--mounts`    | Extra host bind mounts for the node containers                            |

```sh
./zek.sh --mounts "/srv/data:/mnt/data" up   # host dir inside every node container
ZEK_MOUNTS="/srv/data:/mnt/data" ./zek.sh up # same, via environment
```

`--mounts` takes a space-separated list of
`host-path:container-path[:options]` bindings (`--mounts "/a:/x /b:/y:ro"`).
Like `--image` and `--dns`, it only affects containers created afterwards
(the first `up`, `clean`) — existing node containers are never
reconfigured.

## High availability (`--masters 3`)

With more than one master, zek starts an extra container `<cluster>-lb`
(haproxy) at `<subnet>.10`:

- haproxy listens on `6443`, round-robins to every master's apiserver and
  health-checks them (stats page at `http://<lb-ip>:8404/`, CSV at
  `http://<lb-ip>:8404/;csv`).
- kubeadm's `controlPlaneEndpoint` is that address, so every kubeconfig
  (all kubelets, kubectl, scheduler, controller-manager) talks to the
  endpoint — kubeadm also puts it into the apiserver certificate SANs.
- each master runs its own stacked **etcd** member and a full set of
  control-plane static pods (leader-elected, so one active scheduler /
  controller-manager, N apiservers).
- additional masters join with `kubeadm join --control-plane` using a
  certificate key the first master generates and publishes when the
  cluster is created — joiners start immediately after, while the
  uploaded certificates are fresh.

The masters walk up from `--master-ip` (default `<subnet>.2`): with the
default `/24` subnet and default `--master-ip` at most **8 masters** fit,
since master 9 would land on `<subnet>.10` — the load balancer's own IP —
and zek refuses that combination before creating anything. A custom
`--subnet`/`--master-ip` moves the limit, and the network, gateway and
broadcast addresses are always refused.

Use **odd** master counts: etcd needs a majority to stay writable. 1 master
has no redundancy, 2 masters lose quorum if either fails, 3 masters survive
one failure. Failover is plain: `docker stop <cluster>-master-2` — haproxy
takes it out of rotation within seconds; `docker start` brings it back and
it rejoins the cluster.

The apiserver is also reachable directly at `https://<master-ip>:6443`, but
the certificate is only issued for the endpoint (and the first master's
address), so use the endpoint — or `curl -k` — for direct checks.

## Install a CNI

After `kubectl get nodes` shows the control plane, install your CNI of
choice. Nodes transition to `Ready` once the CNI daemonsets run.

```sh
# flannel (vxlan backend; matches the default ZEK_POD_CIDR=10.244.0.0/16)
./zek.sh kubectl apply -f - < <(curl -sL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml)

# cilium (tested with v1.20.2)
cilium install --version v1.20.2
```

### Istio with istio-cni

```sh
docker exec <cluster>-master-1 cat /etc/cluster/admin.conf > admin.conf
istioctl install --set profile=default --set components.cni.enabled=true \
  --set values.cni.enabled=true --kubeconfig admin.conf -y
```

istio-cni drops its plugin into the node's CNI directories (which zek
pre-creates world-writable), so no sidecar init containers are needed;
label a namespace (`istio-injection=enabled`) and pods get sidecars on
their next start.

For other host-side CLIs, export `admin.conf` the same way
(`KUBECONFIG=admin.conf`).

### Switching CNIs

An in-place CNI uninstall removes cluster resources but leaves node-local
kernel state — iptables chains, ipsets, BPF pins, interfaces — behind in the
_node's own_ netns. The host-side CLI cannot reach kernel state inside each
node container, so the next CNI/mesh inherits a polluted netns. Refresh the
affected node, or the whole cluster:

```sh
./zek.sh clean <cluster>-worker-1    # one worker: pristine netns, cluster keeps running
./zek.sh destroy && ./zek.sh up ...  # everywhere (also resets the masters)
```

`clean` refuses control-plane nodes (etcd lives on their layer). Use it
after any CNI/mesh uninstall so the new stack starts from a clean netns.

## Persistence and recovery

Everything kubeadm, kubelet, containerd and etcd write lives on the node
container's own writable layer, and the published credentials (`admin.conf`,
join token, CA hash, API endpoint, certificate key) live under
`/etc/cluster` on the first master's layer. A node container can be stopped
or restarted, and the whole machine can be rebooted, and everything comes
back with the same identity: the cluster survives `down`/`up`,
`docker stop`/`docker start`, `docker restart`, a Docker daemon restart and
host reboots. It is gone once the containers are removed (`destroy`,
`docker rm`).

A creation that is interrupted before kubeadm finished (crash or power loss
during `up`) is detected on the next start: the partial state is reset and
the node re-initialises or re-joins from scratch. Completed nodes are never
reset.

## Notes

- **`--cgroupns=host` is mandatory.** With the private cgroup namespace the kubelet fails to move itself into the right cgroup (`cgroup.procs` write returns `ENOENT`).
- **`--privileged`** is required for containerd's mounts and the CNI networking.
- The nodes are prepared so CNI daemonsets "just work": `/etc/cni/net.d` and the CNI bin dir are pre-created world-writable (some installers run as non-root), `/`, `/sys`, `/run` are made shared mounts so eBPF setups can mount fs types into pods, and `bpffs` is pre-mounted at `/sys/fs/bpf`.
- The node loads kernel modules `br_netfilter` and `vxlan` (only if the host lacks them) with `modprobe` and attempts to unload them again on shutdown. Nothing is written to disk. Set `NO_HOST_MODULES=1` on the container to skip all host kernel setup (e.g. if the modules are already loaded at boot); life is fully host-neutral then.
- The node also raises the host-wide `fs.inotify.max_user_instances` quota to 1024 (all node containers share the per-uid quota) and leaves it raised on exit, since running containers still need it. With `NO_HOST_MODULES=1` this is skipped too.
- `kube-proxy`'s automatic conntrack table tuning is disabled via its ConfigMap because the global `nf_conntrack_max` sysctl is not writable from a container netns.
- Containerd's CNI plugin search path is set to `['/opt/cni/bin', '/usr/libexec/cni']` since CNI providers install their plugin binary into `/opt/cni/bin`.
- `--dns` is a convenience for the node's own resolution; the entrypoint rewrites `/etc/resolv.conf` to the same upstream so coredns (which uses `dnsPolicy: Default`) does not forward to itself and loop.
- The image carries a `HEALTHCHECK`; `docker ps` and `./zek.sh status` show its verdict per container (`healthy`/`unhealthy`/`starting`, `-` while docker is not probing it, i.e. stopped). It probes the container's own daemons — haproxy's stats page on the lb, containerd plus kubelet's healthz on nodes — and never the cluster (a node stays NotReady until a CNI is installed, so cluster state would mislabel a healthy container). Docker never restarts or stops a container for reporting unhealthy.
