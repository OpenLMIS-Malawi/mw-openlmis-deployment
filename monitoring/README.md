# Monitoring

OpenLMIS Malawi is monitored by the [`soldevelo-monitoring`](https://github.com/SolDevelo/soldevelo-monitoring)
stack at `olmis-monitoring.soldevelo.com`, shared with the other OpenLMIS
implementations (`deployment=malawi`). Each environment host runs an Alloy
agent that pushes metrics and logs to it. Probe targets, agent inventory and
Slack routes for Malawi live in
[`openlmis-monitoring-overlay`](https://github.com/OpenLMIS/openlmis-monitoring-overlay).

| Directory | What |
|---|---|
| [`alloy/`](alloy/) | The agent deployed to each environment host by `mw-monitoring-alloy-deploy-to-{dev,uat,prod}` |
