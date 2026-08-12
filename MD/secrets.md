## Terraform cluster level resource

### secrets.tf
```
create a resource from random pass along with aws_secretsmanager_secret and aws_secretsmanager_secret_version.

aws_secretsmanager_secret - to setup secret
aws_secretsmanager_secret_version - to add secret data for password from random password.

```

### irsa.tf

```
get the external_secrets_assume policy from aws_iam_policy_document by using data resource. it is very important because it says that the pods running as a provided
service account and provided anmespace is allowed to assume this role. 

create a iam role and using aws_iam_role resource

attach the policy to the iam role and provide secret manager resource in resource section

without this file you would need to keep the aws access key in the k8s secret.

add a output block to get the arn of the iam role which will be used in creating service account
```

## project deployment level resource

### k8s/service-accounts.yml


```
this is a bridge between kubernetes and aws IAM. craete a namespace and a service account with eks.amazonaws.com/role-arn annotation to attach the iam role created before
to this service account. get the id from the output of terraform apply.

while creating service account create a namespace as well and create the SA in the that namespace.

```

### argocd/external-secrets-app.yml


```
this installs external secret operator which looks for external secret and pulls data from AWS. and below field to make it use the service account we created and use a default one

serviceAccount:
          create: false
          name: external-secrets

#make sure this deploys after service account is created.

you can also check the exact version for the argocd app deployment

helm repo add external-secrets https://charts.external-secrets.io --force-update
helm search repo external-secrets/external-secrets

```

### k8s/secretstore.yml

```
create a clustersecretstore resource to provide data above the aws secret manager on how to connect and which service account to use.
we use cluster secret store so that it can access all the secrets across different namespaces.

SecretStore → ServiceAccount → IAM role → AWS permission.

```

### mysql-external-secret.yml

```
This is actual secret which fetches bankapp/mysql secret from aws via secret store materialize it as normal k8s secret.
refreshInterval: 1h means ESO re-checks AWS every hour and updates the k8s Secret.
once this file is created with exact name and key value the deployment file does not need to change at all.

```

Important commands to check if something goes wrong

```
kubectl get crd | grep external-secrets
kubectl get application external-secrets -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}'
kubectl get application bankapp -n argocd -o yaml | grep -B5 -A15 "history:"
argocd app sync external-secrets
kubectl get appproject default -n argocd -o yaml | grep -A10 destinations
```

**Sync waves order of deployment ( very Important)**
**aws secret manager should be already configured**

```
service account namespace and service account (-2)
secretstore (1)
mysql-external-secret(0)
then all the stateful sets and deployments

In argoCD apps deployment

bankapp-app.yml should be deployed before external-secret-app.
```

---

## add Grafana admin secret ro any other secret process

### update terraform/secrets.tf

```
create a resource from random pass along with aws_secretsmanager_secret and aws_secretsmanager_secret_version.
```
### update irsa.tf

```
add aws_secretsmanager_secret.grafana.arn to "aws_iam_role_policy".
```

### Create a grafana-external-secret.yml 

```
this is same as mysql-external-secret.yml.
make sure to add both user and password as shown below in sepc.template to avoid any errors.

engineVersion: v2
      data:
        admin-user: "admin"
        admin-password: "{{ .password }}"
  data:
    - secretKey: password
      remoteRef:
        key: bankapp/grafana-admin

note: In my case faced an error due to admin-user not found.

```

### No need to create a a seperate secretStore as already created a cluster level secretstore which applies to all namespace. so every external secret will reference the secret store.


### update argocd/kube-prometheus-stack

```
ads below inside spec.source,helm.valuesObject.grafana

admin:
  existingSecret: grafana-admin-secret
  userKey: admin-user   
  passwordKey: admin-password

```

**things to amke sure is order of deployment**

```
kube-rometheus satck should be deployed after grafana-admin-secret exists

```

### delete at the end

```
aws secretsmanager delete-secret --secret-id bankapp/mysql --force-delete-without-recovery

aws secretsmanager delete-secret --secret-id bankapp/grafana-admin --force-delete-without-recovery
```

