#!/bin/bash

curl -s -H 'Host: vllm.local' -X POST http://localhost:8080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen2.5-3b",
    "prompt": "How to say hi in Spanish, answer in one word",
    "max_tokens": 10
  }' | jq .
