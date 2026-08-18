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
> you are creating a fixed IP add in AWS. this is the actual solution to the problem. A load balancer or kubernetes cannot create its own IP, it has to come from a real > AWS resource.A NLB normally gets a new network interface (and therefore a new IP) every time it's created or its underlying infrastructure changes.
> When you instead attach pre-allocated EIPs to the NLB's subnet mappings, AWS binds those specific, permanent addresses to the load balancer's front end instead of
> letting it generate its own

- lb-controller
> we register a new AWS controller as a child app using helm. A controller is a software that runs in your cluster. that watches over service, gateway object and
> translate them into real aws lb resource. the role created in step 1 is attached to the controller for IRSA.

- envouyproxy setup
> this is telling envoy gateway to attach speciic aws annotation to the underlying k8s service it creates.
- annotations required
> aws-load-balancer-type: external -> his is the signal that tells the in-tree cloud provider (the default one built into EKS) to back off and ignore this Service entirely, handing control to the AWS Load Balancer Controller instead.

> aws-load-balancer-nlb-target-type: instance -> tells the controller how traffic should actually be routed once it hits the NLB: to node instances
> then to pods via kube-proxy.

> aws-load-balancer-scheme: internet-facing -> IP allocation is explicitly only supported for internet-facing NLBs.
> and your app needs to be reachable from the public internet anyway, so this has to be set explicitly rather than relying on a default.

> aws-load-balancer-eip-allocations -> his is the actual instruction that connects Step 2's Elastic IPs to this specific load balancer. this is were we enter the arn from the output.

- GatewayClass update
> update getway class to point to envoy proxy using parametersref with name, namespace and kind.


#### get the IP address of all AZ

```
aws elbv2 describe-load-balancers --region eu-north-1 \
  --query "LoadBalancers[?contains(DNSName, 'envoynew-39a5dc42c2')].LoadBalancerArn" --output text

aws elbv2 describe-load-balancers --region eu-north-1 --load-balancer-arns <arn-from-above> \
  --query "LoadBalancers[0].AvailabilityZones[].LoadBalancerAddresses"

```
