#!/bin/sh
# Stand up a three-node TessariDB S3 cluster (erasure code 2+1) in Docker, with its metadata on one
# TessariDB node, for trying cluster behaviour on one machine.
#
#   sh local-s3-cluster.sh <directory>
#
# S3 on 127.0.0.1:48187-48189 (override PORT, default 48187), the console of s1 on 48190. Root key `local-root`; its secret, the
# database passwords and the cluster secret are generated and written to <directory>/env.
# Remove everything with:
#   docker rm -f s3c-db s3c-s1 s3c-s2 s3c-s3; docker volume rm s3c-db s3c-s1 s3c-s2 s3c-s3; docker network rm s3c
# Needs docker and openssl.
set -eu
D=$1
PORT=${PORT:-48187}
NET=s3c
mkdir -p "$D/certs"
cd "$D"

OWNER_PW=owner-$(openssl rand -hex 8)
META_PW=meta-$(openssl rand -hex 8)
ROOT_SECRET=root-$(openssl rand -hex 12)
CLUSTER_SECRET=$(openssl rand -hex 32)
IAM_KEY=$(openssl rand -hex 32)
umask 077
printf 'OWNER_PW=%s\nMETA_PW=%s\nROOT_SECRET=%s\nCLUSTER_SECRET=%s\nIAM_KEY=%s\n' \
  "$OWNER_PW" "$META_PW" "$ROOT_SECRET" "$CLUSTER_SECRET" "$IAM_KEY" > env
umask 022

# 1. One authority, and a certificate per node named <node id>.peer.tessari-s3 for both TLS ends.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
  -subj "/CN=tessaridb-s3 cluster authority" -keyout certs/ca.key -out certs/ca.pem 2>/dev/null
for n in s1 s2 s3; do
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$n.peer.tessari-s3" \
    -keyout certs/$n.key -out certs/$n.csr 2>/dev/null
  printf 'subjectAltName=DNS:%s.peer.tessari-s3\nextendedKeyUsage=serverAuth,clientAuth\n' $n > certs/$n.ext
  openssl x509 -req -in certs/$n.csr -CA certs/ca.pem -CAkey certs/ca.key -CAcreateserial -days 365 \
    -extfile certs/$n.ext -out certs/$n.pem 2>/dev/null
done
# The container runs as a non-root user that must read its key through the bind mount.
chmod 644 certs/s?.key

# 2. The metadata node, with its owner declared on first start.
docker network create $NET > /dev/null
docker run -d --name s3c-db --network $NET -v s3c-db:/var/lib/tessaridb \
  -e TESSARIDB_INITIAL_USER=owner -e TESSARIDB_INITIAL_PASSWORD="$OWNER_PW" \
  tessaridb/tessaridb:0.38.3 > /dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  docker exec -e TESSARIDB_PASSWORD="$OWNER_PW" s3c-db \
    tessaridb --at 127.0.0.1:9080 --user owner -e 'RETURN 1;' > /dev/null 2>&1 && break
  python3 -c 'import time; time.sleep(1)'
done

# 3. The S3 servers' own account: an editor of the s3 namespace, never the owner.
cat > account.tessariql <<EOF
DEFINE NAMESPACE IF NOT EXISTS s3 REPLICATION NONE ACKNOWLEDGE MAJORITY OR WEAKER;
USE NAMESPACE s3;
DEFINE DATABASE IF NOT EXISTS meta;
USE NAMESPACE s3 DATABASE meta;
DEFINE USER IF NOT EXISTS s3 ON NAMESPACE s3 ROLE editor PASSWORD '$META_PW';
EOF
chmod 600 account.tessariql
# Sent on standard input, so the account's password is never in a process's arguments.
docker exec -i -e TESSARIDB_PASSWORD="$OWNER_PW" s3c-db \
  tessaridb --at 127.0.0.1:9080 --user owner -f /dev/stdin < account.tessariql > /dev/null

# 4. Three S3 nodes, founding members of one 2+1 cluster.
p=$PORT
for n in s1 s2 s3; do
  console=""
  [ $n = s1 ] && console="-e TESSARIDB_S3_CONSOLE_LISTEN=0.0.0.0:9101 -p 127.0.0.1:$((PORT + 3)):9101"
  # shellcheck disable=SC2086
  docker run -d --name s3c-$n --network $NET --network-alias $n -p 127.0.0.1:$p:9100 $console \
    -v s3c-$n:/var/lib/tessaridb-s3 -v "$PWD/certs:/certs:ro" \
    -e TESSARIDB_S3_ROOT_ACCESS_KEY=local-root -e TESSARIDB_S3_ROOT_SECRET_KEY="$ROOT_SECRET" \
    -e TESSARIDB_S3_META_ADDRESS=s3c-db:9080 -e TESSARIDB_S3_META_USER=s3 \
    -e TESSARIDB_S3_META_PASSWORD="$META_PW" -e TESSARIDB_S3_IAM_KEY="$IAM_KEY" \
    -e TESSARIDB_S3_ERASURE=2+1 -e TESSARIDB_S3_NODE_ID=$n \
    -e TESSARIDB_S3_INTERNAL_LISTEN=0.0.0.0:9200 -e TESSARIDB_S3_INTERNAL_ADVERTISE=$n:9200 \
    -e TESSARIDB_S3_CLUSTER_SECRET="$CLUSTER_SECRET" -e TESSARIDB_S3_FOUNDING_MEMBERS=s1,s2,s3 \
    -e TESSARIDB_S3_INTERNAL_TLS_CERT=/certs/$n.pem -e TESSARIDB_S3_INTERNAL_TLS_KEY=/certs/$n.key \
    -e TESSARIDB_S3_INTERNAL_TLS_CA=/certs/ca.pem \
    tessaridb/s3:0.8.0 > /dev/null
  p=$((p + 1))
done

echo "console of s1 on http://127.0.0.1:$((PORT + 3))"
echo "S3 on 127.0.0.1:$PORT-$((PORT + 2)); root key local-root, secret in $D/env (ROOT_SECRET)"
echo "try:  AWS_ACCESS_KEY_ID=local-root AWS_SECRET_ACCESS_KEY=<ROOT_SECRET> AWS_DEFAULT_REGION=us-east-1 \\"
echo "      aws --endpoint-url http://127.0.0.1:$PORT s3 mb s3://first"
