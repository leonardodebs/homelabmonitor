# Changelog

Todas as mudanças notáveis deste projeto serão documentadas aqui.

## [Não publicado]

### Adicionado

- Alertas por e-mail de CPU, memória e disco acima de 90% para o Lenovo.

### Alterado

- Alertas de recursos do Dell padronizados em 90% por 10 minutos.
- Imagens dos exporters fixadas por digest SHA-256.
- Documentação atualizada após a retirada definitiva do Beszel.
- Restic do Dell atualizado de `0.16.4` para `0.19.1`.

### Segurança

- Padrões adicionais de credenciais e arquivos `.env` adicionados ao
  `.gitignore`.
- Porta `8090/tcp` removida do UFW após a aposentadoria do Beszel.

## [1.0.0] - 2026-08-24

### Adicionado

- Monitoramento do Dell com Node Exporter e cAdvisor.
- Monitoramento dos backups com Restic Exporter.
- Dashboards Grafana para Dell, Lenovo e Restic.
- Alertas Prometheus enviados por e-mail através do Alertmanager.
- Persistência idempotente das regras `DOCKER-USER` por systemd.
- Validação automatizada de Compose, dashboards, regras e Alertmanager.
