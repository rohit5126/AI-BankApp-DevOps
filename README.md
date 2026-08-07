<div align="center">

# DevSecOps Banking Application

A high-performance, containerized financial platform built with Spring Boot 3, Java 21, and integrated Contextual AI. This project implements a secure "DevSecOps Pipeline" using GitHub Actions, OIDC authentication, AWS managed services, and a fully GitOps-driven deployment via **ArgoCD (App of Apps pattern)**.

![dashboard](screenshots/1.png)

<img width="1920" height="1040" alt="Screenshot From 2026-08-07 12-22-01" src="https://github.com/user-attachments/assets/b7b0bfe0-1d52-461b-8298-583e38a43b07" />


</div>



---

This README explains the full architecture, exactly how a request travels through the system, how the entire platform is deployed and reconciled via ArgoCD, and how to set the whole project up from scratch on a new server/cluster.

---

## 1. What this project is

BankApp is a demo banking web app built with:
- **Backend:** Java 21, Spring Boot 3.4, Spring Security (form login, BCrypt passwords), Spring Data JPA / Hibernate
- **Database:** MySQL 8.0
- **Session store:** Redis (shared session storage across multiple app replicas)
- **AI assistant:** Ollama running a local `tinyllama` model, answering questions about the user's balance/transactions via a chat widget
- **Frontend:** Server-rendered Thymeleaf templates (dashboard, login, register, transactions)
- **Infrastructure:** Terraform-provisioned AWS EKS cluster, Envoy Gateway (Kubernetes Gateway API) as the ingress layer
- **GitOps / CD:** ArgoCD, using the **App of Apps** pattern to declaratively manage BankApp, the monitoring stack, and Envoy Gateway itself — all reconciled continuously from Git, with zero manual `kubectl apply` steps after bootstrap

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

                         Everything above is deployed and
                         continuously reconciled by ArgoCD ▼

      ┌───────────────────────────────────────────────────────┐
      │                    ArgoCD (argocd ns)                 │
      │                                                        │
      │   ┌──────────────────────────────────────────────┐    │
      │   │  root-app  (App of Apps)                      │    │
      │   │  points at  argocd/apps/                       │    │
      │   └───────────┬───────────────┬────────────────┬──┘    │
      │               ▼               ▼                ▼       │
      │        ┌───────────┐  ┌───────────────┐  ┌────────────┐│
      │        │ bankapp   │  │ envoy-gateway │  │ monitoring ││
      │        │ Application│ │ Application   │  │ Application││
      │        └───────────┘  └───────────────┘  └────────────┘│
      └───────────────────────────────────────────────────────┘
```

All internal traffic (bankapp → MySQL, bankapp → Redis, bankapp → Ollama) stays inside the cluster. Only the Envoy Gateway's load balancer is internet-facing. ArgoCD itself is only reachable via port-forward / its own internal Gateway route (see §9.6), it is not exposed the same way as the bank app.

![argocd-app-of-apps-tree](screenshots/argocd-app-of-apps-tree.png)

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
├── k8s/                                 # raw Kubernetes manifests (source of truth ArgoCD syncs from)
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
├── argocd/                             # GitOps definitions — the App of Apps pattern
│   ├── root-app.yml                    # the single "bootstrap" Application (points at argocd/apps)
│   ├── apps/
│   │   ├── bankapp-app.yml             # ArgoCD Application → Helm/bankapp (or k8s/)
│   │   ├── envoy-gateway-app.yml       # ArgoCD Application → Envoy Gateway Helm chart + gateway.yml
│   │   └── monitoring-app.yml          # ArgoCD Application → kube-prometheus-stack + dashboards
│   └── projects/
│       └── bankapp-project.yml         # AppProject: scopes repos/namespaces/resource kinds allowed
├── monitoring/                         # values files & extra manifests for the monitoring stack
│   ├── kube-prometheus-stack-values.yml
│   ├── dashboards/                     # custom Grafana dashboard JSON for BankApp
│   └── servicemonitors.yml             # ServiceMonitor CRs for bankapp/mysql/redis metrics
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
- `helm` - used to bootstrap ArgoCD itself (Envoy Gateway and the monitoring stack are then installed *by* ArgoCD, not manually).
- `argocd` CLI (optional but recommended) - for logging in and syncing apps from the terminal.
- Docker (for building the app image).
- Java 21 + Maven (only needed for local, non-container development).
- An EBS CSI driver installed on the cluster (required for MySQL's, Ollama's, and Prometheus's persistent volumes).

> With the GitOps flow in §9, you no longer need to manually install Envoy Gateway with Helm — ArgoCD does it for you as one of the managed child Applications. The manual steps in §6 are kept below for reference / non-GitOps setups, but §9 is the recommended path for a new cluster.

---

## 6. Setting this up manually on a new cluster/server — step by step

> Use this section if you want to deploy without ArgoCD. If you want the fully automated, self-healing GitOps setup, skip to **§9**.

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

### Step 10 — Install Envoy Gateway and expose the app

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.1.2 -n envoy-gateway-system --create-namespace
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

## 9. GitOps deployment with ArgoCD (App of Apps)

This is the recommended, fully automated way to stand up the entire platform — BankApp, Envoy Gateway, and the monitoring stack — on a brand-new cluster. After the one-time bootstrap in §9.2, **every subsequent change is a `git push`**: ArgoCD detects the diff and reconciles the cluster automatically, with no further `kubectl apply` or `helm install` commands.

### 9.1 Why App of Apps

Instead of registering three separate ArgoCD Applications by hand, we register **one root Application** (`root-app`) whose only job is to point at the `argocd/apps/` directory in this repo. Every YAML file ArgoCD finds there is itself an `Application` manifest, so ArgoCD recursively creates and manages:

- **`bankapp`** — the Spring Boot app, MySQL, Redis, Ollama, and the app's Service/NetworkPolicy
- **`envoy-gateway`** — the Envoy Gateway controller (via its Helm chart) plus the `Gateway`/`HTTPRoute` objects that expose BankApp to the internet
- **`monitoring`** — kube-prometheus-stack (Prometheus, Grafana, Alertmanager) plus `ServiceMonitor`s and dashboards for BankApp, MySQL, and Redis

Add, remove, or update a child app by editing files under `argocd/apps/` — you never touch ArgoCD's UI/CLI to register a new component again.

<img width="1918" height="1041" alt="Screenshot From 2026-08-06 21-14-37" src="https://github.com/user-attachments/assets/1499063b-26e3-4b34-8258-b89d268ba79b" />

### 9.2 One-time bootstrap

Everything below is run **once** per cluster. After this, the platform is entirely self-managing.

```bash
# 1. Install ArgoCD itself
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd

