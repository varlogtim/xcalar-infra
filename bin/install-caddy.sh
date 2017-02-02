#!/bin/bash

NAME="$(basename ${BASH_SOURCE[0]})"
ACME_CA="${ACME_CA:-https://acme-staging.api.letsencrypt.org/directory}"

die () {
    syslog "ERROR: $*"
    exit 1
}

syslog () {
    logger -t "$NAME" -i -s "$@"
}

get_dns_entry () {
    local dnsip=
    dnsip="$(set -o pipefail; dig @8.8.8.8 ${1} | egrep '^'${1}'.\s+([-0-9]+)\s+IN\s+A\s+' | awk '{print $(NF)}')"
    local rc=$?
    if [ $rc -ne 0 ] || [ "$dnsip" = "" ]; then
        return 1
    fi
    echo "$dnsip"
    return 0
}


test -z "$1" && die "Need to specify dns name"

FQDN="$1"
FQDNHOST="${FQDN%.xcalar.*}"
FQDNDOMAIN="${FQDN#$FQDNHOST.}"
FQDNDEFAULT="$(hostname -s).${FQDNDOMAIN}"
PUBIP="$(curl -sSL http://icanhazip.com)"
if [ $? -ne 0 ] || [ "$PUBIP" = "" ]; then
    die "No public ip for $FQDN"
fi

DNSIP="$(get_dns_entry $FQDN)"
until [ $? -eq 0 ] && [ "$DNSIP" = "$PUBIP" ]; do
    syslog "Got $DNSIP from DNS for $FQDN. Looking for $PUBIP. Sleeping ..."
    sleep 5
    DNSIP="$(get_dns_entry $FQDN)"
done

syslog "Matched IP Address of $FQDN PUBIP=$PUBIP with DNSIP=$DNSIP"

CADDY_HOME=/etc/ssl/caddy

CERT=$CADDY_HOME/.caddy/acme/acme-v01.api.letsencrypt.org/sites/$FQDN

HOSTLINE="https://${FQDN}"
if [ "$FQDN" != "$FQDNDEFAULT" ]; then
    HOSTLINE="${HOSTLINE}, https://${FQDNDEFAULT}"
fi


mkdir -p /etc/caddy

if ! test -e /etc/caddy/Caddyfile; then
	cat > /etc/caddy/Caddyfile <<-EOF
	${HOSTLINE} {
	    redir 301 {
	       if {>X-Forwarded-Proto} is http
	       /  https://{host}{uri}
	    }
	    tls abakshi@xcalar.com
	    cors
	    gzip
	    root /opt/xcalar/xcalar-gui
	    proxy /thrift/service http://127.0.0.1:9090/thrift/service {
	        without /thrift/service
	        max_fails 5
	        fail_timeout 10s
	        transparent
	    }
	    proxy /app  http://127.0.0.1:12124 {
	        without /app
	        max_fails 5
	        fail_timeout 10s
	        transparent
	    }
	    errors /var/log/caddy/error.log
	    log / /var/log/caddy/access.log "{hostname} {remote} - - [{when}] \"{method} {uri} {proto}\" {status} {size} \"{>Referer}\" \"{>User-Agent}\" {latency}" {
	        rotate {
	            size 100 # Rotate after 100 MB
	            age  14  # Keep log files for 14 days
	            keep 10  # Keep at most 10 log files
	        }
	    }
	}
	EOF
    echo >&2 "Generated /etc/caddy/Caddyfile. Please modify and run 'start caddy'"
else
    sed -r -i"-$(date +%s).bak" -e 's@^http[s]?://.*$@'${HOSTLINE}' {@g' -e 's/tls .*$/tls abakshi@xcalar.com/g' /etc/caddy/Caddyfile
fi

if ! id -u www-data &>/dev/null; then
    useradd --system --no-create-home --user-group --home-dir $CADDY_HOME --shell /usr/sbin/nologin www-data
fi

