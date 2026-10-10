# Part 3: Troubleshooting log

`troubleshoot/broken-app.yaml` had **11 independent faults**. They hide behind each other, so they surfaced one layer at a time: scheduling, then volume mount, then image pull, then probes, then the Service, then the network. Fixing one layer exposed the next. The fixed manifests are in `troubleshoot/fixed-app.yaml` (every change is marked `FIX n`), and `scripts/30-troubleshoot.sh` applies them and runs `verify.sh`.

Rules kept: the `default-deny` NetworkPolicy is untouched (three narrow allow policies are added next to it), and no node label or taint was changed.

All output below is copied from the real session on the k3d cluster (k3s v1.36.5), trimmed to the relevant lines.

## Starting point

```console
$ kubectl apply -f troubleshoot/broken-app.yaml
$ kubectl -n troubleshoot get pods -o wide
NAME                            READY   STATUS    RESTARTS   AGE   IP       NODE
ai-inference-77cfc6f99b-x25pw   0/1     Pending   0          25s   <none>   <none>
web-5c8d87f7d8-nbgzj            0/1     Pending   0          25s   <none>   <none>
web-5c8d87f7d8-snq2m            0/1     Pending   0          25s   <none>   <none>

$ sh troubleshoot/verify.sh
[3/7] Deployment 'web' must be fully rolled out...
FAIL: deployment/web is not ready
```

Everything is Pending, so the first layer is the scheduler.

---

## Layer 1: scheduling

### 1. `web` asks for 16Gi of memory

- **Symptom:** both `web` pods Pending.
- **Diagnosis:**
  ```console
  $ kubectl -n troubleshoot get events --field-selector involvedObject.kind=Pod | grep web
  FailedScheduling  pod/web-5c8d87f7d8-nbgzj  0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 Insufficient memory.
  $ kubectl get nodes -o custom-columns=NODE:.metadata.name,ALLOCATABLE_MEM:.status.allocatable.memory
  k3d-quote-agent-0    10175188Ki      # about 9.7Gi, every node reports the whole Docker VM
  $ kubectl -n troubleshoot get deploy web -o jsonpath='{.spec.template.spec.containers[0].resources}'
  {"limits":{"cpu":"500m","memory":"16Gi"},"requests":{"cpu":"100m","memory":"16Gi"}}
  ```
- **Root cause:** a 16Gi memory request cannot fit on any node (about 9.7Gi allocatable each). The fifth node is the GPU node, rejected by its taint.
- **Fix:** request 32Mi, limit 128Mi. nginx serving one static file uses a few MiB.
- **Note:** on a machine whose Docker VM has more than 16Gi, this bug is invisible, because k3d nodes are containers that all report the VM's full memory. On this Mac the VM has 10Gi, so it shows.

### 2. `ai-inference` selects a label key that does not exist

- **Symptom:** `ai-inference` Pending.
- **Diagnosis:**
  ```console
  $ kubectl -n troubleshoot describe pod -l app=ai-inference | sed -n '/Events:/,$p'
  FailedScheduling  0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 node(s) didn't match Pod's node affinity/selector.
  $ kubectl get nodes -L acme.io/node-type,acme.io/capacity
  NAME                 NODE-TYPE   CAPACITY
  k3d-quote-agent-3    gpu
  ```
- **Root cause:** `nodeSelector: {node-type: gpu}`, but `prepare.sh` sets `acme.io/node-type=gpu`. No node has a plain `node-type` label.
- **Fix:** `nodeSelector: {acme.io/node-type: gpu}`.

### 3. `ai-inference` does not tolerate the GPU taint

- **Symptom:** after fix 2 alone, **the scheduler message did not change at all**:
  ```console
  $ kubectl -n troubleshoot patch deploy ai-inference --type=json -p='[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"acme.io/node-type":"gpu"}}]'
  $ kubectl -n troubleshoot get events --field-selector reason=FailedScheduling | grep ai-inference | tail -1
  0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 node(s) didn't match Pod's node affinity/selector.
  $ kubectl get node -l acme.io/node-type=gpu -o jsonpath='{.spec.taints}'
  [{"effect":"NoSchedule","key":"nvidia.com/gpu","value":"true"}]
  ```
