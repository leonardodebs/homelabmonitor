[CmdletBinding()]
param(
    [switch]$SkipPromtool
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Name falhou com codigo $LASTEXITCODE."
    }
}

$requiredFiles = @(
    'docker-compose.restic-exporter.yml',
    'docker-compose.node-exporter-dell.yml',
    'prometheus/restic-alerts.yml',
    'prometheus/restic-scrape.yml',
    'prometheus/dell-node-alerts.yml',
    'prometheus/dell-node-scrape.yml',
    'prometheus/dell-cadvisor-scrape.yml',
    'alertmanager/alertmanager.yml',
    'alertmanager/templates/email.tmpl',
    'grafana/restic-dashboard.json',
    'grafana/dell-overview.json',
    'grafana/homelab-overview.json',
    'README.md'
)

foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Arquivo obrigatorio ausente: $file"
    }
}

$alertmanagerConfig = Get-Content -Raw -LiteralPath 'alertmanager/alertmanager.yml'
if ($alertmanagerConfig -notmatch 'smtp_auth_password_file:\s*/run/secrets/gmail_app_password') {
    throw 'O Alertmanager deve ler a senha SMTP de um arquivo separado.'
}
if ($alertmanagerConfig -match '(?m)^\s*smtp_auth_password:\s*\S+') {
    throw 'A senha SMTP nao pode ser gravada diretamente no YAML do Alertmanager.'
}
if ($alertmanagerConfig -notmatch 'smtp_require_tls:\s*true') {
    throw 'O SMTP do Alertmanager deve exigir TLS.'
}

$emailTemplate = Get-Content -Raw -LiteralPath 'alertmanager/templates/email.tmpl'
if ($alertmanagerConfig -notmatch 'html:\s*''\{\{ template "homelab\.email\.html" \. \}\}''') {
    throw 'O Alertmanager nao referencia o template de e-mail do HomeLab.'
}
if ($emailTemplate -match '\.ExternalURL|alertmanager:9093|192\.168\.100\.3:9093') {
    throw 'O template de e-mail ainda possui um link para o Alertmanager interno.'
}
foreach ($dashboardUid in @('restic-homelab', 'dell-overview', 'homelab-overview')) {
    if ($emailTemplate -notmatch [regex]::Escape("/d/$dashboardUid/")) {
        throw "O template de e-mail nao referencia o dashboard $dashboardUid."
    }
}

foreach ($composePath in @('docker-compose.restic-exporter.yml', 'docker-compose.node-exporter-dell.yml')) {
    Invoke-NativeChecked -Name "docker compose config ($composePath)" -Command {
        docker compose -f $composePath config --quiet
    }

    $compose = Get-Content -Raw -LiteralPath $composePath
    $imageRefs = [regex]::Matches($compose, '(?m)^\s*image:\s*(\S+)') |
        ForEach-Object { $_.Groups[1].Value }
    if ($imageRefs.Count -eq 0) {
        throw "O Compose $composePath nao declara imagens."
    }
    $unpinnedImages = @($imageRefs | Where-Object { $_ -notmatch '@sha256:[0-9a-f]{64}$' })
    if ($unpinnedImages.Count -gt 0) {
        throw "O Compose $composePath possui imagens sem digest SHA-256: $($unpinnedImages -join ', ')"
    }
    if ($compose -notmatch 'read_only:\s*true') {
        throw "O Compose $composePath nao usa filesystem somente leitura."
    }
    if ($compose -notmatch 'no-new-privileges:true') {
        throw "O Compose $composePath nao habilita no-new-privileges."
    }
}

$compose = Get-Content -Raw -LiteralPath 'docker-compose.restic-exporter.yml'
if ($compose -notmatch '/srv/backup/restic:/repo:ro') {
    throw 'O repositorio Restic nao esta montado como somente leitura.'
}

foreach ($dashboardPath in @('grafana/restic-dashboard.json', 'grafana/dell-overview.json', 'grafana/homelab-overview.json')) {
    $dashboardRaw = Get-Content -Raw -LiteralPath $dashboardPath
    $dashboard = $dashboardRaw | ConvertFrom-Json

    if ($dashboardRaw.Contains('${DS_PROMETHEUS}')) {
        throw "O dashboard $dashboardPath ainda contem o placeholder DS_PROMETHEUS."
    }

    $panelIds = @($dashboard.panels.id)
    $duplicateIds = @($panelIds | Group-Object | Where-Object Count -gt 1)
    if ($duplicateIds.Count -gt 0) {
        throw "IDs de painel duplicados em ${dashboardPath}: $($duplicateIds.Name -join ', ')"
    }

    $datasourceUids = @(
        $dashboard.panels.datasource.uid
        $dashboard.panels.targets.datasource.uid
    ) | Where-Object { $_ } | Sort-Object -Unique

    $allowedDatasourceUids = if ($dashboardPath -eq 'grafana/homelab-overview.json') {
        @('prometheus', 'influxdb')
    }
    else {
        @('prometheus')
    }
    $unexpectedDatasources = @($datasourceUids | Where-Object { $_ -notin $allowedDatasourceUids })
    if ($unexpectedDatasources.Count -gt 0) {
        throw "Datasources inesperados em ${dashboardPath}: $($unexpectedDatasources -join ', ')"
    }
}

