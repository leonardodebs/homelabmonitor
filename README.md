# Monitoramento do Dell e dos backups Restic no HomeLab

Camada de observabilidade do servidor Dell e do repositório Restic do HomeLab.
Node Exporter, cAdvisor e Restic Exporter rodam no Dell; Prometheus, Alertmanager
e Grafana rodam no Lenovo. O dashboard `Dell Overview` cobre sistema, disco,
sensores e containers e substituiu definitivamente o Beszel em 24/08/2026.
Os backups continuam sendo executados exclusivamente pelos serviços e timers
systemd existentes.

## Ambiente-alvo

| Função | Host | Endereço |
|---|---|---|
| Servidor, repositório e exporters | Dell `homelab` | `192.168.100.2` |
| Prometheus, Alertmanager e Grafana | Lenovo `vmlab` | `192.168.100.3` |

O repositório fica em `/srv/backup/restic` e o exporter publica métricas em
`192.168.100.2:8001`. O Node Exporter publica as métricas do host em
`192.168.100.2:9100` e o cAdvisor publica métricas Docker em
`192.168.100.2:8081`. Os dashboards usam a fonte de dados Grafana com UID
`prometheus`.

## Arquitetura

```text
Dell 192.168.100.2                         Lenovo 192.168.100.3
+--------------------------------+         +---------------------------+
| node-exporter :9100 <------------------- | Prometheus                |
| cAdvisor :8081 <------------------------ |   job: cadvisor-dell      |
| /srv/backup/restic             | scrape  |   job: node-dell          |
|           |                    |         |   job: restic             |
| restic-exporter :8001 <----------------- |   regras de alerta         |
|           ^                    |         |           v               |
| systemd executa os backups     |         | Alertmanager -> Gmail     |
|                                |         | Grafana                   |
+--------------------------------+         +---------------------------+
```

## Estrutura do projeto

```text
.
├── docker-compose.restic-exporter.yml
├── docker-compose.node-exporter-dell.yml
├── alertmanager/
│   ├── alertmanager.yml
│   └── templates/
│       └── email.tmpl
├── grafana/
│   ├── dell-overview.json
│   ├── homelab-overview.json
│   └── restic-dashboard.json
├── prometheus/
│   ├── dell-node-alerts.yml
│   ├── dell-cadvisor-scrape.yml
│   ├── dell-node-scrape.yml
│   ├── restic-alerts.yml
│   └── restic-scrape.yml
├── scripts/
│   ├── persist-docker-user.sh
│   └── validate.ps1
├── docs/
│   └── REVISAO-2026-08-24.md
├── CHANGELOG.md
└── README.md
```

O relatório da revisão integral está em
[`docs/REVISAO-2026-08-24.md`](docs/REVISAO-2026-08-24.md).

## Segurança aplicada

- Imagens fixadas por digest SHA-256, preservando exatamente as versões
  validadas do Restic Exporter, Node Exporter e cAdvisor.
- Repositório e arquivo de senha montados somente leitura.
- Filesystem do Node Exporter e Restic Exporter somente leitura.
- Todas as capabilities Linux do Node Exporter e Restic Exporter removidas.
- `no-new-privileges` habilitado.
- Cache isolado em volume Docker.
- Rotação dos logs do container configurada.
- Healthcheck HTTP executado a cada minuto.
- Portas publicadas apenas no endereço LAN do Dell.
- Senha SMTP fora do repositório, em arquivo de modo `600` no Lenovo.
- Alertmanager sem porta publicada no host e com TLS obrigatório no SMTP.

O cAdvisor precisa observar cgroups, `/sys`, `/var/lib/docker` e dispositivos do
host. Por isso ele roda privilegiado, como o cAdvisor já existente no Lenovo.
Seus mounts são somente leitura e a porta `8081` deve aceitar apenas o
Prometheus em `192.168.100.3`.

No Lenovo, as imagens da stack também estão fixadas nas versões validadas:

| Serviço | Imagem |
|---|---|
| Grafana | `grafana/grafana:13.1.3` |
| Prometheus | `prom/prometheus:v3.13.2` |
| Alertmanager | `prom/alertmanager:v0.33.1` |
| Node Exporter | `prom/node-exporter:v1.12.1` |
| cAdvisor | `gcr.io/cadvisor/cadvisor:v0.55.1` |
| PostgreSQL Exporter | `quay.io/prometheuscommunity/postgres-exporter:v0.20.1` |
| InfluxDB | `influxdb:1.8.10` |

