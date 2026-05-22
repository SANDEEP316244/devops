# AWS ALB Analysis — Concepts Explained

**DNS | Route53 | Cloudflare | WAF | Security Groups | ALB Deletion Checklist | Listeners | Health Checks | TLS | Failure Modes | Debug Workflow | Hands-on**

---

## 1. DNS — The Phone Book of the Internet

Imagine the internet is a city. Every building (server) has a house number (IP address) like `54.23.11.8`. But you don't type that — you type `login.sadhguru.org`.

DNS (Domain Name System) is the phone book that translates:

```
    login.sadhguru.org  →  54.23.11.8
```

When you type a URL in a browser:

```
    Browser asks DNS: "Where is login.sadhguru.org?"
    DNS replies:      "Go to 54.23.11.8"
    Browser connects: hits that IP
```

Types of DNS records:

```
    A      → Points domain to an IP address
             Example: login.sadhguru.org → 54.23.11.8

    CNAME  → Points domain to another domain name
             Example: login.sadhguru.org → prodSSOLBNew-xxx.elb.amazonaws.com
```

ALBs don't have fixed IPs — AWS gives them a DNS name like:

```
    prodSSOLBNew-1078693949.ap-south-1.elb.amazonaws.com
```

So you use a CNAME to point your domain to that ALB DNS name. (Route53 also supports an **A-Alias** record — an AWS-specific record type that resolves like an A record but tracks the ALB's underlying IPs automatically as ALB nodes scale.)

---

## 2. Route53 — AWS's DNS Service

Route53 is simply AWS's version of a DNS server. You manage your domain's DNS records inside it.

```
    Route53 Hosted Zone: internal.isha.in
    │
    ├── prod-pms-router.internal.isha.in    → CNAME    → prodSSOLBNew-xxx.elb.amazonaws.com
    ├── prod-pms-srv-in.internal.isha.in    → CNAME    → prodSSOLBNew-xxx.elb.amazonaws.com
    └── prod-sso-alb-alias.internal.isha.in → A (Alias) → prodSSOLBNew
```

These are INTERNAL DNS names (only resolvable inside your VPC/network). Your public domains like `login.sadhguru.org` are managed in Cloudflare.

**Why it matters for deletion:** If a Route53 record points to an ALB and you delete the ALB, the DNS record becomes a dangling pointer — requests go nowhere, causing errors for internal services.

---

## 3. Cloudflare — Your Public DNS + CDN

Since you use Cloudflare, your public domain DNS is managed there, not in AWS Route53.

```
    User types: login.sadhguru.org
                        │
                        ▼
                  Cloudflare DNS
                  (manages sadhguru.org)
                        │
                        ▼  (CNAME or proxied record)
                  prodSSOLBNew-xxx.ap-south-1.elb.amazonaws.com
                        │
                        ▼
                     ALB (AWS)
                        │
                        ▼
                  Target Group → EC2
```

Cloudflare sits IN FRONT OF your ALB. It can also act as a proxy — meaning traffic goes: Cloudflare → ALB, not directly user → ALB.

**Why it matters for deletion:** Your public URLs like `login.sadhguru.org` are configured in Cloudflare. If Cloudflare has a record pointing to an ALB's DNS name, deleting that ALB breaks the site publicly.

> **YOU MUST CHECK CLOUDFLARE MANUALLY — this cannot be verified from AWS CLI.**

Search in Cloudflare dashboard for any records pointing to:

```
    prodSSOLBNew-1078693949.ap-south-1.elb.amazonaws.com
    Isha-ibpl-ALB-719330762.ap-south-1.elb.amazonaws.com
    ols-admin-alb-1014571363.ap-south-1.elb.amazonaws.com
```

---

## 4. WAF — The Bouncer at the Door

WAF (Web Application Firewall) sits in front of your ALB and inspects every incoming request before it reaches your app.

```
    Internet
       │
       ▼
     WAF  ← checks rules: block bots, SQL injection, bad IPs, rate limits
       │
       ▼
     ALB
       │
       ▼
     Target Group → EC2
```

It can block, allow, or count requests based on rules.

**Why it matters for deletion:** If a WAF is attached to an ALB, it means someone deliberately put security protection on it — strong signal the ALB is considered active and in use.

Status for your 3 ALBs:

```
    prodSSOLBNew    → No WAF attached
    Isha-ibpl-ALB   → No WAF attached
    ols-admin-alb   → No WAF attached
```

---

## 5. Security Groups — The Firewall at the Instance Level

A Security Group is a virtual firewall that controls who can talk to what at the network level.

```
    Internet
       │  (port 80, 443)
       ▼
    ALB  ←── ALB Security Group: allow inbound 80/443 from 0.0.0.0 (internet)
       │  (port 8080, etc.)
       ▼
    EC2  ←── EC2 Security Group: allow inbound ONLY from ALB's security group
```

The EC2 instances typically only allow traffic FROM the ALB's security group — not directly from the internet. This is the standard secure pattern.

**Why it matters for deletion:** If you delete an ALB, its security group reference in EC2's inbound rules becomes a ghost rule — harmless but messy. Clean up any inbound rules on EC2s that reference the deleted ALB's SG.

Security Groups on your 3 ALBs:

```
    prodSSOLBNew    → sg-0a2921bff2b4116bd
    Isha-ibpl-ALB   → sg-00dc0483b49ab6248
    ols-admin-alb   → sg-0468624f583690112
```

---

## 6. The Full Picture — Your Setup

```
                    USER (browser)
                         │
                         ▼
                  ┌─────────────┐
                  │  Cloudflare │  ← manages public DNS (sadhguru.org)
                  │  (public)   │  ← may proxy/cache traffic
                  └──────┬──────┘
                         │  CNAME: login.sadhguru.org → ALB DNS name
                         ▼
                  ┌─────────────┐
                  │     WAF     │  ← (not attached to your ALBs currently)
                  └──────┬──────┘
                         │
                  ┌──────▼──────┐
                  │  ALB        │  ← has Security Group (allow 80/443)
                  │  Listeners  │  ← rules: which URL goes where
                  └──────┬──────┘
                         │
                  ┌──────▼──────┐
                  │ Target Group│  ← group of EC2s
                  └──────┬──────┘
                         │
                  ┌──────▼──────┐
                  │  EC2 / App  │  ← Security Group: allow only from ALB SG
                  └─────────────┘

    Internal services also reach ALB via:
    Route53 (internal.isha.in) → ALB DNS name
```

---

## 7. ALB Analysis Summary — Account 700392259328 (ap-south-1 / Mumbai)

### ALB 1: prodSSOLBNew

```
Created       : Jan 25, 2025
Scheme        : internet-facing
Listeners     : HTTP:80 + HTTPS:443
Target Groups : 4 (ALL EMPTY — no registered instances)
30-day traffic: 917,900 requests → 0 success (2xx/3xx), 12,163 x 4xx, 10 x 5xx
WAF           : None
Security Group: sg-0a2921bff2b4116bd
```

Listener rules route these hostnames to empty target groups:

```
    login.sadhguru.org       → prodSSOoAuthAppTG        (empty)
    ishalogin.sadhguru.org   → prodSSOLoginAppNewTG     (empty)
    pms.sadhguru.org         → prodSSOPMSRouterAppTGNew (empty)
```

Default action: `503 fixed-response`.

Route53 records pointing to it (internal.isha.in):

```
    prod-pms-router.internal.isha.in    (CNAME)
    prod-pms-srv-in.internal.isha.in    (CNAME)
    prod-sso-alb-alias.internal.isha.in (A Alias)
```

**Verdict:** IDLE but DNS-coupled. Delete AFTER:

1. Removing the 3 Route53 records above
2. Verifying Cloudflare records for login/pms/ishalogin domains are removed
3. Cleaning up EC2 SG rules referencing `sg-0a2921bff2b4116bd`

### ALB 2: Isha-ibpl-ALB

```
Created       : Sep 24, 2025
Scheme        : internet-facing
Listeners     : HTTP:80 + HTTPS:443
Target Groups : 1 (TG1-Isha-ibpl-ALB — EMPTY)
30-day traffic: 0 requests
WAF           : None
Security Group: sg-00dc0483b49ab6248
VPC           : vpc-08f98764f19f98401 (separate VPC)
Route53       : No records found
Cloudflare    : Must verify manually
```

**Verdict:** SAFE TO DELETE IMMEDIATELY. No traffic, no targets, no DNS dependency found. After delete: clean up `sg-00dc0483b49ab6248` if unused.

### ALB 3: ols-admin-alb

```
Created       : Nov 6, 2025
Scheme        : internet-facing
Listeners     : HTTPS:443 only (no HTTP listener)
Target Groups : 1 (ols-admin-targets-https port 7080 — EMPTY)
30-day traffic: 9,439 requests → 0 success, 1,924 x 4xx, 2,012 x 5xx
WAF           : None
Security Group: sg-0468624f583690112
Route53       : No records found
Cloudflare    : Must verify manually
```

**Verdict:** SAFE TO DELETE. Confirm no OLS admin tool is still configured to call its DNS: `ols-admin-alb-1014571363.ap-south-1.elb.amazonaws.com`. After delete: clean up `sg-0468624f583690112` if unused.

---

## 8. Deletion Checklist (all layers)

| Layer              | prodSSOLBNew         | Isha-ibpl-ALB | ols-admin-alb |
|--------------------|----------------------|---------------|---------------|
| Target Groups      | Empty                | Empty         | Empty         |
| Successful traffic | 0 (2xx)              | 0             | 0             |
| Route53 records    | YES — 3 records      | None          | None          |
| WAF attached       | No                   | No            | No            |
| Cloudflare check   | MUST verify          | Must verify   | Must verify   |
| SG cleanup needed  | Yes (after delete)   | Yes           | Yes           |

---

## 9. Order of Operations for Safe Deletion

**For prodSSOLBNew (most dependencies):**

```
Step 1: Verify Cloudflare — remove records for login/pms/ishalogin domains
Step 2: Delete 3 Route53 records in internal.isha.in
Step 3: Deregister / delete 4 Target Groups
Step 4: Delete ALB
Step 5: Clean up Security Group sg-0a2921bff2b4116bd (check EC2 SG rules)
```

**For Isha-ibpl-ALB (no dependencies):**

```
Step 1: Verify Cloudflare (quick check)
Step 2: Delete Target Group TG1-Isha-ibpl-ALB
Step 3: Delete ALB
Step 4: Clean up Security Group sg-00dc0483b49ab6248
```

**For ols-admin-alb:**

```
Step 1: Confirm OLS admin tool is not pointing to ALB DNS name
Step 2: Verify Cloudflare (quick check)
Step 3: Delete Target Group ols-admin-targets-https
Step 4: Delete ALB
Step 5: Clean up Security Group sg-0468624f583690112
```

---

## 10. ALB Listeners & Rules — In Depth

An ALB by itself is just a managed proxy fronted by ENIs in your public subnets. The behavior comes from **listeners** and the **rules** attached to them.

### 10.1 What a listener actually is

A **listener** is a port + protocol the ALB accepts traffic on. You attach rules to it that decide what to do with each request.

```
   ┌──────────── ALB ────────────┐
   │                             │
   │  Listener :80   (HTTP)      │── rules → actions
   │  Listener :443  (HTTPS)     │── rules → actions
   │  Listener :8443 (HTTPS)     │── rules → actions
   │                             │
   └─────────────────────────────┘
```

Each listener has:

- A **default action** — what happens when nothing else matches (forward, redirect, fixed-response, or auth)
- An **ordered list of rules** — evaluated in **priority order** (1 = highest), first match wins; the default action is effectively the lowest-priority catch-all

### 10.2 Rule conditions — what you can match on

You match a rule using one or more **conditions**, AND-ed together:

| Condition type      | Example                                                 |
|---------------------|---------------------------------------------------------|
| `host-header`       | `login.sadhguru.org`, `*.sadhguru.org`                  |
| `path-pattern`      | `/api/*`, `/static/*`, `/healthz`                       |
| `http-header`       | `X-Internal-Tenant: foo`                                |
| `http-request-method` | `POST`                                                |
| `query-string`      | `?canary=true`                                          |
| `source-ip`         | `203.0.113.0/24` (CIDR allowlist)                       |

Each rule can have up to 5 conditions and matches on the AND of them.

### 10.3 Rule actions — what happens when a rule matches

| Action            | Description                                                        |
|-------------------|--------------------------------------------------------------------|
| `forward`         | Send to one or more target groups (with optional weighted routing) |
| `redirect`        | HTTP 301/302 to another URL (the classic HTTP→HTTPS redirect)      |
| `fixed-response`  | Return a static status code + body without touching any target     |
| `authenticate-oidc` / `authenticate-cognito` | Block until user authenticates       |

### 10.4 Host-based routing

A single ALB can serve many domains. Common pattern: one ALB per environment (prod-alb, stage-alb) with many host-based rules — cheaper than running one ALB per service.

```
   ┌──────────────────── ALB :443 ────────────────────┐
   │                                                  │
   │  Rule 10:  host = login.sadhguru.org    → TG-sso │
   │  Rule 20:  host = pms.sadhguru.org      → TG-pms │
   │  Rule 30:  host = ishalogin.sadhguru.org→ TG-login
   │  Default:  fixed-response 503                    │
   │                                                  │
   └──────────────────────────────────────────────────┘
```

That's exactly the `prodSSOLBNew` shape — the rules exist, the target groups are empty, so requests legitimately fall through to 503 today.

### 10.5 Path-based routing

Common when you have a monolithic frontend in front of a microservices backend.

```
   ┌──────────────────── ALB :443 ────────────────────┐
   │                                                  │
   │  Rule 10:  path = /api/*       → TG-api          │
   │  Rule 20:  path = /static/*    → TG-cdn          │
   │  Rule 30:  path = /admin/*     → TG-admin        │
   │  Default:  forward             → TG-web          │
   │                                                  │
   └──────────────────────────────────────────────────┘
```

### 10.6 The classic HTTP → HTTPS redirect

Every internet-facing ALB should have an `:80` listener whose **default action is a redirect to `:443`**. This is the cheapest, most universal way to enforce HTTPS.

```
   Listener :80 (HTTP)
       Default action: redirect 301
                       protocol  = HTTPS
                       port      = 443
                       host      = #{host}
                       path      = /#{path}
                       query     = #{query}
                       status    = HTTP_301
```

AWS CLI shape:

```bash
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,Host="#{host}",Path="/#{path}",Query="#{query}",StatusCode=HTTP_301}'
```

`ols-admin-alb` deliberately omits the `:80` listener — a defensible choice for internal admin tools (no plaintext at all), but it does mean a user who types `http://...` gets a connection refused rather than a friendly redirect.

### 10.7 Priorities, evaluation order, and the default

- Priorities are integers 1..50000; **lower number = higher priority**
- The first rule whose conditions match wins; nothing else is evaluated
- The **default action** runs only when no rule matches — it has no priority value, it's just "everything else"
- Anti-pattern: putting your most specific rule at priority 1000 and a catch-all at priority 1 — the catch-all swallows everything

### 10.8 Fixed-response — useful and dangerous

A fixed-response action returns a static body and status without involving any target group. Two production uses:

```
   Useful:    Default action on prodSSOLBNew = fixed-response 503
              → tells callers "this hostname exists but has no backend right now"
              → much better than a 502 from an empty target group

   Useful:    Maintenance window: temporarily switch a rule to fixed-response 503
              with a friendly HTML body, then flip it back when deploy finishes

   Dangerous: Forgetting a fixed-response rule at priority 1 with condition
              host = * and silently swallowing 100% of traffic
```

---

## 11. Target Group Health Checks — How They Actually Work

A target group is a pool of backends (EC2 instances, IPs, Lambda, or another ALB). The ALB constantly probes each target; only **healthy** targets receive forwarded traffic.

### 11.1 The health check protocol

Each target group defines its own probe:

```
   Protocol        : HTTP | HTTPS
   Port            : "traffic-port" (the registered port) or a fixed override
   Path            : /healthz, /actuator/health, /
   Matcher         : 200, 200-299, 200,302 (whatever you accept as "alive")
   Interval        : seconds between probes  (default 30)
   Timeout         : seconds to wait for response (default 5)
   Healthy threshold   : consecutive passes required to mark healthy   (default 5)
   Unhealthy threshold : consecutive fails required to mark unhealthy  (default 2)
```

### 11.2 The state machine

```
   ┌──────────┐  N consecutive failures   ┌────────────┐
   │ healthy  │ ────────────────────────► │ unhealthy  │
   │          │                           │ (drained)  │
   │ receives │ ◄──────────────────────── │ no traffic │
   │ traffic  │  M consecutive successes  │            │
   └──────────┘                           └────────────┘

   ┌──────────┐
   │ initial  │  ALB has not finished the first M probes yet
   └──────────┘
   ┌──────────┐
   │ draining │  Target was deregistered; ALB lets in-flight requests finish
   │          │  until deregistration delay expires (default 300s)
   └──────────┘
```

### 11.3 What "unhealthy" actually means

- The ALB **stops new connections** to that target — existing in-flight ones still drain
- If **all** targets in the group are unhealthy and you've enabled "fail open" — disabled by default — the ALB will forward anyway. With fail-open disabled, the ALB returns **503 Service Unavailable** to the client.
- The target itself is unaware unless your app exports the health check endpoint and you correlate

### 11.4 Tuning — production-realistic settings

The AWS defaults are conservative (2 minutes to mark unhealthy with default 30s interval × 4 failures). For most web apps:

```
   interval                 : 10–15s
   timeout                  : 5s
   healthy threshold        : 2
   unhealthy threshold      : 2–3
   matcher                  : 200
   path                     : /healthz (deep enough to be meaningful,
                              shallow enough to not page during a DB blip)
```

Symptom-first failure: a too-aggressive setting (interval 5s, threshold 2) ejects a target during a brief GC pause. A too-loose setting (interval 30s, threshold 5) means a dead target keeps getting traffic for ~2.5 minutes after it died.

### 11.5 Anti-patterns

- **Pointing the health check at `/` when `/` requires login** — first request returns 302, your matcher is `200`, every target is marked unhealthy
- **A deep health check that hits the database** — when the DB hiccups, every target across every AZ flaps unhealthy simultaneously and your ALB returns 503 to the world
- **Different health check paths between target groups in the same ALB** — okay if intentional, often a sign of drift
- **Forgetting to allow the health check port in the target's SG** from the ALB SG — instances show "Health checks failed: target.FailedHealthChecks" in `describe-target-health` reason field

Debug command to inspect:

```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

The output's `TargetHealth.Reason` field is the most useful single field in all of ELBv2 — values like `Target.Timeout`, `Target.ResponseCodeMismatch`, `Elb.InitialHealthChecking` immediately point you at the root cause.

---

## 12. SSL/TLS Termination at the ALB

### 12.1 Where TLS terminates

```
   Client                           ALB                          Target
   ──────         TLS handshake     ───                          ──────
                ──────────────────►         (plain HTTP or HTTPS)
                                            ───────────────────►
```

Three patterns:

1. **TLS termination at ALB (most common)** — client→ALB over HTTPS, ALB→target over HTTP. ALB does the expensive TLS work; targets just speak HTTP on a port like 8080.
2. **End-to-end TLS** — client→ALB HTTPS **and** ALB→target HTTPS. Use when the target is sensitive (PCI/HIPAA) or you want to claim zero plaintext on the wire even within the VPC.
3. **TLS passthrough** — only with **NLB** in TCP mode. ALB cannot do this; it must terminate.

### 12.2 ACM certificates

ALBs use **AWS Certificate Manager (ACM)** certificates. ACM issues free public certs and auto-renews them as long as the domain validation record stays in DNS.

```
   ACM cert            covers domains              attached to listener
   ──────────────────  ─────────────────────────   ─────────────────────
   arn:...:cert/abc    *.sadhguru.org              ALB :443 default cert
   arn:...:cert/xyz    api.example.com             ALB :443 SNI cert
```

- A listener has **one default certificate** and any number of additional **SNI certificates**
- The browser sends the requested hostname in the TLS ClientHello (SNI extension); the ALB picks the matching cert
- Wildcard certs (`*.sadhguru.org`) cover one level — they do **not** match `a.b.sadhguru.org`

### 12.3 Security policy

The listener has a security policy that picks which TLS versions and cipher suites are allowed. Examples:

```
   ELBSecurityPolicy-TLS13-1-2-2021-06   ← modern default, prefer this
   ELBSecurityPolicy-FS-Res-2020-10      ← forward-secrecy only
   ELBSecurityPolicy-2016-08             ← old, still allows TLS 1.0
```

PCI-DSS/HIPAA: insist on TLS 1.2+ — pick a `TLS13-1-2` or `TLS12` policy and confirm with `aws elbv2 describe-listeners`.

### 12.4 The HTTPS-only redirect pattern

The standard production setup for a public ALB:

```
   ┌─────────────────────── ALB ──────────────────────┐
   │                                                  │
   │  Listener :80                                    │
   │    Default action: redirect 301 → https://#{host}#{path}?#{query}
   │                                                  │
   │  Listener :443  (cert: *.sadhguru.org)           │
   │    Rule 10: host = login.sadhguru.org → TG-sso   │
   │    Rule 20: host = pms.sadhguru.org   → TG-pms   │
   │    Default: fixed-response 503                   │
   │                                                  │
   └──────────────────────────────────────────────────┘
```

### 12.5 End-to-end TLS specifics

If you go end-to-end:

- Target group protocol: `HTTPS`
- Target port: 443 (or whatever the app listens on)
- Health check protocol: `HTTPS`
- **ALB does not validate the target's certificate.** You can use a self-signed cert on the EC2 — ALB will accept it. The value is "encrypted on the wire," not "ALB trusts the target."
- Cost: CPU on the target instead of on the ALB; usually invisible at moderate scale

### 12.6 Common cert/TLS mistakes

- Cert covers `sadhguru.org` and `*.sadhguru.org` but a user hits `https://www.app.sadhguru.org` → browser shows "your connection is not private" (cert doesn't match)
- Forgetting to **re-validate** the ACM cert when the DNS validation record is removed → cert silently fails to renew, expires 13 months later
- Using a self-signed cert on the ALB itself (you can't — ALB requires ACM or IAM cert; for a public site, ACM is the only practical choice)
- Mixing security policies across listeners and getting a "TLS 1.0 still enabled" finding in a security audit on the one listener you forgot

---

## 13. Common ALB Failure Modes (Symptom-First)

For each symptom: what you *see*, what it usually *means*, how to *confirm*, and how to *fix*.

### 13.1 HTTP 502 Bad Gateway

**Symptom:** Browser sees `502 Bad Gateway`. `curl -v` shows the ALB returning 502 after the request was sent.

**What it means:** The ALB sent the request to a target, but the target either:

- Closed the TCP connection before a complete response was returned
- Returned a malformed HTTP response (missing status line, bad headers)
- Sent a chunked response that ended unexpectedly

The ALB itself reached a target — that's why it's a *gateway* error, not a *no-backend* error.

**Common causes:**

- Target's idle/keep-alive timeout is **shorter** than the ALB's idle timeout (default ALB = 60s). The target closes the keep-alive socket, ALB picks the same socket for a new request, target RSTs → 502. Fix: target keep-alive > ALB idle timeout (set Nginx `keepalive_timeout 75;` etc.)
- App crashed mid-response (OOM kill, panic). Look at app logs around the 502 timestamp.
- Target is HTTPS but you configured the TG as HTTP (or vice versa)

**Confirm:**

```bash
# Check ALB access logs for elb_status_code=502, target_status_code="-"
aws s3 cp s3://your-alb-logs/AWSLogs/... - | grep " 502 "

# Inspect target health
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

**Anti-pattern:** "Just increase the ALB idle timeout" — that hides the bug, doesn't fix it. The real fix is making the target's keep-alive longer than the ALB's.

### 13.2 HTTP 503 Service Unavailable

**Symptom:** Browser sees `503 Service Unavailable` from the ALB.

**What it means:** The ALB had **nowhere to send the request**:

- Target group is empty
- All targets in the group are unhealthy
- Rule's default action is `fixed-response 503` (intentional)

**Confirm:**

```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN
# All entries with State != "healthy"? → no destination
```

Also: did your deploy de-register all targets at the same time? With deregistration delay 300s, the targets are still listed but state=`draining` — and once they're drained you've got nothing left.

**Fix:** Bring at least one target back to healthy. For deploys, use rolling/blue-green to ensure the target group is never empty.

### 13.3 HTTP 504 Gateway Timeout

**Symptom:** Browser hangs ~60s, then sees `504 Gateway Timeout`.

**What it means:** ALB sent a request to the target. The target accepted it but did not return a response within the **ALB idle timeout** (default 60s).

**Common causes:**

- Slow database query / external API call that the target is blocked on
- Target deadlocked or hung thread pool
- Long-running endpoint legitimately exceeds 60s — raise the timeout

**Confirm:**

```bash
# ALB access logs: target_processing_time will be the timeout value, response_processing_time = -1
# request_processing_time = brief, target_processing_time near the idle timeout
```

**Fix:** First find out *why* the target is slow — fix that. If the endpoint genuinely needs >60s (file uploads, report generation), bump the ALB idle timeout (`aws elbv2 modify-load-balancer-attributes --attributes Key=idle_timeout.timeout_seconds,Value=300`).

### 13.4 DNS NXDOMAIN / Connection Refused After Deletion

**Symptom:** After deleting an ALB, a service starts emitting:

```
   dial tcp: lookup prodSSOLBNew-xxx.elb.amazonaws.com: NXDOMAIN
   curl: (6) Could not resolve host: login.sadhguru.org
   curl: (7) Failed to connect: Connection refused
```

**What it means:** Something — Route53, Cloudflare, an app config, a hardcoded hostname — still believes the ALB exists.

- **NXDOMAIN** on the ALB's `.elb.amazonaws.com` name: AWS reaped the DNS entry; some caller had it hardcoded or a CNAME pointed at it
- **NXDOMAIN** on your custom domain: an A-Alias record dangled; the alias target is gone
- **Connection refused**: DNS still resolves (Cloudflare cached IP, or `/etc/hosts` entry) but nothing is listening at that IP anymore

**Confirm:**

```bash
dig +short login.sadhguru.org
dig +short prodSSOLBNew-1078693949.ap-south-1.elb.amazonaws.com
# What's still pointing here?
grep -r "prodSSOLBNew\|elb.amazonaws.com" /etc/ /opt/myapp/
```

**Fix:** Sweep Route53, Cloudflare, and config repos for the dead ALB DNS name; remove the references. This is the entire reason the deletion checklist in §9 exists.

---

## 14. Debug Workflow — Tracing a Failed Request Layer by Layer

When `https://login.sadhguru.org` returns an error, work the path from outside-in. Each layer below has a definitive test you can run before moving to the next.

```
   Browser  ──►  Cloudflare  ──►  Internet  ──►  ALB  ──►  Target Group  ──►  EC2
      1            2                3              4            5                6
```

### Layer 1 — Browser

- Open DevTools → Network tab → click the failing request → look at:
  - **Status code** (the most important single signal — see §13)
  - **Response headers** — `Server: awselb/2.0` confirms ALB returned it; absence means Cloudflare or browser returned it
  - **Initiator / Timing** — if "Stalled" is huge, the browser never got a TCP connection
- Reproduce with `curl -v` so nothing browser-specific (extensions, cached redirects) confuses you:

  ```bash
  curl -vk https://login.sadhguru.org/healthz
  ```

### Layer 2 — Cloudflare

- Check the response headers in the failing request for `cf-ray`, `server: cloudflare`. If present, Cloudflare touched the request.
- If Cloudflare returns its own error page (520, 521, 522, 524), the problem is **between Cloudflare and your ALB**, not on the client side:

  ```
   520 = "web server returned unknown error"
   521 = origin (ALB) refused connection
   522 = origin TCP timeout
   524 = origin took > 100s to respond
  ```

- Try bypassing Cloudflare to isolate it. From a machine with DNS override:

  ```bash
  curl -vk --resolve login.sadhguru.org:443:<ALB_IP> https://login.sadhguru.org/healthz
  ```

### Layer 3 — DNS / Internet path

```bash
dig +short login.sadhguru.org
dig +short login.sadhguru.org @1.1.1.1
nslookup login.sadhguru.org
```

- If your domain returns Cloudflare IPs, Cloudflare is "orange-cloud" proxying; if it returns `*.elb.amazonaws.com`, it's "gray-cloud" DNS-only
- `traceroute` to confirm you're reaching AWS edge (last few hops will be `*.amazonaws.com`)

### Layer 4 — ALB

- Resolve the ALB DNS name to get one of its ENI public IPs:

  ```bash
  dig +short prodSSOLBNew-1078693949.ap-south-1.elb.amazonaws.com
  ```

- Hit the ALB **directly** by its AWS DNS name (bypasses Cloudflare and your DNS):

  ```bash
  curl -vk -H "Host: login.sadhguru.org" \
       https://prodSSOLBNew-1078693949.ap-south-1.elb.amazonaws.com/healthz
  ```

  - **Connection refused / timeout**: ALB SG is not allowing your client IP, or the listener doesn't exist
  - **503 with `Server: awselb/2.0`**: §13.2 — target group is empty / all unhealthy
  - **502**: §13.1 — target itself misbehaving
  - **504**: §13.3 — target is alive but slow

- Inspect the listener rules and confirm the host header you're sending actually matches a rule:

  ```bash
  aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN
  aws elbv2 describe-rules --listener-arn $LISTENER_ARN
  ```

- Pull ALB access logs (S3) and grep the request ID Cloudflare gave you, or just by timestamp:

  ```
   <timestamp> app/<alb>/<id> <client:port> <target:port> <req_proc_time> <target_proc_time> <resp_proc_time> <elb_status> <target_status> ...
  ```

  Two killer fields: `target_status_code = "-"` means the ALB never got a response from the target; `target_processing_time = -1` means the request never made it to the target.

### Layer 5 — Target group

```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

Read every target's `State` and (if not healthy) `TargetHealth.Reason` + `Description`. The reason codes name the problem:

```
   Elb.RegistrationInProgress    just registered, still on first health checks
   Target.Timeout                target didn't respond to health check in time
   Target.ResponseCodeMismatch   target returned a status the matcher doesn't accept
   Target.FailedHealthChecks     target failed unhealthy_threshold consecutive probes
   Target.NotInUse               target group not associated with a listener
   Target.DeregistrationInProgress  draining
```

### Layer 6 — EC2 / target

From a bastion or another instance in the same SG:

```bash
# Test the target directly on its health check path + port
curl -v http://<EC2_PRIVATE_IP>:8080/healthz
```

- If this works but the ALB says unhealthy → SG between ALB and EC2 is wrong, or you're listening on the wrong interface (`localhost` only)
- If this also fails → the target itself is broken; check the app and instance:

  ```bash
  systemctl status myapp
  journalctl -u myapp -n 200
  ss -tlnp | grep 8080            # is anything actually listening?
  iptables -L                      # local firewall blocking?
  ```

### A quick mental checklist while debugging

```
   [ ] Can I reproduce with curl (not just the browser)?
   [ ] Does the response include Server: awselb/2.0?  → ALB returned it
   [ ] Does the response include cf-ray?               → Cloudflare touched it
   [ ] Is the host header matching an ALB rule?
   [ ] Are targets healthy (describe-target-health)?
   [ ] Can I curl the target directly on its private IP?
   [ ] Have I checked ALB access logs for this request?
```

---

## 15. Hands-on Exercise — ALB with Path-Based Routing to Two Target Groups

**Goal:** From scratch, build an internet-facing ALB in an existing VPC that routes `/api/*` to one target group and everything else to another. Both target groups have a single EC2 instance running a trivial HTTP server. You should be able to `curl` the ALB DNS name and see different responses based on the path.

### 15.1 Pre-reqs

```
   VPC with at least 2 public subnets (one per AZ)
   AWS CLI v2 configured with credentials and a default region
   An existing key pair (or use Session Manager — preferred)
```

Export the things you'll need:

```bash
export VPC_ID=vpc-xxxxxxxx
export SUBNET_A=subnet-aaa11111
export SUBNET_B=subnet-bbb22222
export AMI=ami-xxxxxxxxxxxxxx        # Amazon Linux 2023 in your region
export KEY_NAME=your-keypair          # optional if using SSM
export REGION=ap-south-1
```

### 15.2 Create the security groups

```bash
# SG for the ALB: allow :80 from anywhere
ALB_SG=$(aws ec2 create-security-group \
  --group-name alb-lab-sg --description "lab ALB SG" --vpc-id $VPC_ID \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0

# SG for the EC2s: allow :80 only from the ALB SG
EC2_SG=$(aws ec2 create-security-group \
  --group-name alb-lab-ec2-sg --description "lab EC2 SG" --vpc-id $VPC_ID \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG --protocol tcp --port 80 --source-group $ALB_SG
```

### 15.3 Launch two EC2s, one per target group

User-data installs a tiny HTTP server that responds with which target group it belongs to.

```bash
USERDATA_WEB=$(base64 -w0 <<'EOF'
#!/bin/bash
dnf install -y nginx
cat >/usr/share/nginx/html/index.html <<HTML
hello from WEB target group ($(hostname))
HTML
cat >/etc/nginx/conf.d/healthz.conf <<NGX
location = /healthz { return 200 "ok\n"; default_type text/plain; }
NGX
systemctl enable --now nginx
EOF
)

USERDATA_API=$(base64 -w0 <<'EOF'
#!/bin/bash
dnf install -y nginx
mkdir -p /usr/share/nginx/html/api
cat >/usr/share/nginx/html/api/index.html <<HTML
hello from API target group ($(hostname))
HTML
cat >/etc/nginx/conf.d/healthz.conf <<NGX
location = /healthz { return 200 "ok\n"; default_type text/plain; }
NGX
systemctl enable --now nginx
EOF
)

WEB_INSTANCE=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro \
  --subnet-id $SUBNET_A --security-group-ids $EC2_SG \
  --user-data "$USERDATA_WEB" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=alb-lab-web}]' \
  --query 'Instances[0].InstanceId' --output text)

API_INSTANCE=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro \
  --subnet-id $SUBNET_B --security-group-ids $EC2_SG \
  --user-data "$USERDATA_API" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=alb-lab-api}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $WEB_INSTANCE $API_INSTANCE
```

### 15.4 Create the two target groups

```bash
WEB_TG=$(aws elbv2 create-target-group \
  --name lab-tg-web --protocol HTTP --port 80 --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-path /healthz --health-check-interval-seconds 10 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

API_TG=$(aws elbv2 create-target-group \
  --name lab-tg-api --protocol HTTP --port 80 --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-path /healthz --health-check-interval-seconds 10 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 register-targets --target-group-arn $WEB_TG --targets Id=$WEB_INSTANCE
aws elbv2 register-targets --target-group-arn $API_TG --targets Id=$API_INSTANCE
```

### 15.5 Create the ALB and its listener

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name lab-alb --type application --scheme internet-facing \
  --subnets $SUBNET_A $SUBNET_B --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$WEB_TG" \
  --query 'Listeners[0].ListenerArn' --output text)
```

The listener now sends **everything** to `lab-tg-web` by default.

### 15.6 Add the path-based rule

```bash
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 10 \
  --conditions Field=path-pattern,Values='/api/*' \
  --actions "Type=forward,TargetGroupArn=$API_TG"
```

### 15.7 Wait for healthy, then test

```bash
# Wait until both target groups report healthy
aws elbv2 describe-target-health --target-group-arn $WEB_TG \
  --query 'TargetHealthDescriptions[].TargetHealth.State'
aws elbv2 describe-target-health --target-group-arn $API_TG \
  --query 'TargetHealthDescriptions[].TargetHealth.State'

# Hit it
curl -s http://$ALB_DNS/                # should say "hello from WEB target group"
curl -s http://$ALB_DNS/api/            # should say "hello from API target group"
```

### 15.8 Things to break on purpose (the real learning)

1. **Stop the API instance.** Watch `describe-target-health` flip to `unhealthy` after ~20s. `curl /api/` now returns `503` because the rule matched but its target group has no healthy targets. The default route still works.
2. **Change the API target group's health check matcher to `301`.** Watch every API target become unhealthy. Read the `Reason` field — `Target.ResponseCodeMismatch`. Revert.
3. **Add an HTTPS-redirect listener on :80** and move the rule to :443 with an ACM cert. Confirm `curl -L http://...` follows a 301 to `https://...`. (Cert must be issued for a domain you actually own — use Route53 + ACM if you have a domain in the same account.)
4. **Send a request with `Host: api.example.com`** while the rule is host-based instead of path-based — observe how the same listener handles two domains with two different routings.

### 15.9 Tear down

```bash
aws elbv2 delete-listener --listener-arn $LISTENER_ARN
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
aws elbv2 delete-target-group --target-group-arn $WEB_TG
aws elbv2 delete-target-group --target-group-arn $API_TG
aws ec2 terminate-instances --instance-ids $WEB_INSTANCE $API_INSTANCE
aws ec2 wait instance-terminated --instance-ids $WEB_INSTANCE $API_INSTANCE
aws ec2 delete-security-group --group-id $EC2_SG
aws ec2 delete-security-group --group-id $ALB_SG
```

The deletion order matters: listeners and target groups must go before the ALB; SGs can only be deleted once nothing references them — exactly the pattern §9 walks through for the real ALBs.

---

## 16. The Full HTTPS Journey — From Browser Keystroke to EC2

This section answers the exact question: *what happens at every hop, what is encrypted where, and how does Cloudflare fit into the encryption picture?*

---

### 16.1 HTTP vs HTTPS — What's Actually Different

**HTTP** is plain text. Every router, ISP, and anyone on the same Wi-Fi can read it.

```
   Browser sends:
   GET /login HTTP/1.1
   Host: login.sadhguru.org
   Cookie: session=abc123supersecret      ← readable by anyone in the path
```

**HTTPS** is HTTP running *inside* a TLS tunnel. The content is encrypted — routers can see the destination IP but not what you're sending.

```
   Browser sends (over the wire):
   [TLS record][xZ9#@!k2mQp...]           ← gibberish to anyone watching
```

The lock icon in the browser means: "the connection between my browser and the server I'm talking to is encrypted." It says nothing about what happens *after* that server — that's the Cloudflare nuance you need to understand.

---

### 16.2 TLS — How the Encrypted Tunnel Gets Built

TLS (Transport Layer Security) does two things:
1. **Authenticates** the server — proves you're talking to the real `login.sadhguru.org`, not an imposter
2. **Encrypts** everything after the handshake

Here's what the handshake looks like (simplified to what you need):

```
   Browser                                      Server (Cloudflare / ALB)
   ───────                                      ─────────────────────────

   1. ClientHello ──────────────────────────►
      "I support TLS 1.2/1.3, here are my
       cipher suites, and I want to reach
       login.sadhguru.org"  ← this is SNI
                                                2. ServerHello ◄────────
                                                   "Let's use TLS 1.3 +
                                                    AES-256-GCM cipher"

                                                3. Certificate ◄────────
                                                   server sends its TLS
                                                   certificate

   4. Browser verifies certificate
      (is it signed by a trusted CA?
       does it match the hostname?
       is it expired?)

   5. Key exchange ◄────────────────────────►
      Both sides derive the same
      symmetric encryption key
      (neither side sends the key itself
       — it's derived mathematically)

   6. Handshake complete. All data now
      encrypted with that symmetric key.
      ─────────────────────────────────►  7. Encrypted HTTP request arrives
```

**Key insight:** After the handshake, both sides have the *same secret key* — but that key was never sent over the wire. This is why HTTPS is secure even if someone recorded the handshake.

---

### 16.3 Certificates — What They Are and Why the Browser Trusts Them

A TLS certificate is a file that contains:
- The **domain name** it's valid for (e.g., `*.sadhguru.org`)
- The server's **public key**
- A **digital signature** from a Certificate Authority (CA) — e.g., Let's Encrypt, DigiCert, Amazon

```
   Certificate for *.sadhguru.org
   ├── Subject:  CN=*.sadhguru.org
   ├── Valid:    2025-01-01 → 2026-01-01
   ├── Public key: [long number]
   └── Signed by: Amazon (CA)
                    └── Signed by: Amazon Root CA
                                     └── in browser's built-in trust store
```

Your browser ships with ~150 trusted root CAs pre-installed (you can see them in browser settings). When a server presents a cert, the browser walks the chain: "was this cert signed by someone I trust?" If yes, the padlock appears.

**ACM (AWS Certificate Manager)** issues certs signed by Amazon's CA — which browsers trust. That's why ACM certs work for ALBs without any extra setup.

**What happens if the cert doesn't match?**
```
   You visit:    https://login.sadhguru.org
   Cert says:    CN=sadhguru.org  (no wildcard, no login. subdomain)
   Browser says: "Your connection is not private" NET::ERR_CERT_COMMON_NAME_INVALID
```

---

### 16.4 Cloudflare SSL/TLS Modes — The Most Misunderstood Setting

This is where most teams have a hidden misconfiguration. Cloudflare sits between your users and your ALB, which means there are **two separate TLS connections**:

```
   User ──[connection 1]──► Cloudflare ──[connection 2]──► ALB (your origin)
```

Cloudflare's SSL/TLS mode controls what **connection 2** looks like. There are 4 modes:

```
   ┌──────────────┬────────────────────────┬────────────────────────────────────┐
   │ Mode         │ User → Cloudflare      │ Cloudflare → ALB (origin)          │
   ├──────────────┼────────────────────────┼────────────────────────────────────┤
   │ Off          │ HTTP only              │ HTTP                               │
   │              │ (no encryption)        │                                    │
   ├──────────────┼────────────────────────┼────────────────────────────────────┤
   │ Flexible     │ HTTPS ✓                │ HTTP ✗  ← plain text to your ALB  │
   │              │ (user sees padlock)    │ ALB doesn't even need a cert       │
   ├──────────────┼────────────────────────┼────────────────────────────────────┤
   │ Full         │ HTTPS ✓                │ HTTPS ✓                            │
   │              │                        │ But cert NOT verified — self-signed │
   │              │                        │ or expired cert is fine            │
   ├──────────────┼────────────────────────┼────────────────────────────────────┤
   │ Full (Strict)│ HTTPS ✓                │ HTTPS ✓                            │
   │              │                        │ Cert IS verified — must be valid    │
   │              │                        │ CA-signed cert (e.g. ACM)          │
   └──────────────┴────────────────────────┴────────────────────────────────────┘
```

**Flexible is the dangerous one.** The user sees a padlock. The URL says `https://`. But between Cloudflare and your ALB, the data is travelling in plain text. Anyone with access to your internal network or AWS traffic logs can read it.

Production recommendation: **Full (Strict)** with an ACM certificate on your ALB.

---

### 16.5 The Full Picture — Encryption at Every Hop for Your Setup

```
   USER (browser)
        │
        │  HTTPS (TLS 1.3)
        │  Cert: Cloudflare's cert for *.sadhguru.org
        │  Encrypted: yes — browser ↔ Cloudflare
        ▼
   ┌─────────────────────────────────────────────┐
   │  CLOUDFLARE EDGE  (e.g. Mumbai PoP)         │
   │                                             │
   │  Terminates the browser's TLS connection.   │
   │  Decrypts the request.                      │
   │  Inspects it (DDoS, WAF rules, cache).      │
   │  Re-encrypts using a NEW TLS connection     │
   │  to your origin (ALB).                      │
   └──────────────────┬──────────────────────────┘
        │
        │  HTTPS (TLS — if mode is Full or Full Strict)
        │  Cert: your ACM cert on the ALB listener
        │  OR plain HTTP if mode is Flexible
        ▼
   ┌─────────────────────────────────────────────┐
   │  ALB (AWS ap-south-1)                       │
   │                                             │
   │  Listener :443 terminates TLS.              │
   │  Forwards to Target Group as plain HTTP     │
   │  (unless you configured end-to-end TLS).    │
   └──────────────────┬──────────────────────────┘
        │
        │  HTTP (plain text — within your VPC private network)
        │  This is acceptable: VPC is isolated, not the public internet.
        │  Traffic never leaves AWS's private backbone.
        ▼
   ┌─────────────────────────────────────────────┐
   │  EC2 / App (private subnet)                 │
   │  Receives plain HTTP on port 8080           │
   └─────────────────────────────────────────────┘
```

**Why is plain HTTP from ALB to EC2 acceptable?**
The ALB and your EC2 are inside a VPC. Traffic on that path never touches the public internet — it's on AWS's private internal network. Your Security Group already ensures only the ALB can send traffic to port 8080. For most workloads this is fine. For PCI-DSS or HIPAA, you'd enable end-to-end TLS (§12.5) to eliminate plaintext even inside the VPC.

---

### 16.6 What Cloudflare Actually Does to Your Request

When Cloudflare is in "proxy" mode (orange cloud in DNS settings), it's not just a DNS middleman — it's a full reverse proxy:

```
   ┌── What Cloudflare does before forwarding ──────────────────────────┐
   │                                                                    │
   │  1. Terminates TLS from the browser (decrypts the request)        │
   │  2. Inspects the request:                                          │
   │     - DDoS protection (rate limiting, challenge pages)            │
   │     - WAF rules (SQL injection patterns, OWASP top 10)            │
   │     - Bot detection                                                │
   │     - Cache check (is this response already cached?)              │
   │  3. Adds headers:                                                  │
   │     CF-Connecting-IP: <real client IP>   ← your ALB sees this     │
   │     X-Forwarded-For: <real client IP>                              │
   │     CF-Ray: 8a3b2c1d...                  ← unique request ID      │
   │  4. Opens a new TLS connection to your ALB                        │
   │  5. Forwards the request                                           │
   └────────────────────────────────────────────────────────────────────┘
```

**Important consequence:** Your ALB's access logs will show **Cloudflare's IP** as the source, not the real user's IP. To get the real client IP, read the `CF-Connecting-IP` or `X-Forwarded-For` header in your application.

---

### 16.7 SNI — How One ALB Serves Many Domains with Different Certs

When your browser opens a TLS connection to the ALB, it sends the target hostname in the first message (the ClientHello). This is called **SNI — Server Name Indication**.

```
   Browser connects to ALB IP and says:
   "I want to talk to login.sadhguru.org"  ← SNI

   ALB checks its listener's certificates:
   - Default cert: *.sadhguru.org  ✓ matches → use this cert
   - SNI cert:     api.example.com ✗ doesn't match

   ALB replies with the *.sadhguru.org certificate.
   TLS handshake completes.
```

Without SNI, you'd need one ALB (and one IP) per domain just for certificate selection. SNI is why a single ALB can host `login.sadhguru.org`, `pms.sadhguru.org`, and `ishalogin.sadhguru.org` all on port 443 with one listener.

---

### 16.8 Common Misconceptions — What Interviewers Probe

**"HTTPS means end-to-end encryption"**
Not necessarily. HTTPS means the *browser-to-first-server* connection is encrypted. If that server is Cloudflare in Flexible mode, the traffic from Cloudflare to your ALB is HTTP. The padlock doesn't say anything about what happens after Cloudflare.

**"The padlock means the site is safe / trustworthy"**
The padlock means the *connection* is encrypted — not that the site itself is legitimate. A phishing site can have a valid TLS cert and padlock.

**"Deleting an ALB won't affect HTTPS because Cloudflare handles it"**
Cloudflare handles the browser-facing TLS. But if Cloudflare is configured to forward to your ALB and the ALB is gone, every request Cloudflare proxies will get a connection refused → Cloudflare returns 521/522 errors to users.

**"Self-signed certs are always bad"**
Self-signed certs are fine for ALB→EC2 internal traffic (end-to-end TLS within VPC). They're a problem only at the public edge where a browser needs to verify the chain.

---

### 16.9 Quick Reference — Encryption Layer Summary

```
   Hop                          Protocol        Encrypted?    Who holds the cert?
   ─────────────────────────────────────────────────────────────────────────────
   Browser → Cloudflare         HTTPS/TLS 1.3   Yes           Cloudflare
   Cloudflare → ALB (Strict)    HTTPS/TLS       Yes           ACM cert on ALB
   Cloudflare → ALB (Flexible)  HTTP            NO            —
   ALB → EC2 (default setup)    HTTP            No            —  (VPC internal)
   ALB → EC2 (end-to-end TLS)   HTTPS           Yes           Self-signed or ACM
```

For a GCC/product company interview: if asked "is your setup secure?", the correct answer is not just "yes we use HTTPS" — it's "yes, we use Cloudflare Full Strict mode so traffic is encrypted browser-to-ALB, and the ALB is in a private VPC so ALB-to-EC2 plaintext is acceptable because it never leaves AWS's internal network."
