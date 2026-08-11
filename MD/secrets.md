## Terraform cluster level resource

### secrets.tf
```
create a resource fro random pass along with aws_secretsmanager_secret and aws_secretsmanager_secret_version.

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

create it under app deployment folder with other yml files
```

### argocd/external-secrets-app.yml


```
this installs external secret operator which looks for external secret and pulls data from AWS. and below field to make it use the service account we created and use a default one

serviceAccount:
          create: false
          name: external-secrets

#make sure this deploys after service account is created.

```

### k8s/secretstore.yml

```
create a clustersecretstore resource to provide data above the aws secret manager on how to connect and which service account to use.

SecretStore → ServiceAccount → IAM role → AWS permission.

```


