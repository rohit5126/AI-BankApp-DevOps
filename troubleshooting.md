
 ##  1. first error without AI integration.

 ```
kubectl run net-test --rm -it --image=busybox --restart=Never -- nslookup mysql-state-0.mysql.default.svc.cluster.local

kubectl get endpoints mysql

kubectl get netpol

 kubectl exec -it mysql-state-0 -- mysql -u root -pbankapp -e "SHOW STATUS LIKE 'Threads_connected';"

 kubectl exec -it mysql-state-0 -- mysql -u root -pbankapp -e "SELECT host, user, command, state FROM information_schema.processlist;"
kubectl exec -it mysql-state-0 -- mysql -u root -pbankapp -e "SELECT host, db, command FROM information_schema.processlist WHERE db IS NOT NULL;"

kubectl get pods -o wide

kubectl logs -l app=bankapp --tail=100 -f

kubectl exec -it deploy/bankapp-dep -- env | grep MYSQL

kubectl logs -l app=bankapp --tail=50 | grep -i "insert into accounts"

# Confirm row count actually grew
 
kubectl exec -it mysql-state-0 -- mysql -u root -pbankapp -e "SELECT id, username FROM bankapp.accounts;"
```
 
 ## 2. second error during AI integartion.

 **using below command for checking the ollama site is ready before  installing tinyllama**

 echo "Waiting for Ollama server to become available..."
            while ! nc -z localhost 11434; do
              sleep 1
            done

**it did not work because nc is not instlled in sh**


#### then tried curl to resolve above issue

 echo "Waiting for Ollama server to become available..."
            while ! curl -s http://localhost:11434/ > /dev/null; do
              sleep 1
            done

**curl was laso not installed on sh**

#### then did some research  and found the correct command

echo "Waiting for Ollama server to become available..."
            while ! (: </dev/tcp/127.0.0.1/11434) 2>/dev/null; do
              sleep 1
            done

**this worked and ollama was successfully installed on the pod and readinesss probe was also success**


## 3. New issue came up that tinyllama should be installed after the server is ready but it is getting interrupted due tosome reason.

The /dev/tcp/... check requires bash, not sh,
so when I am running it using sh the line
(: </dev/tcp/127.0.0.1/11434) 2>/dev/null; is giving error,
which is false so 'while ! false' always remains true and its going to 'sleep 1' every time. and not moving forward to line ollama pull. this is silent error which is not there in the logs.

to resolve this just changed the shell from sh to bash for running the command in deloyemnet file. this resolved the issue.
tinyllama is etting installed at container runtime and everything is working as expected.

## 4. Envoy Gateway controller crash-looping — missing `EnvoyProxy` CRD

**Symptom:**
```
kubectl get pods -n envoy-gateway-system
envoy-gateway-57785fffc8-2rmjk   0/1   CrashLoopBackOff

Error: failed to create provider Kubernetes: failed to create gatewayapi controller:
no matches for kind "EnvoyProxy" in version "gateway.envoyproxy.io/v1alpha1"
```

**Root cause:** `--skip-crds` (used to work around Issue 6) told Helm to skip installing **all** CRDs bundled in its chart — not just the standard Gateway API ones causing the conflict, but also Envoy Gateway's own custom CRDs (`EnvoyProxy`, `ClientTrafficPolicy`, etc.). The controller started, tried to watch for `EnvoyProxy` objects, and crashed because that CRD was never installed anywhere on the cluster.

**Fix — clean reinstall, letting Helm own every CRD from scratch:**
```bash
kubectl delete gateway bankapp-gateway -n newbankapp
kubectl delete httproute bankapp-route -n newbankapp

helm uninstall eg -n envoy-gateway-system

kubectl delete crd \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io \
  grpcroutes.gateway.networking.k8s.io \
  2>/dev/null

helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.1.2 \
  -n envoy-gateway-system \
  --create-namespace
```
Then re-applied `gateway.yml`. Confirmed with `kubectl get pods -n envoy-gateway-system` showing `1/1 Running`, no restarts.

**Takeaway:** `--skip-crds` skips *all* CRDs bundled in a chart, not selectively — don't reach for it as a partial fix when only some CRDs conflict. The reliable fix is to let one tool (Helm, in this case) own the entire CRD set from a clean slate.

---

## 5. Login worked, but session didn't persist across app replicas

**Symptom:** Users could log in successfully (confirmed via app logs — Hibernate correctly selected/inserted account rows), but would intermittently get bounced back to `/login` on subsequent requests.

**Root cause:** the app ran with 2 replicas behind Envoy Gateway with no session affinity. Spring's default session handling keeps `HttpSession` data only in the memory of whichever pod first created it. When Envoy routed a later request to a *different* pod (which had never seen that session), the app treated the user as unauthenticated.

**Fix — moved session storage to Redis** so any pod can serve any request for any session:

- Added to `pom.xml`:
```xml
<dependency>
    <groupId>org.springframework.session</groupId>
    <artifactId>spring-session-data-redis</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
```
- Added to `application.properties`:
```properties
spring.session.store-type=redis
spring.data.redis.host=${REDIS_HOST}
spring.data.redis.port=${REDIS_PORT:6379}
spring.session.timeout=1800s
```
- New file `k8s/redis.yml` — Redis Deployment + Service (namespace `newbankapp`, port 6379).
- Added `REDIS_HOST` / `REDIS_PORT` env vars to `bankapp-deployment.yml`.
- Added `redis-policy` NetworkPolicy (ingress from `bankapp` pods only) and a new egress rule on `bankapp-policy` allowing traffic to `app: redis` on port 6379.

