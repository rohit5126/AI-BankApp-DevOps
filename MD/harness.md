 ## deplooy using Harness

 This is for existing argocd in your cluster
 ```
 make sure you ahve override.yml file downloaded from harness

helm repo add gitops-agent-byoa https://harness.github.io/gitops-helm-byoa/

helm repo update gitops-agent-byoa

helm install harness  gitops-agent-byoa/gitops-helm-byoa --values override.yaml --namespace argocd

```
For more Info what below youtube video

https://youtu.be/Lmcw4s299_0?si=KiW7l1iVUQ8woexR


