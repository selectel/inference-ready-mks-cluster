# AI/ML observability stack

## Структура

```text
chart/                              umbrella Helm chart и зависимости
  crds/                             OpenSearch CRD, устанавливаемые до templates
  templates/dashboards/             Grafana dashboard ConfigMaps
  templates/endpoints/              vLLM/Ray ServiceMonitor и PodMonitor
  templates/opensearch/             OpenSearch cluster, secrets, datasource
  files/dashboards/                 dashboard JSON
```

## Требования

- Kubernetes и рабочий `kubectl` context;
- Helm 3+;
- StorageClass `fast2.ru-6` либо другое имя, указанное в `chart/values.yaml`;
- для DCGM: NVIDIA driver, NVIDIA Container Toolkit/device plugin и GPU-ноды с
  label `nvidia.com/gpu=true`;
- runtime handler `nvidia`. Если `RuntimeClass/nvidia` уже создан, установите
  `dcgm.runtimeClass.create: false` в `chart/values.yaml`.

Chart создаёт PVC суммарно на 17 Gi: OpenSearch `2 x 5 Gi`, Prometheus `5 Gi`,
Alertmanager `1 Gi`, Grafana `1 Gi`.

## Установка

Перед установкой отредактируйте единственный файл `chart/values.yaml`.
В этом же файле можно установить `dcgm.enabled: false`, если GPU нет. По умолчанию
все PVC используют `fast2.ru-6`. Если в кластере StorageClass называется иначе,
замените это имя во всех четырёх местах `chart/values.yaml`.

Команды установки:

```bash
export KUBECONFIG=/path/to/kubeconfig

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add opensearch-operator https://opensearch-project.github.io/opensearch-k8s-operator/
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add dcgm https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

helm dependency build ./chart
helm lint ./chart

# Одна команда устанавливает CRD, операторы и весь observability stack.
helm upgrade --install monitoring ./chart \
  --namespace monitoring \
  --create-namespace \
  --wait \
  --timeout 20m
```

## Проверка

```bash
kubectl -n monitoring get pods,pvc
kubectl -n monitoring get servicemonitor,podmonitor
kubectl -n monitoring get opensearchcluster

kubectl -n monitoring wait \
  --for=jsonpath='{.status.phase}'=RUNNING \
  opensearchcluster/opensearch \
  --timeout=15m
```

Grafana:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Пароль Grafana (в другом терминале):

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Откройте <http://localhost:3000>, пользователь `admin`.

Prometheus:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Откройте <http://localhost:9090/targets>. Ожидаются `UP` для node-exporter,
kube-state-metrics, Fluent Bit и DCGM (если включён). Проверочный GPU-запрос:
`DCGM_FI_DEV_GPU_UTIL`.


## Удаление

```bash
helm uninstall monitoring --namespace monitoring
kubectl delete namespace monitoring
```

PVC и CRD проверьте отдельно перед удалением: Helm обычно не удаляет CRD, а удаление
namespace уничтожит данные OpenSearch, Prometheus, Alertmanager и Grafana.
