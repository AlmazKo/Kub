#!/bin/sh
# A fake microservice for the demo cluster: busybox only, no real app.
# Prints believable request logs and serves a Prometheus /metrics page
# (a file rewritten every tick, served by busybox httpd on $PORT).
#
# Env: SERVICE (name in logs/labels), PORT (default 8080), PATHS (space-separated),
#      ERROR_RATE (percent of 5xx, default 4).

PORT="${PORT:-8080}"
# Not ${PATHS:-…}: the "}" of {id} would close that expansion early.
[ -n "$PATHS" ] || PATHS='/api/v1/items /api/v1/items/{id} /healthz'
ERROR_RATE="${ERROR_RATE:-4}"

# PID 1 ignores SIGTERM by default — exit at once so rollouts don't stall 30s.
trap 'exit 0' TERM INT

mkdir -p /www
echo "ok" > /www/healthz
httpd -p "$PORT" -h /www

echo "INFO  [$SERVICE] starting, version=${VERSION:-1.0.0} port=$PORT"
echo "INFO  [$SERVICE] connected to config service, profile=production"
echo "INFO  [$SERVICE] ready"

npaths=$(echo $PATHS | wc -w)
ok=0; client=0; server=0; total_ms=0; tick=0

while true; do
    tick=$((tick + 1))
    i=$((RANDOM % npaths + 1))
    path=$(echo $PATHS | tr ' ' '\n' | sed -n "${i}p" | sed "s/{id}/$((RANDOM % 9000 + 1000))/")
    ms=$((RANDOM % 180 + 4))
    r=$((RANDOM % 100))
    trace=$(printf '%04x%04x' $RANDOM $RANDOM)
    if [ "$r" -lt "$ERROR_RATE" ]; then
        server=$((server + 1)); ms=$((ms + 900))
        echo "ERROR [$SERVICE] GET $path status=503 duration=${ms}ms trace=$trace upstream timed out"
    elif [ "$r" -lt $((ERROR_RATE + 6)) ]; then
        client=$((client + 1))
        echo "WARN  [$SERVICE] GET $path status=429 duration=${ms}ms trace=$trace rate limit exceeded"
    else
        ok=$((ok + 1))
        echo "INFO  [$SERVICE] GET $path status=200 duration=${ms}ms trace=$trace"
    fi
    total_ms=$((total_ms + ms))
    [ $((tick % 40)) -eq 0 ] && echo "DEBUG [$SERVICE] connection pool active=$((RANDOM % 12 + 2)) idle=$((RANDOM % 6)) max=20"

    cat > /www/metrics.tmp <<EOF
# HELP http_requests_total Total HTTP requests served.
# TYPE http_requests_total counter
http_requests_total{service="$SERVICE",code="200"} $ok
http_requests_total{service="$SERVICE",code="429"} $client
http_requests_total{service="$SERVICE",code="503"} $server
# HELP http_request_duration_seconds_sum Total time spent serving requests.
# TYPE http_request_duration_seconds_sum counter
http_request_duration_seconds_sum{service="$SERVICE"} $((total_ms / 1000)).$((total_ms % 1000))
# HELP db_pool_connections Database connections by state.
# TYPE db_pool_connections gauge
db_pool_connections{state="active"} $((RANDOM % 12 + 2))
db_pool_connections{state="idle"} $((RANDOM % 6))
# HELP process_resident_memory_bytes Resident memory size in bytes.
# TYPE process_resident_memory_bytes gauge
process_resident_memory_bytes $((RANDOM * 900 + 41000000))
# HELP app_info Build information.
# TYPE app_info gauge
app_info{service="$SERVICE",version="${VERSION:-1.0.0}"} 1
EOF
    mv /www/metrics.tmp /www/metrics
    sleep "0.$((RANDOM % 8 + 2))"
done
