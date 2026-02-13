param(
  [ValidateSet("install", "uninstall", "restart", "upgrade", "status", "logs")]
  [string]$Command = "install",
  [string]$RepoUrl = "https://github.com/openclaw/openclaw.git",
  [string]$Branch = "main",
  [string]$InstallDir = "$HOME\openclaw-kasmvnc",
  [string]$GatewayToken = "",
  [string]$KasmPassword = "",
  [string]$HttpsPort = "8443",
  [string]$GatewayPort = "18789",
  [int]$Tail = 200,
  [switch]$Purge
)

$ErrorActionPreference = "Stop"

function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing command: $Name"
  }
}

function New-RandomHex {
  param([int]$Bytes = 32)
  $buf = New-Object byte[] $Bytes
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
  return ($buf | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Upsert-EnvLine {
  param(
    [string]$FilePath,
    [string]$Key,
    [string]$Value
  )
  $line = "$Key=$Value"
  if (-not (Test-Path $FilePath)) {
    Set-Content -Path $FilePath -Value $line -Encoding UTF8
    return
  }
  $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
  if ($content -match "(?m)^$([regex]::Escape($Key))=") {
    $updated = [regex]::Replace(
      $content,
      "(?m)^$([regex]::Escape($Key))=.*$",
      [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $line }
    )
    Set-Content -Path $FilePath -Value $updated -Encoding UTF8
  } else {
    Add-Content -Path $FilePath -Value "`r`n$line" -Encoding UTF8
  }
}

function Get-RepoDir {
  return (Join-Path $InstallDir "openclaw")
}

function Invoke-Compose {
  param([Parameter(Mandatory = $true)][string[]]$ComposeArgs)
  & docker compose -f docker-compose.yml -f docker-compose.kasmvnc.yml @ComposeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "docker compose failed: $($ComposeArgs -join ' ')"
  }
}

function Assert-GatewayRunning {
  $cid = (& docker compose -f docker-compose.yml -f docker-compose.kasmvnc.yml ps -q openclaw-gateway | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($cid)) {
    throw "openclaw-gateway container not found after compose operation."
  }
  $running = (& docker inspect -f "{{.State.Running}}" $cid 2>$null)
  if ($LASTEXITCODE -ne 0 -or "$running".Trim() -ne "true") {
    throw "openclaw-gateway is not running (container: $cid)."
  }
}

function Require-Repo {
  $repoDir = Get-RepoDir
  if (-not (Test-Path $repoDir)) {
    throw "Repo not found: $repoDir"
  }
}

function Install-Command {
  Assert-Command -Name "git"
  Assert-Command -Name "docker"
  try {
    docker compose version | Out-Null
  } catch {
    throw "Missing Docker Compose v2 plugin: 'docker compose'"
  }

  if ([string]::IsNullOrWhiteSpace($GatewayToken)) {
    $GatewayToken = New-RandomHex -Bytes 32
  }
  if ([string]::IsNullOrWhiteSpace($KasmPassword)) {
    $KasmPassword = New-RandomHex -Bytes 16
  }

  if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
  }

  $repoDir = Get-RepoDir
  if (-not (Test-Path (Join-Path $repoDir ".git"))) {
    git clone --branch $Branch --depth 1 $RepoUrl $repoDir
  } else {
    Write-Host "Repo exists, pulling latest: $repoDir"
    Push-Location $repoDir
    try {
      git fetch origin $Branch
      git checkout $Branch
      git pull --rebase origin $Branch
    } finally {
      Pop-Location
    }
  }

  Push-Location $repoDir
  try {
    if (-not (Test-Path ".env")) {
      Copy-Item ".env.example" ".env"
    }

    if (-not (Test-Path ".openclaw")) {
      New-Item -ItemType Directory -Path ".openclaw" | Out-Null
    }
    if (-not (Test-Path ".openclaw\workspace")) {
      New-Item -ItemType Directory -Path ".openclaw\workspace" | Out-Null
    }

    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_CONFIG_DIR" -Value "./.openclaw"
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_WORKSPACE_DIR" -Value "./.openclaw/workspace"
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_GATEWAY_TOKEN" -Value $GatewayToken
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_GATEWAY_PORT" -Value $GatewayPort
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_KASMVNC_PASSWORD" -Value $KasmPassword
    Upsert-EnvLine -FilePath ".env" -Key "OPENCLAW_KASMVNC_HTTPS_PORT" -Value $HttpsPort
    Upsert-EnvLine -FilePath ".env" -Key "TZ" -Value "Asia/Shanghai"
    Upsert-EnvLine -FilePath ".env" -Key "LANG" -Value "zh_CN.UTF-8"
    Upsert-EnvLine -FilePath ".env" -Key "LANGUAGE" -Value "zh_CN:zh"
    Upsert-EnvLine -FilePath ".env" -Key "LC_ALL" -Value "zh_CN.UTF-8"

    Invoke-Compose -ComposeArgs @("up", "-d", "--build", "openclaw-gateway")
    Assert-GatewayRunning
  } finally {
    Pop-Location
  }

  Write-Host ""
  Write-Host "Install complete."
  Write-Host "Repo: $repoDir"
  Write-Host "WebChat: http://127.0.0.1:$GatewayPort/chat?session=main"
  Write-Host "Desktop: https://127.0.0.1:$HttpsPort"
  Write-Host "OPENCLAW_GATEWAY_TOKEN=$GatewayToken"
  Write-Host "OPENCLAW_KASMVNC_PASSWORD=$KasmPassword"
}

function Uninstall-Command {
  $repoDir = Get-RepoDir
  if (Test-Path $repoDir) {
    Push-Location $repoDir
    try {
      if (Get-Command docker -ErrorAction SilentlyContinue) {
        Invoke-Compose -ComposeArgs @("down")
      }
      Write-Host "Stopped services in: $repoDir"
    } finally {
      Pop-Location
    }
  } else {
    Write-Host "Repo directory not found: $repoDir"
  }

  if ($Purge) {
    if (Test-Path $InstallDir) {
      Remove-Item -Recurse -Force $InstallDir
      Write-Host "Removed install directory: $InstallDir"
    }
  } else {
    Write-Host "Uninstall completed without deleting files."
    Write-Host "Use -Purge to remove install directory."
  }
}

function Restart-Command {
  Require-Repo
  Push-Location (Get-RepoDir)
  try {
    Invoke-Compose -ComposeArgs @("restart", "openclaw-gateway")
    Assert-GatewayRunning
  } finally {
    Pop-Location
  }
}

function Upgrade-Command {
  Require-Repo
  Push-Location (Get-RepoDir)
  try {
    git fetch origin $Branch
    git checkout $Branch
    git pull --rebase origin $Branch
    Invoke-Compose -ComposeArgs @("up", "-d", "--build", "openclaw-gateway")
    Assert-GatewayRunning
  } finally {
    Pop-Location
  }
}

function Status-Command {
  Require-Repo
  Push-Location (Get-RepoDir)
  try {
    Invoke-Compose -ComposeArgs @("ps")
  } finally {
    Pop-Location
  }
}

function Logs-Command {
  Require-Repo
  Push-Location (Get-RepoDir)
  try {
    Invoke-Compose -ComposeArgs @("logs", "--tail=$Tail", "openclaw-gateway")
  } finally {
    Pop-Location
  }
}

switch ($Command) {
  "install" { Install-Command; break }
  "uninstall" { Uninstall-Command; break }
  "restart" { Restart-Command; break }
  "upgrade" { Upgrade-Command; break }
  "status" { Status-Command; break }
  "logs" { Logs-Command; break }
  default { throw "Unknown command: $Command" }
}
