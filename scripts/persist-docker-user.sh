#!/usr/bin/env bash
set -Eeuo pipefail

# Persiste apenas as restricoes DOCKER-USER do Dell. O Ubuntu declara conflito
# entre ufw e iptables-persistent; por isso a persistencia e feita por systemd,
# depois que o Docker cria a cadeia DOCKER-USER.

readonly BACKUP_ROOT="/var/backups/homelab-firewall"
readonly HELPER_PATH="/usr/local/sbin/homelab-docker-user-firewall"
readonly UNIT_PATH="/etc/systemd/system/homelab-docker-user-firewall.service"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "execute com sudo: sudo bash $0"
fi

for command_name in apt-get docker grep install iptables iptables-save ip6tables-save systemctl systemd-analyze; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "comando obrigatorio ausente: $command_name"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$BACKUP_ROOT/$timestamp"
install -d -m 700 "$backup_dir"

log "Salvando o estado anterior em $backup_dir"
iptables-save > "$backup_dir/iptables.before.rules"
ip6tables-save > "$backup_dir/ip6tables.before.rules"
iptables -S DOCKER-USER > "$backup_dir/docker-user.before.txt" 2>/dev/null || true
cp -a /etc/ufw "$backup_dir/ufw-config"
for rules_file in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
  if [[ -f "$rules_file" ]]; then
    cp --preserve=mode,timestamps "$rules_file" "$backup_dir/$(basename "$rules_file").conflicting"
  fi
done
chmod -R go-rwx "$backup_dir"

if dpkg-query -W -f='${Status}' iptables-persistent netfilter-persistent 2>/dev/null \
  | grep -q 'install ok installed'; then
  log "Removendo pacotes que conflitam com UFW"
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y iptables-persistent netfilter-persistent
fi

log "Restaurando o pacote UFW"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y ufw
command -v ufw >/dev/null 2>&1 || die "o executavel ufw nao foi restaurado"
grep -q -- '-A ufw-user-input -p tcp --dport 22 -s 192.168.100.0/24 -j ACCEPT' \
  /etc/ufw/user.rules || die "a regra SSH LAN nao foi encontrada; UFW nao sera recarregado"

log "Instalando o aplicador idempotente de DOCKER-USER"
install -m 755 /dev/stdin "$HELPER_PATH" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly IPTABLES="/usr/sbin/iptables"
readonly PROMETHEUS_IP="192.168.100.3/32"
readonly CADVISOR_PUBLISHED_PORT=8081
readonly -a DIRECT_PORTS=(8001 9100)

for _attempt in $(seq 1 30); do
  if "$IPTABLES" -nL DOCKER-USER >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
"$IPTABLES" -nL DOCKER-USER >/dev/null 2>&1 \
  || { echo "DOCKER-USER nao foi criada pelo Docker" >&2; exit 1; }

for port in "${DIRECT_PORTS[@]}"; do
  "$IPTABLES" -C DOCKER-USER -s "$PROMETHEUS_IP" -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
    || "$IPTABLES" -I DOCKER-USER 1 -s "$PROMETHEUS_IP" -p tcp --dport "$port" -j ACCEPT
  "$IPTABLES" -C DOCKER-USER -p tcp --dport "$port" -j DROP 2>/dev/null \
    || "$IPTABLES" -A DOCKER-USER -p tcp --dport "$port" -j DROP
done

# O Docker traduz a porta publicada 8081 para 8080 antes de DOCKER-USER.
# Remova a forma antiga e use a porta original registrada no conntrack.
while "$IPTABLES" -C DOCKER-USER -s "$PROMETHEUS_IP" -p tcp --dport "$CADVISOR_PUBLISHED_PORT" -j ACCEPT 2>/dev/null; do
  "$IPTABLES" -D DOCKER-USER -s "$PROMETHEUS_IP" -p tcp --dport "$CADVISOR_PUBLISHED_PORT" -j ACCEPT
