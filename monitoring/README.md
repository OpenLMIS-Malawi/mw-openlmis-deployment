# Monitoring

OpenLMIS Malawi is monitored by the [`soldevelo-monitoring`](https://github.com/SolDevelo/soldevelo-monitoring)
stack at `olmismalawi-monitoring.soldevelo.com`. Each environment host runs an
Alloy agent that pushes metrics and logs to it.

| Directory | What |
|---|---|
| [`alloy/`](alloy/) | The agent deployed to each environment host by `mw-monitoring-alloy-deploy-to-{dev,uat,prod}` |
| [`monitoring-host/`](monitoring-host/) | Malawi-specific files for the central monitoring host: alert rules, probe targets |
