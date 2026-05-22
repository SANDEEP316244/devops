# AWS VPC — Production Setup Guide & Cross-VPC Traffic Walkthrough

A practical guide for someone new to AWS networking. Read it top-to-bottom and you should be able to (a) understand what each VPC building block does, (b) build a production-grade VPC, and (c) reason about how a request travels from one VPC to another when no direct route exists.

---

## 0. The Whole Picture (Mind Map)

```
                         ┌──────────────────────┐
                         │       AWS VPC        │
                         │   (your private      │
                         │     network)         │
                         └──────────┬───────────┘
                                    │
        ┌──────────────┬────────────┼────────────┬──────────────┐
        │              │            │            │              │
   ┌────▼────┐    ┌────▼────┐  ┌────▼────┐  ┌────▼────┐   ┌─────▼─────┐
   │  CIDR   │    │ Subnets │  │   IGW   │  │  Route  │   │   NAT     │
   │ block   │    │ (per AZ)│  │(door to │  │ Tables  │   │ Gateway   │
   │10.0.0/16│    │         │  │ internet│  │         │   │(outbound) │
   └─────────┘    └────┬────┘  └────┬────┘  └────┬────┘   └─────┬─────┘
                       │            │            │              │
                  ┌────┴────┐       │       ┌────┴────┐    ┌────┴────┐
                  │ Public  │       │       │ Routes  │    │   EIP   │
                  │ Private │       │       │ (rules) │    │(static  │
                  └─────────┘       │       └────┬────┘    │ public  │
                                    │            │         │   IP)   │
                                    │       ┌────┴────┐    └─────────┘
                                    │       │ Assoc.  │
                                    │       │ subnet ↔│
                                    │       │  table  │
                                    │       └─────────┘
                                    │
                              attaches to VPC
```

The relationships in one sentence: a **VPC** owns a **CIDR**, gets cut into **subnets**, each subnet is **associated** with a **route table** that contains **routes** pointing to **targets** like an **IGW** (for the public internet) or a **NAT gateway** (so private subnets can reach out without being reached in). An **EIP** is the static public IP you bolt onto things that need to live on the internet.

---

## 1. What is a VPC?

A **Virtual Private Cloud (VPC)** is your own logically isolated network inside AWS. You choose the IP address range, you carve it into subnets, you decide what is reachable from the internet and what is not. Nothing inside the VPC is reachable from outside unless you explicitly wire it up.

Think of a VPC as a private data center on rented hardware: you draw the floor plan, install the doors (gateways), put up signs that say where each hallway leads (route tables), and decide which rooms face the street (public subnets) versus which rooms are interior (private subnets).

---

## 2. Core Building Blocks

### 2.1 VPC with CIDR

When you create a VPC you assign it a **CIDR block** — a range of private IP addresses it will own.

- Typical choices: `10.0.0.0/16`, `172.31.0.0/16`, `192.168.0.0/16`
- A `/16` gives you 65,536 addresses — plenty of room for many subnets
- Pick from the **RFC 1918 private ranges**: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
- **Do not overlap** with on-prem networks or other VPCs you may want to peer with later — overlapping CIDRs cannot be peered

```
   VPC CIDR   10.0.0.0/16   ◄── 65,536 addresses (the whole pool)
   ├── Subnet 10.0.0.0/24   ◄── 256 addresses (a slice)
   ├── Subnet 10.0.1.0/24
   └── Subnet 10.0.2.0/24
```

### 2.2 Internet Gateway (IGW)

The IGW is the **door to the public internet**. It is a horizontally scaled, redundant AWS-managed component.

- One IGW per VPC
- Created separately, then **attached** to the VPC
- Performs **1:1 NAT** for instances that have an EIP/public IP — translating the public IP into the instance's private IP and vice versa
- Without an IGW attached, *nothing* in the VPC can reach the internet, no matter what else you configure

```
                INTERNET
                   │
                   ▼
            ┌─────────────┐
            │     IGW     │   ◄── 1:1 NAT: EIP ↔ private IP
            └──────┬──────┘
                   │  attached to
                   ▼
            ┌─────────────┐
            │     VPC     │
            └─────────────┘
```

### 2.3 Subnets with CIDR

A **subnet** is a slice of the VPC's CIDR, scoped to a single Availability Zone (AZ).

- Subnet CIDR must fit inside the VPC CIDR (e.g., VPC `10.0.0.0/16`, subnet `10.0.1.0/24`)
- Each subnet lives in exactly one AZ — for high availability, create subnets in at least 2 AZs
- AWS reserves 5 IPs in every subnet (network, VPC router, DNS, future use, broadcast)
- A subnet becomes **public** or **private** purely based on its **route table** — there is no checkbox for it. A subnet is "public" if its route table has a route to the IGW. Otherwise it is "private."

```
   ┌─────────────────────── VPC 10.0.0.0/16 ───────────────────────┐
   │                                                               │
   │   ┌────── AZ-a ──────┐         ┌────── AZ-b ──────┐           │
   │   │ Public  10.0.0/24│         │ Public  10.0.1/24│           │
   │   │ Private 10.0.10/24         │ Private 10.0.11/24           │
   │   │ Data    10.0.20/24         │ Data    10.0.21/24           │
   │   └──────────────────┘         └──────────────────┘           │
   └───────────────────────────────────────────────────────────────┘
```

### 2.4 Route Tables

A **route table** is a list of rules that says "for traffic going to this destination, send it to that target."

- Every VPC has a **main route table** by default
- You can create additional **custom** route tables
- Every route table includes an implicit **local route** for the VPC CIDR — this is what lets every subnet talk to every other subnet inside the VPC. You cannot delete or modify it.

### 2.5 Route Table Association with Subnets

A route table only takes effect on a subnet once you **associate** it.

- One subnet → exactly one route table at a time
- One route table → can be associated with many subnets
- If a subnet has no explicit association, it implicitly uses the **main** route table
- Best practice: leave the main route table empty/locked-down and create explicit route tables for "public" and "private" subnets

```
   Subnet A ──┐
   Subnet B ──┼──► rt-public  (0.0.0.0/0 → IGW)
              │
   Subnet C ──┼──► rt-private (0.0.0.0/0 → NAT)
   Subnet D ──┘
```

### 2.6 Routes

Individual entries inside a route table. Each has a **destination** (CIDR) and a **target** (where to send matching traffic).

| Destination     | Target          | Meaning                                       |
|-----------------|-----------------|-----------------------------------------------|
| `10.0.0.0/16`   | `local`         | Stay inside the VPC (implicit, always there)  |
| `0.0.0.0/0`     | `igw-xxx`       | "Default route" — send everything else to IGW |
| `0.0.0.0/0`     | `nat-xxx`       | Send everything else to a NAT gateway         |
| `10.1.0.0/16`   | `pcx-xxx`       | Send to a peered VPC                          |

AWS uses **longest-prefix match** — the most specific route wins.

```
   Packet dst=8.8.8.8 arrives at the subnet's router
                       │
                       ▼
        ┌──────────────────────────────────┐
        │ Match against route table:       │
        │   10.0.0.0/16 → local      ✗     │
        │   0.0.0.0/0   → igw-xxx    ✓     │
        └──────────────────────────────────┘
                       │
                       ▼
                Forward to IGW
```