Grafana, Prometheus e InfluxDB publicam suas portas apenas no endereço
`192.168.100.3`. O arquivo `.env` da stack deve permanecer com modo `600`.

O exporter atual chama Restic com `--no-lock`; por isso não precisa escrever no
repositório. Ele não executa `backup`, `forget`, `prune` ou `unlock`.

## 1. Validar o pacote

No Windows, a partir da raiz do projeto:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate.ps1
```

Se o Docker Engine ou o `promtool` não estiver disponível, é possível validar
somente a estrutura, o Compose e o dashboard:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -SkipPromtool
```

## 2. Instalar Node Exporter e cAdvisor no Dell

Envie, valide e inicie o serviço:

```powershell
scp .\docker-compose.node-exporter-dell.yml leonardo@192.168.100.2:/home/leonardo/homelab-infrastructure-server/compose/
```

```bash
cd /home/leonardo/homelab-infrastructure-server/compose
docker compose -f docker-compose.node-exporter-dell.yml config --quiet
docker compose -f docker-compose.node-exporter-dell.yml pull
docker compose -f docker-compose.node-exporter-dell.yml up -d
docker compose -f docker-compose.node-exporter-dell.yml ps
curl -fsS http://192.168.100.2:9100/metrics | head
curl -fsS http://192.168.100.2:8081/metrics | head
```

O Node Exporter coleta CPU, memória, load, filesystem, rede, I/O e temperaturas.
O cAdvisor coleta CPU, memória e rede por container Docker. A porta `8081` foi
usada porque `8080` pertence ao serviço `homelab-web`.

## 3. Instalar o Restic Exporter no Dell

Envie o Compose:

```powershell
scp .\docker-compose.restic-exporter.yml leonardo@192.168.100.2:/home/leonardo/homelab-infrastructure-server/compose/
```

Valide e aplique no Dell:

```bash
cd /home/leonardo/homelab-infrastructure-server/compose
docker compose -f docker-compose.restic-exporter.yml config --quiet
docker compose -f docker-compose.restic-exporter.yml pull
docker compose -f docker-compose.restic-exporter.yml up -d
docker compose -f docker-compose.restic-exporter.yml ps
```

Confirme as métricas usando o endereço no qual a porta foi publicada:

```bash
curl -fsS http://192.168.100.2:8001/metrics \
  | grep -E '^restic_(check_success|snapshots_total|backup_timestamp|size_total)'
```

Verifique também o endurecimento do container:

```bash
docker inspect restic-exporter \
  --format '{{range .Mounts}}{{.Destination}} RW={{.RW}}{{println}}{{end}}rootfs_readonly={{.HostConfig.ReadonlyRootfs}}'
```

## 4. Restringir o acesso no firewall do Dell

Permita a porta somente a partir do Lenovo:

```bash
sudo ufw allow from 192.168.100.3 to any port 8001 proto tcp comment 'restic-exporter para Prometheus'
sudo ufw allow from 192.168.100.3 to any port 9100 proto tcp comment 'node-exporter para Prometheus'
sudo ufw allow from 192.168.100.3 to any port 8081 proto tcp comment 'cadvisor para Prometheus'
sudo ufw status numbered
```

Portas publicadas pelo Docker podem contornar a cadeia `INPUT` usada pelo UFW.
Quando o Docker estiver usando o backend iptables, aplique também a restrição na
cadeia `DOCKER-USER`:

```bash
sudo iptables -C DOCKER-USER -s 192.168.100.3/32 -p tcp --dport 8001 -j ACCEPT 2>/dev/null \
  || sudo iptables -I DOCKER-USER 1 -s 192.168.100.3/32 -p tcp --dport 8001 -j ACCEPT

sudo iptables -C DOCKER-USER -p tcp --dport 8001 -j DROP 2>/dev/null \
  || sudo iptables -A DOCKER-USER -p tcp --dport 8001 -j DROP

sudo iptables -C DOCKER-USER -s 192.168.100.3/32 -p tcp --dport 9100 -j ACCEPT 2>/dev/null \
  || sudo iptables -I DOCKER-USER 1 -s 192.168.100.3/32 -p tcp --dport 9100 -j ACCEPT

sudo iptables -C DOCKER-USER -p tcp --dport 9100 -j DROP 2>/dev/null \
  || sudo iptables -A DOCKER-USER -p tcp --dport 9100 -j DROP

sudo iptables -C DOCKER-USER -s 192.168.100.3/32 -p tcp --dport 8081 -j ACCEPT 2>/dev/null \
  || sudo iptables -I DOCKER-USER 1 -s 192.168.100.3/32 -p tcp --dport 8081 -j ACCEPT

sudo iptables -C DOCKER-USER -p tcp --dport 8081 -j DROP 2>/dev/null \
  || sudo iptables -A DOCKER-USER -p tcp --dport 8081 -j DROP

sudo iptables -S DOCKER-USER
```

