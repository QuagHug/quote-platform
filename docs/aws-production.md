# quote-api in production on AWS (bonus)

This diagram shows how we would run quote-api in production, using the same patterns as the local harness: GitOps with ArgoCD, spot plus on-demand placement, and a tainted GPU pool. Solid arrows are request and data paths. Dotted arrows are control, delivery and telemetry paths.

```mermaid
flowchart TB
  user(["Users: web and mobile"])

  subgraph cf["Cloudflare"]
    cdn["DNS + CDN + WAF<br/>static assets cached, /api/* bypass"]
  end

  subgraph gh["GitHub"]
    gha["GitHub Actions<br/>test, SAST scan, build, push"]
    repo["Git repo<br/>Helm chart with image.tag"]
  end

  subgraph aws["AWS prod account"]
    alb["ALB in public subnets<br/>created by AWS Load Balancer Controller"]
    subgraph eks["EKS, 3 AZs"]
      subgraph sys["system pool"]
        ctrl["on-demand managed node group<br/>ArgoCD, Karpenter, External Secrets,<br/>AWS Load Balancer Controller"]
        otel["OpenTelemetry Collector"]
      end
      subgraph gen["general pool"]
        api["Karpenter NodePool: spot first, on-demand fallback<br/>quote-api pods: HPA min 3, PDB,<br/>at least 1 replica on on-demand"]
      end
      subgraph gpu["gpu pool"]
        infer["Karpenter NodePool, taint nvidia.com/gpu<br/>GPU inference pods only"]
      end
    end
    rds[("RDS PostgreSQL<br/>Multi-AZ")]
    redis[("ElastiCache Redis<br/>optional")]
    ecr["ECR<br/>quote-api:FULL_GIT_SHA"]
    sqs["SQS interruption queue<br/>EventBridge spot warnings"]
    sm["Secrets Manager"]
    subgraph obs["observability"]
      amp["Managed Prometheus<br/>rules + alert manager"]
      amg["Managed Grafana"]
      logs["CloudWatch Logs"]
      xray["X-Ray"]
      sns["SNS to PagerDuty / Slack"]
    end
  end

  user --> cdn
  cdn -->|"HTTPS, origin allows Cloudflare IPs only"| alb
  alb -->|"IP targets"| api
  api --> rds
  api -.-> redis

  gha -.->|"push image"| ecr
  gha -.->|"commit new image.tag"| repo
  ctrl -.->|"ArgoCD pulls chart, syncs"| repo
  ctrl -.->|"ArgoCD applies"| api
  api -.->|"image pull"| ecr
  ctrl -.->|"Karpenter reads"| sqs
  ctrl -.->|"ESO via Pod Identity"| sm

  api -.->|"OTLP, /metrics"| otel
  otel -.->|"remote write"| amp
  otel -.-> logs
  otel -.-> xray
  amg -.-> amp
  amp -.-> sns
```

## Notes on the choices

- **Edge.** Cloudflare stays in front, because the team already manages DNS and CDN for it in Terraform (Part 5b). It caches static assets and sends `/api/*` straight to the origin. The ALB security group allows only Cloudflare's published IP ranges, so nobody can reach the origin directly. Route 53 with CloudFront would be the all-AWS equivalent.
- **Ingress.** Only the ALB sits in public subnets. Nodes, RDS and ElastiCache sit in private subnets across 3 AZs. The AWS Load Balancer Controller turns the chart's Ingress into an ALB with IP targets. Traffic goes straight to pod IPs (the VPC CNI gives each pod a VPC address), with no NodePort hop.
- **Three node pools.**
  - **System pool:** a small on-demand managed node group for controllers. AWS best practice is to never run Karpenter on nodes it manages.
  - **General pool:** a Karpenter NodePool that prefers spot and falls back to on-demand. It spreads across many instance types to lower the chance of reclaims.
  - **GPU pool:** tainted `nvidia.com/gpu`, so only inference pods land there. It uses the same NodePool design as Part 5a.
- **Placement matches the local harness.** quote-api prefers spot, keeps at least one replica on on-demand, and uses soft spread across zones and hosts. This is the same rule that `scripts/25-reclaim-drill.sh` tests locally. A PDB keeps drains from taking too many replicas at once.
- **Spot reclaims are a non-event.** EventBridge sends the 2-minute spot warning to an SQS queue. Karpenter reads it, then cordons and drains the node before AWS takes it back. This is why reclaims do not page anyone (see OPS-ANSWERS Q2).
- **Data.** RDS PostgreSQL runs Multi-AZ, with a synchronous standby in another AZ and automatic failover. ElastiCache is optional and only worth adding if quote reads need caching. Today's quote-api is stateless, so both boxes describe the real service rather than the demo.
- **Secrets.** External Secrets Operator reads from Secrets Manager using EKS Pod Identity and writes a native Kubernetes Secret. Git only ever holds a reference to the secret. Database credentials rotate in Secrets Manager, and ESO picks up the change on its next refresh (see OPS-ANSWERS Q4).
- **GitOps delivery.** CI never talks to the cluster. GitHub Actions pushes an immutable image tagged with the full git SHA, then commits the new `image.tag` to the chart. ArgoCD in each cluster pulls that change and syncs it. To run several clusters, add an ApplicationSet. In production, ECR beats GHCR: pulls go through IAM and a VPC endpoint, and no registry credentials are needed. The take-home uses GHCR only because it is public and free.
- **Observability.** An OpenTelemetry Collector scrapes `/metrics` and receives traces. It sends metrics to Amazon Managed Prometheus (Grafana reads from it), logs to CloudWatch Logs, and traces to X-Ray. Alerts go through AMP's alert manager to SNS, because SNS is the only receiver that AMP's alert manager supports. A cheaper option at small scale is to self-host kube-prometheus-stack (the local Part 6 stack) plus Loki and Tempo.
- **Cost drivers.**
  - The EKS control plane costs $0.10 per cluster-hour on standard support, and $0.60 once a version falls into extended support.
  - Spot carries most of the stateless capacity.
  - VPC endpoints for ECR, S3 and STS keep image pulls and credential calls off the NAT gateways.