done
while "$IPTABLES" -C DOCKER-USER -p tcp --dport "$CADVISOR_PUBLISHED_PORT" -j DROP 2>/dev/null; do
  "$IPTABLES" -D DOCKER-USER -p tcp --dport "$CADVISOR_PUBLISHED_PORT" -j DROP
done
# Remova tambem a primeira versao conntrack, que nao limitava a direcao e podia
# descartar os pacotes de resposta do container.
while "$IPTABLES" -C DOCKER-USER -s "$PROMETHEUS_IP" -p tcp -m conntrack \
  --ctorigdstport "$CADVISOR_PUBLISHED_PORT" -j ACCEPT 2>/dev/null; do
  "$IPTABLES" -D DOCKER-USER -s "$PROMETHEUS_IP" -p tcp -m conntrack \
    --ctorigdstport "$CADVISOR_PUBLISHED_PORT" -j ACCEPT
done
while "$IPTABLES" -C DOCKER-USER -p tcp -m conntrack \
  --ctorigdstport "$CADVISOR_PUBLISHED_PORT" -j DROP 2>/dev/null; do
  "$IPTABLES" -D DOCKER-USER -p tcp -m conntrack \
    --ctorigdstport "$CADVISOR_PUBLISHED_PORT" -j DROP
done
"$IPTABLES" -C DOCKER-USER -s "$PROMETHEUS_IP" -p tcp -m conntrack \
  --ctdir ORIGINAL --ctorigdstport "$CADVISOR_PUBLISHED_PORT" -j ACCEPT 2>/dev/null \
  || "$IPTABLES" -I DOCKER-USER 1 -s "$PROMETHEUS_IP" -p tcp -m conntrack \
    --ctdir ORIGINAL --ctorigdstport "$CADVISOR_PUBLISHED_PORT" -j ACCEPT
"$IPTABLES" -C DOCKER-USER -p tcp -m conntrack \
  --ctdir ORIGINAL --ctorigdstport "$CADVISOR_PUBLISHED_PORT" -j DROP 2>/dev/null \
  || "$IPTABLES" -A DOCKER-USER -p tcp -m conntrack \
    --ctdir ORIGINAL --ctorigdstport "$CADVISOR_PUBLISHED_PORT" -j DROP
HELPER

install -m 644 /dev/stdin "$UNIT_PATH" <<'UNIT'
[Unit]
Description=HomeLab DOCKER-USER rules for Prometheus exporters
Requires=docker.service
After=docker.service network-online.target
PartOf=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-docker-user-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

log "Reativando UFW e aplicando DOCKER-USER"
systemctl daemon-reload
systemd-analyze verify "$UNIT_PATH"
systemctl enable ufw.service >/dev/null
ufw --force enable
systemctl enable --now homelab-docker-user-firewall.service >/dev/null
systemctl restart homelab-docker-user-firewall.service

log "Validando o estado final"
ufw status | grep -q '^Status: active' || die "UFW nao ficou ativo"
systemctl is-enabled homelab-docker-user-firewall.service | grep -qx enabled
systemctl is-active homelab-docker-user-firewall.service | grep -qx active
for port in 8001 9100; do
  iptables -C DOCKER-USER -s 192.168.100.3/32 -p tcp --dport "$port" -j ACCEPT
  iptables -C DOCKER-USER -p tcp --dport "$port" -j DROP
done
iptables -C DOCKER-USER -s 192.168.100.3/32 -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 8081 -j ACCEPT
iptables -C DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 8081 -j DROP

iptables-save > "$backup_dir/iptables.after.rules"
ip6tables-save > "$backup_dir/ip6tables.after.rules"
iptables -S DOCKER-USER > "$backup_dir/docker-user.after.txt"
ufw status numbered > "$backup_dir/ufw.after.txt"
chmod -R go-rwx "$backup_dir"

log "Resultado"
ufw status | head -1
iptables -S DOCKER-USER
systemctl is-enabled homelab-docker-user-firewall.service
systemctl is-active homelab-docker-user-firewall.service
printf 'Backup: %s\n' "$backup_dir"
printf 'Persistencia DOCKER-USER configurada por systemd.\n'