No Ubuntu 24.04, `iptables-persistent`/`netfilter-persistent` conflitam com o
UFW. Persista somente a cadeia `DOCKER-USER` usando o serviço systemd instalado
pelo script do projeto:

```bash
sudo bash scripts/persist-docker-user.sh
systemctl status homelab-docker-user-firewall.service
sudo iptables -S DOCKER-USER
```

A porta publicada `8081` é traduzida para `8080` no container. Sua regra usa
`conntrack --ctorigdstport 8081 --ctdir ORIGINAL`, em vez de `--dport 8081`.

## 5. Configurar o Prometheus no Lenovo

Copie as regras para a stack de monitoramento:

```powershell
scp .\prometheus\restic-alerts.yml .\prometheus\dell-node-alerts.yml leonardo@192.168.100.3:/home/leonardo/homelab-automation-server/docker/monitoring/prometheus/
```

O `prometheus.yml` do Lenovo deve conter:

```yaml
rule_files:
  - /etc/prometheus/restic-alerts.yml
  - /etc/prometheus/dell-node-alerts.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

scrape_configs:
  - job_name: restic
    scrape_interval: 60s
    scrape_timeout: 30s
    static_configs:
      - targets:
          - "192.168.100.2:8001"
        labels:
          instance: homelab-dell
          site: homelab

  - job_name: node-dell
    scrape_interval: 15s
    scrape_timeout: 10s
    static_configs:
      - targets:
          - "192.168.100.2:9100"
        labels:
          instance: homelab-dell
          server: dell
          site: homelab

  - job_name: cadvisor-dell
    scrape_interval: 15s
    scrape_timeout: 10s
    static_configs:
      - targets:
          - "192.168.100.2:8081"
        labels:
          instance: homelab-dell
          server: dell
          site: homelab
```

O serviço `prometheus` do Compose do Lenovo também deve montar o arquivo:

```yaml
volumes:
  - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
  - ./prometheus/restic-alerts.yml:/etc/prometheus/restic-alerts.yml:ro
  - ./prometheus/dell-node-alerts.yml:/etc/prometheus/dell-node-alerts.yml:ro
  - prometheus_data:/prometheus
```

Valide antes de recriar o container:

```bash
cd /home/leonardo/homelab-automation-server/docker/monitoring
docker run --rm --entrypoint promtool \
  -v "$PWD/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$PWD/prometheus/restic-alerts.yml:/etc/prometheus/restic-alerts.yml:ro" \
  -v "$PWD/prometheus/dell-node-alerts.yml:/etc/prometheus/dell-node-alerts.yml:ro" \
  prom/prometheus:v3.13.2 check config /etc/prometheus/prometheus.yml
docker compose config --quiet
docker compose up -d prometheus
```

Confirme o target e uma métrica:

```bash
curl -fsS http://192.168.100.3:9090/api/v1/targets | grep -o '192.168.100.2:8001[^}]*'
curl -fsSG --data-urlencode 'query=restic_check_success' \
  http://192.168.100.3:9090/api/v1/query
curl -fsSG --data-urlencode 'query=up{job="node-dell"}' \
  http://192.168.100.3:9090/api/v1/query
curl -fsSG --data-urlencode 'query=up{job="cadvisor-dell"}' \
  http://192.168.100.3:9090/api/v1/query
```

## 6. Provisionar os dashboards no Grafana

O arquivo já referencia diretamente o datasource UID `prometheus`. Envie-o para
o diretório monitorado pelo provisioner:

```powershell
scp .\grafana\restic-dashboard.json .\grafana\dell-overview.json leonardo@192.168.100.3:/home/leonardo/homelab-automation-server/docker/monitoring/grafana/provisioning/dashboards/
```

O Grafana verifica esse diretório a cada 30 segundos. Para forçar uma nova
leitura sem manipular a API:

```bash
cd /home/leonardo/homelab-automation-server/docker/monitoring
docker compose restart grafana
```

Dashboard:

```text
http://192.168.100.3:3000/d/dell-overview/dell-overview
http://192.168.100.3:3000/d/homelab-overview/homelab-overview
http://192.168.100.3:3000/d/restic-homelab/restic-homelab
```

