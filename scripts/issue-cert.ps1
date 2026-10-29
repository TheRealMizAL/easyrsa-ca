<#
.SYNOPSIS
    Almost simple CA script for issuing client certificates

.PARAMETER CertType
    Certificate type

.PARAMETER Fqdn
    Subject full domain name

.PARAMETER Ip
    Subject IPv4 address
.EXAMPLE
    ./New-EasyRsaCert.ps1 server -Fqdn host.example.com -Ip 10.0.0.1

.EXAMPLE
    ./New-EasyRsaCert.ps1 server host.example.com 10.0.0.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$CertType,

    [Parameter(Mandatory, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$')]
    [string]$Fqdn,

    [Parameter(Mandatory, Position = 2)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$')]
    [string]$Ip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Docker {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$DockerArgs)
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($DockerArgs -join ' ') ended with code $LASTEXITCODE"
    }
}

$running = & docker inspect -f '{{.State.Running}}' easyrsa-ca 2>$null
if ($LASTEXITCODE -ne 0 -or "$running".Trim() -ne 'true') {
    throw 'Container easyrsa-ca is not active'
}

$san = "DNS:$Fqdn,DNS:$($Fqdn.Split('.')[0]),IP:$Ip"

Invoke-Docker exec easyrsa-ca easyrsa gen-req $Fqdn nopass
Invoke-Docker exec easyrsa-ca easyrsa "--san=$san" sign-req $CertType $Fqdn
Invoke-Docker cp "easyrsa-ca:/app/data/pki/issued/$Fqdn.crt" .
Invoke-Docker cp "easyrsa-ca:/app/data/pki/private/$Fqdn.key" .