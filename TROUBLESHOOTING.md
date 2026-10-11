# Troubleshooting (Part 3)

11 faults, fixed in [`troubleshoot/fixed-app.yaml`](troubleshoot/fixed-app.yaml) (`FIX n` markers). `default-deny` kept, nodes untouched. Each fault hid the next, so they appeared layer by layer.

Start: all pods `Pending`, `verify.sh` fails at `[3/7]`.

| # | Symptom | Diagnosed with | Cause | Fix |
|---|---|---|---|---|
| 1 | web `Pending`: `4 Insufficient memory` | `kubectl -n troubleshoot get events`; node allocatable ~9.7Gi | requests 16Gi | 32Mi / 128Mi |
| 2 | ai-inference `Pending`: `didn't match node affinity/selector` | `kubectl get nodes -L acme.io/node-type` | selector key `node-type` | `acme.io/node-type: gpu` |
| 3 | Same message after fix 2 | `kubectl get node -l acme.io/node-type=gpu -o jsonpath='{.spec.taints}'` | no toleration; taints are checked before the selector | tolerate `nvidia.com/gpu=true:NoSchedule` |
| 4 | web `ContainerCreating`: `configmap "web-conf" not found` | `kubectl -n troubleshoot get events --field-selector reason=FailedMount` | wrong ConfigMap name (hid fault 5: mount happens before pull) | `web-config` |
| 5 | `ImagePullBackOff`: `nginx:1.25.99: not found` | events | tag doesn't exist | `nginx:1.30` |
| 6 | `0/1 Running`, restarts: probe `dial tcp ...:8080: connection refused` | `kubectl exec deploy/web -- grep listen /etc/nginx/conf.d/default.conf` → `listen 80` | probes on 8080 | named port `http` |
| 7 | `[6/7]` no endpoints | `kubectl get endpointslices -l kubernetes.io/service-name=web-svc` empty; selector `{"app":"webapp"}` | wrong selector | `app: web` |
| 8 | `[7/7]` `curl: (7) ... Couldn't connect to server` | endpoints show port 8080 | targetPort 8080 | `targetPort: http` |
| 9 | (see note) | probe pod: DNS works at t=0, fails at t=8s | default-deny blocks DNS | smoke-client → kube-dns, UDP+TCP 53 |
| 10 | Same curl error as fault 8 | `kubectl -n troubleshoot get netpol` shows only `default-deny` | egress to web blocked | smoke-client → web, TCP 80 |
| 11 | Same | same | ingress to web blocked | web ← smoke-client, TCP 80 |

## Notes

- **Policy blocks look like a wrong port.** k3s (kube-router) rejects blocked packets, so faults 8, 10 and 11 all show the same curl error.
- **Fault 9 is invisible to `verify.sh`.** It passed 3/3 without the DNS rule: kube-router programs a new pod's policy a few seconds late and curl caches the first lookup. The probe pod proves the block; Calico or Cilium would fail at once.
- **Probes need no rule:** kube-router always allows traffic from the pod's own node.
- **Policies match the pod port** after Service DNAT, not the Service port.

## Result

```console
$ sh troubleshoot/verify.sh
[1/7] ... [7/7] In-cluster smoke test through the Service...
PASS
```

## Provided-script caveats

- `prepare.sh` assigns pools by node-name order; on kind it would label the control-plane as spot.
- `verify.sh` allows 60s including the image pull, so `30-troubleshoot.sh` retries once.
