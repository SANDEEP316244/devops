# Application Load Balancers, Listeners, Target Groups, and Targets — A Deep Dive

**A technical reference for the AWS ALB control plane and data plane**

This document explains the moving parts of an AWS Application Load Balancer in enough detail to support real decisions — debugging a 502, deciding whether a target group is safe to delete, designing a blue/green rollout, choosing between path-based and host-based routing. It assumes you have used an ALB at least once. It does not assume you know how AWS stores the relationships between these objects, why some "idle" things are not actually idle, or what the listener really does when a request arrives.

The goal is twofold: a junior engineer should be able to read this end-to-end and walk away with a coherent mental model; a senior engineer should be able to skim it and find the corners they only half-remembered — weighted forwards, mutual TLS, ALB-as-target, target health states, draining behaviour.

---

## 1. Why this layer exists at all

Before the cloud, load balancers were a single appliance with a single configuration: a virtual IP, a pool of backend servers, and a health-check definition. You added servers to the pool, you took them out, you tuned the health check. That was the whole model.

The AWS Application Load Balancer breaks that single object into five distinct resources that can be created, modified, and deleted independently:

1. The **Load Balancer** itself — a network appliance that AWS runs in multiple Availability Zones, gives a DNS name, attaches to subnets, and protects with a Security Group.
2. **Listeners** — port-and-protocol entry points on the load balancer (`HTTP:80`, `HTTPS:443`, `HTTPS:8443`, etc.). A listener owns the TLS termination, the certificate, and the routing logic.
3. **Listener Rules** — conditional routing inside a single listener. A rule is "if the request matches X, do Y".
4. **Target Groups** — addressable backend pools. A target group is a collection of registered backends plus a health check definition, plus a protocol and port that the load balancer uses to reach them.
5. **Targets** — the actual backends: an EC2 instance ID, an IP address (typically belonging to an ECS task or another ENI), a Lambda function ARN, or even another ALB.

Each of these can live without the others. You can have a target group with no registered targets, a load balancer with no listeners, a listener with no rules, a target group attached to multiple listeners on multiple load balancers. The looseness is a feature — it lets infrastructure-as-code provision pieces in any order. But the looseness is also why "is this thing in use?" requires walking the whole chain rather than reading a single attribute.

---

## 2. The hierarchy, drawn

```
              ┌─────────────────────────────────────────────────────────┐
              │   Application Load Balancer                             │
              │   • DNS:    my-alb-1234567890.ap-south-1.elb.amazonaws  │
              │   • Scheme: internet-facing / internal                  │
              │   • Subnets: at least 2 AZs                             │
              │   • Security Group: controls who can reach the ALB      │
              │   • Itself has no routing logic                         │
              └────────┬────────────────────────────────────────────────┘
                       │  has 1..N
                       ▼
              ┌─────────────────────────────────────────────────────────┐
              │   Listener  (e.g., HTTPS:443)                           │
              │   • Protocol + Port                                     │
              │   • TLS: cert(s), security policy, mTLS settings        │
              │   • Default Action: where unmatched traffic goes        │
              │   • Has 0..N Rules                                      │
              └────────┬────────────────────────────────────────────────┘
                       │  has 0..N (in addition to its default)
                       ▼
              ┌─────────────────────────────────────────────────────────┐
              │   Rule  (priority N)                                    │
              │   • Conditions:  host / path / header / method / source │
              │   • Actions:     forward / redirect / fixed-response /  │
              │                  authenticate-cognito / -oidc           │
              │   • First-match wins; default action fires otherwise    │
              └────────┬────────────────────────────────────────────────┘
                       │  forward action references
                       ▼
              ┌─────────────────────────────────────────────────────────┐
              │   Target Group                                          │
              │   • Protocol + Port the ALB uses to reach targets       │
              │   • Target type: instance / ip / lambda / alb           │
              │   • Health check: protocol, path, codes, intervals      │
              │   • Attributes: stickiness, deregistration delay, etc.  │
              │   • LoadBalancerArns: which LBs reference this TG       │
              └────────┬────────────────────────────────────────────────┘
                       │  has 0..N
                       ▼
              ┌─────────────────────────────────────────────────────────┐
              │   Registered Target                                     │
              │   • Identity:  i-xxx / 10.0.5.42 / arn:lambda:... / arn:elb:... │
              │   • Port (target_type=instance can have per-target port)│
              │   • Health: initial / healthy / unhealthy / draining /  │
              │             unused                                      │
              └─────────────────────────────────────────────────────────┘
```

A single request walks the diagram top to bottom. The load balancer is the entry point; the listener decides which routing logic to use based on the TCP port that received the connection; the rules are evaluated in priority order until one matches; the matched rule names a target group; the target group picks one healthy target (using stickiness or round-robin); the target processes the request and returns a response back up the chain.

If you remember nothing else from this section, remember this: **the load balancer does no routing. The listener does the routing. The target group is a pool. The target is a backend.** Most confusion in this area comes from imagining the load balancer "owns" the routing logic. It does not. The listener owns it.

---

## 3. The data model — how AWS stores these things

Each of the five entities has its own ARN and lifecycle. AWS exposes the relationships through three mechanisms:

**Containment.** A listener belongs to exactly one load balancer (`LoadBalancerArn`). A rule belongs to exactly one listener (`ListenerArn`). These are owned-by relationships and they are immutable: you cannot detach a listener from one ALB and attach it to another. To "move" it, you create a new one on the destination ALB and delete the old.

**Reference.** A rule action *references* a target group by ARN. A listener's default action also references a target group by ARN. The target group itself is a free-standing object — it is not "inside" any listener. This is what makes target groups reusable: the same target group can be referenced by multiple listeners across multiple load balancers in the same account and region.