- **Root cause:** two faults on one pod. The scheduler rejects the GPU node for its taint before it checks the selector, so the GPU node is still counted as "untolerated taint" even once the selector points at it. An unchanged error after a correct fix means a second fault, not a wrong fix.
- **Fix:** add the toleration `nvidia.com/gpu=true:NoSchedule`. Result: `ai-inference ... Running ... k3d-quote-agent-3`. Dropping the selector and only tolerating would also schedule, but anywhere, and `verify.sh` step 5 checks it is on the GPU node.

## Layer 2: volume

### 4. The volume points at a ConfigMap that does not exist

- **Symptom:** with memory fixed, the new `web` pod sat in `ContainerCreating`.
- **Diagnosis:**
  ```console
  $ kubectl -n troubleshoot get events --field-selector reason=FailedMount
  FailedMount  pod/web-5dc8678cf6-zqw5w  MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found
  $ kubectl -n troubleshoot get configmap
  web-config         1      2m5s
  ```
- **Root cause:** the volume references `web-conf`; the ConfigMap is `web-config`.
- **Fix:** `configMap.name: web-config`.
- **Why the next bug was hidden:** the kubelet mounts volumes before it pulls the image, so the bad image tag never got a chance to fail until the mount worked.

## Layer 3: image

### 5. `nginx:1.25.99` does not exist

- **Symptom:** `ImagePullBackOff`.
- **Diagnosis:**
  ```console
  $ kubectl -n troubleshoot get events | grep -E 'Failed|BackOff' | grep web
  Failed  pod/web-5854d8b696-9mbs9  Failed to pull image "nginx:1.25.99": ... docker.io/library/nginx:1.25.99: not found
  ```
- **Root cause:** there is no 1.25.99 release (`docker manifest inspect nginx:1.25.99` says "no such manifest").
- **Fix:** `nginx:1.30`, the current stable line, multi-arch. `nginx:1.25` would be the closest to the typo, but that line stopped getting updates in 2024.

## Layer 4: probes

### 6. Probes check port 8080; nginx listens on 80

- **Symptom:** the pod ran but never became Ready, and kept restarting.
- **Diagnosis:**
  ```console
  $ kubectl -n troubleshoot get pods -l app=web
  web-78bfbd49cb-n8j5f   0/1     Running   1 (5s ago)   30s
  $ kubectl -n troubleshoot get events | grep -E 'Unhealthy|Killing'
  Killing    Container nginx failed liveness probe, will be restarted
  Unhealthy  Readiness probe failed: Get "http://10.42.4.5:8080/": dial tcp 10.42.4.5:8080: connect: connection refused
  $ kubectl -n troubleshoot exec deploy/web -- sh -c 'grep -m1 listen /etc/nginx/conf.d/default.conf'
      listen       80;
  ```
- **Root cause:** `containerPort: 80` but both probes use `port: 8080`.
- **Fix:** name the container port `http` and point both probes (and later the Service) at the name, so the port is defined once. `kubectl rollout status deploy/web` then succeeded.

## Layer 5: Service

### 7. The Service selects `app: webapp`; the pods are `app: web`

- **Symptom:** `verify.sh` step 6, "Service 'web-svc' has no endpoints".
- **Diagnosis:**
  ```console
  $ kubectl -n troubleshoot get endpointslices -l kubernetes.io/service-name=web-svc
  NAME            ADDRESSTYPE   PORTS     ENDPOINTS   AGE
  web-svc-t9zkq   IPv4          <unset>   <unset>     4m
  $ kubectl -n troubleshoot get svc web-svc -o jsonpath='{.spec.selector}'
  {"app":"webapp"}
  $ kubectl -n troubleshoot get pods --show-labels -l app=web
  web-56989c4fb6-djkf2   1/1   Running   app=web,pod-template-hash=56989c4fb6
  ```
- **Fix:** `selector: {app: web}`. Endpoints appeared: `10.42.1.4,10.42.4.6` on port `8080`.

### 8. The Service targets port 8080

- **Symptom:** step 6 now passed, but the endpoints showed port `8080`, and step 7 (the smoke test) failed:
  ```console
  curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 1 ms: Couldn't connect to server
  FAIL: smoke test failed (check NetworkPolicy/DNS/Service path)
  ```
- **Root cause:** `targetPort: 8080`, nothing listens there.
- **Fix:** `targetPort: http`. Endpoints now show port `80`.

