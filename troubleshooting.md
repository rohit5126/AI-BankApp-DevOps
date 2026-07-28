
 ## first error without AI integration.
 
 1970  kubectl run net-test --rm -it --image=busybox --restart=Never -- nslookup mysql-state-0.mysql.default.svc.cluster.local

 1974  kubectl get endpoints mysql

 1975  kubectl get netpol

 1976  kubectl exec -it mysql-state-0 -- mysql -u root -pbankapp -e "SHOW STATUS LIKE 'Threads_connected';"

 1977  kubectl exec -it mysql-state-0 -- mysql -u root -pbankapp -e "SELECT host, user, command, state FROM information_schema.processlist;"
 1978  kubectl exec -it mysql-state-0 -- mysql -u root -pbankapp -e "SELECT host, db, command FROM information_schema.processlist WHERE db IS NOT NULL;"

 1979  kubectl get pods -o wide

 2012  kubectl logs -l app=bankapp --tail=100 -f

 2013  kubectl exec -it deploy/bankapp-dep -- env | grep MYSQL

 2016  kubectl logs -l app=bankapp --tail=50 | grep -i "insert into accounts"

 2017  # Confirm row count actually grew
 2018  kubectl exec -it mysql-state-0 -- mysql -u root -pbankapp -e "SELECT id, username FROM bankapp.accounts;"

 
 ## second error during AI integartion.

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


## New issue came up that tinyllama should be installed after the server is ready but it is getting interrupted due tosome reason.

The /dev/tcp/... check requires bash, not sh,
so when I am running it using sh the line
(: </dev/tcp/127.0.0.1/11434) 2>/dev/null; is giving error,
which is false so 'while !' false always remains true and its going to 'sleep 1' every time. and not moving forward to line ollama pull. this is silent error which is not there in the logs.

to resolve this just changed the shell from sh to bash for running the command in deloyemnet file. this resolved the issue.
tinyllama is etting installed at container runtime and everything is working as expected.




