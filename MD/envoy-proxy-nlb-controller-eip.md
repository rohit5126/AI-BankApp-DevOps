### issue - the IP changes because ArgoCD sync cycles trigger reconciliation, and without an explicit AWS annotation, Kubernetes provisions a dynamic classic AWS load balancer that spins up new underlying nodes (and IPs) frequently.

### Solution - a Network Load Balancer's IP can change if it's recreated or is used in multiple AZ subnets without fixed IPs. The fix is to pin Elastic IPs to the NLB so the IP never changes, then point domain at that.

Files to add :

- IAM role policy for controller.
- Elastic IP for each subnet and to attach in envoy proxy.
- create a lb controller application in argocd namespace
- create a envoyproxy to connect to gateway class
- update gateway class to point to envoy proxy.

why each file is needed and their importance:

- IAM role for the controller
> IAM role policy is fetched from AWS own Json file. AWS IAM role which a kubernetes service account assumes, using this trust AWS calls IRSA(Identity roles and service account).
> Pods running inside your cluster needs to call AWS API and need AWS account level permissions, pods has no build in identity.IRSA acts as a bridge.
> EKS OIDC provider lets AWS trust k8s service account to have permission and attached via IAM policy. without this the pod would not be able to call the API and fail with an unauthorized error.

- Allocate Elastic IPs (Terraform)
> 

