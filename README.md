# Zek — Kubernetes Node Container

A Docker image that bundles **kubeadm**, **kubelet**, **kubectl**, and **containerd** so you can spin up real Kubernetes cluster nodes as containers. Designed for testing, development, and CI.

One image, three roles:

| Role      | Purpose                                      |
| --------- | -------------------------------------------- |
| `master`  | Control-plane node: `kubeadm init` + kubelet |
| `worker`  | Worker node: `kubeadm join` + kubelet        |
| `kubectl` | `kubectl` client for the cluster             |

No CNI is installed automatically. Once the nodes are up the user installs their own CNI (e.g. flannel); until then nodes report `NotReady`, which is expected.

## Build

```sh
make build    # tags zek:<alpine>-<k8s>-<commit>, e.g. zek:3.24.1-v1.37.0-a1b2c3d
```

Each build is tagged `<alpine>-<k8s>-<commit>` where the version pair is pinned
in the Makefile (`ALPINE_VERSION` = `3.24.1`, `KUBERNETES_VERSION` = `v1.37.0`)
and the last component is the short git commit SHA (suffixed `-dirty` when the
working tree has uncommitted changes), so every machine building the same
commit produces the same tag and no state needs to be shared. `:latest` is
re-pointed at each new build so default usage keeps working.
`make build-nocache` re-runs the image preload step. Neither version is
hard-coded in the Dockerfile. To build with raw docker:

```sh
docker build --build-arg ALPINE_VERSION=3.24.1 \
  --build-arg KUBERNETES_VERSION=v1.37.0 -t zek:latest .
```

## Setup (one time)

```sh
docker network create --driver bridge --subnet 172.20.0.0/24 zek-net
```

A shared cluster volume, plus one persistent volume per node. On Fedora with SELinux Enforcing, mount volumes with the `z`/`Z` flag as needed.

## Start the control plane

```sh
docker run -d --name zek-master \
  --hostname zek-master \
  --privileged --cgroupns=host \
  --network zek-net --ip 172.20.0.2 \
  --dns <your-dns> \
  -v zek-master:/var/lib \
  -v zek-cluster:/etc/cluster \
  -v /lib/modules:/lib/modules:ro \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /tmp \
  --restart unless-stopped \
  zek:latest master
```

`--cgroupns=host` and `--privileged` are required (see Notes). `--dns <your-dns>` should be a real upstream resolver (e.g. the host's gateway); the entrypoint rewrites `/etc/resolv.conf` so that pod DNS does not loop back on itself. When the master finishes it publishes `admin.conf`, the join token, the CA hash and its IP into the shared `zek-cluster` volume.

## Join a worker

```sh
docker run -d --name zek-worker-1 \
  --hostname zek-worker-1 \
  --privileged --cgroupns=host \
  --network zek-net \
  --dns <your-dns> \
  -v zek-worker-1:/var/lib \
  -v zek-cluster:/etc/cluster \
  -v /lib/modules:/lib/modules:ro \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /tmp \
  --restart unless-stopped \
  zek:latest worker
```

The worker waits for the master's join credentials in `zek-cluster`, then runs `kubeadm join`. Add more workers by repeating with unique names and volumes.

## kubectl

```sh
docker run --rm --network zek-net \
  -v zek-cluster:/etc/cluster:ro \
  zek:latest kubectl get nodes

docker run --rm --network zek-net \
  -v zek-cluster:/etc/cluster:ro \
  zek:latest kubectl apply -f - < some-manifest.yaml
```

## Install a CNI

After `kubectl get nodes` shows the control plane, install your CNI of choice. The manager runs kubectl against the cluster:

```sh
# flannel (works out of the box; default backend is vxlan)
./zek.sh kubectl apply -f - < <(curl -sL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml)
```

Nodes transition to `Ready` once the CNI daemonsets run. For host-side CLIs (`istioctl`, ...) you need the admin config:

```sh
docker exec zek-master cat /etc/cluster/admin.conf > admin.conf   # KUBECONFIG=admin.conf
```

### Switching CNIs

An in-place CNI uninstall removes cluster resources but leaves node-local kernel state — iptables chains, ipsets, BPF pins, interfaces — behind in the _persisting_ node netns. The host-side CLI cannot reach kernel state inside each node container, so the next CNI/mesh inherits a polluted netns. Refresh the affected node, or the whole cluster:

```sh
./zek.sh clean zek-master-worker-1    # one worker: pristine netns, cluster keeps running
./zek.sh destroy && ./zek.sh up 1     # everywhere, including the master (etcd lives on its layer)
```

Use `clean` after any CNI/mesh uninstall so the new stack starts from a clean netns.

## Persistence and recovery

Everything kubeadm, kubelet, containerd and etcd write lives under `/var/lib`, which is a named volume per node; `admin.conf`, the token, CA hash and master IP live in the shared `zek-cluster` volume. This means a node container can be stopped, restarted, or removed and recreated, and it rejoins the same cluster:

```sh
docker rm -f zek-master zek-worker-1
docker run -d ... zek:latest master        # same args as before
docker run -d ... zek:latest worker
```

## Destroy everything

```sh
docker rm -f zek-master zek-worker-1
docker volume rm zek-master zek-worker-1 zek-cluster
docker network rm zek-net
```

## Notes

- **`--cgroupns=host` is mandatory.** With the private cgroup namespace the kubelet fails to move itself into the right cgroup (`cgroup.procs` write returns `ENOENT`).
- **`--privileged`** is required for containerd's mounts and the CNI networking.
- The nodes are prepared so CNI daemonsets "just work": `/etc/cni/net.d` and the CNI bin dir are pre-created world-writable (some installers run as non-root), `/`, `/sys`, `/run` are made shared mounts so eBPF setups can mount fs types into pods, and `bpffs` is pre-mounted at `/sys/fs/bpf`.
- The node loads kernel modules `br_netfilter` and `vxlan` (only if the host lacks them) with `modprobe` and attempts to unload them again on shutdown. Nothing is written to disk. Set `NO_HOST_MODULES=1` on the container to skip all host kernel setup (e.g. if the modules are already loaded at boot); life is fully host-neutral then.
- `kube-proxy`'s automatic conntrack table tuning is disabled via its ConfigMap because the global `nf_conntrack_max` sysctl is not writable from a container netns.
- Containerd's CNI plugin search path is set to `['/opt/cni/bin', '/usr/libexec/cni']` since CNI providers install their plugin binary into `/opt/cni/bin`.
- `--dns` is a convenience for the node's own resolution; the entrypoint rewrites `/etc/resolv.conf` to the same upstream so coredns (which uses `dnsPolicy: Default`) does not forward to itself and loop.
