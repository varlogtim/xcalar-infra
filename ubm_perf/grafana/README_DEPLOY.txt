Push new container to the registry:

    docker tag ubm-perf-grafana-datasource registry.service.consul/xcalar-qa/ubm-perf-grafana-datasource
    docker push registry.service.consul/xcalar-qa/ubm-perf-grafana-datasource

Do the nomad stuff:
    Job file here:
        nomad/jobs/ubm-perf-grafana-datasource.nomad
    Make any adjustments

    Tell nomad to pick up new containers:
        export NOMAD_ADDR=http://nomad.service.consul:4646/
        nomad job plan ubm-perf-grafana-datasource.nomad
        nomad job run <whatever the above tells you to do>

Eyeball here:
    https://hashi-ui.service.consul/nomad/global/jobs

Datasource URL config for nomad containers:
    http://ubm-perf-grafana-datasource.service.consul:9999/
