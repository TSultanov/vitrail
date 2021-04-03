param(
    [ValidateSet("Include", "Lib")]
    [string]$Type
)

$sdkRegRoot = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows Kits\Installed Roots\'
$kitsRoot = Get-ItemPropertyValue -Name 'KitsRoot10' $sdkRegRoot

$latestSdkVersion = (@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots\'|Sort-Object -Property Name -Descending)|select -First 1).Name | Split-Path -Leaf

if(-not $latestSdkVersion) {
    throw "Failed to locate WinSDK"
}

$path = Join-Path (Join-Path $kitsRoot $Type) $latestSdkVersion
Write-Host -NoNewline $path.Replace("\", "/")