O dashboard `Dell Overview` foi separado do `Homelab Overview`: consultas do
host usam `job="node-dell"` e consultas Docker usam `job="cadvisor-dell"`,
impedindo que métricas dos dois servidores sejam somadas. Ele possui filtros de
interface, disco e container e as seções `Core`, `Disco` e `Containers Docker`.
O `Homelab Overview` usa exclusivamente `job="node"` e `job="cadvisor"` para
continuar representando somente o Lenovo.
O `Restic HomeLab` usa o período padrão de 15 dias, alinhado à retenção atual do
Prometheus, e todas as consultas usam `job="restic"`.
Após uma implantação nova, aguarde o primeiro scrape e atualize a página. Os
gráficos históricos começam a ser preenchidos a partir desse momento.

## Alertas incluídos

| Alerta | Condição | Severidade |
|---|---|---|
| `ResticExporterDown` | target fora do ar por 5 minutos | critical |
| `ResticBackupAtrasado` | série de backup entre 26 e 48 horas | warning |
| `ResticBackupCritico` | série de backup acima de 48 horas | critical |
| `ResticCheckFalhou` | check de integridade com falha | critical |
| `ResticSemSnapshots` | repositório sem snapshots | critical |
| `ResticExporterSemMetricas` | endpoint ativo sem métricas de backup | critical |
| `ResticLockPreso` | lock presente por mais de 2 horas | warning |
| `ResticRepoCrescendoRapido` | crescimento superior a 5 GiB em 7 dias | info |
| `NodeDellExporterDown` | Node Exporter inacessível por 5 minutos | critical |
| `NodeDellCpuAlta` | CPU acima de 90% por 15 minutos | warning |
| `NodeDellMemoriaAlta` | memória acima de 90% por 15 minutos | warning |
| `NodeDellDiscoRaizAlerta` | disco raiz entre 85% e 95% por 30 minutos | warning |
| `NodeDellDiscoRaizCritico` | disco raiz acima de 95% por 15 minutos | critical |
| `NodeDellFilesystemSomenteLeitura` | filesystem raiz somente leitura por 5 minutos | critical |
| `NodeDellTemperaturaAlta` | sensor acima de 75 °C por 5 minutos | warning |
| `CadvisorDellDown` | cAdvisor inacessível por 5 minutos | critical |

As regras são avaliadas pelo Prometheus e enviadas ao Alertmanager, que agrupa e
deduplica os eventos. O receptor envia alertas ativos e resolvidos para
`leonardodebs@gmail.com` pelo SMTP do Gmail.

## 7. Configurar notificações por e-mail