**Reverse reference.** Because target groups are referenced by listeners, AWS maintains a reverse pointer on the target group: `LoadBalancerArns`. This is computed, not stored. When you call `DescribeTargetGroups`, AWS returns the current list of load balancers whose listeners (default actions or rule actions) forward to this TG. If you delete the rule that referenced the TG, `LoadBalancerArns` becomes empty on the next describe.

The reverse pointer is the single most useful field for understanding "what is this TG attached to". It also has a precise definition that surprises people:

- A forward action with weight 0 still counts.
- A listener whose default action forwards to the TG counts.
- A rule whose forward action references the TG counts.
- A TG referenced only by an *authenticate-cognito → forward* compound action still counts.

A target group whose `LoadBalancerArns` list is empty is a *true orphan*: no listener default action and no listener rule anywhere references it. Deleting an orphan TG cannot break any load balancer, because no load balancer points at it.

---

## 4. Listeners in depth

A listener represents one (protocol, port) pair on the load balancer. Most ALBs have either one listener on HTTPS:443 with an HTTP:80 listener that redirects to it, or — for internal services — one listener on HTTP:80. You can have up to fifty listeners on a single ALB.

### 4.1 Protocols

ALBs support `HTTP` and `HTTPS` listeners. They terminate TLS on `HTTPS` listeners: the connection from the client to the ALB is encrypted, and the connection from the ALB to the target is whatever the *target group* protocol is (`HTTP` or `HTTPS`). It is normal for an `HTTPS:443` listener to forward to an `HTTP:8080` target group — the ALB decrypts on ingress and talks to the backend in plaintext over the VPC. (Network Load Balancers and Gateway Load Balancers use different listener semantics and are not covered here.)

### 4.2 TLS termination

An `HTTPS` listener requires at least one certificate. You can attach multiple certificates to the same listener; the ALB selects which to present using Server Name Indication (SNI) — the client tells the ALB which hostname it is asking for, and the ALB picks the matching certificate. This is what lets a single listener serve `*.example.com`, `app.different.com`, and `legacy.thirdparty.org` from the same port. The ALB also honours a **security policy**, which is the bundle of TLS protocol versions and cipher suites it will negotiate. `ELBSecurityPolicy-2016-08` is the long-standing default; modern systems should be on `ELBSecurityPolicy-TLS13-1-2-2021-06` or newer to disable weak ciphers.

For services that need to verify the client's identity, **mutual TLS (mTLS)** is configurable at the listener level: the ALB asks the client for a certificate, validates it against a configured trust store (a bundle of CAs you upload), and either passes the client certificate through to the backend in a header or rejects the request. This replaces ad-hoc API key schemes for service-to-service traffic.

### 4.3 Default action

Every listener has exactly one default action. This is what fires when none of the listener's rules match. The default action can be any of:

- **forward** — send the request to one target group (the common case) or split traffic between several target groups with weights (the canary / blue-green case).
- **redirect** — send a `301`/`302` to a different URL, optionally rewriting host, path, query, port, or protocol. Universally used for the HTTP:80 → HTTPS:443 redirect.
- **fixed-response** — return a status code and a short body without forwarding. Useful as a polite "this host has moved" or as a strict-router catch-all (`404 Not Found` for any unrecognised host header).
- **authenticate-cognito** / **authenticate-oidc** — perform OAuth/OIDC authentication at the load-balancer layer before forwarding. The user is redirected to the identity provider, the ALB sets a session cookie, and the actual backend never sees unauthenticated traffic.

The default action matters more than people expect during cleanup. An ALB whose only listener defaults to `fixed-response 404` is acting as a strict router: it serves only the host headers explicitly named in its rules. An ALB whose default is `forward → some_tg` is a generic dispatcher: any request that does not match a specific rule still reaches the catch-all backend. The same ALB with the same set of rules can be either, depending on how the default action is configured. Read the default action first when triaging a "what does this ALB actually do" question.

### 4.4 Listener rules

A rule has three parts: a priority (1 to 50000, lower wins), a set of conditions, and a set of actions. The listener evaluates rules in priority order; the first rule whose conditions all match has its actions executed. If no rule matches, the default action fires.

The conditions you can use are:

- **host-header** — the `Host` header sent by the client. Up to five values per rule, with one wildcard each. `*.api.example.com` matches `v1.api.example.com` and `v2.api.example.com` but not `api.example.com`.
- **path-pattern** — the URL path. Supports `*` and `?` wildcards. `/v1/users/*` matches `/v1/users/123` and `/v1/users/123/profile`.
- **http-header** — any other request header, including custom ones. Useful for routing based on `X-Tenant-Id` or `User-Agent`.
- **query-string** — key/value pairs in the URL query. Useful for A/B tests gated by a flag.
- **http-request-method** — `GET`, `POST`, etc. Useful for separating read and write traffic to different backends.
- **source-ip** — CIDR-based, supports both IPv4 and IPv6. Useful for restricting admin paths to office networks.

A rule can have multiple conditions; all of them must match (logical AND across condition types). Inside a single condition type, multiple values are OR'd (e.g., five host-headers in a `host-header` condition match if any one matches).

The actions a rule can take are the same set as the listener default action: `forward`, `redirect`, `fixed-response`, `authenticate-cognito`, `authenticate-oidc`. A rule can chain authentication before forwarding ("authenticate, then forward to TG"). The order in the action list matters: ALB executes them sequentially, and a forward must always be the last action.

Rules are how a single ALB serves many services. A typical pattern is:

```
Listener HTTPS:443  (default: fixed-response 404)
├── priority 10:  host=api.example.com,       path=/v1/*           → forward → api-v1-tg
├── priority 20:  host=api.example.com,       path=/v2/*           → forward → api-v2-tg
├── priority 30:  host=admin.example.com,     source-ip=10.0.0.0/8 → forward → admin-tg
├── priority 40:  host=admin.example.com                            → fixed-response 403
└── priority 50:  host=static.example.com                           → redirect → cdn.example.com
```

