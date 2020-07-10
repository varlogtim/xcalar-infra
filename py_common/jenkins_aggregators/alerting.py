#!/usr/bin/env python3

import logging
import os
from prometheus_client import CollectorRegistry, Gauge
from prometheus_client import push_to_gateway, delete_from_gateway
import sys

sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
from py_common.mongo import JenkinsMongoDB

CFG = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO},
                        'PUSHGATEWAY_URL': {'default': 'pushgateway.nomad:9999'}})
ONE_DAY = (60*60*24)

class AlertManager(object):
    def __init__(self, *, alert_group):
        self.logger = logging.getLogger(__name__)
        self.jmdb = JenkinsMongoDB()
        self.alert_group = alert_group

    def _set_alert(self, *, alert_id, description, ttl, severity):
        self.logger.debug("alert_id {}".format(alert_id))
        self.logger.debug("severity {}".format(severity))
        self.logger.debug("decription {}".format(description))
        self.logger.debug("ttl {}".format(ttl))
        registry = CollectorRegistry()
        g = Gauge(self.alert_group, description, ['severity', 'description'], registry=registry)
        g.labels(severity=severity, description=description).set(1)
        push_to_gateway(CFG.get('PUSHGATEWAY_URL'), job=alert_id, registry=registry)
        self.jmdb.alert_ttl(alert_group=self.alert_group, alert_id=alert_id, ttl=ttl)

    def warning(self, *, alert_id, description, ttl=ONE_DAY):
        args = locals()
        args.pop('self')
        args['severity'] = "warning"
        self._set_alert(**args)

    def error(self, *, alert_id, description, ttl=ONE_DAY):
        args = locals()
        args.pop('self')
        args['severity'] = "error"
        self._set_alert(**args)

    def critical(self, *, alert_id, description, ttl=ONE_DAY):
        args = locals()
        args.pop('self')
        args['severity'] = "critical"
        self._set_alert(**args)

    def clear(self, *, alert_id):
        self.logger.debug("alert_id {}".format(alert_id))
        delete_from_gateway(CFG.get('PUSHGATEWAY_URL'), job=alert_id)
        self.jmdb.alert_ttl(alert_group=self.alert_group, alert_id=alert_id, ttl=None)

    def clear_expired(self):
        for alert_id in self.jmdb.alerts_expired(alert_group=self.alert_group):
            self.logger.debug("alert_id {}".format(alert_id))
            self.clear(alert_id=alert_id)

# In-line "unit test"
if __name__ == '__main__':
    print("Compile check A-OK!")

    import time
    from random import randrange

    # It's log, it's log... :)
    logging.basicConfig(level=CFG.get('LOG_LEVEL'),
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler(sys.stdout)])

    logger = logging.getLogger(__name__)
    mgr = AlertManager(alert_group="rls_experimental")
    mgr.critical(alert_id="alert1", description="Some critical alert", ttl=60)
    mgr.warning(alert_id="alert2", description="Some warning alert", ttl=60)
    mgr.error(alert_id="alert3", description="Some error alert", ttl=60)
    logger.debug("sleeping 300s...")
    time.sleep(300)
    logger.debug("clearing expired...")
    mgr.clear_expired()
    """
    """
