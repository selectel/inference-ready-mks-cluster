# vLLM Inference через Envoy Gateway

Развёртывание vLLM с API-шлюзом на базе Envoy Gateway и Gateway API.

## Архитектура

```
Client → Envoy Gateway → HTTPRoute → vLLM Service → vLLM Pods (x2)
```

## Требования

- Kubernetes 1.28+
- Gateway API CRD
- Helm 3.x
- GPU-ноды (NVIDIA)

## Конфигурация кластера

| Параметр       | Значение         |
|----------------|------------------|
| Ноды           | 2                |
| CPU            | 8 vCPU           |
| RAM            | 32 ГБ            |
| Диск           | 300 ГБ           |
| GPU            | 1 × L4 24 ГБ     |

## Быстрый старт

### 1. Установка Envoy Gateway

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.1 \
  -n envoy-gateway-system --create-namespace
```

### 2. Применение манифестов

```bash
kubectl apply -f manifests/
```

### 3. Проверка

```bash
# Проверка vLLM
kubectl get all -n vllm-inference

# Проверка Envoy Gateway
kubectl get all -n envoy-gateway-system
```

### 4. Тестирование

```bash
./scripts/test.sh
```

## API Endpoints

| Метод | Путь                  | Описание          |
|-------|-----------------------|-------------------|
| GET   | `/health`             | Health check      |
| GET   | `/v1/models`          | Список моделей    |
| POST  | `/v1/completions`     | Text completion   |
| POST  | `/v1/chat/completions`| Chat completion   |

## Когда нужен Envoy AI Gateway

- Маршрутизация по имени модели (`model: qwen`)
- Единый endpoint для нескольких моделей
- AI-специфичные политики (лимиты по токенам)

Для простого случая с 1-2 моделями базового Envoy Gateway достаточно.

## Ресурсы

- [Envoy Gateway Docs](https://gateway.envoyproxy.io/docs/tasks/quickstart/)
- [Gateway API Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
- [AI on EKS - Envoy Gateway](https://github.com/awslabs/ai-on-eks/blob/main/website/docs/blueprints/gateways/envoy-gateway.md)
