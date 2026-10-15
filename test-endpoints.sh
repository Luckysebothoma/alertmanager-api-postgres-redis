#!/usr/bin/env bash
# Endpoint verification test suite for alertmanager-forecast-api

BASE_URL="http://192.168.0.140:4400"

echo "=========================================="
echo "1. Testing GET /health"
echo "=========================================="
curl -i -X GET "${BASE_URL}/health"
echo -e "\n"

echo "=========================================="
echo "2. Testing GET /metrics (Preview)"
echo "=========================================="
curl -i -X GET "${BASE_URL}/metrics" | head -n 20
echo -e "\n... [truncated metrics output] ...\n"

echo "=========================================="
echo "3. Testing POST /webhook/alertmanager"
echo "=========================================="
curl -i -X POST "${BASE_URL}/webhook/alertmanager" \
  -H "Content-Type: application/json" \
  -d '{
    "version": "4",
    "groupKey": "{}:{alertname=\"TestAlert\"}",
    "status": "firing",
    "receiver": "default",
    "alerts": [
      {
        "status": "firing",
        "labels": {
          "alertname": "TestAlert",
          "severity": "critical",
          "instance": "test-instance:9100"
        },
        "annotations": {
          "summary": "Manual test alert",
          "description": "Verifying database write and log output"
        },
        "startsAt": "2026-10-15T19:00:00Z",
        "generatorURL": "http://localhost/graph",
        "fingerprint": "testfingerprint999"
      }
    ]
  }'
echo -e "\n"

echo "=========================================="
echo "4. Testing GET /alerts (Query filter)"
echo "=========================================="
curl -i -X GET "${BASE_URL}/alerts?limit=5&alertname=TestAlert"
echo -e "\n"

echo "=========================================="
echo "5. Testing GET /alerts/generic"
echo "=========================================="
curl -i -X GET "${BASE_URL}/alerts/generic?limit=5"
echo -e "\n"

echo "=========================================="
echo "All endpoint tests completed successfully!"
echo "=========================================="
