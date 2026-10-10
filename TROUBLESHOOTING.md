# Part 3: Troubleshooting

`broken-app.yaml` has **11 faults**. They hide behind each other, so they show up one layer at a time: scheduling, volume, image, probes, Service, network. The fixes are in `troubleshoot/fixed-app.yaml` (marked `FIX n`). `default-deny` stays, and no node was touched.

Starting point: all three pods `Pending`, and `verify.sh` fails at `[3/7] deployment/web is not ready`.

## Layer 1: scheduling

**1. web asks for 16Gi of memory**
- Symptom: `web` Pending.
- Diagnose: `kubectl -n troubleshoot get events | grep web` shows `0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 Insufficient memory`. `kubectl get nodes -o custom-columns=NAME:.metadata.name,MEM:.status.allocatable.memory` shows about 9.7Gi per node.
- Cause: requests and limits of `16Gi` fit no node.
- Fix: 32Mi request, 128Mi limit.

**2. ai-inference selects a label that doesn't exist**
- Symptom: `ai-inference` Pending, `4 node(s) didn't match Pod's node affinity/selector`.
- Diagnose: `kubectl get nodes -L acme.io/node-type` shows the label is `acme.io/node-type`, not `node-type`.
- Fix: `nodeSelector: {acme.io/node-type: gpu}`.

**3. ai-inference doesn't tolerate the GPU taint**
- Symptom: after fix 2 the event text was **unchanged**. The GPU node still counts as "untolerated taint", because the scheduler checks taints before the selector.
- Diagnose: `kubectl get node -l acme.io/node-type=gpu -o jsonpath='{.spec.taints}'` returns `nvidia.com/gpu=true:NoSchedule`.
- Fix: add that toleration. The pod then runs on `k3d-quote-agent-3`.

## Layer 2: volume

**4. Wrong ConfigMap name**
- Symptom: `web` stuck in `ContainerCreating`.
- Diagnose: `kubectl -n troubleshoot get events --field-selector reason=FailedMount` shows `configmap "web-conf" not found`. `kubectl -n troubleshoot get cm` shows `web-config`.
- Fix: `configMap.name: web-config`. The kubelet mounts volumes before it pulls the image, so this hid fault 5.

## Layer 3: image

**5. `nginx:1.25.99` does not exist**
- Symptom: `ImagePullBackOff`, with `docker.io/library/nginx:1.25.99: not found`.
- Fix: `nginx:1.30`, the current stable line.

## Layer 4: probes

**6. Probes hit 8080, nginx listens on 80**
- Symptom: `0/1 Running`, restarts, and `Readiness probe failed: ... dial tcp 10.42.4.5:8080: connect: connection refused`.
- Diagnose: `kubectl -n troubleshoot exec deploy/web -- grep -m1 listen /etc/nginx/conf.d/default.conf` shows `listen 80;`.
- Fix: name the port `http` and point both probes at it.

## Layer 5: Service

**7. Selector `app: webapp`, pods are `app: web`**
- Symptom: `verify.sh [6/7]`: no endpoints.
- Diagnose: `kubectl -n troubleshoot get endpointslices -l kubernetes.io/service-name=web-svc` is empty, and `kubectl -n troubleshoot get svc web-svc -o jsonpath='{.spec.selector}'` returns `{"app":"webapp"}`.
- Fix: `selector: {app: web}`.

**8. targetPort 8080**
- Symptom: step 6 passes, but the endpoints list port `8080`, and step 7 fails: `curl: (7) Failed to connect to web-svc... port 80: Couldn't connect to server`.
- Fix: `targetPort: http`.

## Layer 6: network

After fix 8, step 7 failed with **the same curl error**. On k3s, kube-router rejects blocked packets instead of dropping them, so a policy block looks exactly like a wrong port. `kubectl -n troubleshoot get netpol` shows only `default-deny`, which blocks ingress and egress for every pod.

**9. Smoke client can't reach DNS.** Fix: egress from `app=smoke-client` to `k8s-app=kube-dns` in `kube-system` on UDP and TCP 53.
- `verify.sh` passed 3 times out of 3 **without** this rule: kube-router enforces policy on a new pod a few seconds after it starts, and curl caches the first lookup.
- A probe pod shows the block is real: lookup at t=0 `resolved`, at t=8s `FAILED`. On Calico or Cilium it would fail immediately.

**10. Smoke client can't connect to web.** Fix: egress from `app=smoke-client` to `app=web` on TCP 80. Policies see the pod port after Service DNAT.

**11. web doesn't accept the smoke client.** Fix: ingress to `app=web` from `app=smoke-client` on TCP 80. Egress and ingress are checked separately, so both rules are needed.

Probes need no rule, because kube-router always allows traffic from a pod's own node.

## Result

```console
$ kubectl -n troubleshoot get netpol
default-deny                  <none>
smoke-client-allow-dns        app=smoke-client
smoke-client-allow-web        app=smoke-client
web-allow-from-smoke-client   app=web
$ sh troubleshoot/verify.sh
...
[7/7] In-cluster smoke test through the Service...
PASS
```

## Notes on the provided scripts

1. `prepare.sh` assigns pools by node-name order and treats an empty control-plane label as a worker. That works on k3s, but on kind the control-plane node would be labeled spot.
2. The k3s server is a schedulable fifth node with no pool label.
3. `verify.sh` gives the smoke test 60s including the image pull, so `30-troubleshoot.sh` retries once.
4. `verify.sh` can't detect a missing DNS rule on k3s (fault 9).