### 2.7 Elastic IP (EIP)

An **EIP** is a static, public IPv4 address allocated to your account.

- Without an EIP (or auto-assigned public IP), an instance has no presence on the public internet
- You **associate** an EIP with an EC2 instance (or NAT gateway, or network interface)
- EIPs cost money when they are *not* in use — don't allocate and forget them
- An EIP only "works" if the underlying subnet has a route to the IGW; attaching an EIP to an instance in a private subnet does not magically give it internet

### 2.8 NAT Gateway

A NAT (Network Address Translation) gateway lets instances in **private** subnets initiate **outbound** connections to the internet (e.g., to download OS patches, hit external APIs) without being reachable inbound from the internet.

- AWS-managed, scales automatically
- Lives in a **public** subnet (it needs to talk to the IGW itself)
- Requires an **EIP** attached at creation time
- For HA: deploy one NAT gateway **per AZ** and route each AZ's private subnets to its local NAT — otherwise an AZ outage takes down outbound traffic for private subnets in surviving AZs
- **Outbound only** — NAT does *not* allow the public internet to initiate connections inward

```
                    INTERNET
                       │
                       ▼
                    ┌─────┐
                    │ IGW │
                    └──┬──┘
                       │
              ┌────────┴────────┐
              │                 │
        ┌─────▼────────┐        │
        │ Public subnet│        │   inbound from internet → BLOCKED
        │  ┌────────┐  │        │   by NAT (it only tracks outbound flows)
        │  │  NAT   │◄─┼────────┘
        │  │+ EIP   │  │
        │  └───┬────┘  │
        └──────┼───────┘
               │  outbound only
        ┌──────▼───────┐
        │Private subnet│
        │   App EC2    │ ──► outbound: app → NAT → IGW → internet ✓
        └──────────────┘     inbound:  internet → ??? → app       ✗
```

### 2.9 Adding the NAT Route to Private Subnets

The private subnet's route table needs:

```
0.0.0.0/0 → nat-gateway-id
```

Now an app server in a private subnet can `apt update`, hit `api.stripe.com`, push logs to an external SaaS — but no one on the internet can SSH to it.

---

## 3. Step-by-Step Production VPC Setup

Goal: a 2-AZ VPC for a typical web application (load balancer in front, app servers in the middle, database in the back).

### Final Architecture (visual)

```
                                  INTERNET
                                     │
                                  ┌──▼──┐
                                  │ IGW │
                                  └──┬──┘
                                     │
              ┌──────────────────────┴──────────────────────┐
              │                  ALB (public)               │
              └──┬───────────────────────────────────────┬──┘
                 │                                       │
   ═══ AZ-a ════════════════════════ │ ════════════════════════ AZ-b ═══
                 │                   │                   │
        ┌────────▼────────┐          │          ┌────────▼────────┐
        │ Public subnet   │          │          │ Public subnet   │
        │ 10.0.0.0/24     │          │          │ 10.0.1.0/24     │
        │   • NAT-a + EIP │          │          │   • NAT-b + EIP │
        │   • ALB ENI     │          │          │   • ALB ENI     │
        └────────┬────────┘          │          └────────┬────────┘
                 │                   │                   │
        ┌────────▼────────┐          │          ┌────────▼────────┐
        │ Private app     │          │          │ Private app     │
        │ 10.0.10.0/24    │          │          │ 10.0.11.0/24    │
        │   • App EC2/ECS │          │          │   • App EC2/ECS │
        └────────┬────────┘          │          └────────┬────────┘
                 │                   │                   │
        ┌────────▼────────┐          │          ┌────────▼────────┐
        │ Private data    │          │          │ Private data    │
        │ 10.0.20.0/24    │◄── RDS multi-AZ ──►│ 10.0.21.0/24    │
        │   • RDS primary │          │          │   • RDS standby │
        └─────────────────┘          │          └─────────────────┘
                                     │
   ═══════════════════════ VPC 10.0.0.0/16 ═══════════════════════════
```

### Step 1 — Plan the IP space

```
VPC:               10.0.0.0/16

Public subnets:    10.0.0.0/24    (AZ-a)
                   10.0.1.0/24    (AZ-b)

Private app:       10.0.10.0/24   (AZ-a)
                   10.0.11.0/24   (AZ-b)

Private data:      10.0.20.0/24   (AZ-a)
                   10.0.21.0/24   (AZ-b)
```

Leave gaps between groups so you can grow each tier later.

### Step 2 — Create the VPC

Set CIDR `10.0.0.0/16`. Enable DNS hostnames and DNS resolution.

### Step 3 — Create and attach an Internet Gateway

Create the IGW, then **attach** it to the VPC.

### Step 4 — Create the 6 subnets

Three per AZ, in the CIDRs above. Pick the right AZ for each subnet.

### Step 5 — Create route tables

- **`rt-public`** — for the two public subnets
- **`rt-private-a`** — for AZ-a's app + data subnets
- **`rt-private-b`** — for AZ-b's app + data subnets

(Two private route tables, one per AZ, so each routes to its own NAT for HA.)

### Step 6 — Add routes

In `rt-public`:
```
10.0.0.0/16 → local
0.0.0.0/0   → igw-xxx
```

In `rt-private-a` and `rt-private-b`: only `local` for now — NAT comes next.

### Step 7 — Associate subnets with route tables

```
   rt-public ──┬── public-a (10.0.0.0/24)
               └── public-b (10.0.1.0/24)

   rt-private-a ──┬── app-a  (10.0.10.0/24)
                  └── data-a (10.0.20.0/24)

   rt-private-b ──┬── app-b  (10.0.11.0/24)
                  └── data-b (10.0.21.0/24)
```

### Step 8 — Allocate EIPs and create NAT Gateways

- Allocate 2 EIPs
- Create one NAT gateway in each public subnet, attach one EIP to each

### Step 9 — Add NAT routes to private subnets

In `rt-private-a`:
```
0.0.0.0/0 → nat-gateway-in-AZ-a
```

In `rt-private-b`:
```
0.0.0.0/0 → nat-gateway-in-AZ-b
```

### Step 10 — Place workloads

- Application Load Balancer → public subnets
- App servers (EC2/ECS/EKS) → private app subnets
- RDS / ElastiCache → private data subnets

Lock down security groups to match: ALB SG accepts `:443` from `0.0.0.0/0`; app SG accepts `:8080` only from ALB SG; DB SG accepts `:5432` only from app SG.

```
   Internet ──:443──► [ALB SG]
                         │
                         └──:8080──► [App SG]
                                        │
                                        └──:5432──► [DB SG]
```

### Sanity checks before you call it production

