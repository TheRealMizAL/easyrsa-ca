<#
.SYNOPSIS
    Almost simple CA script for issuing client certificates

.PARAMETER CertType
    Certificate type

.PARAMETER Fqdn
    Subject full domain name

.PARAMETER Ip
    Subject IPv4 address

.PARAMETER AlgType
    Algorithm used for key generation. Default is EC

.PARAMETER KeyLen
    Key length for RSA. Default is 2048

.PARAMETER AltCN
    Alternative CommonName. Used when the certificate subject (CN) should differ from FQDN.
    This name is also used as the file name for the generated .crt/.key.

.EXAMPLE
    ./issue-cert.ps1 server -Fqdn host.example.com -Ip 10.0.0.1

#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$CertType,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$')]
    [string]$Fqdn,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$')]
    [string]$Ip,

    [ValidateSet("EC", "RSA")]
    [string]$AlgType = "EC",

    [int]$KeyLen = 2048,

    [string]$AltCN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Verbose "FQDN is valid"
Write-Verbose "IP is valid"
Write-Warning "THIS SCRIPT DOESN'T CHECK THAT IP ACTUALLY CORRESPONDS WITH FQDN! BE CAREFUL!"

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
Write-Verbose "Docker container is active"

$san = "DNS:$Fqdn,DNS:$($Fqdn.Split('.')[0]),IP:$Ip"
$subjectName = $AltCN ? $AltCN : $Fqdn

$algoArgs = if ($AlgType -eq "RSA") {
    Write-Verbose "Using RSA with key size of $KeyLen bits"
    @("--use-algo=rsa", "--keysize=$KeyLen")
} else {
    Write-Verbose "Using EC with secp256r1 curve"
    @("--use-algo=ec")
}


Write-Verbose "================================================================"
Write-Verbose "Issuing certificate.."
Invoke-Docker exec easyrsa-ca easyrsa @algoArgs gen-req $subjectName nopass
Invoke-Docker exec easyrsa-ca easyrsa "--san=$san" sign-req $CertType $subjectName
Write-Verbose "Certificate issued"
Invoke-Docker cp "easyrsa-ca:/app/data/pki/issued/$subjectName.crt" .
Invoke-Docker cp "easyrsa-ca:/app/data/pki/private/$subjectName.key" .
Write-Verbose "Done!"
Write-Verbose "================================================================"