(A temporary alternative — Envoy Gateway `BackendTrafficPolicy` with cookie-based consistent hashing for sticky sessions — was considered but not used, since it only masks the problem: pod restarts and scaling events still drop sessions pinned to a specific pod. Redis-backed sessions fix it properly at any replica count.)

---

## 6. Dashboard showed the old balance after a deposit/withdrawal

**Symptom:** After making a deposit, the transaction appeared correctly in the transaction history, but the dashboard's balance display didn't update — until logging out and back in, at which point the correct balance appeared.

**Root cause:** `Account` implements Spring Security's `UserDetails` and is used directly as the `@AuthenticationPrincipal`. This principal object is captured once at login time and cached in the session (now backed by Redis). `BankController.dashboard()` was rendering the balance straight from this cached principal instead of reading current data from the database — so it kept showing whatever the balance was *at login time*, regardless of any deposits/withdrawals made afterward. Logging out and back in forced a fresh read from the database, which is why that "fixed" it temporarily.

**Fix — `BankController.java`:**
```java
@GetMapping("/dashboard")
public String dashboard(@AuthenticationPrincipal Account account, Model model) {
    Account freshAccount = accountService.getAccountByUsername(account.getUsername());
    model.addAttribute("account", freshAccount);
    return "dashboard";
}
```

**New helper — `AccountService.java`:**
```java
public Account getAccountByUsername(String username) {
    return accountRepository.findByUsername(username)
            .orElseThrow(() -> new UsernameNotFoundException("User not found: " + username));
}
```

---

## 7. Deposits/withdrawals silently corrupted the real balance (critical)

**Symptom:** After the fix in Issue 9, the dashboard displayed balances correctly — but a new, more serious bug appeared: depositing money and then trying to withdraw a smaller amount than the (correct, displayed) balance was incorrectly rejected as "insufficient funds." Worse, a withdrawal that *was* accepted would reset the balance to an incorrect, much lower value — effectively erasing the deposit.

**Root cause:** Issue 9 only fixed the *read* path (the dashboard's display). The *write* path — `deposit()`, `withdraw()`, and `transferAmount()` in `AccountService` — still operated on the same stale, session-cached `@AuthenticationPrincipal Account` object passed in from the controller. Sequence of events that caused real data loss:

1. User logs in — session principal captures balance at that moment (e.g. `500`).
2. User deposits `1000` — correctly saved to MySQL as `1500`. Dashboard correctly displays `1500` (Issue 9's fix).
3. The session's cached principal is *never updated* — it's still frozen at `500`.
4. User tries to withdraw `1000` — the code checks the **stale** principal (`500 < 1000`) and incorrectly rejects it as insufficient funds, even though the true balance is `1500`.
5. User withdraws `500` instead — stale check passes (`500 >= 500`), and the code computes `500 - 500 = 0` and **saves that stale-derived value back to the database**, overwriting the correct `1500` with `0`.

**Fix — re-fetch the account fresh from the database inside every financial operation, using only the username (an immutable identifier) from the cached principal:**

`AccountService.java`:
```java
@Transactional
public void deposit(String username, BigDecimal amount) {
    Account account = getAccountByUsername(username);
    account.setBalance(account.getBalance().add(amount));
    accountRepository.save(account);
    transactionRepository.save(new Transaction(amount, "Deposit", LocalDateTime.now(), account));
}

@Transactional
public boolean withdraw(String username, BigDecimal amount) {
    Account account = getAccountByUsername(username);
    if (account.getBalance().compareTo(amount) < 0) {
        return false;
    }
    account.setBalance(account.getBalance().subtract(amount));
    accountRepository.save(account);
    transactionRepository.save(new Transaction(amount, "Withdrawal", LocalDateTime.now(), account));
    return true;
}

@Transactional
public String transferAmount(String fromUsername, String toUsername, BigDecimal amount) {
    if (fromUsername.equals(toUsername)) {
        return "Cannot transfer to yourself.";
    }
    Account from = getAccountByUsername(fromUsername);
    if (from.getBalance().compareTo(amount) < 0) {
        return "Insufficient funds.";
    }
    Account to = accountRepository.findByUsername(toUsername).orElse(null);
    if (to == null) {
        return "Recipient not found.";
    }
    from.setBalance(from.getBalance().subtract(amount));
    to.setBalance(to.getBalance().add(amount));
    accountRepository.save(from);
    accountRepository.save(to);
    LocalDateTime now = LocalDateTime.now();
    transactionRepository.save(new Transaction(amount, "Transfer Out", now, from));
    transactionRepository.save(new Transaction(amount, "Transfer In", now, to));
    return null;
}
```

`BankController.java` — updated call sites to pass only the username:
```java
accountService.deposit(account.getUsername(), amount);
accountService.withdraw(account.getUsername(), amount);
accountService.transferAmount(account.getUsername(), toUsername, amount);
```

**Data recovery:** since this bug had already overwritten real balances during testing, affected accounts needed a manual correction:
```bash
kubectl exec -it mysql-state-0 -n newbankapp -- mysql -u root -p$MYSQL_ROOT_PASSWORD bankapp \
  -e "UPDATE accounts SET balance = <correct-value> WHERE username = '<affected-user>';"
```

**Takeaway:** `@AuthenticationPrincipal` should only ever be used to identify **who** is making a request (via an immutable field like username or ID). It should never be treated as the source of truth for mutable data like an account balance — any operation that changes money must re-read current state from the database at the moment it runs, inside its own transaction.

---






