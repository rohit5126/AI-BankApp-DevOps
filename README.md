<div align="center">

# DevSecOps Banking Application

A high-performance, containerized financial platform built with Spring Boot 3, Java 21, and integrated Contextual AI. This project implements a secure "DevSecOps Pipeline" using GitHub Actions, OIDC authentication, and AWS managed services.

[![Java Version](https://img.shields.io/badge/Java-21-blue.svg)](https://www.oracle.com/java/technologies/javase/jdk21-archive-downloads.html)
[![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.4.1-brightgreen.svg)](https://spring.io/projects/spring-boot)
[![GitHub Actions](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions-orange.svg)](.github/workflows/devsecops.yml)
[![REDIS](https://img.shields.io/badge/Caching-Redis-red.svg)](#phase-3-security-and-identity-configuration)

</div>

![dashboard](screenshots/1.png)

---

This README explains the full architecture, exactly how a request travels through the system, and how to set the whole project up from scratch on a new server/cluster.

---

## 1. What this project is

BankApp is a demo banking web app built with:
- **Backend:** Java 21, Spring Boot 3.4, Spring Security (form login, BCrypt passwords), Spring Data JPA / Hibernate
- **Database:** MySQL 8.0
- **Session store:** Redis (shared session storage across multiple app replicas)
- **AI assistant:** Ollama running a local `tinyllama` model, answering questions about the user's balance/transactions via a chat widget
- **Frontend:** Server-rendered Thymeleaf templates (dashboard, login, register, transactions)
- **Infrastructure:** Terraform-provisioned AWS EKS cluster, Envoy Gateway (Kubernetes Gateway API) as the ingress layer

---

## 2. Architecture overview

```
                                Internet
                                   │
                                   ▼
                     ┌─────────────────────────┐
                     │   AWS ELB/NLB           │  (auto-created by Envoy Gateway)
                     └────────────┬────────────┘
                                   │
                                   ▼
                     ┌─────────────────────────┐
                     │  Envoy Gateway          │  Gateway + HTTPRoute
                     │  (envoy-gateway-system) │  routes / → bankapp-svc:80
                     └────────────┬────────────┘
                                   │
                                   ▼
                     ┌─────────────────────────┐
                     │ bankapp-svc (ClusterIP) │
                     └────────────┬────────────┘
                                   │
                                   ▼
                     ┌─────────────────────────┐
                     │  bankapp pods (×N)      │  Spring Boot app :8080
                     └──────┬───────┬──────────┘
                            │       │
                 ┌──────────┘       └──────────┐
                 ▼                              ▼
      ┌────────────────────┐        ┌────────────────────┐
      │  MySQL StatefulSet │        │Redis Deployment    │
      │  (accounts,        │        │(HTTP session store,│
      │   transactions)    │        │ shared across pods)│
      └────────────────────┘        └────────────────────┘
                 │
                 ▼
      ┌────────────────────┐
      │ Ollama StatefulSet │  local LLM (tinyllama),
      │(AI chat assistant) │  called by the app over HTTP
      └────────────────────┘
```

All internal traffic (bankapp → MySQL, bankapp → Redis, bankapp → Ollama) stays inside the cluster. Only the Envoy Gateway's load balancer is internet-facing.

---

## 3. Full request flow — step by step

### 3.1 A user visits the site

1. The browser resolves the Envoy Gateway's ELB/NLB DNS hostname and sends an HTTP request.
2. **Envoy Gateway** (the controller + its data-plane proxy pods, running in `envoy-gateway-system`) receives the request. It matches the request against the `HTTPRoute` object (`bankapp-route`), which says: "any path `/` -> send to `bankapp-svc` on port 80."
3. Envoy forwards the request to one of the `bankapp` pods behind `bankapp-svc` (a `ClusterIP` Service), load-balancing across however many replicas are running.
4. Spring Security's filter chain (`SecurityConfig.java`) intercepts the request. Any path other than `/login`, `/register`, static assets, or `/actuator/**` requires authentication.
5. If the user isn't authenticated, they're redirected to `/login` (Spring Security's default form-login flow).

### 3.2 Logging in

1. The user submits username + password on `/login`.
2. Spring Security calls `AccountService.loadUserByUsername()`, which queries **MySQL** via `AccountRepository.findByUsername()`.
3. The password is checked against the BCrypt hash stored in the `accounts` table.
4. On success, Spring Security builds an `Authentication` object wrapping the `Account` entity (which implements `UserDetails`) and stores it in the `SecurityContext`.
5. The `SecurityContext` is persisted into the **HTTP session** — and because the app is configured with Spring Session backed by **Redis**, this session data is written to Redis rather than kept only in the memory of the one pod that handled the request.
6. This is what makes the app safely horizontally scalable: the **next** request — even if routed by Envoy to a *different* pod — can read the same session back out of Redis and knows the user is still authenticated.
7. The user is redirected to `/dashboard`.

### 3.3 Viewing the dashboard

1. `GET /dashboard` hits `BankController.dashboard()`.
2. The controller looks up the account fresh from MySQL (via `AccountService`) rather than trusting any cached copy, so the balance shown always reflects the true current state of the database.
3. `dashboard.html` (Thymeleaf) renders the balance, username, and account ID, along with Deposit / Withdraw / Transfer forms.

### 3.4 Making a deposit / withdrawal / transfer

1. The user submits one of the forms (`POST /deposit`, `/withdraw`, or `/transfer`).
2. The controller identifies **who** is making the request from the authenticated principal's username (identity only — never used as the source of truth for the balance itself).
3. `AccountService` re-reads the account fresh from **MySQL** inside a `@Transactional` method, so the balance check and update always operate on the true current value, not a value cached from login time.
4. On success, a new row is written to the `transactions` table, and the account's `balance` column is updated.
5. The user is redirected back to `/dashboard`, which re-renders with the updated balance (see 3.3).

### 3.5 Viewing transaction history

1. `GET /transactions` fetches all transactions for the account's ID from the `transactions` table, ordered by most recent first, and renders them in `transactions.html`.

### 3.6 Using the AI assistant

1. The chat widget (bottom-right button on the dashboard) sends the user's message to `POST /api/chat` (`ChatController`).
2. `ChatService` builds a context string containing the user's username, current balance, and last 5 transactions (read-only — the AI assistant never modifies account data).
3. This context + the user's message is sent as a chat completion request to **Ollama**, reachable inside the cluster at `http://ollama:11434`.
4. Ollama runs the request through the locally-hosted `tinyllama` model and returns a reply.
5. The reply is sent back to the browser and appended to the chat window.

### 3.7 Logging out

1. `POST /logout` (Spring Security's default logout handler) invalidates the session — both destroying the local reference and removing the corresponding entry from Redis.
2. The user is redirected to `/login?logout`.

---

## 4. Repository structure

```
AI-BankApp-DevOps/
├── Dockerfile                          # multi-stage build: Maven build → slim JRE runtime image
├── docker-compose.yml                  # local dev stack (app + MySQL + Ollama)
├── k8s/                                 # Kubernetes manifests for the EKS deployment
│   ├── namespace.yml
│   ├── secrets.yml                     # MySQL credentials (Secret) + host ConfigMap
│   ├── mysql-stata.yml                 # MySQL headless Service + StatefulSet + PVC
│   ├── ollam.yml                       # Ollama StatefulSet (model pulled at container startup)
│   ├── ollama_svc.yml                  # Ollama headless Service
│   ├── redis.yml                       # Redis Deployment + Service (session store)
│   ├── bankapp-deployment.yml          # App Deployment, env vars, resource limits
│   ├── bankapp-service.yml             # App ClusterIP Service
│   ├── gateway.yml                     # GatewayClass + Gateway + HTTPRoute (Envoy Gateway)
│   └── networkpolicy.yml               # default-deny baseline + explicit allow rules
├── Helm/bankapp/                       # Helm chart packaging of the above manifests
├── scripts/ollama-setup.sh             # helper script for local Ollama setup
├── OLLAMA_INFO.md                      # notes on the Ollama integration
└── troubleshooting.md                  # known issues and their fixes
```

---

## 5. Prerequisites

- AWS account with an existing EKS cluster (v1.30+), or access to provision one via Terraform
- `kubectl`, configured against the target cluster.
  
  ```
  install kubectl
  aws eks update-kubeconfig --name <cluster_name> --region eu-north-1
  ```
- `helm` - to install envoy gateway.
- Docker (for building the app image).
- Java 21 + Maven (only needed for local, non-container development).
- Envoy Gateway installed on the cluster (Gateway API CRDs + the `envoy-gateway` controller running in `envoy-gateway-system`).
  
  ```
  helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.1.2 -n envoy-gateway-system --create-namespace
  ```
  
- An EBS CSI driver installed on the cluster (required for MySQL's and Ollama's persistent volumes).

---

## 6. Setting this up on a new cluster/server — step by step

### Step 1 — Clone the repo

```bash
git clone https://github.com/rohit5126/AI-BankApp-DevOps.git
cd AI-BankApp-DevOps
```

### Step 2 — Build and push the application image

```bash
docker build -t <your-dockerhub-username>/bankapp:latest .
docker push <your-dockerhub-username>/bankapp:latest
```

If you use a different image name/tag, update the `image:` field in `k8s/bankapp-deployment.yml` to match.

### Step 3 — Confirm cluster prerequisites

```bash
kubectl get nodes                                   # cluster is reachable
kubectl get pods -n kube-system | grep ebs-csi       # EBS CSI driver is running
kubectl get pods -n envoy-gateway-system              # Envoy Gateway controller is running
kubectl get storageclass                              # a usable StorageClass (e.g. gp2/gp3) exists
```

### Step 4 — Apply the namespace

```bash
kubectl apply -f k8s/namespace.yml
```

### Step 5 — Apply secrets and config

```bash
kubectl apply -f k8s/secrets.yml
```
This creates the `mysql-secret` (root password, database name) and the `mysql-host` ConfigMap the app reads its DB connection details from. **Replace the placeholder values with real, unique credentials before using this outside of local testing.**

### Step 6 — Deploy MySQL

```bash
kubectl apply -f k8s/mysql-stata.yml
kubectl rollout status statefulset/mysql-state -n newbankapp
```
Hibernate creates the `accounts` and `transactions` tables automatically on first startup (`spring.jpa.hibernate.ddl-auto=update`) — no manual schema step required.

### Step 7 — Deploy Redis

```bash
kubectl apply -f k8s/redis.yml
kubectl rollout status deployment/redis-deployment -n newbankapp
```

### Step 8 — Deploy Ollama

```bash
kubectl apply -f k8s/ollam.yml
kubectl apply -f k8s/ollama_svc.yml
kubectl rollout status statefulset/ollama-state -n newbankapp
```
On first startup, the container pulls the `tinyllama` model — this can take a few minutes depending on network speed. The readiness probe won't pass until the model is fully pulled and Ollama is serving.

### Step 9 — Deploy the application

```bash
kubectl apply -f k8s/bankapp-deployment.yml
kubectl apply -f k8s/bankapp-service.yml
kubectl rollout status deployment/bankapp-dep -n newbankapp
```

### Step 10 — Expose it via Envoy Gateway

```bash
kubectl apply -f k8s/gateway.yml
kubectl get gateway -n newbankapp        # wait for PROGRAMMED: True and an ELB address
```

### Step 11 — Lock down traffic with NetworkPolicies

Apply this **last**, only after confirming the app works end-to-end — the default-deny baseline will block anything not explicitly allowed, which makes debugging much harder if applied too early.
```bash
kubectl apply -f k8s/networkpolicy.yml
```

### Step 12 — Get the app's public URL and test

```bash
kubectl get svc -n envoy-gateway-system
```
Find the `LoadBalancer` Service created for your Gateway and open its `EXTERNAL-IP` hostname in a browser. Register a new account, log in, and confirm deposit/withdraw/transfer and the AI chat assistant all work.

---

## 7. Local development (without Kubernetes)

A `docker-compose.yml` is included for running the app, MySQL, and Ollama together on a single machine:
```bash
docker compose up --build
```
The app will be reachable at `http://localhost:8080`. Session storage falls back to in-memory in this mode (no Redis) since it's a single-instance setup.

---

## 8. Key environment variables

| Variable | Used by | Purpose |
|---|---|---|
| `MYSQL_HOST` | app | MySQL Service DNS name |
| `MYSQL_PORT` | app | MySQL port (3306) |
| `MYSQL_DATABASE` | app, MySQL | database name |
| `MYSQL_USER` | app | DB username |
| `MYSQL_PASSWORD` | app, MySQL | DB password (from `mysql-secret`) |
| `REDIS_HOST` | app | Redis Service DNS name |
| `REDIS_PORT` | app | Redis port (6379) |
| `OLLAMA_URL` | app | Ollama Service base URL |

All of these are wired via `env:` blocks in `k8s/bankapp-deployment.yml`, sourced from the `mysql-secret` Secret and `mysql-host` ConfigMap where applicable.

---
