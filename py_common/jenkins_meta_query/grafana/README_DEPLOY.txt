Push new container to the registry:

    docker tag jmq-grafana-datasource registry.service.consul/xcalar-qa/jmq-grafana-datasource
    docker push

Do the nomad stuff:
    Job file here:
        nomad/jobs/jmq-grafana-datasource.nomad
    Make any adjustments

    Tell nomad to pick up new containers:
        nomad job plan jmq-grafana-datasource.nomad
        nomad job run <whatever the above tells you to do>

Eyeball here:
    https://hashi-ui.service.consul/nomad/global/jobs

Datasource URL config for nomad containers:
    http://jmq-grafana-datasource.service.consul:9999/
