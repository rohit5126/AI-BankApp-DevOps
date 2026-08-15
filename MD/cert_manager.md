## cert manager and https domain setup.

**Duckdns setup**

### argocd/cert-manager.yml

```
this application installs the abse cert-manager controller inthe cluster inside cert-manager namespace

this is the foundational piece on which everything depends on. the cert-manager controller and CRD's must exist before any webhook or certificate issuer.

repoURL: https://charts.jetstack.io - pull teh official chart and make sure about the version

make sure installCRDs: true in spec.source.hml.valuesObject  - this install all the CRD's

```

### argocd/cert-manager-webhook.yml

```
this is the application that installs cert-manager webhook into cert-manager namespace.
this is where dukcdns token lives and it creates its own cluster issuer.

token.value — the DuckDNS token used to prove domain ownership via DNS-01.
clusterIssuer.production.create: true — makes the chart generate a working ClusterIssuer automatically

```

### k8s/bankapp-cert.yml

```
this resource actually requests the TLS certificate.

the issuerRef.name must point to the actual cluster issuer name created by the webhook chart in last step
```

### update k8s/gateway.yml

```
References bankapp-tls-secret in certificateRefs for TLS termination.

```

### Important commands

```
kubectl get crds | grep cert-manager

kubectl get clusterissuer

kubectl describe certificate bankapp-tls -n newbankapp

```

### connect your domain name to the lb balancer address

```
kubectl get secret bankapp-tls-secret -n newbankapp -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates

kubectl get gateway -n newbankapp -0 wide  - to get the lb address

dig +short <a4d25a7...lb -address>  - to get the ip add of the load balancer.

curl "https://www.duckdns.org/update?domains=aibankapp&token=ecdaa977-9ad9-443f-af09-4397abfbbd3f&ip=13.63.52.172" - update ip in the domain

#wait for few minutes than run curl

curl -I https://aibankapp.duckdns.org

nslookup bankappai.duckdns.org

```






