# =============================================================================
# Job: загрузка весов моделей с HuggingFace в S3-том (PVC models, SC csi-s3).
# Рендерится terraform-корнём 02-addons в kubernetes_manifest (Job — core API).
# force_new = список моделей: изменение hf_models пересоздаёт Job.
#
# Схема: job монтирует PVC models (RWX, geesefs) и качает веса НАПРЯМОУ в том —
# драйвер сам пишет в S3 в префикс тома (pvc-<uid>). Никаких boto3/кредов.
# Альтернатива «скачать на диск ноды и залить в бакет» ловила DiskPressure
# (вся модель 65 ГБ на диске system-ноды) — проверено 2026-09-11.
# =============================================================================
apiVersion: batch/v1
kind: Job
metadata:
  name: hf-models-upload
  # ns default: PVC models (csi-s3) — в этом же ns, монтирование PVC
  # кросс-namespace невозможно
  namespace: default
  labels:
    app.kubernetes.io/name: hf-models-upload
spec:
  # Egress к huggingface.co из сети кластера нестабилен (проверено
  # 2026-09-21: чередование 200/timeout с нод) — ретраев много, каждый
  # продолжает закачку (готовые файлы пропускаются по размеру)
  backoffLimit: 20
  # Перезапуск безопасен: существующие файлы пропускаются по размеру
  template:
    metadata:
      labels:
        app.kubernetes.io/name: hf-models-upload
    spec:
      restartPolicy: Never
      nodeSelector:
        nodegroup: system
      containers:
        - name: hf-sync
          # Зеркало docker.io (pull-through); тег существует (проверено 2026-09-11)
          image: docker-registry.selectel.ru/library/python:3.12.9-slim
          command: ["bash", "-c"]
          args:
            - |
              set -euo pipefail
              pip install --no-cache-dir --quiet "huggingface_hub"
              python - <<'PY'
              import os, pathlib
              from huggingface_hub import HfApi, hf_hub_download

              api = HfApi()
              root = pathlib.Path("/models")

              # MODELS: "repo=alias,repo=alias" — alias = каталог в томе
              for item in filter(None, os.environ["MODELS"].split(",")):
                  repo, alias = item.split("=", 1)
                  print(f"== {repo} -> /models/{alias}", flush=True)
                  info = api.model_info(repo_id=repo, files_metadata=True)
                  # Пропускаем тяжёлые/посторонние форматы: LoRA-репо часто
                  # содержат GGUF/ONNX-конверсии (десятки ГБ), модели —
                  # дубликаты весов в .pth/.msgpack; .safetensors достаточно
                  skip = {".gguf", ".onnx", ".pth", ".pt", ".msgpack",
                          ".h5", ".png", ".jpg", ".jpeg", ".webp"}
                  files = [s for s in info.siblings
                           if not s.rfilename.startswith(".git")
                           and pathlib.Path(s.rfilename).suffix.lower() not in skip]
                  for i, f in enumerate(files, 1):
                      dest = root / alias / f.rfilename
                      if dest.exists() and dest.stat().st_size == f.size:
                          print(f"   [{i}/{len(files)}] есть: {f.rfilename}", flush=True)
                          continue
                      print(f"   [{i}/{len(files)}] качаю: {f.rfilename} "
                            f"({round(f.size/1e9,1)} ГБ)", flush=True)
                      hf_hub_download(repo_id=repo, filename=f.rfilename,
                                      local_dir=root / alias)
              print("== готово", flush=True)
              PY
          env:
            - name: MODELS
              value: "${models_csv}"
            # Xet-клиент HF раздувает RSS до OOM на крупных репо — отключаем,
            # обычный HTTP-поток памяти почти не ест (проверено: OOMKilled 4Gi)
            - name: HF_HUB_DISABLE_XET
              value: "1"
            # Дефолтный HTTP-таймаут huggingface_hub — 10 с: на нестабильном
            # egress убивает начавшиеся загрузки. 60 с переживает окна потерь
            - name: HF_HUB_DOWNLOAD_TIMEOUT
              value: "60"
%{ if has_hf_token ~}
            # Токен HF из Secret hf-token (без анонимного rate-limit)
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: token
%{ endif ~}
          resources:
            # Буферы geesefs-FUSE + huggingface_hub
            requests:
              cpu: "1"
              memory: 512Mi
            limits:
              memory: 2Gi
          volumeMounts:
            - name: models
              mountPath: /models
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: models
