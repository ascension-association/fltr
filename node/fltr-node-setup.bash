#!/bin/bash

# load configuration settings
while read LINE; do declare "$LINE"; done <fltr-node-setup.conf

# verify root
if [ "${EUID}" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# verify hub domain name
if [[ -z "${HUB_DOMAIN_NAME}" ]] || [[ "${HUB_DOMAIN_NAME}" != *"."* ]]; then
  echo 'Missing hub domain name. Please see README for instructions.'
  exit
fi

# enable community repo and use TLS
sed -i "s/#//" /etc/apk/repositories
sed -i "s/^http:/https:/g" /etc/apk/repositories
apk update

# enable automatic updates
if [ "$(apk list --installed | grep apk-autoupdate | wc -l)" -eq 0 ]; then
  echo "Enabling automatic updates..."
  apk add apk-autoupdate --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing
  cat >>/etc/apk/autoupdate.conf <<EOF

after_upgrade() {
  for pkg in \$@; do
    case \$pkg in
      linux-*) reboot;;
    esac
  done
}
EOF

  cat >/etc/periodic/daily/apk-autoupdate.sh <<EOF
#!/bin/sh
set -eu
apk-autoupdate
EOF

  chmod 700 /etc/periodic/daily/apk-autoupdate.sh
fi

# disable IPv6
echo 1 >/proc/sys/net/ipv6/conf/all/disable_ipv6

# install and run Endwall
if [ ! -f /usr/local/bin/endwall ]; then
  echo "Installing endwall..."
  apk del iptables ip6tables
  apk add curl nftables iproute2 nmap
  rc-update add nftables
  rc-service nftables start
  curl -sLo /usr/local/bin/endwall https://raw.githubusercontent.com/ascension-association/endwall/master/endwall_nft_alpine.sh
  sed -i "s/client_out udp 64738/client_out udp 41641/" /usr/local/bin/endwall
  sed -i "s/#server_in udp 123/server_in udp 41641/" /usr/local/bin/endwall
  chmod u+wrx /usr/local/bin/endwall
  /usr/local/bin/endwall
fi

# install Tailscale exit node
echo "Installing Tailscale..."
echo "net.ipv4.ip_forward = 1" >/etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf
apk add ethtool
apk add tailscale --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community

# optimize Tailscale
rc-update add local default
cat >/etc/local.d/tailscale.start <<EOF
#!/bin/sh
ulimit -n 65535
ethtool -K $(ip route show 0/0 | cut -f5 -d" " | head -n1) rx-udp-gro-forwarding on rx-gro-list off
EOF

chmod u+wrx /etc/local.d/tailscale.start

# run Tailscale
rc-update add tailscale
rc-service tailscale start
tailscale up --advertise-exit-node --login-server=https://${HUB_DOMAIN_NAME}:8443 --authkey ${TAILSCALE_AUTH_KEY}
exit

# install Blocky, including SafeSurfer.io upstream DNS servers
apk add blocky --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community
rm /etc/blocky/config.example.yml
cat >/etc/blocky/config.yml <<EOF
upstreams:
  groups:
    default:
      - 104.197.28.121
      - 104.155.237.225
filtering:
  queryTypes:
    - AAAA
blocking:
  denylists:
    proxy:
      - https://raw.githubusercontent.com/dibdot/DoH-IP-blocklists/master/doh-ipv4.txt
      - https://iplists.firehol.org/files/firehol_anonymous.netset
      - https://iplists.firehol.org/files/et_tor.ipset
      - https://iplists.firehol.org/files/iblocklist_onion_router.netset
    adult:
      - https://nsfw.oisd.nl/domainswild
      - https://raw.githubusercontent.com/ascension-association/FLTR/main/node/dufcxgnbjsdwmwctgfuj-iblocklist-pedophiles-mirror.txt
    ads:
      - https://small.oisd.nl/domainswild
    security:
      - https://iplists.firehol.org/files/firehol_level1.netset
      - https://iplists.firehol.org/files/turris_greylist.ipset
      - https://cinsscore.com/list/ci-badguys.txt
      - https://lists.blocklist.de/lists/all.txt
    custom:
      - |
        # inline definition with YAML literal block scalar style
        baddomain.org
        tor.bravesoftware.com
        odoh.cloudflare-dns.com
        odoh1.surfdomeinen.nl
        dweb.link
        nftstorage.link
  allowlists:
    custom:
      - |
        # inline definition with YAML literal block scalar style
        doh.safesurfer.io
        www.yahoo.com
        assets.msn.com
        vecpea.com
        zzztest.oisd.nl
  clientGroupsBlock:
    default:
      - proxy
      - adult
      - ads
      - security
      - custom
caching:
  minTime: 5m
ports:
  dns: 53
bootstrapDns:
  - tcp+udp:104.197.28.121
  - tcp+udp:104.155.237.225
EOF

# run Blocky
rc-update add blocky
rc-service blocky start
tailscale set --accept-dns=false
echo "nameserver 127.0.0.1" >/etc/resolv.conf

# compile and install Zeek
apk add g++ cmake make openssl-dev libpcap-dev git python3-dev bison flex-dev musl-fts-dev linux-headers zlib-dev swig bash geoip-dev libmaxminddb-dev
cd /tmp
git clone --recursive https://github.com/zeek/zeek.git
cd zeek
./configure --prefix=/usr/local/zeek
make
make install
cat >/etc/node.cfg <<EOF
[zeek]
type=standalone
host=localhost
interface=$(ip route show 0/0 | cut -f5 -d" " | head -n1)
EOF

# install and load json-streaming-logs
echo y | /usr/local/zeek/bin/zkg autoconfig
sed -i "s/# @load packages/@load packages/" /usr/local/zeek/share/zeek/site/local.zeek
echo "SitePluginPath = $(/usr/local/zeek/bin/zkg config plugin_dir)" >>/usr/local/zeek/etc/zeekctl.cfg
apk add py3-gitpython py3-semantic-version --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community
echo y | /usr/local/zeek/bin/zkg install json-streaming-logs
sed -i "s/disable_default_logs = F/disable_default_logs = T/" /usr/local/zeek/share/zeek/site/packages/json-streaming-logs/main.zeek
/usr/local/zeek/bin/zkg load json-streaming-logs
/usr/local/zeek/bin/zeekctl deploy

# run Zeek when Tailscale runs
/usr/local/zeek/bin/zeekctl start
echo "/usr/local/zeek/bin/zeekctl start" >>/etc/local.d/tailscale.start

# install Vector
apk add openssl
apk add librdkafka zlib-ng --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community
apk add vector --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing
mkdir -p /var/lib/vector

# install LogSlash
apk add git
cd /tmp
git clone https://github.com/ascension-association/LogSlash
cp ./LogSlash/Vector/logslash-zeek_*.toml /etc/vector/
test -f /etc/vector/vector.yaml && rm /etc/vector/vector.yaml

# configure Vector
sed -i 's/type = "console"/type = "mqtt"/' /etc/vector/*.toml
sed -i "/type = \"mqtt\"/a topic = \"${MQTT_WRITE_STORE_KEY}/db/\"" /etc/vector/*.toml
sed -i '/type = "mqtt"/a port = 443' /etc/vector/*.toml
sed -i "/type = \"mqtt\"/a host = \"${HUB_DOMAIN_NAME}\"" /etc/vector/*.toml

# run Vector
apk add screen
/usr/bin/screen -d -m /usr/bin/vector -C /etc/vector
echo "/usr/bin/screen -d -m /usr/bin/vector -C /etc/vector" >>/etc/local.d/tailscale.start
