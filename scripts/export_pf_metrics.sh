#!/bin/sh
set -eu

TEXTFILE_DIR="${1:-/var/db/node_exporter}"
OUT_FILE="${TEXTFILE_DIR}/pf_metrics.prom"
TMP_FILE="$(mktemp)"

trap 'rm -f "$TMP_FILE"' EXIT HUP INT TERM

mkdir -p "$TEXTFILE_DIR"

cat << 'EOF' > "$TMP_FILE"
# HELP pf_rule_packets_total Total packets matching PF rules
# TYPE pf_rule_packets_total counter
# HELP node_network_port_packets_total Total packets on specific network ports
# TYPE node_network_port_packets_total counter
EOF

if command -v pfctl >/dev/null 2>&1; then
    pfctl -sr -v 2>/dev/null | awk '
    /^\[ rule/ { rule=$3; proto="all"; port="all" }
    /proto/ {
        for(i=1;i<=NF;i++) {
            if ($i == "proto") proto=$(i+1);
            if ($i == "port") port=$(i+1);
        }
    }
    /Packets:/ {
        pkts=$2;
        gsub(/[^0-9]/, "", rule);
        gsub(/[^0-9a-zA-Z]/, "", proto);
        gsub(/[^0-9a-zA-Z]/, "", port);
        print "pf_rule_packets_total{rule=\"" rule "\",proto=\"" proto "\",port=\"" port "\"} " pkts;
        if (port != "all" && port != "") {
            print "node_network_port_packets_total{protocol=\"" proto "\",port=\"" port "\",service=\"pf\"} " pkts;
        }
    }' >> "$TMP_FILE"
fi

mv "$TMP_FILE" "$OUT_FILE"
chmod 0644 "$OUT_FILE"