$dellDashboardRaw = Get-Content -Raw -LiteralPath 'grafana/dell-overview.json'
if ($dellDashboardRaw -notmatch 'job=\\"node-dell\\"') {
    throw 'O dashboard Dell nao restringe as consultas ao job node-dell.'
}
if ($dellDashboardRaw -notmatch 'sensor!=\\"temp1\\"') {
    throw 'O dashboard Dell nao remove os sensores de temperatura duplicados.'
}

$homelabDashboardRaw = Get-Content -Raw -LiteralPath 'grafana/homelab-overview.json'
if ($homelabDashboardRaw -notmatch 'job=\\"node\\"' -or $homelabDashboardRaw -notmatch 'job=\\"cadvisor\\"') {
    throw 'O dashboard Homelab nao restringe as consultas aos jobs do Lenovo.'
}
if ($homelabDashboardRaw -notmatch 'job=\\"postgres\\"') {
    throw 'O dashboard Homelab nao restringe as consultas ao job postgres.'
}

$homelabDashboard = $homelabDashboardRaw | ConvertFrom-Json
if ($homelabDashboard.refresh -ne '15s') {
    throw 'O dashboard Homelab deve usar refresh de 15 segundos.'
}

$resticDashboardRaw = Get-Content -Raw -LiteralPath 'grafana/restic-dashboard.json'
$resticDashboard = $resticDashboardRaw | ConvertFrom-Json
if ($resticDashboard.time.from -ne 'now-15d') {
    throw 'O dashboard Restic deve respeitar a retencao de 15 dias do Prometheus.'
}

$unscopedResticQueries = @(
    $resticDashboard.panels.targets.expr |
        Where-Object { $_ -match 'restic_' -and $_ -notmatch 'job="restic"' }
)
if ($unscopedResticQueries.Count -gt 0) {
    throw 'O dashboard Restic possui consultas sem filtro job="restic".'
}

if (-not $SkipPromtool) {
    $promtool = Get-Command promtool -ErrorAction SilentlyContinue
    if ($promtool) {
        foreach ($rulesPath in @('prometheus/restic-alerts.yml', 'prometheus/dell-node-alerts.yml')) {
            Invoke-NativeChecked -Name "promtool check rules ($rulesPath)" -Command {
                promtool check rules $rulesPath
            }
        }
    }
    else {
        docker info *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Promtool nao esta instalado e o Docker Engine nao esta disponivel. Use -SkipPromtool apenas para validar estrutura e JSON.'
        }

        foreach ($relativeRulesPath in @('prometheus/restic-alerts.yml', 'prometheus/dell-node-alerts.yml')) {
            $rulesPath = (Resolve-Path -LiteralPath $relativeRulesPath).Path
            Invoke-NativeChecked -Name "promtool via Docker ($relativeRulesPath)" -Command {
                docker run --rm --entrypoint promtool `
                    --volume "${rulesPath}:/etc/prometheus/rules.yml:ro" `
                    prom/prometheus:v3.13.2 `
                    check rules /etc/prometheus/rules.yml
            }
        }
    }

    $amtool = Get-Command amtool -ErrorAction SilentlyContinue
    if ($amtool) {
        Invoke-NativeChecked -Name 'amtool check-config (alertmanager/alertmanager.yml)' -Command {
            amtool check-config alertmanager/alertmanager.yml
        }
    }
    else {
        docker info *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Amtool nao esta instalado e o Docker Engine nao esta disponivel. Use -SkipPromtool apenas para validar estrutura e JSON.'
        }

        $alertmanagerPath = (Resolve-Path -LiteralPath 'alertmanager/alertmanager.yml').Path
        Invoke-NativeChecked -Name 'amtool via Docker (alertmanager/alertmanager.yml)' -Command {
            docker run --rm --entrypoint amtool `
                --volume "${alertmanagerPath}:/etc/alertmanager/alertmanager.yml:ro" `
                prom/alertmanager:v0.33.1 `
                check-config /etc/alertmanager/alertmanager.yml
        }
    }
}

if ($SkipPromtool) {
    Write-Host 'Validacao estrutural concluida: Compose e dashboard estao consistentes; promtool e amtool foram ignorados.' -ForegroundColor Yellow
}
else {
    Write-Host 'Validacao concluida: Compose, dashboards, regras e Alertmanager estao consistentes.' -ForegroundColor Green
}
