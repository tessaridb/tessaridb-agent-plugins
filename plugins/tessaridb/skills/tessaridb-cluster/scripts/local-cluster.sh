#!/bin/sh
# Stand up a three-node TessariDB cluster on this machine, for trying statements and failover.
#
#   sh local-cluster.sh <directory> [tessaridb binary]
#
# Ports: clients 48161-48163, peers 48171-48173, HTTP 48181-48183 (override BASE, default 481).
# Owner: user `owner`, password from OWNER_PASSWORD (default `local-cluster-owner`).
# Stop it with: kill $(cat <directory>/n*/pid)
# Needs openssl. Every node gets its own store, peer certificate and log under <directory>.
set -eu
S=$1
B=${2:-tessaridb}
BASE=${BASE:-481}
PW=${OWNER_PASSWORD:-local-cluster-owner}
# The script works inside <directory>, so a relative binary path is made absolute first.
case $B in */*) B=$(cd "$(dirname "$B")" && pwd)/$(basename "$B") ;; esac

mkdir -p "$S"
cd "$S"
for n in 1 2 3; do mkdir -p n$n; done

# 1. Each store makes its node id the first time it opens.
id() { "$B" n$1/store -e "INFO FOR NODE;" | grep -o "id: '[0-9a-f]*'" | cut -d"'" -f2; }
I1=$(id 1); I2=$(id 2); I3=$(id 3)
echo "$I1 $I2 $I3" > ids

# 2. A cluster authority, and a peer certificate per node named <node id>.peer.tessari.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
  -subj "/CN=tessaridb cluster authority" -keyout ca.key -out ca.pem 2>/dev/null
for n in 1 2 3; do
  eval I=\$I$n
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$I.peer.tessari" \
    -keyout n$n/peer.key -out n$n/peer.csr 2>/dev/null
  printf 'subjectAltName=DNS:%s.peer.tessari\nextendedKeyUsage=serverAuth,clientAuth\n' "$I" > n$n/ext
  openssl x509 -req -in n$n/peer.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 \
    -extfile n$n/ext -out n$n/peer.pem 2>/dev/null
  chmod 600 n$n/peer.key
done

# 3. The same membership on every node, in the same order, itself included, in ONE transaction.
cat > members.tessariql <<EOF
BEGIN;
DEFINE USER owner ROLE owner PASSWORD '$PW';
DEFINE REPLICA n1 AT '127.0.0.1:${BASE}71' CLIENTS AT '127.0.0.1:${BASE}61' NODE '$I1' ROLES serving, writable, coordinating REPLICATES STORE;
DEFINE REPLICA n2 AT '127.0.0.1:${BASE}72' CLIENTS AT '127.0.0.1:${BASE}62' NODE '$I2' ROLES serving, writable, coordinating REPLICATES STORE;
DEFINE REPLICA n3 AT '127.0.0.1:${BASE}73' CLIENTS AT '127.0.0.1:${BASE}63' NODE '$I3' ROLES serving, writable, coordinating REPLICATES STORE;
DEFINE NODE ROLES serving, writable, coordinating;
COMMIT;
EOF
for n in 1 2 3; do "$B" n$n/store -f members.tessariql > /dev/null; done

# 4. Start every node with all five cluster options.
for n in 1 2 3; do
  case $n in
    1) seed="$I2@127.0.0.1:${BASE}72" ;;
    2) seed="$I3@127.0.0.1:${BASE}73" ;;
    3) seed="$I1@127.0.0.1:${BASE}71" ;;
  esac
  nohup "$B" n$n/store --serve 127.0.0.1:${BASE}6$n --http 127.0.0.1:${BASE}8$n \
    --cluster-credential n$n/peer.pem --cluster-key n$n/peer.key --cluster-authority ca.pem \
    --cluster-address 127.0.0.1:${BASE}7$n --seed "$seed" > n$n/log 2>&1 &
  echo $! > n$n/pid
done

echo "started: clients 127.0.0.1:${BASE}61-${BASE}63, peers ${BASE}71-${BASE}73, http ${BASE}81-${BASE}83"
echo "check:   TESSARIDB_PASSWORD='$PW' $B --at 127.0.0.1:${BASE}61 --user owner -e 'INFO FOR NODE;'"
echo "stop:    kill \$(cat $S/n*/pid)"
