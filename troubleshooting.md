
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

 