This is one ALB serving three hostnames, two API versions, and a tightened access-list on `admin.example.com` where a stricter rule (priority 30) appears before a fallback (priority 40). Priority order matters: if you swapped 30 and 40, the admin path would return 403 to everyone.

---

## 5. Target groups in depth

A target group is a backend pool plus a health check. It is the unit of "which backends serve this slice of traffic". A typical service has one target group per (deployment slot × API version) — so a blue/green API v1 has `api-v1-blue` and `api-v1-green`; an API gateway pattern with five microservices behind one ALB has five target groups.

### 5.1 Target type

The target group's `target_type` field is set at creation time and cannot be changed afterwards. Four values exist:

- **instance** — registers EC2 instance IDs. The ALB resolves the instance's primary network interface to find an IP, then sends traffic to it. Works only for instances in the same VPC. Cannot be used for ECS tasks running in `awsvpc` mode (those need `ip`). Health checks run against the instance's primary IP at the configured port.
- **ip** — registers IP addresses directly. Works for EC2 instances in any VPC the ALB can reach (peered VPC, transit-gateway-attached VPC, on-premises via Direct Connect), and is the *only* target type supported by ECS tasks running with their own ENI in `awsvpc` mode. The IP must be a routable IP from the ALB's VPC.
- **lambda** — registers a Lambda function ARN. The ALB invokes the Lambda synchronously per request, with the request body packaged as a JSON event. Health checks for Lambda target groups are special: the ALB invokes the function once with a health-check payload and treats a successful invocation as healthy. There is no port; there is no IP.
- **alb** — registers another ALB. This is for the "Network Load Balancer in front of Application Load Balancer" pattern, where an NLB provides a static IP and forwards to an ALB-typed target group whose target is the actual ALB. The ALB-as-target pattern is also used for cross-account routing where one team's ALB needs to forward to another team's ALB without exposing the internal one publicly.

### 5.2 Protocol and port

The target group has its own protocol and port, separate from the listener. The ALB will translate from the listener's protocol/port to the target group's. A common pattern is `HTTPS:443` listener → `HTTP:8080` target group: TLS terminates at the ALB; the backend speaks plaintext HTTP on port 8080. Another common pattern is `HTTPS:443` listener → `HTTPS:8443` target group when the backend must do TLS itself for compliance or end-to-end-encryption reasons. The third pattern, `HTTP:80` listener → `HTTP:80` target group, is fine for internal services where TLS is not required.

### 5.3 Health checks