Ative a verificação em duas etapas na conta Google e crie uma senha de app com o
nome `HomeLab Alertmanager` em
[Senhas de app da Conta Google](https://myaccount.google.com/apppasswords).
Não use nem compartilhe a senha normal da conta.

No Lenovo, como `leonardo`, grave a senha de app diretamente no arquivo seguro.
O comando não mostra a senha na tela nem a registra no histórico do shell:

```bash
install -d -m 700 /home/leonardo/.config/homelab-alerts
install -d -m 700 /home/leonardo/.local/share/homelab-alertmanager
read -rsp 'Senha de app do Google: ' GMAIL_APP_PASSWORD; echo
printf '%s' "${GMAIL_APP_PASSWORD// /}" > /home/leonardo/.config/homelab-alerts/gmail-app-password
unset GMAIL_APP_PASSWORD
chmod 600 /home/leonardo/.config/homelab-alerts/gmail-app-password
test -s /home/leonardo/.config/homelab-alerts/gmail-app-password
stat -c '%a %U:%G %n' /home/leonardo/.config/homelab-alerts/gmail-app-password
```

O Compose monta esse arquivo como `/run/secrets/gmail_app_password`. O YAML usa
`smtp.gmail.com:587`, STARTTLS obrigatório e não contém credenciais. A porta do
Alertmanager não é publicada; apenas o Prometheus acessa `alertmanager:9093` na
rede Docker `monitoring`.

O corpo do e-mail não expõe um link para a interface interna do Alertmanager.
Ele abre o dashboard correspondente no Grafana: Restic para `service=restic`,
Dell para `server=dell` e Homelab Overview como destino padrão. Esses links
funcionam quando o dispositivo está conectado à rede local do HomeLab.

Valide antes de iniciar:

```bash
cd /home/leonardo/homelab-automation-server/docker/monitoring
docker run --rm --user 1000:1000 --entrypoint amtool \
  -v "$PWD/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
  prom/alertmanager:v0.33.1 check-config /etc/alertmanager/alertmanager.yml
docker run --rm --entrypoint promtool \
  -v "$PWD/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$PWD/prometheus/restic-alerts.yml:/etc/prometheus/restic-alerts.yml:ro" \
  -v "$PWD/prometheus/dell-node-alerts.yml:/etc/prometheus/dell-node-alerts.yml:ro" \
  prom/prometheus:v3.13.2 check config /etc/prometheus/prometheus.yml
docker compose config --quiet
docker compose up -d alertmanager prometheus
```

## Solução de problemas

### Dashboard mostra `No data`

1. Aguarde pelo menos 60 segundos após recriar o Prometheus.
2. Confirme que os targets `restic`, `node-dell` e `cadvisor-dell` estão `UP`.
3. Confirme que o datasource Grafana possui UID `prometheus`.
4. Teste as métricas diretamente no Prometheus.

```bash
curl -fsSG --data-urlencode 'query=up{job="restic"}' \
  http://192.168.100.3:9090/api/v1/query
curl -fsSG --data-urlencode 'query=up{job="node-dell"}' \
  http://192.168.100.3:9090/api/v1/query
curl -fsSG --data-urlencode 'query=up{job="cadvisor-dell"}' \
  http://192.168.100.3:9090/api/v1/query
```

### Exporter não inicia

```bash
docker logs --tail 100 restic-exporter
docker inspect restic-exporter --format '{{json .State.Health}}'
docker logs --tail 100 node-exporter-dell
docker inspect node-exporter-dell --format '{{json .State.Health}}'
docker logs --tail 100 cadvisor-dell
docker inspect cadvisor-dell --format '{{json .State.Health}}'
test -d /srv/backup/restic
sudo test -r /etc/homelab-backup/restic-password
```

### Verificações operacionais

```bash
systemctl status homelab-backup.timer homelab-backup-maintenance.timer
docker ps --filter name=restic-exporter
docker ps --filter name=node-exporter-dell
docker ps --filter name=cadvisor-dell
curl -fsS http://192.168.100.2:8001/metrics | head
curl -fsS http://192.168.100.2:9100/metrics | head
curl -fsS http://192.168.100.2:8081/metrics | head
```

## Migração concluída do Beszel para o Grafana

O Beszel Hub e o Agent foram removidos depois da validação do dashboard e dos
alertas por e-mail. Antes da exclusão dos volumes, foi criado um backup com
checksums em:

```text
/home/leonardo/backups/beszel-retirement/20260824-145811
```

O Dell utiliza Restic `0.19.1`; o binário anterior `0.16.4` foi preservado em
`/var/backups/homelab-restic` para rollback. O restore test mensal, a manutenção
semanal e o backup diário permanecem agendados por systemd.

## Estado das pendências

Não há pendência operacional conhecida em 24/08/2026. Alterações futuras de
versão devem passar pelo script de validação, backup e janela de manutenção.

## Rollback

No Dell:

```bash
cd /home/leonardo/homelab-infrastructure-server/compose
docker compose -f docker-compose.node-exporter-dell.yml down
docker compose -f docker-compose.restic-exporter.yml down
sudo ufw delete allow from 192.168.100.3 to any port 8081 proto tcp
sudo ufw delete allow from 192.168.100.3 to any port 9100 proto tcp
sudo ufw delete allow from 192.168.100.3 to any port 8001 proto tcp
sudo iptables -D DOCKER-USER -s 192.168.100.3/32 -p tcp --dport 9100 -j ACCEPT
sudo iptables -D DOCKER-USER -p tcp --dport 9100 -j DROP
sudo iptables -D DOCKER-USER -s 192.168.100.3/32 -p tcp --dport 8081 -j ACCEPT
sudo iptables -D DOCKER-USER -p tcp --dport 8081 -j DROP
sudo iptables -D DOCKER-USER -s 192.168.100.3/32 -p tcp --dport 8001 -j ACCEPT
sudo iptables -D DOCKER-USER -p tcp --dport 8001 -j DROP
```

O volume `homelab_restic_exporter_cache` contém apenas cache. Remova-o somente se
quiser limpar completamente a camada de monitoramento:

```bash
docker volume rm homelab_restic_exporter_cache
```

No Lenovo, remova os jobs `restic` e `node-dell`, as referências em
`rule_files`, os mounts das regras e os dashboards provisionados. Valide o
Compose e recrie Prometheus/Grafana. As cópias imediatamente anteriores à
ampliação para paridade com o Beszel foram salvas em:

```text
Dell:   /home/leonardo/.backups/grafana-beszel-parity/20260822-150000
Lenovo: /home/leonardo/.backups/grafana-beszel-parity/20260822-150002
```
