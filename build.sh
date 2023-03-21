
#shellcheck disable=SC2129,SC2164
#set -euo pipefail

MANIFESTS="manifests"
TOP=$(git rev-parse --show-toplevel)
TMPDIR="${TOP}/tmp/repos"

# Make sure to use project tooling
PATH="${TOP}/tmp/bin:${PATH}"


download_mixin() {
  local mixin="$1"
  local repo="$2"
  local subdir="$3"
  local dashboard_path="$4"

  git clone --depth 1 "$repo" "${TMPDIR}/$mixin"
  mkdir -p "${TOP}/${MANIFESTS}/alerts/${mixin}"
  mkdir -p "${TOP}/${MANIFESTS}/dashboards/${mixin}"
  (
    cd "${TMPDIR}/${mixin}/${subdir}"
    if [ -f "jsonnetfile.json" ]; then
      jb install
    fi
    
cat << EOF > myconfig.libsonnet
local utils = (import '${TOP}/lib/utils.libsonnet');

// Define a list of alerts to ignore from upstream
local enableGKESupport = true;

// Define a list of alerts to ignore from upstream
local ignore_alerts = if enableGKESupport then [
  'KubeSchedulerDown',
  'KubeControllerManagerDown',
  'KubeAPIDown',
  'KubeProxyDown',
  'KubeSchedulerDown',
  'KubeAPIErrorsHigh',
  'KubeAPILatencyHigh',
  'KubeClientCertificateExpiration',
  'ThanosRuleIsDown',
  'ThanosReceiveIsDown',
] else [];

local ignore_dashboards = [
  'prometheus-remote-write.json'
];

// Define a list of groups to ignore from upstream
local ignore_groups = if enableGKESupport then [
  'kube-scheduler.rules',
  'kube-apiserver.rules',
] else [];

// Define a mapping of alert/recordname to expression.
// Overrides the expr field for the specifeid record name.
local expr_overrides = {};

// Create our updates - they will get applied to the generated jsonnet
local updates = utils.filterGroups(ignore_groups) + utils.filterAlerts(ignore_alerts);
(import 'mixin.libsonnet') +
  updates + 
  {
    # Configuration for thanos mixin (multicluster support)
    targetGroups+:: {
      cluster: 'up{job=~".*thanos.*"}',
    },
    _config+:: {
      namespace: 'monitoring',

      # General multicluster support
      showMultiCluster: true,
      clusterLabel: "cluster",

      # Configuration for kubernetes-mixin (prom operator names)
      alertmanagerSelector: 'job="alertmanager-main"',
      cadvisorSelector: 'job="kubelet", metrics_path="/metrics/cadvisor"',
      kubeletSelector: 'job="kubelet"',
      kubeStateMetricsSelector: 'job="kube-state-metrics"',
      nodeExporterSelector: 'job="node-exporter"',
      kubeSchedulerSelector: 'job="kube-scheduler"',
      kubeApiserverSelector: 'job="apiserver"',

      # Device selectors
      diskDevices: ['mmcblk.p.+', 'nvme.+', 'rbd.+', 'sd.+', 'vd.+', 'xvd.+', 'dm-.+', 'dasd.+'],
      diskDeviceSelector: 'device=~".*(%s)"' % std.join('|', self.diskDevices),
      blackboxExporterSelector: '',
      
      # prometheus-mixin tune
      prometheusNameTemplate: '{{$labels.cluster}}/{{$labels.namespace}}/{{$labels.pod}}',
      prometheusSelector: 'job="prometheus-k8s"',
      
      # alertmanager tune
      alertmanagerClusterLabels: 'job',
      alertmanagerClusterName: '{{ \$labels.job }}',

      grafanaK8s+:: {
        refresh: "60s"
      },
      grafanaPrometheus: {
        prefix: 'Prometheus / ',
        tags: ['prometheus-mixin'],
        refresh: '60s',
      },
    },
    prometheus+:: {
      alerts: {
        apiVersion: 'monitoring.coreos.com/v1',
        kind: 'PrometheusRule',
        metadata: {
          labels: {
            role: 'alert-rules',
          },
          name: 'prometheus-' + (import "${TOP}/${MANIFESTS}/alerts/${mixin}/alerts.json").groups[0].name + '-rules',
          namespace: $._config.namespace,
        },
        spec: {
          groups: (import "${TOP}/${MANIFESTS}/alerts/${mixin}/alerts.json").groups,
        },
      },
      rules: {
        apiVersion: 'monitoring.coreos.com/v1',
        kind: 'PrometheusRule',
        metadata: {
          labels: {
            role: 'alert-rules',
          },
          name: 'prometheus-' + (import "${TOP}/${MANIFESTS}/alerts/${mixin}/rules.json").groups[0].name + '-rules',
          namespace: $._config.namespace,
        },
        spec: {
          groups: (import "${TOP}/${MANIFESTS}/alerts/${mixin}/rules.json").groups,
        },
      },
    },
  }
EOF

cat << EOF > mybuild.libsonnet
local kp = 
  (import 'myconfig.libsonnet') + 
  {
    _config+:: {
      namespace: 'monitoring',
      enableGKESupport: true,  
    }
  };
  
{ ['buildRules']: kp.prometheusRules }
{ ['buildDashboards']: kp.grafanaDashboards }
{ ['buildAlertsYAML']: kp.prometheus.alerts }
{ ['buildRulesYAML']: kp.prometheus.rules }
{ ['buildAlerts']: kp.prometheusAlerts }
EOF


    # Build alert and rules json and dashboards
    jsonnet -J vendor -S -e 'std.manifestYamlDoc((import "mybuild.libsonnet").buildAlerts)' | yq eval --tojson -P > "${TOP}/${MANIFESTS}/alerts/${mixin}/alerts.json" || :
    jsonnet -J vendor -S -e 'std.manifestYamlDoc((import "mybuild.libsonnet").buildRules)' | yq eval --tojson -P > "${TOP}/${MANIFESTS}/alerts/${mixin}/rules.json" || :
    jsonnet -J vendor -m "${TOP}/${MANIFESTS}/dashboards/${mixin}" -e '(import "mybuild.libsonnet").buildDashboards' || :
    
    # Build prometheusRule form json if is not empyt
    [[ -s ${TOP}/${MANIFESTS}/alerts/${mixin}/alerts.json ]] && jsonnet -J vendor -S -e 'std.manifestYamlDoc((import "mybuild.libsonnet").buildAlertsYAML)' | yq eval -P > "${TOP}/${MANIFESTS}/alerts/${mixin}/alerts.yaml" || :
    [[ -s ${TOP}/${MANIFESTS}/alerts/${mixin}/rules.json ]] && jsonnet -J vendor -S -e 'std.manifestYamlDoc((import "mybuild.libsonnet").buildRulesYAML)' | yq eval -P > "${TOP}/${MANIFESTS}/alerts/${mixin}/rules.yaml" || :
    rm -f ${TOP}/${MANIFESTS}/alerts/${mixin}/alerts.json || /bin/true
    rm -f ${TOP}/${MANIFESTS}/alerts/${mixin}/rules.json || /bin/true
    
    # Build configMap form dashboards    
    for i in $(ls -1 ${TOP}/${MANIFESTS}/dashboards/${mixin}); do
      local dashboard=$(echo $i|cut -f1 -d".")
      echo Building dashboard $dashboard configMap
      
cat << EOF > mybuild.libsonnet
local kp = 
  (import '../config.libsonnet') + 
  (import 'mixin.libsonnet') + 
  {
    _config+:: {
      namespace: 'monitoring',
      enableGKESupport: true,
    },
    prometheus+:: {
      dashboard+:: {
        apiVersion: 'v1',
        kind: 'ConfigMap',
        metadata: {
          annotations: {
            "kustomize.toolkit.fluxcd.io/substitute": "disabled",
            "argocd.argoproj.io/sync-option": "Replace=true",
            "k8s-sidecar-target-directory": "/tmp/dashboards/${dashboard_path}",
          },
          labels: {
            "grafana_dashboard": "1",
          },
          name: "grafana-dashboard-${mixin}-${dashboard}",
          namespace: $._config.namespace,
        },
        data: {
          "${dashboard}.json": (importstr "${TOP}/${MANIFESTS}/dashboards/${mixin}/${dashboard}.json"),
        },
      },
    },
  };

{ ['buildDashboard']: kp.prometheus.dashboard }
EOF

      [ -s ${TOP}/${MANIFESTS}/dashboards/${mixin}/${i} ] && jsonnet -J vendor -S -e 'std.manifestYamlDoc((import "mybuild.libsonnet").buildDashboard )' | yq eval -P > "${TOP}/${MANIFESTS}/dashboards/${mixin}/${i}.yaml" || :
      rm -f ${TOP}/${MANIFESTS}/dashboards/${mixin}/${i} || /bin/true
    done
  )
}