## Layer 6: network (default-deny stays)

After fix 8 the smoke test failed with **exactly the same error** as before:

```console
curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 0 ms: Couldn't connect to server
$ kubectl -n troubleshoot get netpol
NAME           POD-SELECTOR   AGE
default-deny   <none>         5m31s
```

On k3s the network policy engine (kube-router) **rejects** blocked packets instead of silently dropping them, so a policy block fails instantly and looks identical to a wrong port. That is why the same curl error appears for faults 8, 10 and 11. `default-deny` covers ingress and egress for every pod in the namespace, so three things are blocked.

### 9. The smoke client cannot reach DNS

- **Root cause:** egress is denied, including UDP/TCP 53 to CoreDNS.
- **Fix:** `smoke-client-allow-dns`: egress from `app=smoke-client` to pods `k8s-app=kube-dns` in namespace `kube-system` (both selectors in one `to` entry, so they AND), UDP and TCP 53. TCP matters for large/truncated answers.
- **A finding worth reading:** without this rule, `verify.sh` still **passed 3 out of 3 times**. kube-router programs a new pod's firewall chain a few seconds after the pod starts, and the smoke Job's first lookup slips through in that window. curl then caches the answer. A probe pod proves the block is real:
  ```console
  # busybox pod in the troubleshoot namespace, no allow rule
  t0: resolved        # first lookup, before kube-router programmed the pod
  t8: FAILED          # same lookup 8 seconds later
  ```
  So the rule is required for correctness even though `verify.sh` alone can't tell. On Calico or Cilium, which program policy before the pod starts, the smoke test would fail with `curl: (6) Could not resolve host`.

### 10. The smoke client cannot open connections to `web`

- **Fix:** `smoke-client-allow-web`: egress from `app=smoke-client` to pods `app=web` on TCP 80. NetworkPolicy matches the pod port after Service DNAT, not the Service port (here both are 80).

### 11. `web` does not accept connections from the smoke client

- **Fix:** `web-allow-from-smoke-client`: ingress to `app=web` from `app=smoke-client` on TCP 80. Egress (10) and ingress (11) are enforced separately, on the source pod and on the destination pod, and both must allow.
- **Not needed:** a rule for kubelet probes. kube-router always accepts traffic to a pod from its own node (rule "permit the traffic to pods when source is the pod's local node" in the pod's firewall chain), so readiness kept working under default-deny.

## Result

```console
$ kubectl -n troubleshoot get netpol
NAME                          POD-SELECTOR       AGE
default-deny                  <none>             9m31s
smoke-client-allow-dns        app=smoke-client   0s
smoke-client-allow-web        app=smoke-client   24s
web-allow-from-smoke-client   app=web            24s

$ sh troubleshoot/verify.sh
[1/7] default-deny NetworkPolicy must still exist (deleting it is not a fix)...
[2/7] Node labels and taints must be untouched (fixing the nodes is not a fix)...
[3/7] Deployment 'web' must be fully rolled out...
[4/7] Deployment 'ai-inference' must be fully rolled out...
[5/7] ai-inference pod must be running ON the GPU node...
[6/7] Service must have ready endpoints...
[7/7] In-cluster smoke test through the Service...

PASS
```

## Notes on the provided scripts (the "imperfect handoff")

1. **`prepare.sh` assigns pools by node-name order** and treats any node whose `node-role.kubernetes.io/control-plane` label is empty as a worker. k3s sets that label to `"true"`, so it works here. kind (kubeadm) sets it to `""`, so on kind the control-plane node would be labeled spot. One more reason to use k3d.
2. **The k3s server node is schedulable and has no pool label.** It is a fifth node any pod can land on. The Part 2 chart therefore requires `acme.io/capacity In [spot, on-demand]`.
3. **`verify.sh` gives the smoke test 60s, including pulling `curlimages/curl`.** On a cold cache a correct fix can fail once, so `30-troubleshoot.sh` retries once.
4. **`verify.sh` step 5 reads the first `ai-inference` pod, including one still terminating.** Rerunning within ~30s of a wrong placement can falsely fail (busybox `sleep` ignores SIGTERM, so the old pod lingers for the full grace period).
5. **`verify.sh` cannot detect a missing DNS rule on k3s** (fault 9 above).