- Subnets exist in **at least two AZs** for every tier
- Public subnets have a route to **IGW**, private subnets do **not**
- Each AZ has its **own NAT** (or you've consciously accepted the cost-vs-HA trade-off)
- No instance in a private subnet has a public IP
- VPC Flow Logs are enabled
- The default security group is empty (or unused)
- EIPs that are not attached are released

---

## 4. Cross-VPC Communication When No Direct Route Exists

> **Scenario:** A server in **VPC-A** needs to talk to a server in **VPC-B**. There is no VPC peering, no Transit Gateway, no VPN, no PrivateLink — nothing inside AWS connects them. How does the request actually get there, and what happens at the other end?

The short answer: **the request goes out to the public internet through VPC-A's IGW and comes back in through VPC-B's IGW** — the two VPCs treat each other like any other internet host.

### 4.1 Prerequisites for this to work at all

For the source server in VPC-A:
- It must be in a **public subnet** with an EIP, **or** in a private subnet with a NAT gateway in front of it. Either way it needs an outbound path to the internet.
- Its route table must have `0.0.0.0/0 → igw-or-nat`.

For the destination server in VPC-B:
- It must be **reachable from the public internet** in some form — meaning either it sits in a public subnet with an EIP, or there is something in a public subnet (load balancer, etc.) that fronts it.

### 4.2 Hop-by-hop diagram (destination is in a PUBLIC subnet)

Source instance has private IP `10.0.10.7` and EIP `54.99.99.99`.
Destination instance has private IP `10.1.5.55` and EIP `54.10.20.30`.

```
   ┌─────────────────────── VPC-A (10.0.0.0/16) ───────────────────────┐
   │                                                                   │
   │   ┌────── Public subnet ──────┐                                   │
   │   │  Source EC2               │                                   │
   │   │  private 10.0.10.7        │                                   │
   │   │  EIP     54.99.99.99      │                                   │
   │   └─────────────┬─────────────┘                                   │
   │                 │                                                 │
   │                 │ ① pkt: src=10.0.10.7  dst=54.10.20.30           │
   │                 ▼                                                 │
   │     ┌─────────────────────┐                                       │
   │     │  Route table lookup │  0.0.0.0/0 → IGW-A  ✓                 │
   │     └─────────────┬───────┘                                       │
   │                   ▼                                               │
   │              ┌─────────┐                                          │
   │              │  IGW-A  │  ② source-NAT: src 10.0.10.7 → 54.99.99.99
   │              └────┬────┘                                          │
   └───────────────────┼───────────────────────────────────────────────┘
                       │
                       ▼
            ╔══════════════════════╗
            ║  Public Internet     ║   ③ pkt: src=54.99.99.99  dst=54.10.20.30
            ║  (AWS backbone in    ║
            ║   practice)          ║
            ╚══════════┬═══════════╝
                       │
   ┌───────────────────┼───────────────────────────────────────────────┐
   │                   ▼                                               │
   │              ┌─────────┐                                          │
   │              │  IGW-B  │  ④ dest-NAT: dst 54.10.20.30 → 10.1.5.55 │
   │              └────┬────┘                                          │
   │                   │                                               │
   │                   │ ⑤ pkt: src=54.99.99.99  dst=10.1.5.55         │
   │                   ▼                                               │
   │   ┌────── Public subnet ──────┐                                   │
   │   │  Destination EC2          │ ⑥ delivered (if SG/NACL allow)    │
   │   │  private 10.1.5.55        │                                   │
   │   │  EIP     54.10.20.30      │                                   │
   │   └───────────────────────────┘                                   │
   │                                                                   │
   └─────────────────────── VPC-B (10.1.0.0/16) ───────────────────────┘
```

The key insight: **the IGW is the NAT device**. It is what makes a private `10.x.x.x` address visible on the internet as a public EIP, in both directions.

### 4.3 What if the destination subnet is PRIVATE?

A private subnet has **no route to an IGW**. That has two consequences that together make direct inbound from the internet impossible:

1. **You cannot attach an EIP that "works."** Technically the AWS console will let you associate an EIP with an instance in a private subnet, but no inbound traffic will ever reach it because there is no IGW in the routing path. There is nothing to perform the destination-NAT step.
2. **NAT gateway does not help inbound.** A NAT gateway is **outbound-only** — it tracks connections initiated from inside the VPC and allows their replies back in. It will silently drop a connection initiated from the public internet.

```
            INTERNET
               │
               ▼ pkt dst = ???
            ┌─────┐
            │IGW-B│  ◄── No EIP maps to a private-subnet instance.
            └──┬──┘     Even if you "attached" an EIP, there is no
               │        route from the IGW into a subnet without
               │        0.0.0.0/0 → IGW.
               ✗
            ┌─────────────────┐
            │  NAT Gateway    │  ◄── only allows OUTBOUND; silently
            │  (public subnet)│      drops new inbound connections
            └────────┬────────┘
                     ✗
            ┌────────────────────┐
            │  PRIVATE subnet    │
            │  ┌──────────────┐  │
            │  │ Dest EC2     │  │   never receives the request
            │  │ 10.1.5.55    │  │
            │  └──────────────┘  │
            └────────────────────┘
```

**The only ways for a private-subnet instance to be reached from outside its VPC** are:

```
   Option 1: front-end with a load balancer
   ┌─────────────┐   ┌──────────────────┐    ┌──────────────────┐
   │  Internet   │──►│ ALB/NLB (public) │───►│ App EC2 (private)│
   └─────────────┘   └──────────────────┘    └──────────────────┘
                          ▲
                          └── only the LB has an EIP / public DNS

   Option 2: private connectivity (preferred for VPC↔VPC)
   ┌────── VPC-A ──────┐                       ┌────── VPC-B ──────┐
   │ App (private)     │◄── peering / TGW ────►│ App (private)     │
   │                   │   PrivateLink / VPN   │                   │
   └───────────────────┘                       └───────────────────┘
   (no internet, no IGW; uses route table entries to the peer)
```

- Put a **load balancer** (ALB/NLB) in a **public** subnet of VPC-B — the LB has the public-facing EIP/DNS, terminates the connection, and forwards to the private instance over the VPC's internal network.
- Establish **VPC peering**, a **Transit Gateway**, **PrivateLink**, **VPN**, or **Direct Connect** — these create private routing paths so the request never has to leave AWS's private network or touch the internet.
- Place a **bastion / jump host** in a public subnet that the private instance trusts — typical for SSH, not for application traffic.

### 4.4 Public vs Private destination — side by side

| Aspect                          | Destination in PUBLIC subnet                  | Destination in PRIVATE subnet                                 |
|--------------------------------|-----------------------------------------------|---------------------------------------------------------------|
| Has EIP / public IP?           | Yes                                           | Effectively no (any attached EIP is non-functional)           |
| Route to IGW in its subnet?    | Yes (`0.0.0.0/0 → igw`)                       | No                                                            |
| Reachable from another VPC via internet path? | **Yes** — IGW does 1:1 NAT, packet delivered | **No** — packet has nowhere to land                           |
| To make it reachable           | Already reachable (lock down with SG/NACL)    | Front it with a load balancer in a public subnet, or set up peering / TGW / PrivateLink |
| Outbound to internet possible? | Yes, directly via IGW                         | Yes, via NAT gateway                                          |
| Typical use                    | Load balancers, bastions, NAT gateways        | App servers, databases, internal services                     |

### 4.5 Decision flow: how should two VPCs talk?

```
                    "VPC-A needs to reach VPC-B"
                                │
                                ▼
                ┌──────────────────────────────┐
                │ Same AWS account / org?      │
                │ Long-lived, high-volume?     │
                └──────────────────────────────┘
                       │              │
                      yes            no/maybe
                       ▼              ▼
            ┌─────────────────┐   ┌──────────────────────────┐
            │ Few VPCs (2–3)? │   │ Exposing one specific    │
            └────────┬────────┘   │ service only?            │
                yes  │  no        └────────────┬─────────────┘
                     ▼  ▼                      │
              ┌────────┐ ┌──────────────┐     yes/no
              │  VPC   │ │   Transit    │      ▼
              │Peering │ │   Gateway    │  ┌─────────────┐
              └────────┘ └──────────────┘  │ PrivateLink │
                                           │  (one-way)  │
                                           └─────────────┘
                                │
                                ▼
                 (last resort, dev/test only)
                ┌─────────────────────────────┐
                │  Public IGW path (§4.2)     │
                │  — costs more, less secure  │
                └─────────────────────────────┘
```

### 4.6 Why you would (and would not) use the internet path on purpose

You almost never *want* cross-VPC traffic to traverse the IGW path in production:

- It costs more (internet egress charges)
- It exposes your services to the public internet attack surface
- Latency and reliability depend on internet routing
- You lose the ability to use private DNS and private IPs

For real production cross-VPC traffic, use **VPC Peering**, **Transit Gateway**, or **PrivateLink**. The IGW-to-IGW path described above is mostly useful for understanding *how* the pieces fit together — and for explaining why a private-subnet instance simply cannot be reached that way.

---

## 5. Quick Reference Cheat Sheet

| Term         | One-liner                                                                |
|--------------|--------------------------------------------------------------------------|
| VPC          | Your private network in AWS, defined by a CIDR                           |
| Subnet       | A slice of a VPC, in one AZ                                              |
| IGW          | Door to the internet; performs 1:1 NAT for EIPs                          |
| EIP          | Static public IPv4 you allocate and attach                               |
| NAT Gateway  | Outbound-only internet access for private subnets                        |
| Route Table  | Rules that decide where traffic goes                                     |
| Route        | One rule: destination CIDR → target                                      |
| Association  | Link between a subnet and a route table                                  |
| Public subnet| A subnet whose route table has `0.0.0.0/0 → IGW`                         |
| Private subnet| A subnet without an IGW route (may have a NAT route)                    |

---

## 6. Common Mistakes to Avoid

- Choosing a VPC CIDR that overlaps with on-prem or another VPC you'll later peer
- Putting a database in a public subnet "just to make testing easier"
- A single NAT gateway shared across AZs — single point of failure
- Forgetting to attach the IGW after creating it (it doesn't auto-attach)
- Attaching an EIP to a private-subnet instance and expecting inbound internet to work
- Using the main route table for production subnets — use explicit custom tables
- Leaving the default security group permissive
- Allocating EIPs and forgetting to release them — they bill while idle

---

## 7. NACLs (Network Access Control Lists)

A **Network ACL** is a **stateless, subnet-level** firewall. Every subnet is associated with exactly one NACL; if you do not create one explicitly, the subnet uses the VPC's default NACL.

```
            ┌────────────────── Subnet 10.0.10.0/24 ──────────────────┐
            │                                                         │
   pkt ─►   │  NACL (stateless)  ──►  SG (stateful)  ──►  ENI / EC2   │
            │                                                         │
            └─────────────────────────────────────────────────────────┘
```

A packet must pass **both** the NACL and the security group to reach the instance. They evaluate independently — there is no shared state.

### 7.1 How NACLs are different from Security Groups

| Aspect              | Security Group                          | NACL                                                  |
|---------------------|-----------------------------------------|-------------------------------------------------------|
| Stateful?           | **Yes** — return traffic is auto-allowed | **No** — you must explicitly allow each direction     |
| Scope               | Per-ENI (per-instance)                  | Per-subnet                                            |
| Rule types          | **Allow only** (implicit deny)          | **Allow and Deny** (explicit deny is possible)        |
| Evaluation order    | All rules evaluated, any match = allow  | Rules evaluated in numeric order; first match wins    |
| Default             | Deny all inbound, allow all outbound    | Default NACL allows everything in and out            |
| Where it lives      | Attached to ENI                         | Associated to subnet                                  |
| Typical use         | Fine-grained allowlists between tiers   | Subnet-wide deny / regulatory boundary                |

### 7.2 Rules — inbound and outbound

A NACL has two independent rule lists: **inbound** and **outbound**. Each rule has:

```
   Rule #     (e.g. 100, 200; lower number evaluated first)
   Protocol   (TCP, UDP, ICMP, or all)
   Port range (e.g. 443, or 1024-65535)
   Source/Dest CIDR
   Allow / Deny
```

Evaluation: rules are processed **in ascending rule-number order**, the **first match wins**. At the end is an implicit `* DENY` you cannot remove. Anti-pattern: putting a `DENY 0.0.0.0/0` at rule #100 and an `ALLOW 443` at rule #200 — the deny fires first and the allow is never reached.

### 7.3 The "stateless" trap — ephemeral ports

Because NACLs are stateless, the return half of a connection is **a separate flow** as far as the NACL is concerned. If you allow inbound HTTPS but block outbound ephemeral ports, the server can never reply.

```
   Client 203.0.113.5:54321  ─── SYN, dst=:443 ───►  Server 10.0.10.7:443
                                                                 │
   Client 203.0.113.5:54321  ◄── SYN-ACK, src=:443, dst=:54321 ──┘
                                                       ▲
                                                       │
                                      NACL outbound must allow :1024-65535
                                      to 0.0.0.0/0 — otherwise the SYN-ACK
                                      is dropped and the client times out
```

The conventional minimum-viable NACL for a public web subnet:

```
   Inbound
   100  ALLOW  TCP   443        from 0.0.0.0/0
   110  ALLOW  TCP   80         from 0.0.0.0/0
   120  ALLOW  TCP   1024-65535 from 0.0.0.0/0    ← return traffic for outbound conns
   *    DENY   all              (implicit)

   Outbound
   100  ALLOW  TCP   443        to 0.0.0.0/0
   110  ALLOW  TCP   80         to 0.0.0.0/0
   120  ALLOW  TCP   1024-65535 to 0.0.0.0/0      ← return traffic for inbound conns
   *    DENY   all              (implicit)
```

### 7.4 When to use NACLs vs Security Groups

Defaults you should keep:

- **Use security groups as your primary control.** They are stateful, instance-scoped, and let you reason about flows the way the application sees them.
- **Use NACLs for coarse, subnet-wide policy.** Examples:
  - Block a known-bad IP range across an entire subnet without touching every SG
  - Enforce a regulatory boundary ("nothing in this PCI subnet may speak to the rest of the VPC") via an explicit `DENY`
  - Cheap blast-radius limiter during an incident — drop all traffic from a CIDR in one place

If you find yourself reimplementing security-group rules in NACLs you've taken a wrong turn.

### 7.5 Symptom-first: "Connections drop randomly after a few seconds"

Classic NACL misconfiguration. The application opens a TCP connection, exchanges some bytes, then everything stalls and eventually RSTs. The cause is almost always:

- An outbound NACL rule allows the destination port but not the **ephemeral source port** of the reply
- Or you "tightened" the inbound NACL to a single port and the OS started picking source ports outside the range you allowed

Confirm by enabling Flow Logs (see §9) and searching for `REJECT` actions on the affected ENI — the rejected packet's port range will name the missing rule.

### 7.6 Anti-patterns

- Putting an explicit `DENY 0.0.0.0/0` somewhere in the middle of the rule list to "be safe" — the implicit `*` deny is already there, an explicit one above your allow rules will silently swallow traffic
- Treating NACLs as the place to do per-app allowlisting (the granularity is wrong, and you'll forget the rule exists when debugging the SG)
- Modifying the **default** NACL instead of creating a custom one — when you replace it later, the audit trail is gone

---

## 8. VPC Endpoints

A **VPC endpoint** lets resources inside your VPC reach AWS services **without traversing the internet, NAT, or an IGW**. The traffic stays on the AWS internal network.

There are two distinct flavors that look the same on the console but behave differently underneath.

### 8.1 Gateway Endpoints — S3 and DynamoDB only

Gateway endpoints are **free** and work by adding a magic **prefix-list route** to a route table.

```
   Route table on the private subnet
   ───────────────────────────────────────────
   10.0.0.0/16        → local
   pl-78a54011  (S3)  → vpce-xxx-s3-gw     ← AWS-managed prefix list
   0.0.0.0/0          → nat-xxx
```

`pl-78a54011` is a **prefix list** — an AWS-maintained, periodically-updated set of CIDRs that cover all S3 IPs in the region. When the EC2 sends a packet to `s3.ap-south-1.amazonaws.com`, DNS resolves it to one of those IPs, the longest-prefix match wins (more specific than `0.0.0.0/0`), and the packet is delivered via the gateway endpoint instead of through NAT.

Why this matters operationally:

- **No NAT data-processing charges** for S3/DynamoDB traffic
- **No IGW egress** for the same
- The S3 service still sees the call as coming from inside the VPC — you can write a bucket policy that **only allows access from `aws:sourceVpce`**
- Only supports S3 and DynamoDB (those are the only two services with gateway endpoints)

### 8.2 Interface Endpoints — most other AWS services (PrivateLink)

Interface endpoints are **PrivateLink** under the hood. AWS creates an **ENI in each of your specified subnets**, with a private IP from that subnet's CIDR.

```
   ┌──────────── Private subnet 10.0.10.0/24 ────────────┐
   │                                                     │
   │   EC2 ──►  Endpoint ENI  10.0.10.42  (vpce-...)    │
   │              │                                      │
   │              ▼                                      │
   │   (PrivateLink tunnel to the AWS service)          │
   │                                                     │
   └─────────────────────────────────────────────────────┘
```

- Costs money — per ENI per hour, plus data processing
- DNS resolution: when you enable **private DNS** on the endpoint, AWS intercepts the service's public hostname (e.g. `sts.ap-south-1.amazonaws.com`) and resolves it to the endpoint ENI's private IP **only inside the VPC**
- The endpoint ENI **has its own security group** — you must allow inbound 443 from the calling instances' SG, otherwise the API call times out (a classic gotcha)
- Works for almost every AWS API — SSM, Secrets Manager, KMS, CloudWatch Logs, ECR, STS, etc.

### 8.3 When to actually use them

- **Private subnet calls to S3/DynamoDB at non-trivial volume** — gateway endpoint is free and removes the NAT data charge, often the largest single line item on a VPC bill
- **Compliance: "data must not traverse the public internet"** — interface endpoints for KMS, Secrets Manager, etc., keep AWS API traffic inside the VPC
- **EKS / Fargate workloads** that pull container images — VPC endpoint for ECR + ECR-DKR + S3 (ECR's underlying storage) lets pods pull images without NAT
- **SSM Session Manager into a fully-private instance** — needs interface endpoints for `ssm`, `ssmmessages`, `ec2messages`

### 8.4 Endpoint policies

Each endpoint can attach a **resource policy** that further restricts what can be done through it. Common pattern: an S3 gateway endpoint policy that allows only specific buckets, so an attacker who compromises an EC2 can't exfiltrate to an arbitrary S3 bucket.

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": ["s3:GetObject", "s3:PutObject"],
    "Resource": [
      "arn:aws:s3:::my-app-bucket",
      "arn:aws:s3:::my-app-bucket/*"
    ]
  }]
}
```

### 8.5 Common mistakes

- **Creating an Interface Endpoint and forgetting the security group on the endpoint ENI** — your API call hangs for 60s and times out. The endpoint SG must allow `:443` from your callers.
- **Forgetting to enable Private DNS** — your code calls `sts.ap-south-1.amazonaws.com` and the resolver returns the public IP because the override isn't in place. Traffic still goes through NAT/IGW silently; you pay for the endpoint and get none of the benefit.
- **Adding a Gateway Endpoint for S3 but the route table it landed in is the wrong one** — only subnets associated with the chosen route table benefit. The other subnets still go via NAT.
- **VPC has `enableDnsSupport=false` or `enableDnsHostnames=false`** — private DNS overrides don't apply; treat both as non-negotiable when using interface endpoints.
- **Bucket policy with `aws:sourceVpce` for the wrong endpoint ID** — locks legitimate traffic out. Test the policy in a non-prod bucket first.

---

## 9. VPC Flow Logs

Flow logs capture **metadata about IP traffic** going to and from network interfaces in your VPC. They do not capture packet contents — they are essentially the AWS equivalent of `netflow`.

### 9.1 Where they can be enabled and where they go

You can enable flow logs at three scopes:

```
   VPC-level    ─►  every ENI in the VPC
   Subnet-level ─►  every ENI in the subnet
   ENI-level    ─►  one specific ENI
```

Destinations:

- **CloudWatch Logs** — easy to query with Logs Insights, costs more
- **S3** — cheaper, queryable via Athena, what most teams use for retention
- **Kinesis Data Firehose** — for streaming into a SIEM

### 9.2 What a flow log line looks like

Default v2 format, in order:

```
   version account-id interface-id srcaddr dstaddr srcport dstport
   protocol packets bytes start end action log-status
```

Example:

```
   2 700392259328 eni-0abc12345 10.0.10.7 8.8.8.8 54321 53 17 1 73 1716000000 1716000060 ACCEPT OK
   │  │            │             │         │       │     │  │  │ │  │           │           │       │
   │  │            │             │         │       │     │  │  │ │  │           │           │       └─ log delivery status
   │  │            │             │         │       │     │  │  │ │  │           │           └───────── ACCEPT / REJECT / NODATA
   │  │            │             │         │       │     │  │  │ │  │           └───────────────────── window end (epoch)
   │  │            │             │         │       │     │  │  │ │  └───────────────────────────────── window start (epoch)
   │  │            │             │         │       │     │  │  │ └──────────────────────────────────── bytes
   │  │            │             │         │       │     │  │  └────────────────────────────────────── packets
   │  │            │             │         │       │     │  └───────────────────────────────────────── IANA protocol (6=TCP, 17=UDP, 1=ICMP)
   │  │            │             │         │       │     └──────────────────────────────────────────── dst port
   │  │            │             │         │       └────────────────────────────────────────────────── src port
   │  │            │             │         └────────────────────────────────────────────────────────── dst IP
   │  │            │             └──────────────────────────────────────────────────────────────────── src IP
   │  │            └────────────────────────────────────────────────────────────────────────────────── ENI ID
   │  └─────────────────────────────────────────────────────────────────────────────────────────────── account
   └────────────────────────────────────────────────────────────────────────────────────────────────── log format version
```

You can also use a **custom format** to add fields like `vpc-id`, `subnet-id`, `pkt-srcaddr` (the original source before any NAT), `tcp-flags`, `flow-direction`, and `traffic-path` — extremely useful for debugging.

### 9.3 ACCEPT vs REJECT vs NODATA

- `ACCEPT` — the traffic was allowed by the SG and NACL
- `REJECT` — the traffic was blocked. **The block could be at either NACL or SG**; the flow log does not tell you which.
- `NODATA` — no traffic was seen on this ENI in the aggregation window (common on idle ENIs)

Flow logs aggregate per-window (1- or 10-minute), so the `packets`/`bytes` count is a sum over that window, not a per-flow record.

### 9.4 Using flow logs to debug

**Symptom: "My EC2 in a private subnet can't reach S3."**

1. Note the ENI of the EC2 and the S3 endpoint/prefix you expect it to call.
2. In Logs Insights:

   ```
   filter interface-id = "eni-0abc..." and action = "REJECT"
   | stats count() by srcaddr, dstaddr, dstport
   ```
3. If you see `REJECT` entries with `dstport 443` to a CIDR in the S3 prefix list — your SG or NACL is blocking. If you see **no rejects at all** and **no accepts** — the packet never even reached the ENI, and the issue is upstream (route table missing the S3 endpoint route, DNS resolving to a wrong IP).

**Symptom: "Latency spike, was it traffic from one source?"**

```
   filter dstaddr = "10.0.20.50" and dstport = 5432
   | stats sum(bytes) as bytes by srcaddr
   | sort bytes desc
   | limit 10
```

A single source IP dominating is often a runaway batch job.

### 9.5 What flow logs do NOT capture

- **DNS queries** to the VPC resolver (169.254.169.253) — use Route53 Resolver query logging for that
- **Traffic to/from 169.254.169.254** (the EC2 instance metadata service)
- **Traffic to the reserved DHCP/router IPs** in the VPC
- **Mirror-quality packet data** — for actual packet inspection, use VPC Traffic Mirroring (NLB or ENI-source) into a Suricata/Zeek sensor

Flow logs are a metadata stream. If you need to know *why* a request failed at the application layer, you still need app logs; flow logs only tell you whether the packet was allowed onto the wire.

### 9.6 Production posture

- Enable flow logs at the **VPC level** in every account from day one — the cost is negligible compared to debugging without them
- Send to **S3 with a 30–90 day lifecycle policy to Glacier**; query with Athena
- Use the **custom format** that includes `vpc-id`, `subnet-id`, `pkt-srcaddr`, `pkt-dstaddr`, `flow-direction`, `traffic-path`, `tcp-flags`
- Wire an Athena saved query named `"recent_rejects_per_eni"` so on-call doesn't have to rediscover the schema at 3am

---

## 10. DNS in a VPC

### 10.1 The two VPC DNS settings

A VPC has two boolean attributes that control DNS:

```
   enableDnsSupport     true  → the VPC resolver (at 10.x.0.2) answers queries
                        false → no in-VPC DNS at all; instances need external resolvers

   enableDnsHostnames   true  → public-IP instances get an AWS DNS hostname
                                like ec2-54-x-x-x.ap-south-1.compute.amazonaws.com
                        false → no auto-generated public DNS names
```

For anything beyond a one-off lab, **leave both `true`**. Interface endpoints with private DNS, ECR pulls, and many other things silently break if you flip them off.

### 10.2 The VPC resolver — `VPC CIDR base + 2`

Every VPC has a built-in DNS resolver reachable at the **VPC's CIDR base address + 2**. For `10.0.0.0/16` that's `10.0.0.2`. Instances also see it via the link-local `169.254.169.253`.

```
   VPC 10.0.0.0/16
       ├── 10.0.0.0  → network address (reserved)
       ├── 10.0.0.1  → VPC router (reserved)
       ├── 10.0.0.2  → VPC DNS resolver (reserved)  ◄── this one
       ├── 10.0.0.3  → reserved for future use
       └── 10.0.0.255 → broadcast (reserved, not actually used in AWS)
```

The DHCP options set for the VPC tells instances to use this resolver. The resolver answers:

- **Public DNS** — recursively, against AWS's upstream resolvers
- **Private hosted zones** — any Route53 PHZ associated with this VPC
- **VPC interface endpoint private DNS** — service hostnames override to endpoint ENIs
- **Default `compute.internal` hostnames** — `ip-10-0-10-7.ap-south-1.compute.internal` etc.

### 10.3 Route53 Private Hosted Zones (PHZ)

A **private hosted zone** is a Route53 zone that is only resolvable from VPCs you explicitly **associate** with it. The same domain name (e.g. `internal.isha.in`) can have a public hosted zone in Cloudflare and a private hosted zone in Route53 with completely different records — and instances in the associated VPC will see the private one.

```
   ┌───── Route53 Private Hosted Zone: internal.isha.in ─────┐
   │                                                          │
   │   Associated VPCs:                                       │
   │     vpc-aaaaa  (prod)                                    │
   │     vpc-bbbbb  (stage)                                   │
   │                                                          │
   │   Records:                                               │
   │     db.internal.isha.in   A      10.0.20.50              │
   │     api.internal.isha.in  CNAME  internal-alb-xxx.elb... │
   │                                                          │
   └──────────────────────────────────────────────────────────┘
```

Common failure: you create the PHZ but **forget to associate it with the VPC**. Instances cannot resolve `db.internal.isha.in`, you spend an hour debugging, then you spot the missing association in the PHZ page.

### 10.4 Route53 Resolver — inbound and outbound endpoints (hybrid DNS)

When you connect AWS to on-premises via VPN or Direct Connect, you usually want DNS to work in **both directions**:

- On-prem hosts should resolve `db.internal.isha.in` (a name in a Route53 PHZ)
- AWS instances should resolve `corp-ad.example.local` (a name in your on-prem AD DNS)

That is what **Route53 Resolver endpoints** are for:

```
                  Corp DC                       AWS
                  ┌──────┐                      ┌─────────────────────────────┐
                  │ DNS  │                      │                             │
                  │ srv  │                      │  ┌────────────────────────┐ │
                  │      │◄── outbound rule ────┼──┤ Resolver OUTBOUND ep   │ │
                  │      │   "for *.local, ask  │  │ (ENIs in private subs) │ │
                  │      │   on-prem DNS"       │  └────────────────────────┘ │
                  │      │                      │                             │
                  │      │── on-prem fwd ──────►┼──┤ Resolver INBOUND ep      │
                  │      │   for *.isha.in      │  │ (ENIs in private subs)   │
                  └──────┘                      │  └────────────────────────┘ │
                                                │       │                     │
                                                │       └─► VPC resolver      │
                                                │           (Route53 PHZ etc.)│
                                                └─────────────────────────────┘
```

- **Inbound endpoint** — gives on-prem DNS a target IP (the resolver ENIs) to forward queries for AWS-side names to
- **Outbound endpoint** — runs **resolver rules** that say "forward queries for these domains to those on-prem DNS servers"

You enable hybrid DNS by creating both endpoints (each is a pair of ENIs, one per AZ) and one or more resolver rules.

### 10.5 Symptom-first: "I can't resolve `db.internal.isha.in` from my EC2"

Step through these in order:

1. From the EC2, run `dig db.internal.isha.in @169.254.169.253` (or `@10.0.0.2`). If it returns `NXDOMAIN`:
2. Check the PHZ exists: `aws route53 list-hosted-zones --query "HostedZones[?Name=='internal.isha.in.']"`. If it does:
3. Check the VPC is **associated** with the PHZ: `aws route53 get-hosted-zone --id Z...`. If not, that's your bug.
4. If the PHZ is associated but the record is missing, well, it's missing — list records: `aws route53 list-resource-record-sets --hosted-zone-id Z...`
5. If everything looks right but `dig` still fails — confirm `enableDnsSupport` on the VPC. `aws ec2 describe-vpcs --vpc-ids $VPC_ID --query 'Vpcs[0].EnableDnsSupport'` must be `true`.
6. If you're hybrid with on-prem and the name is on-prem — check your outbound resolver rules and the resolver endpoint health.

### 10.6 Anti-patterns

- A PHZ named `internal.example.com` and another **public** zone named `internal.example.com` in Cloudflare with different records — instances in a non-associated VPC see the public records and get very confused
- Pointing apps at `10.0.0.2` directly instead of the system resolver — works until you build a new VPC with a different CIDR
- Disabling `enableDnsHostnames` and then wondering why ECR pulls and SSM agent intermittently fail (they sometimes depend on auto-generated hostnames)

---

## 11. Troubleshooting Connectivity — Symptom-First Debug Workflows

Each scenario starts from the user-visible symptom and walks the layers in order. Stop at the first layer that yields a fix.

### 11.1 "EC2 in a PRIVATE subnet can't reach the internet"

Test: `curl -v https://www.google.com` from the instance hangs / times out.

```
   1. Is there a 0.0.0.0/0 route at all?
      aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$SUBNET_ID
      → look for a route 0.0.0.0/0 → nat-xxx
      → if missing, add it; that's the bug

   2. Is the NAT gateway up?
      aws ec2 describe-nat-gateways --filter Name=subnet-id,Values=$PUBLIC_SUBNET
      → State must be "available"
      → if "failed" or "deleted", recreate (and remember to update the route)

   3. Does the NAT have an EIP?
      Visible in the same describe-nat-gateways call. No EIP = NAT can't egress.

   4. Is the NAT's own subnet public?
      The NAT must live in a subnet whose route table has 0.0.0.0/0 → IGW.
      If you put a NAT in a private subnet, it will silently fail forever.

   5. Is the EC2's security group allowing OUTBOUND :443?
      Default SG allows all outbound. If someone tightened it, you need explicit
      allow rules for the ports you actually use.

   6. NACL on the private subnet — does it allow outbound :443 AND inbound :1024-65535
      for the return traffic? Default NACL allows all; custom ones often don't.

   7. DNS resolving? `dig www.google.com @169.254.169.253` — if NXDOMAIN, the
      problem isn't routing, it's DNS (see §10).

   8. Flow logs:
      filter interface-id = $ENI_ID
      | stats count() by action
      → all REJECT? SG/NACL blocking. No entries at all? Route table.
```

### 11.2 "EC2 in a PUBLIC subnet can't reach the internet"

Test: same `curl` hangs from an instance you believe is in a public subnet.

```
   1. Does the instance actually have a public IP / EIP?
      Without one, an IGW route alone does nothing — the IGW NATs against
      the public IP, and "no public IP" means no NAT mapping.
      Fix: associate an EIP, or relaunch with --associate-public-ip-address.

   2. Does the subnet's route table really have 0.0.0.0/0 → igw-xxx?
      If the subnet is implicitly using the main route table and main lacks
      that route, you only *think* you're in a public subnet.

   3. Is the IGW actually attached to the VPC?
      aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC_ID
      → must show Attachments[0].State=available

   4. Security group outbound and NACL — same checks as §11.1.

   5. Test with curl --resolve to bypass DNS:
      curl -v --resolve www.google.com:443:142.250.x.x https://www.google.com
      If that works but plain curl doesn't, you have a DNS problem, not a routing one.
```

### 11.3 "Can't SSH to an EC2 instance"

```
   1. Where is the instance?
      → Public subnet with public IP? Direct SSH should work.
      → Private subnet? You need a bastion, SSM Session Manager, or VPN/peering.

   2. Is sshd actually running?
      Use SSM Session Manager (no SSH needed) or EC2 Serial Console to log in
      and `systemctl status sshd`. Often the answer is the disk is full and
      sshd's auth pipeline can't write a PAM log.

   3. Security group: inbound :22 from your IP?
      Many shops restrict :22 to the corp VPN CIDR — if you're WFH off the
      VPN, you're blocked.

   4. NACL on the subnet: inbound :22 AND outbound :1024-65535 (return)?

   5. Network reachability test:
      aws ec2 start-network-insights-path-analysis --network-insights-path-id ...
      Or simpler:
      aws ec2 describe-instance-status --instance-id $ID
      → if "instance reachability" is failing, the instance itself is wedged.

   6. Key pair / username mismatch:
      Amazon Linux: ec2-user. Ubuntu: ubuntu. Debian: admin. Try the right one.
      Permission denied (publickey) with the right user → key isn't installed
      → if it was working yesterday, did someone reboot from a different AMI?

   7. Could the SSH host key have changed?
      Look at ~/.ssh/known_hosts conflict — relaunched instance with new key.

   8. Last resort: detach the root EBS, mount on a helper instance, fix the
      sshd_config / authorized_keys, reattach.
```

### 11.4 "Service A in VPC-A can't reach Service B in VPC-B (peering is set up)"

```
   1. Peering connection: status = "active"?
      aws ec2 describe-vpc-peering-connections --filters Name=status-code,Values=active
      → "pending-acceptance" is the #1 cause; the other account hasn't accepted.

   2. CIDR overlap?
      aws ec2 describe-vpcs --vpc-ids $VPCA $VPCB --query 'Vpcs[].CidrBlock'
      → If they overlap, peering CANNOT route. AWS won't let you create
        overlapping peering routes; the symptom is "I set it up but traffic
        doesn't flow."

   3. Routes in BOTH directions:
      In VPC-A's route table (for the subnet hosting Service A):
         10.1.0.0/16 → pcx-xxxxx
      In VPC-B's route table (for the subnet hosting Service B):
         10.0.0.0/16 → pcx-xxxxx
      Missing the return route is the second most common bug.

   4. Security groups:
      Peered SGs can reference each other ONLY if both VPCs are in the same
      region. Cross-region peering requires CIDR-based SG rules. Confirm the
      target SG allows inbound from the source's CIDR (or SG, if same-region).

   5. NACLs on both subnets:
      Source subnet outbound + ephemeral inbound.
      Destination subnet inbound + ephemeral outbound.

   6. DNS resolution across peering:
      By default, instances in VPC-A cannot resolve VPC-B's private DNS names.
      Enable "DNS resolution from accepter VPC to private DNS" on the peering
      attachment (both sides), or share a Route53 PHZ across both VPCs.

   7. End-to-end test from the source EC2:
      curl -v http://<service-b-private-ip>:<port>/healthz
      → "No route to host"   → route table missing
      → "Connection timed out" → SG/NACL or no listener on the other side
      → "Connection refused"   → service isn't listening
```

### 11.5 "ALB returning 502/503 to clients"

(See `ALB_DNS_Route53_WAF_CloudFlare_Explained.md` §13–14 for the full ALB-side workflow. The VPC-layer summary:)

```
   1. describe-target-health → are any targets healthy?
      All unhealthy → 503. None registered → 503.

   2. From a sibling instance, curl the EC2 directly on its health check
      port and path: curl http://10.0.10.7:8080/healthz
      Works directly but ALB says unhealthy → SG between ALB and EC2 is
      blocking, or EC2 is binding to 127.0.0.1 instead of 0.0.0.0.

   3. Mid-request 502 → target closed the TCP socket before responding.
      Most common cause: target keep-alive timeout < ALB idle timeout.

   4. 504 → target is alive but slow. Look at target's app metrics.

   5. Flow logs on the target's ENI: ACCEPT inbound from ALB SG, with
      bytes returning → the network is fine, the app is the problem.
```

---

## 12. Hands-on Exercise — Build a 2-AZ VPC from Scratch with the AWS CLI

**Goal:** From a clean slate, build a 2-AZ VPC, deploy an EC2 in a private subnet, give it outbound internet through NAT, and front it with an ALB. End state: `curl http://<alb-dns>/` returns a response from the private EC2.

This is the production pattern from §3 expressed as concrete CLI commands you can run end-to-end. Don't paste the whole thing blindly — run it block by block and inspect each output.

### 12.1 Variables and pre-flight

```bash
export REGION=ap-south-1
export AZ_A=${REGION}a
export AZ_B=${REGION}b
export AMI=$(aws ssm get-parameter --region $REGION \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
echo "Using AMI: $AMI"
```

### 12.2 VPC, IGW

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.42.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=lab-vpc}]' \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=lab-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
```

### 12.3 Subnets — 2 public, 2 private

```bash
PUB_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.42.0.0/24 \
  --availability-zone $AZ_A \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=lab-pub-a}]' \
  --query 'Subnet.SubnetId' --output text)

