# marathon-dns.ps1
# Меню-CLI для переключения DNS пресетов и отката.
# Сам запрашивает права администратора.

$PresetA = @("31.192.108.180","176.99.11.77")
$PresetB = @("80.78.247.254","176.99.11.77")
$StatePath = "$env:ProgramData\dns-cli-state.json"

function Ensure-Admin {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    Write-Host "Запрашиваю права администратора (UAC)..." -ForegroundColor Yellow
    $ps = (Get-Process -Id $PID).Path
    Start-Process -FilePath $ps -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`""
    ) -Verb RunAs | Out-Null
    exit
  }
}

function Flush-Dns {
  try { Clear-DnsClientCache } catch {}
  ipconfig /flushdns | Out-Null
}

function Get-ActiveIPv4Ifaces {
  Get-NetIPInterface -AddressFamily IPv4 |
    Where-Object { $_.ConnectionState -eq "Connected" -and $_.InterfaceAlias -notmatch "Loopback" } |
    Select-Object -ExpandProperty InterfaceAlias
}

function Save-State($ifaces) {
  $state = @()
  foreach ($iface in $ifaces) {
    $dnsClient = Get-DnsClient -InterfaceAlias $iface -ErrorAction SilentlyContinue
    $wasDhcp = $false
    if ($dnsClient) { $wasDhcp = [bool]$dnsClient.Dhcp }

    $cur = Get-DnsClientServerAddress -InterfaceAlias $iface -AddressFamily IPv4
    $state += [pscustomobject]@{
      InterfaceAlias  = $iface
      WasDhcp         = $wasDhcp
      ServerAddresses = $cur.ServerAddresses
    }
  }
  $state | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $StatePath
}

function Load-State {
  if (-not (Test-Path $StatePath)) { return $null }
  Get-Content $StatePath -Raw | ConvertFrom-Json
}

function Set-Dns($iface, $servers) {
  Set-DnsClientServerAddress -InterfaceAlias $iface -ServerAddresses $servers | Out-Null
}

function Reset-DnsToDhcp($iface) {
  Set-DnsClientServerAddress -InterfaceAlias $iface -ResetServerAddresses | Out-Null
}

function Ensure-State {
  $ifaces = Get-ActiveIPv4Ifaces
  if (-not $ifaces) { throw "Активных IPv4 интерфейсов не найдено." }
  if (-not (Test-Path $StatePath)) {
    Save-State $ifaces
    Write-Host "Сохранил 'как было' в: $StatePath" -ForegroundColor DarkGray
  }
  return $ifaces
}

function Apply-Preset($preset) {
  $ifaces = Ensure-State
  foreach ($iface in $ifaces) {
    Set-Dns $iface $preset
    Write-Host "[$iface] => DNS = $($preset -join ', ')" -ForegroundColor Green
  }
  Flush-Dns
  Write-Host "DNS-кэш очищен." -ForegroundColor DarkGray
}

function Swap-Current {
  $ifaces = Ensure-State

  foreach ($iface in $ifaces) {
    $cur = Get-DnsClientServerAddress -InterfaceAlias $iface -AddressFamily IPv4
    $srv = @($cur.ServerAddresses)
    if ($null -eq $srv -or $srv.Count -lt 2) {
      Write-Host "[$iface] Нечего swap'ать (нужно 2 DNS в ручном режиме)." -ForegroundColor Yellow
      continue
    }
    $swapped = @($srv[1], $srv[0]) + ($srv | Select-Object -Skip 2)
    Set-Dns $iface $swapped
    Write-Host "[$iface] => SWAP: $($swapped -join ', ')" -ForegroundColor Green
  }
  Flush-Dns
  Write-Host "DNS-кэш очищен." -ForegroundColor DarkGray
}

function Restore-OriginalDns {
  $state = Load-State

  if (-not $state) {
    Write-Host "Сохранённое состояние не найдено. Нечего восстанавливать." -ForegroundColor Yellow
    return
  }

  foreach ($entry in $state) {
    $iface = $entry.InterfaceAlias
    if ($entry.WasDhcp -eq $true) {
      Reset-DnsToDhcp $iface
      Write-Host "[$iface] => AUTO/DHCP (как было; может показывать DNS роутера)" -ForegroundColor Green
    } else {
      if ($null -eq $entry.ServerAddresses -or $entry.ServerAddresses.Count -eq 0) {
        Reset-DnsToDhcp $iface
        Write-Host "[$iface] => AUTO/DHCP (fallback)" -ForegroundColor Green
      } else {
        Set-Dns $iface @($entry.ServerAddresses)
        Write-Host "[$iface] => $(@($entry.ServerAddresses) -join ', ') (как было)" -ForegroundColor Green
      }
    }
  }

  Remove-Item $StatePath -ErrorAction SilentlyContinue
  Flush-Dns
  Write-Host "Исходные DNS восстановлены. State удалён." -ForegroundColor DarkGray
}

function Set-AutoDns {
  $ifaces = Get-ActiveIPv4Ifaces

  if (-not $ifaces) {
    Write-Host "Активных IPv4 интерфейсов не найдено." -ForegroundColor Yellow
    return
  }

  foreach ($iface in $ifaces) {
    Reset-DnsToDhcp $iface
    Write-Host "[$iface] => AUTO/DHCP" -ForegroundColor Green
  }

  Flush-Dns
  Write-Host "Автоматическое получение DNS включено." -ForegroundColor DarkGray
}

function Show-Status {
  $ifaces = Get-ActiveIPv4Ifaces
  if (-not $ifaces) { Write-Host "Активных IPv4 интерфейсов не найдено." -ForegroundColor Yellow; return }

  foreach ($iface in $ifaces) {
    $cur = Get-DnsClientServerAddress -InterfaceAlias $iface -AddressFamily IPv4
    $srv = $cur.ServerAddresses
    if ($null -eq $srv -or $srv.Count -eq 0) { $srv = @("AUTO/DHCP") }
    Write-Host "[$iface] DNS: $($srv -join ', ')"
  }

  Write-Host ""
  Write-Host "Пресеты:" -ForegroundColor DarkGray
  Write-Host " A) 31.192.108.180 / 176.99.11.77" -ForegroundColor DarkGray
  Write-Host " B) 80.78.247.254 / 176.99.11.77" -ForegroundColor DarkGray
  Write-Host " SWAP) 176.99.11.77 первым (если сейчас ручной режим с 2 DNS)" -ForegroundColor DarkGray

  if (Test-Path $StatePath) { Write-Host "State: есть ($StatePath)" -ForegroundColor DarkGray }
  else { Write-Host "State: нет" -ForegroundColor DarkGray }
}

function Pause { Write-Host ""; Read-Host "Enter для продолжения" | Out-Null }

# MAIN
Ensure-Admin

while ($true) {
  Clear-Host
  Write-Host "==============================="
  Write-Host " DNS CLI (Marathon fix presets)"
  Write-Host "==============================="
  Write-Host " 1) Включить Preset A: $($PresetA -join ', ')"
  Write-Host " 2) Включить Preset B: $($PresetB -join ', ')"
  Write-Host " 3) SWAP текущих DNS (поменять местами primary/secondary)"
  Write-Host " 4) Восстановить исходные DNS"
  Write-Host " 5) Включить автоматический DNS (DHCP)"
  Write-Host " 6) Статус"
  Write-Host " 0) Выход"
  Write-Host "-------------------------------"
  $c = Read-Host "Выбор"

  switch ($c) {
    "1" { Apply-Preset $PresetA; Pause }
    "2" { Apply-Preset $PresetB; Pause }
    "3" { Swap-Current; Pause }
    "4" { Restore-OriginalDns; Pause }
    "5" { Set-AutoDns; Pause }
    "6" { Show-Status; Pause }
    "0" { break }
    default { Write-Host "Жми 1/2/3/4/5/6/0" -ForegroundColor Yellow; Start-Sleep 1 }
  }
}