The health check is what tells the ALB which targets are eligible to receive traffic. Without a passing health check, a target stays in the `initial` or `unhealthy` state and the ALB will not send it any requests. The health check has its own protocol and path (often the same as the target group's, but not required to be): `HTTP GET /healthz` returning `200` is the default for HTTP target groups.

The key tunables:

- **HealthCheckIntervalSeconds** — how often the ALB probes (default 30 for instance/IP, 35 for Lambda).
- **HealthyThresholdCount** — how many consecutive successes before marking a target healthy (default 5).
- **UnhealthyThresholdCount** — how many consecutive failures before marking a target unhealthy (default 2 for ALB; was 5 in older versions).
- **HealthCheckTimeoutSeconds** — how long the ALB waits for a response (default 5).
- **Matcher** — which HTTP status codes count as success. Defaults to `200`. Can be a range (`200-299`) or comma-separated list.

The default settings mean: for a fresh target to become healthy and receive traffic, it must pass five consecutive `200` responses spaced 30 seconds apart. That is two and a half minutes from "registered" to "in rotation". This matters for blue/green deployments — a deploy is not "live" the moment the new TG is registered with the listener rule; it is live two and a half minutes later when the new targets pass health checks. Tune `HealthyThresholdCount` down to 2 or 3 if you need faster cutover and you trust your backend's startup.

The unhealthy threshold and interval also determine the **outage detection latency**: with default settings, the ALB will keep sending traffic to a target for up to a minute (`2 × 30s`) after it stops responding before declaring it unhealthy. Set `UnhealthyThresholdCount=2` and `HealthCheckIntervalSeconds=10` if you need faster failover, at the cost of higher health-check traffic on the backend.

### 5.4 Target group attributes

These are tunables that live on the target group, not on the listener. The important ones:

- **deregistration_delay.timeout_seconds** — how long the ALB keeps sending traffic to a target that has been *deregistered* but still has in-flight requests. This is the "drain time". Default is 300 seconds (5 minutes). Set lower for fast deployments where you do not care about long-running requests; set higher for backends serving file downloads or streaming responses. While draining, the target's state is `draining`.
- **stickiness.enabled** + **stickiness.lb_cookie.duration_seconds** — session stickiness. The ALB issues a cookie (`AWSALB`) and routes subsequent requests with that cookie to the same target. Useful for stateful backends; harmful for stateless ones because it concentrates traffic.
- **slow_start.duration_seconds** — when a new target becomes healthy, the ALB ramps its traffic share from zero to full over this many seconds. Lets new pods warm caches before facing full load. Default 0 (disabled). Not compatible with stickiness.
- **load_balancing.algorithm.type** — `round_robin` (default), `least_outstanding_requests`, or `weighted_random`. The second is what you usually want for backends with variable per-request cost; it routes new requests to the target with the fewest in-flight requests, automatically smoothing over straggler targets.
- **target_failover.on_deregistration** / **on_unhealthy** — only for NLB; ignored on ALB target groups.

### 5.5 Cross-zone load balancing

ALBs always have cross-zone load balancing enabled — that is, the ALB distributes traffic evenly to all healthy targets regardless of which AZ they are in. (NLBs default to off; you must opt in.) This means an ALB with one healthy target in `ap-south-1a` and zero in `ap-south-1b` will still serve traffic — it routes everything to the one healthy target. The cost is cross-AZ data transfer charges if the target is in a different AZ from the ALB node that received the connection.

---

## 6. Targets in depth

A target is one entry in a target group's pool: one instance, one IP, one Lambda, one ALB. A target group can hold up to 1000 targets (default 100, raisable).

### 6.1 Health states

A target has one of seven health states:

- **initial** — registered but not yet probed enough times to be marked healthy. New targets start here.
- **healthy** — passed `HealthyThresholdCount` consecutive checks. Receives traffic.
- **unhealthy** — failed `UnhealthyThresholdCount` consecutive checks. Does not receive traffic. The ALB still probes it; if it recovers, it will re-enter `healthy` after passing the healthy threshold.
- **unused** — registered but never probed. Happens when a target was registered but the target group has no associated load balancer (orphan TG). Once attached to an LB, the target will move to `initial`.
- **draining** — currently being deregistered. Receives no new requests; the ALB continues to forward existing connections until the deregistration delay elapses, at which point the target is removed from the group.
- **unavailable** — Lambda function returned an error to the health check, or the target is in an unreachable network state. Special semantics for Lambda target groups.
- **healthy via target health overrides** — only relevant to NLB, ignore on ALB.

The most common confusion is between `initial` and `unhealthy`. `initial` means "we have not finished evaluating yet" — wait one health-check cycle. `unhealthy` means "we evaluated and the target failed" — fix the backend.

### 6.2 Registration semantics

Registering a target is an idempotent operation: registering the same target twice is a no-op (or fails with `TargetAlreadyRegistered` depending on API version). Deregistration moves the target to `draining` and then removes it once the drain timeout elapses. While draining, you can re-register the target; it skips back to `initial` without finishing the drain.

Targets can be registered with a port override (e.g., target group port is 80, but this specific instance listens on 8080). This is useful when running multiple replicas of a service on different ports on the same instance, but is rare in practice — most modern deployments use ECS or Kubernetes, where each task has its own IP and port, and the target group port is the canonical one.

### 6.3 ECS service integration

When an ECS service is configured to register with a target group, ECS owns the registration/deregistration lifecycle. You do not register tasks manually; ECS does it as tasks start, and deregisters as tasks stop. This means:

- If you delete the ECS service, ECS deregisters all its tasks and the target group becomes empty within seconds.
- If you scale the ECS service to zero, the same thing happens — targets disappear.
- If you change the target group ARN on the ECS service (rolling update), ECS deregisters old tasks from the old TG and registers new tasks to the new TG. This is what AWS CodeDeploy does under the hood for blue/green ECS deployments.

A target group with zero targets, behind an active ALB, in an ECS-backed environment, often means: *the ECS service is scaled to zero right now*. UAT and dev environments are often scheduled off at night and on weekends; their target groups go empty during those hours and re-fill on Monday morning. This is a classic false positive for cleanup.

---

## 7. The LoadBalancerArns join — why it matters

Earlier we said: a target group's `LoadBalancerArns` field is the reverse pointer maintained by AWS that lists every load balancer whose listeners reference the TG. This is worth examining more carefully because it is the single most useful field for reasoning about cleanup.

When you call `DescribeTargetGroups`, every TG comes back with a `LoadBalancerArns` array. The array is populated by AWS scanning every listener default action and every rule action in the account/region looking for references to this TG's ARN. If any reference exists — including a forward action with weight 0, including a compound `authenticate-then-forward` action — the LB's ARN appears in the array.

Practically:

```
TG.LoadBalancerArns = []        →  No listener anywhere forwards to this TG.
                                   Deleting the TG cannot break any LB.
                                   This is a true orphan.

TG.LoadBalancerArns = [arn1]    →  Exactly one LB forwards to this TG.
                                   Deleting the TG will cause that LB to
                                   serve 503s on whichever rule referenced it.

TG.LoadBalancerArns = [a, b, c] →  Three LBs forward to this TG (rare but
                                   legal — common in multi-env setups
                                   sharing a backend pool, or in
                                   misconfigured copy-paste IaC).
```

The reverse pointer is computed, not stored. There is no "attach TG to LB" API call — attachment is implicit through listener rule actions. To "detach" a TG from a LB, you delete or modify every listener rule (and default action) on that LB that references the TG. The next describe will show the LB has vanished from the TG's `LoadBalancerArns`.

This data model has one subtle implication: a target group with `LoadBalancerArns = []` cannot serve any traffic, but it can still have registered targets. The targets sit in the `unused` state. This is a sign of stale infrastructure — usually a listener rule was deleted but the target group and its targets were forgotten. It is safe to delete; the targets will simply be deregistered.

---

## 8. Weighted forwards: the canary and blue-green case

A forward action does not have to point at a single target group. It can list up to five target groups with explicit weights and a "stickiness duration" that pins a single client to whichever TG they were routed to on their first request. The ALB distributes traffic across the listed TGs proportional to their weights:

```
forward:
  target_groups:
    - tg_arn: arn:.../prod-blue
      weight: 90
    - tg_arn: arn:.../prod-green
      weight: 10
  stickiness:
    enabled: true
    duration_seconds: 3600
```

This produces a 90/10 canary split: 90% of new requests go to blue, 10% to green, and any individual client stays on whichever side they hit first for an hour. To roll forward, you adjust the weights — `80/20`, `50/50`, `0/100` — and finally swap the rule to point only at green. This is the entire mechanism behind blue/green deployments managed by AWS CodeDeploy: it programmatically rewrites the weights on the listener rule's forward action over the duration of a deploy.

Two consequences for cleanup:

- A target group with weight 0 in a weighted forward still appears in the TG's `LoadBalancerArns`. It is "attached" even though no traffic flows to it. Deleting it requires first removing it from the weighted action.
- During a deployment, the "off" side of blue/green typically has zero targets (because the ECS service has been redeployed there but not yet warmed up, or because the previous deploy's tasks have been stopped). Seeing an empty TG behind a listener with another TG carrying traffic is the *expected* state mid-deploy, not a cleanup opportunity.

Naming conventions help here. AWS CodeDeploy creates target groups with names like `BlueTgI-XXXX` and `GreenT-XXXX`; CloudFormation-driven blue/green creates `*-Green-*` and `*-Blue-*`. Treat any TG name that pattern-matches blue/green hints as a deployment artifact, not a deletion candidate, unless you can confirm the deployment pipeline is no longer in use.

---

## 9. The actions, in detail

Every routing decision an ALB makes ultimately reduces to one of these five actions. Knowing them is core literacy.

**forward.** Send the request to one or more target groups. The single-TG case is the common one. The multi-TG case is the weighted-forward (canary/blue-green) case. The forward action is the only one that interacts with target groups — all the other actions terminate the request at the ALB.

**redirect.** Return an HTTP redirect response (`301` or `302`) to a new URL constructed from a template. The template can substitute `#{host}`, `#{path}`, `#{query}`, `#{protocol}`, and `#{port}` from the incoming request. The canonical use is the HTTP-to-HTTPS redirect on port 80: `redirect to https://#{host}:443/#{path}?#{query}, code 301`. Other uses: redirecting a deprecated host to a successor, or sending traffic to a CDN for static paths.

**fixed-response.** Return a status code (any 2xx, 4xx, or 5xx), an optional short body, and an optional content type. No backend is involved; the ALB serves the response itself. Useful for: graceful "service moved" pages, intentional 503 maintenance windows, strict-router 404 defaults, and `robots.txt`-style minimal responses without provisioning a backend.

**authenticate-cognito.** Perform OAuth2 with an Amazon Cognito user pool. If the request lacks a valid session cookie, the ALB redirects the user to Cognito's hosted UI; on successful login, Cognito redirects back to the ALB, which exchanges the authorization code for tokens, sets a session cookie, and continues to the next action (typically a forward). The user's claims are passed to the backend in custom headers (`x-amzn-oidc-data`, `x-amzn-oidc-accesstoken`, `x-amzn-oidc-identity`).

**authenticate-oidc.** Same as `authenticate-cognito` but with any OIDC-compliant provider (Okta, Auth0, Google Workspace, Azure AD). You configure the issuer URL, client ID, client secret, and the four OIDC endpoints (authorization, token, user-info, logout). The behaviour is identical: redirect, exchange, cookie, headers.

Both authenticate actions can be combined with a forward in the same rule's action list: the ALB authenticates first, then forwards the now-authenticated request to a target group. This is how teams put SSO in front of internal dashboards (Kibana, Grafana, Airflow web UI) without modifying the application — the application sees only requests that the ALB has already verified.

---

## 10. Common patterns

### 10.1 The standard public web service

```
Listener HTTP:80   default: redirect → https://#{host}:443/#{path}?#{query}  (301)
Listener HTTPS:443 default: forward  → app-tg
                   rules:   [none]
TG app-tg          targets: 3× EC2 instances, each running the app on port 8080
```

This is the simplest production pattern. Plain HTTP requests are bounced to HTTPS; HTTPS requests go straight to the backend. The ALB hostname is fronted by a Route 53 alias record (`app.example.com → my-alb-...elb.amazonaws.com`). The certificate on the HTTPS:443 listener covers `app.example.com`. There are no listener rules — the default action handles all traffic.

### 10.2 The host-based multi-tenant router

```
Listener HTTPS:443 default: fixed-response 404
                   rule 10: host=api.example.com → forward → api-tg
                   rule 20: host=admin.example.com → forward → admin-tg
                   rule 30: host=static.example.com → redirect → cdn.example.com
TG api-tg, TG admin-tg: ECS services on different ports
```

One ALB, many services. The 404 default is a *strict-router* signal: unknown hosts get a clean 404 rather than a leaked response. The certificate on the listener is a wildcard (`*.example.com`) or a multi-SAN certificate covering all the hostnames. Adding a new service is a one-rule change.

### 10.3 The blue/green ECS service

```
Listener HTTPS:443 rule 10: host=api.example.com → forward → [
                                                      api-blue-tg (weight 100),
                                                      api-green-tg (weight 0)
                                                    ]
TG api-blue-tg:  current ECS service tasks (3 healthy)
TG api-green-tg: empty most of the time; populated during a deploy
```

Steady state: blue carries all the traffic, green is empty. During a CodeDeploy-driven deploy, ECS spins up tasks against green, waits for health checks to pass, then CodeDeploy adjusts the listener rule weights from `100/0` to (typically) `0/100`, then deregisters and stops the blue tasks. After the deploy, the roles swap: green is now "blue" (carrying traffic) and the next deploy will use the now-empty side.

If you stumble across an empty TG behind an active ALB and the TG name has `Blue`, `Green`, `BlTg`, or `GreenT` in it, you are looking at the off side of a blue/green deploy. Leave it alone.

### 10.4 SSO-gated internal dashboard

```
Listener HTTPS:443 rule 10: host=grafana.internal.example.com → [
                              authenticate-oidc (Okta),
                              forward → grafana-tg
                            ]
TG grafana-tg: ECS task running Grafana on port 3000
```

The ALB authenticates every request against Okta before it ever reaches Grafana. Grafana itself is configured to trust the `x-amzn-oidc-data` JWT that the ALB injects, mapping the email claim to a Grafana user. The result: Okta SSO in front of an application that has no native Okta integration, with no code changes to Grafana.

### 10.5 The fronting NLB for static IPs

```
NLB listener TCP:443 → ALB-typed TG → ALB
ALB listener HTTPS:443 → app-tg → backends
```

NLBs have static IPs (one per AZ, allocated at creation). ALBs do not. If a client needs to whitelist your service by IP (banks, government APIs, legacy on-prem firewalls), you front the ALB with an NLB. The NLB's target group has `target_type=alb`; its targets are the ALB itself. The client connects to the NLB's static IP, the NLB forwards to the ALB (preserving TLS — NLB does not terminate, it passes through), and the ALB does all the listener-rule routing.

---

## 11. Anti-patterns and gotchas

**The ALB attached to a private subnet without an internet gateway.** Internet-facing ALBs need public subnets. If you put one in private subnets, AWS will not stop you, but the ALB has no path to the internet and clients cannot reach it. Use internal-facing ALBs for private subnets.

**Cross-AZ data transfer ignored.** With cross-zone load balancing always-on for ALBs, you pay for every byte that crosses AZs. If your ALB receives a connection in `ap-south-1a` and routes it to a target in `ap-south-1b`, that response data is charged at $0.01/GB out of `1a` and $0.01/GB into `1b`. For high-throughput workloads, this can dominate the ALB bill itself. Mitigation: use stickiness or co-locate clients with backends per AZ.

**Health-check 200 vs 302.** The default matcher is `200`. If your application's `/` returns `302` (redirect to login), the health check fails. Either change the matcher to `200-399`, or point the health check at a `/healthz` endpoint that returns `200`.

**Security group too narrow on the targets.** A common 502 cause: the target group's port is `8080`, but the EC2 security group only allows `80` inbound from the ALB SG. Always allow the *target group port* in the target SG, not the listener port.

**Listener rule limit.** A single listener can hold up to 100 rules (raisable to a soft limit of 500). Past that, you need a second listener or you need to consolidate. Path patterns can have up to 128 characters and five wildcards.

**Stickiness with autoscaling.** If you turn on stickiness and your backends autoscale, new targets see no traffic until either the existing cookies expire or all the existing clients leave. This causes the autoscaler to scale up unnecessarily under sustained load. Either turn off stickiness or use stateless backends.

**Deletion protection.** Production ALBs should have `deletion_protection.enabled=true`. This prevents accidental `delete-load-balancer` calls — the API returns an error until the flag is flipped. Always check the flag before deleting; if it is set, you may be looking at a load balancer someone intentionally protected.

**The empty TG behind an active ALB.** As discussed: this is *not* an idle ALB. It is one rule on an otherwise-busy listener pointing at an empty pool. The ALB itself is in active use; the request slice that hits this rule will get a 503. Investigate by finding the rule, checking the host condition, and asking whether DNS or clients still target it.

**TG attached to multiple LBs.** Legal but rare. If you delete one LB, the TG still has the other LB. If you delete the TG, both LBs lose their backend. Always check `LoadBalancerArns` before deleting a TG, even if you "know" which LB owns it.

**ALB-to-ALB chaining latency.** The ALB-typed TG (ALB-as-target) adds one network hop and one TCP handshake. For latency-sensitive services, this is meaningful. Use only when the static IP front-end is genuinely required.

---

## 12. Investigation cookbook

When you encounter an ALB and need to understand it quickly, walk these layers in order:

### 12.1 From the console

1. Open the **load balancer** page. Note the scheme (internet-facing vs internal), subnets, security groups, and *deletion protection* flag. Read the DNS name.
2. On the **Listeners and rules** tab, list every listener. For each, click into it and read the **default action** first. Then enumerate the rules.
3. For every rule, note the conditions (host/path/etc.) and the action's target group. Click the TG link to follow the chain.
4. On the **target group** page, check the **target type**, **health check** configuration, and the **registered targets** count. If targets exist, look at their **health state** — `initial`, `healthy`, `unhealthy`, `draining`, or `unused`.
5. On the **Monitoring** tab of the load balancer, look at `RequestCount` over the last 30 days. Zero requests on a load balancer that has targets and listeners and rules is the strongest single signal of "actually idle". Look at `HTTPCode_ELB_5XX_Count` for ALB-generated 5XX (e.g., 503s caused by no healthy targets) and `HTTPCode_Target_5XX_Count` for backend-generated ones.
6. On the **target group's Monitoring** tab, look at `RequestCount`, `HealthyHostCount`, and `UnHealthyHostCount`. A target group with 0 healthy hosts for an extended period is either misconfigured or genuinely abandoned.

### 12.2 From the CLI

The chain in shell form (substitute your region and ARNs):

```bash
# 1. List all ALBs in a region
aws elbv2 describe-load-balancers --region ap-south-1 \
  --query 'LoadBalancers[?Type==`application`].[LoadBalancerName,LoadBalancerArn,State.Code]' \
  --output table

# 2. List listeners on an ALB
aws elbv2 describe-listeners --load-balancer-arn <alb-arn> \
  --query 'Listeners[*].[Port,Protocol,DefaultActions[0].Type,ListenerArn]' \
  --output table

# 3. List rules on a listener
aws elbv2 describe-rules --listener-arn <listener-arn> \
  --query 'Rules[*].[Priority,Conditions,Actions[0].Type,Actions[0].TargetGroupArn]' \
  --output json

# 4. List target groups attached to an ALB
aws elbv2 describe-target-groups --load-balancer-arn <alb-arn> \
  --query 'TargetGroups[*].[TargetGroupName,Protocol,Port,TargetType]' \
  --output table

# 5. List registered targets and their health
aws elbv2 describe-target-health --target-group-arn <tg-arn> \
  --query 'TargetHealthDescriptions[*].[Target.Id,Target.Port,TargetHealth.State,TargetHealth.Reason]' \
  --output table

# 6. Check orphan status of a target group
aws elbv2 describe-target-groups --target-group-arns <tg-arn> \
  --query 'TargetGroups[0].LoadBalancerArns' --output text
# Empty output = orphan

# 7. Get 30-day request count for an ALB
aws cloudwatch get-metric-statistics --region ap-south-1 \
  --namespace AWS/ApplicationELB --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=app/<name>/<id> \
  --start-time "$(date -u -d '30 days ago' +%FT%TZ)" \
  --end-time   "$(date -u +%FT%TZ)" \
  --period 2592000 --statistics Sum
```

### 12.3 The investigation pattern

When a single ALB returns 502 / 503 / 504:

- **502 Bad Gateway** — the ALB tried to forward to a target and got an unexpected response (connection reset, malformed HTTP, certificate problem on a backend HTTPS listener). The target is up but speaking the wrong language. Check the target group protocol and port; check the target's application logs.
- **503 Service Unavailable** — the ALB had nowhere to forward to. Either the TG has zero healthy targets, or the listener has a fixed-response 503 default. Check `HealthyHostCount` and the listener's default action.
- **504 Gateway Timeout** — the target accepted the connection but did not respond within `idle_timeout` (default 60 seconds on the ALB) or before the health-check timeout. The target is slow or hung. Check the application's CPU, memory, and dependencies (downstream DB or API).
- **460** (ALB-specific) — the client closed the connection before the target responded.
- **463** (ALB-specific) — the `X-Forwarded-For` header had too many IPs (more than 30). Some proxy chains will exceed this.

When a target group's `RequestCount` is zero and you do not know whether to delete it:

- Check `LoadBalancerArns`. If empty, it is a true orphan — safe to delete after checking it has no registered targets you need.
- If non-empty, find the rule. If the rule's host condition no longer has DNS pointing at the ALB, the rule is reachable only by direct hits to the ALB DNS name (rare in practice). Delete the rule, then delete the TG.
- If DNS does still point at the ALB, check whether the rule expects a hostname that recently moved (DNS cutover, decommissioned subdomain). Confirm with the team that owns the hostname before deleting.

---

## 13. Cleanup decision framework

The decision is not "is this thing idle?" — that has too many false positives. The decision is "what evidence do I have, and what is the worst-case impact of deleting it?"

For a **target group**, walk this:

1. Is `LoadBalancerArns` empty? → Orphan. Safe to delete (after confirming no live targets you need).
2. Is the TG name a blue/green or canary pattern? → Likely a deployment slot. Do not delete without confirming the pipeline.
3. Does the TG have zero targets but is referenced by a listener rule? → Find the rule's host condition. Check DNS. Check `RequestCount` over 30 days. If both are dead, safe to delete the rule then the TG.
4. Does the TG have targets but they are all unhealthy? → Backend is broken. Fix the backend, not the TG.
5. Does the TG have healthy targets but the LB has zero `RequestCount`? → Backend works, nobody is calling. Either DNS moved away or the service is genuinely unused. Confirm with the owner.

For a **load balancer**:

1. Zero listeners? → Trivially safe to delete.
2. Listeners exist but every rule's TG is empty and the ALB has zero `RequestCount` over 30 days? → Safe to delete after checking deletion-protection flag and Route 53 aliases.
3. Listeners exist, some rules have healthy backends, but the ALB has very low `RequestCount`? → Real but underused. Worth consolidating onto a shared ALB to save the $20–25/month per-ALB cost.
4. Deletion-protection is enabled? → Stop. Someone protected this. Find them.

For a **listener rule**:

1. The rule's TG has been deleted? → The rule will return 503 on match. Delete the rule.
2. The rule's host condition has no DNS pointing at the ALB? → The rule is unreachable. Safe to delete unless you have other-than-DNS reasons to keep it (planned host).
3. The rule's conditions overlap with another higher-priority rule? → Dead rule. Walk through with a test request to confirm. Delete.

The general principle: **changes that are reversible within the day are cheap; changes that delete identifiable AWS resources are not.** When in doubt, *disable* before *delete*. Disabling a listener rule (deleting it from the listener but keeping a backup of the rule JSON), or pointing a forward at a fixed-response 503, gives you a fast rollback. Deleting the underlying ALB or TG is a one-way door — recreating it gives you a new ARN, a new DNS name, and a new set of dependencies that may not match what depended on the old one.

---

## 14. Observability and metrics

CloudWatch is the canonical place to find out what an ALB is doing. The namespace is `AWS/ApplicationELB`. The dimensions are `LoadBalancer` (the value is the part of the ARN after `:loadbalancer/`, e.g. `app/my-alb/1234abcd5678ef90`) and optionally `TargetGroup` (similarly, the part after `:targetgroup/`).

The metrics that matter most:

- **RequestCount** — total requests received. Sum over time. This is your primary "is this thing being used" signal.
- **TargetResponseTime** — how long the *target* takes to respond, measured from when the ALB sent the request to when the ALB received the first byte of response. p50/p90/p99 are most useful.
- **HTTPCode_ELB_5XX_Count** — 5XX responses generated by the ALB itself (typically 503 because no healthy targets, or 504 idle timeout).
- **HTTPCode_Target_5XX_Count** — 5XX responses generated by the backend.
- **HTTPCode_ELB_4XX_Count** — 4XX responses generated by the ALB (typically 404 from fixed-response defaults).
- **HealthyHostCount** / **UnHealthyHostCount** (per TG) — current count of healthy / unhealthy targets.
- **ActiveConnectionCount** — concurrent client-to-ALB TCP connections.
- **NewConnectionCount** — rate of new connection arrivals.
- **RuleEvaluations** — how many times each listener rule was matched. Per-rule dimension; useful for spotting dead rules.

**Access logs** are off by default but are the highest-fidelity record of what the ALB did. Enable them on production ALBs (storage in S3, ~$0.10/GB which is negligible for log volumes), and you can answer "which client called this rule and got 503" after the fact. Without access logs, you have only the aggregate CloudWatch metrics and have to infer client behaviour from counts.

**X-Ray and OpenTelemetry tracing** propagate through the ALB if you configure the ALB to inject the `X-Amzn-Trace-Id` header. The ALB does not generate spans itself, but it preserves trace context across the request, allowing a backend trace and a client trace to be stitched together.

---

## 15. Cost considerations

ALB pricing has two components: a fixed hourly charge per ALB (`~$0.0225/hr` in ap-south-1, so `~$16.4/month`), and a "Load Balancer Capacity Unit" (LCU) charge based on the highest of four dimensions (new connections, active connections, processed bytes, rule evaluations) measured per second. For a low-traffic internal service, the LCU charge is rounding error and the fixed charge dominates. For a high-traffic public service, LCU dominates.

Practical implications:

- **Many small ALBs cost more than one large ALB doing the same work.** Five ALBs serving five hostnames each cost five times the fixed charge, even if each is doing nothing. Consolidating onto a single ALB with five listener rules saves four times the fixed charge.
- **Cross-AZ data transfer can rival the LB charge** for chatty internal services. Co-locate frontends and backends by AZ if you can.
- **Idle ALBs are pure waste.** A load balancer doing zero work still costs $16/month. Across 100 accounts and 10 idle LBs per account, that is $16k/year.
- **Deletion-protected ALBs cannot be cleaned up by automation.** Use the flag intentionally; do not enable it everywhere by default.

---

## 16. Security model

Three security boundaries are relevant.

**Network reachability** — controlled by Security Groups. The ALB has a security group that defines who can reach the ALB on which ports. The targets have security groups that define who can reach the target on the target group's port. For traffic to flow, the target SG must allow inbound on the target group port from the ALB SG. The most common ALB-related connectivity failure is a target SG that allows the listener port (80/443) but not the target group port (8080/8443).

**TLS posture** — controlled by the listener's security policy. Older policies allow weak ciphers; modern policies disable them. Pin to `ELBSecurityPolicy-TLS13-1-2-2021-06` or newer for new ALBs. Run `aws elbv2 describe-load-balancer-policies` to see the available list.

**Identity** — controlled by the listener's authenticate actions and by IAM for the control plane. The data plane (clients calling the ALB) is authenticated by mTLS, by `authenticate-oidc`/`authenticate-cognito`, or not at all. The control plane (engineers managing the ALB) is authenticated by IAM permissions on `elasticloadbalancing:*` actions, scoped down to the load balancer ARN when possible. The principle of least privilege applies: most engineers should have read-only on `elbv2`; only platform/devops roles should have create/delete.

**IAM for cleanup specifically:** the minimal read-only permission set to run an inventory scan like the one this document was extracted from is `ReadOnlyAccess` or, more narrowly, a custom policy granting:

```
elasticloadbalancing:Describe*
ec2:DescribeRegions
sts:GetCallerIdentity
cloudwatch:GetMetricStatistics
cloudwatch:GetMetricData
```

The cleanup itself, when you decide to act on the findings, needs additionally:

```
elasticloadbalancing:DeleteLoadBalancer
elasticloadbalancing:DeleteTargetGroup
elasticloadbalancing:DeleteListener
elasticloadbalancing:DeleteRule
elasticloadbalancing:DeregisterTargets
elasticloadbalancing:ModifyListener
elasticloadbalancing:ModifyRule
```

Scope these to the specific ARNs you intend to touch, not `*`. A wildcard delete permission attached to an automation role is one human error away from a production outage.

---

## 17. A mental model for further learning

The shape that holds all of this together is: **the ALB is a programmable HTTP reverse proxy whose configuration is split across five AWS resource types so each can be versioned and reused independently.** Once that frame is internalized, every behaviour follows:

- Why can the same target group be referenced by multiple listeners? Because target groups are free-standing objects, and references are programmable.
- Why does the load balancer not "know" which target groups exist? Because the relationship is computed from listener rules, not stored.
- Why is the ALB itself unable to be moved between VPCs? Because subnets are an attribute of the load balancer object, fixed at create time. The same applies to scheme (internet-facing vs internal) and IP address type (IPv4 vs dualstack).
- Why does a deployment require a rule modification? Because the listener rule is the single point where the routing decision is made, and shifting traffic between backends means changing that decision.
- Why does deleting an orphan target group never affect any load balancer? Because no listener references it, by definition of orphan.

For deeper reading, the AWS documentation that matters is:

- The Elastic Load Balancing API reference for `elbv2` — every action and field is documented, including the failure modes.
- The ALB chapter of the User Guide — has the most detail on rule conditions and action chaining.
- The pricing page — values change; check it before doing cost projections.
- The CloudWatch metric reference for `AWS/ApplicationELB` — full list of metrics, their dimensions, and statistic types.

Real fluency in this area comes from doing two specific things repeatedly: walking the chain manually for ALBs you did not configure (read the listener default action; read the rules; click into the TG; check target health; check the 30-day metrics — every time, in that order), and writing target groups and listener rules from scratch in Terraform or CloudFormation rather than the console (the IaC representation makes the structure explicit).

The deepest insight, after years of this, is that the ALB does very little: it terminates TLS, evaluates a small decision tree, and forwards bytes. Almost every interesting failure is in the layer beyond — a security group, a target's application code, a DNS record, a cookie path. Knowing the ALB well is mostly knowing what *it does not do*, so you can rule it out quickly and look at the next layer.