PUB_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.42.1.0/24 \
  --availability-zone $AZ_B \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=lab-pub-b}]' \
  --query 'Subnet.SubnetId' --output text)

PRV_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.42.10.0/24 \
  --availability-zone $AZ_A \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=lab-prv-a}]' \
  --query 'Subnet.SubnetId' --output text)

PRV_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.42.11.0/24 \
  --availability-zone $AZ_B \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=lab-prv-b}]' \
  --query 'Subnet.SubnetId' --output text)
```

### 12.4 NAT gateway (one for the lab; per-AZ for real prod)

```bash
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=lab-nat-eip}]' \
  --query 'AllocationId' --output text)

NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_A \
  --allocation-id $EIP_ALLOC \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=lab-nat}]' \
  --query 'NatGateway.NatGatewayId' --output text)

# NAT creation takes ~1–2 minutes; wait until available
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID
```

### 12.5 Route tables

```bash
# Public route table
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=lab-rt-pub}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PUB \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB_A
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB_B

# Private route table
RT_PRV=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=lab-rt-prv}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PRV \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID
aws ec2 associate-route-table --route-table-id $RT_PRV --subnet-id $PRV_A
aws ec2 associate-route-table --route-table-id $RT_PRV --subnet-id $PRV_B
```

### 12.6 Security groups

```bash
ALB_SG=$(aws ec2 create-security-group --group-name lab-alb-sg \
  --description "lab ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

APP_SG=$(aws ec2 create-security-group --group-name lab-app-sg \
  --description "lab app" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --protocol tcp --port 80 --source-group $ALB_SG
```

### 12.7 IAM instance profile for SSM (so you can connect without SSH)

```bash
aws iam create-role --role-name lab-ssm-role --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' >/dev/null

aws iam attach-role-policy --role-name lab-ssm-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name lab-ssm-profile >/dev/null
aws iam add-role-to-instance-profile \
  --instance-profile-name lab-ssm-profile --role-name lab-ssm-role
sleep 10   # IAM propagation
```

### 12.8 EC2 in the private subnet

```bash
USERDATA=$(base64 -w0 <<'EOF'
#!/bin/bash
dnf install -y nginx
echo "hello from $(hostname) in the private subnet" >/usr/share/nginx/html/index.html
cat >/etc/nginx/conf.d/healthz.conf <<NGX
server { listen 80 default_server; root /usr/share/nginx/html;
  location = /healthz { return 200 "ok\n"; default_type text/plain; }
  location / { try_files \$uri \$uri/ =404; }
}
NGX
systemctl enable --now nginx
EOF
)

EC2_ID=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro \
  --subnet-id $PRV_A --security-group-ids $APP_SG \
  --iam-instance-profile Name=lab-ssm-profile \
  --user-data "$USERDATA" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=lab-app}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids $EC2_ID
```

### 12.9 Verify outbound internet from the private EC2

Wait ~60s for user-data and SSM agent to register, then:

```bash
aws ssm start-session --target $EC2_ID
# inside the session:
curl -v https://www.amazonaws.com   # should connect; proves NAT works
exit
```

If this hangs, your NAT/route/SG chain is wrong — fix it before continuing. (Walk §11.1.)

### 12.10 Target group + ALB

```bash
TG_ARN=$(aws elbv2 create-target-group --name lab-tg \
  --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type instance \
  --health-check-path /healthz --health-check-interval-seconds 10 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$EC2_ID

ALB_ARN=$(aws elbv2 create-load-balancer --name lab-alb \
  --type application --scheme internet-facing \
  --subnets $PUB_A $PUB_B --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN >/dev/null
```

### 12.11 End-to-end test

Wait for the target to go healthy (~30–60s after registration):

```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].TargetHealth.State'
# expect: ["healthy"]

curl -s http://$ALB_DNS/
# expect: "hello from <hostname> in the private subnet"
```

You have just exercised: VPC, subnets across AZs, IGW, route tables, NAT, security groups (with SG-referencing-SG), an EC2 in a private subnet with managed access (SSM), and an ALB forwarding internet traffic to it. The same pattern scales straight to a real production deployment — just add a second NAT in `$PUB_B`, a second EC2 in `$PRV_B`, and an RDS multi-AZ.

### 12.12 Tear down (do this!)

```bash
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
sleep 15
aws elbv2 delete-target-group --target-group-arn $TG_ARN
aws ec2 terminate-instances --instance-ids $EC2_ID
aws ec2 wait instance-terminated --instance-ids $EC2_ID
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_ID
aws ec2 release-address --allocation-id $EIP_ALLOC
aws ec2 delete-security-group --group-id $APP_SG
aws ec2 delete-security-group --group-id $ALB_SG
for SN in $PUB_A $PUB_B $PRV_A $PRV_B; do aws ec2 delete-subnet --subnet-id $SN; done
aws ec2 delete-route-table --route-table-id $RT_PUB
aws ec2 delete-route-table --route-table-id $RT_PRV
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
aws ec2 delete-vpc --vpc-id $VPC_ID
aws iam remove-role-from-instance-profile --instance-profile-name lab-ssm-profile --role-name lab-ssm-role
aws iam delete-instance-profile --instance-profile-name lab-ssm-profile
aws iam detach-role-policy --role-name lab-ssm-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name lab-ssm-role
```

Idle NAT gateways and EIPs are the two things that quietly burn money — always release them at the end of a lab.
