# Установка Zabbix Agent2 + windows_exporter на Windows 10/11 (офисные машины)
# Запуск в PowerShell ОТ АДМИНИСТРАТОРА:
#   .\install-office-agent.ps1 -ZabbixServer "192.168.1.10"
param(
    [Parameter(Mandatory=$true)]
    [string]$ZabbixServer,
    [string]$Hostname = $env:COMPUTERNAME,
    [string]$ZabbixVersion = "7.0.9"
)

$ErrorActionPreference = "Stop"
Write-Host "=== Установка Zabbix Agent2 (Windows) ===" -ForegroundColor Green
Write-Host "Сервер: $ZabbixServer | Хост: $Hostname"

# --- Zabbix Agent2 (MSI с официального CDN) ---
$msiUrl = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/$ZabbixVersion/zabbix_agent2-$ZabbixVersion-windows-amd64-openssl.msi"
$msiPath = "$env:TEMP\zabbix_agent2.msi"
Write-Host "Скачивание: $msiUrl"
Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

Write-Host "Установка MSI..."
$p = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn SERVER=$ZabbixServer SERVERACTIVE=$ZabbixServer HOSTNAME=$Hostname" -Wait -PassThru
if ($p.ExitCode -ne 0) { Write-Error "MSI завершился с кодом $($p.ExitCode)" }

# Открыть порт 10050 в брандмауэре
New-NetFirewallRule -DisplayName "Zabbix Agent" -Direction Inbound -Protocol TCP -LocalPort 10050 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "windows_exporter" -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow -ErrorAction SilentlyContinue | Out-Null

# --- windows_exporter ---
Write-Host "=== Установка windows_exporter ===" -ForegroundColor Green
$expUrl = "https://github.com/prometheus-community/windows_exporter/releases/latest/download/windows_exporter-latest-amd64.msi"
$expPath = "$env:TEMP\windows_exporter.msi"
try {
    Invoke-WebRequest -Uri $expUrl -OutFile $expPath -UseBasicParsing
    $p2 = Start-Process msiexec.exe -ArgumentList "/i `"$expPath`" /qn" -Wait -PassThru
    Write-Host "windows_exporter установлен (код $($p2.ExitCode))"
} catch {
    Write-Warning "windows_exporter не скачался (прокси/блокировка?). Zabbix-агент работает и без него."
}

Write-Host ""
Write-Host "=== ГОТОВО ===" -ForegroundColor Green
Write-Host "Хост $Hostname появится в Zabbix/Grafana автоматически (сканер офиса, до 10 мин)."
Write-Host "Проверка агента: Get-Service 'Zabbix Agent 2'"
