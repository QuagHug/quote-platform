# quote-api on AWS (bonus)

The same patterns as the local harness, on EKS. Solid arrows are request and data paths; dotted arrows are control, delivery and telemetry.

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

- **Edge:** Cloudflare (Terraform, Part 5b) caches static assets and passes `/api/*` through. The ALB accepts only Cloudflare IP ranges, and everything else sits in private subnets across 3 AZs.
- **Nodes:** a small on-demand node group runs the controllers, since Karpenter should not run on nodes it manages. A Karpenter general pool prefers spot; the GPU pool is tainted and follows Part 5a. quote-api keeps the local placement: prefer spot, at least one replica on on-demand, soft spread, PDB.
- **Spot reclaims:** EventBridge puts the 2-minute warning on SQS and Karpenter drains the node before AWS takes it, so nobody is paged (OPS-ANSWERS Q2).
- **Delivery:** CI pushes a full-SHA image to ECR and commits the tag; ArgoCD syncs it, so CI never touches the cluster. ECR replaces GHCR in production for IAM pulls with no registry credentials.
- **Data and secrets:** RDS PostgreSQL Multi-AZ; ElastiCache only if reads need caching. ESO syncs from Secrets Manager using Pod Identity (OPS-ANSWERS Q4).
- **Observability and cost:** an OpenTelemetry Collector sends metrics to Managed Prometheus (alerts via SNS, its only receiver), logs to CloudWatch and traces to X-Ray. Self-hosted kube-prometheus-stack with Loki and Tempo is cheaper at small scale. EKS costs $0.10 per cluster-hour ($0.60 on extended support); VPC endpoints keep image pulls off NAT.
