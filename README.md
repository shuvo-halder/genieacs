# GenieACS on Kubernetes

Kubernetes manifests and a deploy script for running [GenieACS](https://genieacs.com/) (TR-069 ACS) with MongoDB, a horizontally scalable server tier, and a web UI.

Repository: https://github.com/shuvo-halder/genieacs

## Architecture

| Component | Kind | Replicas | Purpose |
|---|---|---|---|
| `genieacs-mongo` | Deployment (`Recreate`) + PVC | 1 | MongoDB 6, stores all GenieACS data |
| `genieacs-server` | Deployment + HPA | 3 to 20 | CWMP (7547), NBI (7557), File Server (7567) |
| `genieacs-ui` | Deployment | 1 | Web UI (3000) |

Image used for server and UI: `drumsergio/genieacs:1.2.16.0` (third-party image, see [Notes](#notes)).

## Repository layout

```
00-namespace.yaml        Namespace "genieacs"
10-mongo.yaml            PVC, MongoDB Deployment, Service, NetworkPolicy
20-genieacs-server.yaml  Server Deployment, internal Service, CPE-facing NodePort Service
30-genieacs-ui.yaml      UI Deployment + NodePort Service
40-hpa.yaml              HorizontalPodAutoscaler for genieacs-server
deploy.sh                Install / delete script
README.md                This file
```

## Prerequisites

- A working Kubernetes cluster and `kubectl` configured for it
- A default StorageClass, or the name of one to use (`kubectl get sc`)
- `metrics-server` installed (required by the HPA)
- `openssl` on the machine running `deploy.sh` (used to generate the JWT secret)
- A CNI that enforces NetworkPolicy (optional; without it the Mongo policy is simply ignored)

## Quick start

```bash
git clone https://github.com/shuvo-halder/genieacs.git
cd genieacs

# Use the cluster's default StorageClass
./deploy.sh

# Or choose one explicitly
STORAGE_CLASS=ceph-rbd ./deploy.sh
```

The script:

1. Creates the `genieacs` namespace
2. Creates the `genieacs-secrets` secret with a random JWT secret (skipped if it already exists)
3. Deploys MongoDB and waits for it to become ready
4. Deploys the server, UI and HPA, and waits for rollout

### Verify the installation

```bash
kubectl -n genieacs get pods,svc,pvc,hpa
kubectl -n genieacs logs deploy/genieacs-server --tail=50
kubectl -n genieacs logs deploy/genieacs-ui --tail=50
```

All pods should be `Running` and `READY`, the PVC `Bound`, and the HPA `TARGETS` should show a percentage (not `<unknown>`).

## Endpoints

| Service | Access | Port |
|---|---|---|
| Web UI | `http://<node-ip>:30030` | NodePort 30030 |
| CWMP (set this as the ACS URL on CPEs) | `http://<node-ip>:30747` | NodePort 30747 |
| File Server (firmware/config downloads) | `http://<node-ip>:30767` | NodePort 30767 |
| NBI (REST API) | `genieacs-server.genieacs.svc:7557` | **Cluster-internal only** |

The NBI has no authentication by default, so it is intentionally not exposed outside the cluster. For temporary access use:

```bash
kubectl -n genieacs port-forward svc/genieacs-server 7557:7557
```

## Resource requests and limits

- **No `limits` are set on any component** (MongoDB, server, UI). Pods may use all available CPU and memory on their node.
- **`requests` are set** because the scheduler and the HPA need them. HPA CPU utilization is calculated as a percentage of the CPU request.

| Component | CPU request | Memory request |
|---|---|---|
| mongo | 250m | 512Mi |
| genieacs-server | 250m | 256Mi |
| genieacs-ui | 100m | 128Mi |

Without memory limits, a leak or spike in one pod can exhaust node memory and cause the kernel to OOM-kill other pods, including MongoDB. Monitor node resources, and consider pinning MongoDB to a dedicated node via `nodeSelector` and taints.

## Autoscaling (HPA)

`40-hpa.yaml` scales `genieacs-server` on CPU:

- Min 3, max 20 replicas (`maxReplicas` is mandatory in an HPA; raise it if needed)
- Target: 70% average CPU utilization (of the 250m request)
- Scale up quickly (up to +2 pods or +100% per 30 s) to absorb CPE inform spikes
- Scale down slowly (5 minute stabilization, -1 pod per minute) to avoid flapping

Traffic is balanced per TCP connection by kube-proxy. Existing long-lived connections are not rebalanced when new pods appear. `sessionAffinity` is intentionally not used: with `externalTrafficPolicy: Cluster`, client IPs are SNAT'd to node IPs, which would pin all CPEs behind one node to a single pod. Scaling the server tier also increases load on MongoDB, which is a single instance and is likely to be the first bottleneck at scale.

Useful checks:

```bash
kubectl top nodes
kubectl top pods -n genieacs
kubectl -n genieacs get hpa genieacs-server       # TARGETS showing <unknown> means metrics-server or requests problem
kubectl -n genieacs describe hpa genieacs-server
kubectl -n genieacs get endpointslices -l kubernetes.io/service-name=genieacs-cpe
watch kubectl top pods -n genieacs -l app=genieacs-server    # CPU should be spread across pods under load
```

## Migrating existing data

The manifests contain no data. All GenieACS configuration (provisions, presets, virtual parameters, users, devices) lives in MongoDB. To move it from an existing deployment:

```bash
# On the OLD cluster
kubectl -n genieacs exec deploy/genieacs-mongo -- \
  mongodump --db genieacs --archive --gzip > genieacs.archive.gz

# On the NEW cluster, after MongoDB is ready
kubectl -n genieacs exec -i deploy/genieacs-mongo -- \
  mongorestore --archive --gzip --drop < genieacs.archive.gz
kubectl -n genieacs rollout restart deploy/genieacs-server deploy/genieacs-ui
```

The JWT secret does not need to match the old one, but users will need to log in again.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `genieacs-mongo` pod `Pending` | PVC not bound. Check `kubectl -n genieacs describe pvc genieacs-mongo-pvc` and the StorageClass name (`STORAGE_CLASS=...`). |
| HPA `TARGETS` shows `<unknown>` | `metrics-server` missing or not ready (`kubectl top pods` must work), or CPU requests were removed. |
| Server/UI pods `CrashLoopBackOff` | Check logs. Usually MongoDB is not reachable yet, or the image runs different processes than expected (see Notes). |
| One server pod hot, others idle | Long-lived connections stay on one pod; new connections spread to new pods. Check kube-proxy mode and that `sessionAffinity` has not been re-enabled. |
| CPEs cannot reach the ACS | Check firewall for NodePorts 30747/30767 and that the CPE ACS URL is `http://<node-ip>:30747`. |
| Mongo restarts with `Multi-Attach` error | Make sure the Deployment strategy is `Recreate` (it is by default in this repo). |

## Uninstall

```bash
./deploy.sh delete                 # removes workloads/services, keeps PVC and secret (data is preserved)
kubectl delete ns genieacs         # removes everything, including the data volume (depending on StorageClass reclaim policy)
```

## Security notes

- The JWT secret is generated at install time and stored in the `genieacs-secrets` Secret, not in the manifests. Server and UI must use the same value.
- MongoDB has **no authentication**. It is reachable only inside the cluster and is restricted by a NetworkPolicy to the server and UI pods. For production, enable Mongo auth and update `GENIEACS_MONGODB_CONNECTION_URL` accordingly.
- CWMP and the File Server are exposed via NodePort over plain HTTP. Put them behind a firewall, an ingress or load balancer with TLS, or restrict source ranges to your CPE networks.
- The UI is exposed via NodePort 30030; restrict access or place it behind an authenticated ingress.

## Notes

- `drumsergio/genieacs` is a third-party image. Server and UI both use it, so verify which processes each container actually runs (`kubectl -n genieacs logs deploy/genieacs-server`) and adjust env/command if the UI or server starts duplicate services.
- To keep CPE source IPs visible to GenieACS, uncomment `externalTrafficPolicy: Local` in `20-genieacs-server.yaml`. Nodes without a local server pod will then drop CPE traffic, so make sure pods are spread across all nodes that CPEs can reach.
- NodePort numbers (30030, 30747, 30767) are kept stable so existing CPEs do not need their ACS URL changed.
- `genieacs-mongo` uses a `ReadWriteOnce` volume with the `Recreate` strategy, so updates cause a short MongoDB downtime.
- These manifests were validated for YAML/shell syntax only. Run `kubectl apply --dry-run=server -f <file>` and test in a non-production cluster first.