cd "${TOP}" || exit 1

# remove generated assets and temporary directory
rm -rf "$MANIFESTS" "$TMPDIR"
mkdir -p "${TMPDIR}"

# Generate mixins 
CONFIG="mixins.json"

for mixin in $(cat "$CONFIG" | jq -r '.mixins[].name'); do
  repo="$(cat "$CONFIG" | jq -r ".mixins[] | select(.name == \"$mixin\") | .source")"
  subdir="$(cat "$CONFIG" | jq -r ".mixins[] | select(.name == \"$mixin\") | .subdir")"
  dashboard_path="$(cat "$CONFIG" | jq -r ".mixins[] | select(.name == \"$mixin\") | .dashboard_path")"
  set +u
  download_mixin "$mixin" "$repo" "$subdir" "$dashboard_path"
done

# Add kube-prometheus
mkdir ${TOP}/${MANIFESTS}/alerts/kube-prometheus-mixin
wget -q https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/kubePrometheus-prometheusRule.yaml -O ${TOP}/${MANIFESTS}/alerts/kube-prometheus-mixin/kubePrometheus-prometheusRule.yaml

# Create kustomize manifest
cd ${TOP}/${MANIFESTS}
kustomize init --resources=alerts,dashboards
cd ${TOP}/${MANIFESTS}/alerts
kustomize init --autodetect --recursive
cd ${TOP}/${MANIFESTS}/dashboards
kustomize init --autodetect --recursive
