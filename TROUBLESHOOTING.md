# Troubleshooting (Part 3)

11 faults, fixed in [`troubleshoot/fixed-app.yaml`](troubleshoot/fixed-app.yaml) (`FIX n` markers). `default-deny` kept, nodes untouched. Each fault hid the next, so they appeared layer by layer.

Start: all pods `Pending`, `verify.sh` fails at `[3/7]` (web rollout).

| # | Symptom | Diagnosed with | Cause | Fix |
|---|---|---|---|---|
| 1 | web `Pending`: `4 Insufficient memory` | `kubectl -n troubleshoot get events`; `kubectl get nodes -o custom-columns=NODE:.metadata.name,MEM:.status.allocatable.memory` shows ~9.7Gi | requests 16Gi | 32Mi / 128Mi |
| 2 | ai-inference `Pending`: `didn't match node affinity/selector` | `kubectl get nodes -L acme.io/node-type` | selector key `node-type` | `acme.io/node-type: gpu` |
| 3 | Same message after fix 2 | `kubectl get node -l acme.io/node-type=gpu -o jsonpath='{.spec.taints}'` | no toleration; taints are checked before the selector | tolerate `nvidia.com/gpu=true:NoSchedule` |
| 4 | web `ContainerCreating`: `configmap "web-conf" not found` | `kubectl -n troubleshoot get events --field-selector reason=FailedMount` | wrong ConfigMap name (hid fault 5: kubelet mounts volumes before pulling images) | `web-config` |
| 5 | `ImagePullBackOff`: `nginx:1.25.99: not found` | `kubectl -n troubleshoot get events` | tag doesn't exist | `nginx:1.30` |
| 6 | `0/1 Running`, restarts: probe `dial tcp ...:8080: connection refused` | `kubectl -n troubleshoot exec deploy/web -- grep listen /etc/nginx/conf.d/default.conf` shows `listen 80` | probes on 8080 | named port `http` |
| 7 | `[6/7]` no endpoints | `kubectl -n troubleshoot get endpointslices -l kubernetes.io/service-name=web-svc` empty; selector `{"app":"webapp"}` | wrong selector | `app: web` |
| 8 | `[7/7]` `curl: (7) ... Couldn't connect to server` | same as 7: endpoints on port 8080 | targetPort 8080 | `targetPort: http` |
| 9 | None: `verify.sh` passes without it (see Notes) | `kubectl -n troubleshoot run dnsprobe --rm -i --image=busybox:1.36 -- sh -c 'nslookup web-svc.troubleshoot.svc.cluster.local; sleep 8; nslookup web-svc.troubleshoot.svc.cluster.local'`: works at t=0, fails at t=8s | default-deny blocks DNS | egress from smoke-client to kube-dns, UDP+TCP 53 |
| 10 | Same curl error as fault 8 | `kubectl -n troubleshoot describe netpol default-deny`: policy types Ingress and Egress, no allow rules | smoke-client egress to web blocked | egress from smoke-client to web, TCP 80 |
| 11 | Still the same error after fix 10 | `kubectl -n troubleshoot get netpol`: no policy allows ingress to `app=web` | web ingress blocked | ingress to web from smoke-client, TCP 80 |

## Notes

- **Policy blocks look like a wrong port.** k3s's policy agent (kube-router) rejects blocked packets instead of dropping them, so faults 8, 10 and 11 all show the same curl error.
- **Fault 9 is invisible to `verify.sh`.** It passed 3 runs of 3 without the DNS rule: kube-router programs a new pod's policy a few seconds late and curl caches the first lookup. The test pod proves the block; Calico or Cilium would fail at once.
- **Probes need no rule:** kube-router always allows traffic from the pod's own node.
- **Policies match the pod port** after Service DNAT, not the Service port.
- **`verify.sh` allows 60 s including the image pull**, so `30-troubleshoot.sh` retries once.

## Result

Full output from a fresh-clone run: [`docs/evidence/verify.txt`](docs/evidence/verify.txt).

```console
$ sh troubleshoot/verify.sh
[1/7] default-deny NetworkPolicy must still exist ...
[7/7] In-cluster smoke test through the Service...
PASS
```