# In case /var/www/html is a symlink, don't error out
test -e /var/www || mkdir -p /var/www
test -e /var/www/html || mkdir -p /var/www/html
#mkdir -m 0700 -p /var/www/.config /var/www/.caddy
mkdir -m 0700 -p $CADDY_HOME
mkdir -m 0750 -p /var/log/caddy
chown www-data $CADDY_HOME
chown www-data:adm /var/log/caddy

CADDY_VERSION="${CADDY_VERSION:-0.9.4}"
if ! test -e /usr/bin/caddy-${CADDY_VERSION}; then
    curl -sSL http://repo.xcalar.net/deps/caddy-linux-amd64_${CADDY_VERSION} > /usr/bin/caddy.$$
    chmod +x /usr/bin/caddy.$$
    setcap cap_net_bind_service=+ep /usr/bin/caddy.$$
    mv /usr/bin/caddy.$$ /usr/bin/caddy-${CADDY_VERSION}
fi
rm -f /usr/bin/caddy
ln -sfn /usr/bin/caddy-${CADDY_VERSION} /usr/bin/caddy

if command -v systemctl &>/dev/null; then
    cat > /lib/systemd/system/caddy.service <<-EOF
	[Unit]
	Description=Caddy HTTP/2 web server
	Documentation=https://caddyserver.com/docs
	After=network-online.target
	Wants=network-online.target systemd-networkd-wait-online.service

	[Service]
	Restart=on-failure

	; User and group the process will run as.
	User=www-data
	Group=www-data

	; Letsencrypt-issued certificates will be written to this directory.
	Environment=HOME=$CADDY_HOME

	; Always set "-root" to something safe in case it gets forgotten in the Caddyfile.
	ExecStart=/usr/bin/caddy -ca $ACME_CA -log stdout -agree -root /var/tmp -conf /etc/caddy/Caddyfile
	ExecReload=/bin/kill -USR1 \$MAINPID

	; Limit the number of file descriptors; see 'man systemd.exec' for more limit settings.
	LimitNOFILE=1048576
	; Unmodified caddy is not expected to use more than that.
	LimitNPROC=64

	; Use private /tmp and /var/tmp, which are discarded after caddy stops.
	PrivateTmp=true
	; Use a minimal /dev
	PrivateDevices=true
	; Hide /home, /root, and /run/user. Nobody will steal your SSH-keys.
	ProtectHome=true
	; Make /usr, /boot, /etc and possibly some more folders read-only.
	ProtectSystem=full
	; … except /etc/ssl/caddy, because we want Letsencrypt-certificates there.
	;   This merely retains r/w access rights, it does not add any new. Must still be writable on the host!
	ReadWriteDirectories=/etc/ssl/caddy /var/log/caddy

	; Drop all other capabilities. Important if you run caddy as privileged user (which you should not).
	;CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_LEASE
	; … but permit caddy to open ports reserved for system services.
	;   This could be redundant here, but is needed in case caddy runs as nobody:nogroup.
	;AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_LEASE
	; … and prevent gaining any new privileges.
	;NoNewPrivileges=true

	; Caveat: Some plugins need additional capabilities. Add them to both above lines.
	; - plugin "upload" needs: CAP_LEASE
	[Install]
	WantedBy=multi-user.target
	EOF
    systemctl daemon-reload
    systemctl stop httpd || true
    systemctl disable httpd || true
    systemctl enable caddy.service || true
    systemctl stop caddy.service || true
    systemctl start caddy.service
else
    cat > /etc/init/caddy.conf <<-EOF
	description "Caddy Server startup script"

	start on runlevel [2345]
	stop on runlevel [016]

	limit nofile 65535 65535

	setuid www-data
	setgid www-data

	respawn
	respawn limit 10 5

	script
	    export HOME=$CADDY_HOME
	    cd $CADDY_HOME
	    exec /usr/bin/caddy -ca $ACME_CA -agree -root /var/tmp -conf /etc/caddy/Caddyfile
	end script
	EOF
    service apache2 stop || true
    update-rc.d apache2 disable || true
    service caddy stop || true
    service caddy start
fi