# 2. Grab the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# 3. Log in with the ArgoCD CLI (port-forward first if not yet exposed)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd login localhost:8080 --username admin --insecure

# 4. Apply the AppProject (scopes what the apps below are allowed to touch)
kubectl apply -f argocd/projects/bankapp-project.yml

# 5. Apply the single root Application — this is the ONLY manifest you apply by hand
kubectl apply -f argocd/root-app.yml
```

That's it. `root-app` syncs, discovers `bankapp-app.yml`, `envoy-gateway-app.yml`, and `monitoring-app.yml` under `argocd/apps/`, and creates all three as child Applications — which in turn deploy every component described in §2.



### 9.5 What the monitoring stack gives you

- **Prometheus** scrapes BankApp's `/actuator/prometheus` endpoint, plus MySQL and Redis exporters, via the `ServiceMonitor`s in `monitoring/servicemonitors.yml`.
- **Grafana** ships with pre-provisioned dashboards from `monitoring/dashboards/` — request latency, JVM heap, pod restarts, MySQL connections, Redis memory, and login success/failure rate.
- **Alertmanager** is wired for basic alerts (pod crash-looping, high error rate, PVC nearing capacity) — extend `kube-prometheus-stack-values.yml` to add your own alert routes (Slack/email/etc).

<img width="1918" height="1041" alt="Screenshot From 2026-08-06 21-15-31" src="https://github.com/user-attachments/assets/dd0f592a-ab79-4739-b476-17e76faa6631" />

### 9.6 Accessing the ArgoCD and Grafana UIs

Grafana no longer needs a port-forward — it's exposed on the same domain and Gateway as BankApp, under the /monitoring subpath, via an additional HTTPRoute. ArgoCD's UI is still reached via port-forward (or add a similar HTTPRoute for it under an internal/admin hostname if you want it permanently reachable too):

Notes:

parentRefs is cross-namespace (monitoring → the Gateway in newbankapp), so the Gateway needs a ReferenceGrant (or an allowedRoutes.namespaces selector) permitting routes from the monitoring namespace to attach — add this alongside gateway.yml if it isn't already permissive.
The URLRewrite filter strips the /monitoring prefix before forwarding, since Grafana serves from / by default. Alternatively, set GF_SERVER_ROOT_URL=https://<your-domain>/monitoring and GF_SERVER_SERVE_FROM_SUB_PATH=true in the Grafana values (monitoring/kube-prometheus-stack-values.yml) and drop the rewrite filter — either approach works, don't mix both.
Because this route lives in Git (k8s/monitoring-route.yml, referenced by monitoring-app.yml), it's reconciled by ArgoCD like everything else — no manual kubectl apply needed after bootstrap.

### 9.7 Day-2 operations — this is the whole point of GitOps

| You want to... | You do... |
|---|---|
| Ship a new BankApp image version | Update the tag in `Helm/bankapp/values.yaml`, commit, push |
| Scale replicas | Edit `replicaCount` in the Helm values, commit, push |
| Add a Grafana dashboard | Drop a new JSON file in `monitoring/dashboards/`, commit, push |
| Roll back a bad deploy | `argocd app rollback bankapp <REVISION>`, or `git revert` the commit |
| Check drift/health | `argocd app get bankapp` or the ArgoCD UI's app tree |

Any manual `kubectl edit`/`kubectl scale` against a resource ArgoCD manages will be **automatically reverted** by `selfHeal: true` within the next sync interval — Git is the single source of truth.

---
