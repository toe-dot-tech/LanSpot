<#
  hotspot_helper.ps1

  Backend for the LanSpot Flutter app.

  Two ways to run:
    * One shot:  -Action <name> -Payload <json> -OutFile <file>
    * Server:    -Action server -Port <n>
  The server connects back to the app on a loopback port and then reads one JSON
  request per line and writes one JSON reply per line, staying alive between
  calls. That matters because a fresh PowerShell process costs 400ms before it
  runs a single line, and the NetTCPIP and NetSecurity module loads cost several
  seconds on top of that. The app polls several times a second, so paying that
  every time is the difference between a live UI and one that feels frozen.

  The channel is a socket rather than stdin/stdout because Windows PowerShell
  never delivers a line another process writes to its redirected stdin - it only
  ever reads the console - so a long-lived child would wait forever for requests
  it never sees. Loopback is used instead and only one client ever connects.

  Windows quirks this script works around:
    * The Intel AX211 driver reports "Hosted network supported: No", so the old
      netsh wlan set hostednetwork trick does not work on this machine. Everything
      goes through the WinRT tethering API instead (the same one the Settings
      app uses).
    * PowerShell's WinRT adapter silently unwraps IAsyncOperation<T> methods and
      drops the "Async" suffix, so GetCurrentAccessPointConfiguration() and
      GetTetheringClients() are called synchronously while StartTetheringAsync()
      still has to be awaited by hand.
    * Windows keeps several "Wi-Fi Direct Virtual Adapter" instances around and
      renumbers the "Local Area Connection* N" aliases on every boot, so adapters
      are always looked up by description at runtime.
    * ConfigureAccessPointAsync only accepts a
      NetworkOperatorTetheringAccessPointConfiguration object, which has to be
      created with New-Object before its properties can be filled in.
    * It works while tethering is off, so the name, password and band can be set
      before the hotspot is ever started.
    * Get-NetFirewallRule walks all 1016 rules on this PC and takes 2.2s, so
      firewall work goes through netsh instead.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Action,
  [string]$Payload = '{}',
  [string]$OutFile = '',
  [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script:RulePrefix = 'LanSpot block'
# Deliberately a different prefix from the starvation rules above so that
# removing one never takes the other with it.
$script:ClientRulePrefix = 'LanSpot client'
$script:HotspotDescPattern = 'Wi-Fi Direct'
$script:DefaultSubnet = '192.168.137.0/24'

# Windows renumbers the "Local Area Connection* N" aliases across boots, so the
# name is looked up at runtime rather than stored. It is cached between calls
# because the fast poll needs it every time and Get-NetAdapter costs 1.9s the
# first time in a process.
$script:CachedHotspotNic = $null

# ---------------------------------------------------------------------------
# WinRT plumbing
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

$script:AsTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'
})[0]

$script:OpResultType = 'Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime'
$script:AccessPointConfigType = 'Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime'

function Await-Action {
    param($WinRtAction, [int]$TimeoutMs = 25000)
    $task = $script:AsTaskAction.Invoke($null, @($WinRtAction))
    if (-not $task.Wait($TimeoutMs)) { throw "Windows did not finish the operation within $TimeoutMs ms." }
    if ($task.IsFaulted) { throw $task.Exception.GetBaseException().Message }
}

function Await-TetheringOp {
    param($WinRtOp, [int]$TimeoutMs = 25000)
    $resultType = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    $task = $script:AsTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($WinRtOp))
    if (-not $task.Wait($TimeoutMs)) { throw "Windows did not finish the operation within $TimeoutMs ms." }
    if ($task.IsFaulted) { throw $task.Exception.GetBaseException().Message }
    $result = $task.Result
    if ($null -eq $result) { return $null }

    $status = ''
    $detail = ''
    try { $status = $result.Status.ToString() } catch { }
    try { $detail = $result.AdditionalErrorMessage } catch { }

    if ($status -and $status -ne 'Success') {
        $human = switch ($status) {
            'MobileDataTurnedOff'              { 'mobile data is turned off' }
            'WiFiDeviceOff'                    { 'the Wi-Fi radio is off' }
            'EntraCheckFailed'                 { 'Windows could not verify your account' }
            'EntraWifiAccessDenied'            { 'Windows denied Wi-Fi access for tethering' }
            'MobileDataRequired'               { 'Windows wants mobile data to start tethering' }
            'WiFiBandRequired'                 { 'the requested Wi-Fi band is not available' }
            'WifiUnsupported'                  { 'this Wi-Fi adapter cannot host a hotspot' }
            'WifiBandUnsupported'              { 'this Wi-Fi adapter cannot host that band' }
            'TetheringWifiClientLimitReached'  { 'the maximum number of clients is already connected' }
            'TetheringWifiClientTemporarilyUnavailable' { 'Wi-Fi is busy, try again in a moment' }
            default                           { $status }
        }
        throw "Tethering failed: $human.$(if ($detail) { " $detail" })"
    }
    return $result
}

function Get-Profiles {
    [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetConnectionProfiles()
}

function New-TetheringManager {
    param($Profile)
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($Profile)
}

function Get-BandValue {
    param([string]$Name)
    if (-not $Name) { $Name = 'Auto' }
    $bandType = [Windows.Networking.NetworkOperators.TetheringWiFiBand,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    [Enum]::Parse($bandType, $Name, $true)
}

# ---------------------------------------------------------------------------
# Adapters / addressing
# ---------------------------------------------------------------------------

function Get-PhysicalWifiAdapter {
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceDescription -match 'Wireless|Wi-Fi' -and
            $_.InterfaceDescription -notmatch $script:HotspotDescPattern -and
            $_.InterfaceDescription -notmatch 'Bluetooth'
        } |
        Select-Object -First 1
}

# Windows keeps several "Wi-Fi Direct Virtual Adapter" instances around. The live
# one is the one that is Up, or failing that the one holding the ICS address.
function Get-HotspotAdapter {
    $nics = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceDescription -match $script:HotspotDescPattern })
    $up = $nics | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($up) { $script:CachedHotspotNic = $up.Name; return $up }
    foreach ($nic in $nics) {
        if (Get-IcsAddress -InterfaceAlias $nic.Name) { $script:CachedHotspotNic = $nic.Name; return $nic }
    }
    $first = $nics | Select-Object -First 1
    if ($first) { $script:CachedHotspotNic = $first.Name }
    return $first
}

# Live Wi-Fi state for the fast poll.
#
# Get-NetAdapter costs about 0.9s the first time a process touches the NetAdapter
# module and ~60ms after that, so this asks for the one adapter we already know by
# name instead of enumerating every adapter on the PC. It is rate-limited as well:
# the toggle only has to feel real time, and asking several times a second would
# burn a visible slice of a core for no gain anyone would see.
$script:CachedWifiAdapterName = $null
$script:CachedWifiAt = [datetime]::MinValue
$script:CachedWifiLive = $null

function Get-WifiLiveState {
    $now = [datetime]::UtcNow
    if ($script:CachedWifiLive -and ($now - $script:CachedWifiAt).TotalMilliseconds -lt 500) {
        return $script:CachedWifiLive
    }
    $script:CachedWifiAt = $now

    # Resolving which adapter is the Wi-Fi one is the expensive part, so it happens
    # once per process and the name is reused by every call after that.
    if (-not $script:CachedWifiAdapterName) {
        $seed = Get-PhysicalWifiAdapter
        if ($seed) { $script:CachedWifiAdapterName = $seed.Name }
    }

    $nic = $null
    if ($script:CachedWifiAdapterName) {
        try {
            $nic = Get-NetAdapter -Name $script:CachedWifiAdapterName -ErrorAction SilentlyContinue |
                Select-Object -First 1
        } catch { }
    }

    if ($null -eq $nic) {
        # The adapter is gone or has been renamed; resolve it again next time.
        $script:CachedWifiAdapterName = $null
        $script:CachedWifiLive = [ordered]@{ known = $false; alias = $null; status = 'Missing'; up = $false }
    } else {
        $script:CachedWifiLive = [ordered]@{
            known  = $true
            alias  = [string]$nic.Name
            status = [string]$nic.Status
            up     = ([string]$nic.Status -eq 'Up')
        }
    }
    return $script:CachedWifiLive
}

function Get-IcsAddress {
    param([string]$InterfaceAlias)
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '0.0.0.0' } |
        Select-Object -First 1
}

function ConvertTo-IPv4UInt32 {
    param([string]$IPAddress)
    $p = $IPAddress.Split('.')
    [uint64](([uint64]$p[0] -shl 24) -bor ([uint64]$p[1] -shl 16) -bor ([uint64]$p[2] -shl 8) -bor ([uint64]$p[3]))
}

function ConvertFrom-IPv4UInt32 {
    param([uint64]$Value)
    '{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 0xFF), (($Value -shr 16) -band 0xFF), (($Value -shr 8) -band 0xFF), ($Value -band 0xFF)
}

function Get-SubnetBase {
    param([string]$IPAddress, [int]$PrefixLength)
    $value = ConvertTo-IPv4UInt32 $IPAddress
    $size  = [uint64][Math]::Pow(2, 32 - $PrefixLength)
    ConvertFrom-IPv4UInt32 ([uint64]$value - ($value % $size))
}

function Get-SubnetEnd {
    param([string]$Base, [int]$PrefixLength)
    $value = ConvertTo-IPv4UInt32 $Base
    $size  = [uint64][Math]::Pow(2, 32 - $PrefixLength)
    ConvertFrom-IPv4UInt32 ([uint64]$value + $size - 1)
}

# Everything except the ICS subnet itself, expressed as firewall-friendly ranges.
# Traffic aimed at 192.168.137.x (the PC's own DHCP/DNS) stays open so devices
# still get an IP address and still show "connected, no internet".
function Get-OutsideSubnetRanges {
    param([string]$Base, [int]$PrefixLength)

    $zero  = [uint64]0
    $top   = ConvertTo-IPv4UInt32 '255.255.255.255'
    $baseV = ConvertTo-IPv4UInt32 $Base
    $endV  = ConvertTo-IPv4UInt32 (Get-SubnetEnd -Base $Base -PrefixLength $PrefixLength)

    $ranges = @()
    if ($baseV -gt $zero) { $ranges += ('{0}-{1}' -f '0.0.0.0', (ConvertFrom-IPv4UInt32 ($baseV - 1))) }
    if ($endV -lt $top)   { $ranges += ('{0}-{1}' -f (ConvertFrom-IPv4UInt32 ($endV + 1)), '255.255.255.255') }
    return $ranges
}

# ---------------------------------------------------------------------------
# Firewall rules
# ---------------------------------------------------------------------------
#
# The NetSecurity cmdlets are the obvious way to do all of this and they are
# unusable here: Get-NetFirewallRule takes 2.2s even on a warm process because it
# walks all 1016 rules on the PC, and Remove-NetFirewallRule another 2.3s. A
# single mode change cost eleven seconds, which is why the UI used to freeze.
#
# netsh talks to the same firewall service through the same policy store and
# answers in ~170ms, so every rule operation below goes through netsh. Reading
# uses the full listing once and then filters, because netsh's name filter is an
# exact match with no wildcard support.

function Get-OurRuleNames {
    # Display names of every rule this app owns, from the firewall itself.
    $names = New-Object System.Collections.ArrayList
    $lines = netsh advfirewall firewall show rule name=all 2>$null
    if ($null -eq $lines) { return $names }
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*Rule Name:\s+(.+?)\s*$') { continue }
        $name = $matches[1]
        if ($name -like "$script:RulePrefix*" -or $name -like "$script:ClientRulePrefix*") {
            [void]$names.Add($name)
        }
    }
    return $names
}

# The blocked list only changes when this app changes it, so the answer is cached
# and refreshed on demand. Polling does not re-read the firewall; an explicit
# action invalidates it, and the full status sweep forces a fresh read, so a rule
# deleted by hand in the Windows firewall console still converges.
$script:RuleCache = $null

function Invalidate-RuleCache {
    $script:RuleCache = $null
}

function Get-RuleCache {
    if ($null -eq $script:RuleCache) { $script:RuleCache = @(Get-OurRuleNames) }
    return $script:RuleCache
}

function Remove-RuleByName {
    param([string]$Name)
    if (-not $Name) { return $false }
    netsh advfirewall firewall delete rule name="$Name" 2>&1 | Out-Null
    return $true
}

function Remove-BlockRules {
    foreach ($name in @(Get-RuleCache | Where-Object { $_ -like "$script:RulePrefix*" })) {
        [void](Remove-RuleByName -Name $name)
    }
    Invalidate-RuleCache
}

function Get-BlockRules {
    @(Get-RuleCache | Where-Object { $_ -like "$script:RulePrefix*" })
}

function Set-BlockRule {
    param([bool]$Enabled, [string]$WifiAlias, [string]$HotspotAlias,
          [string]$SubnetCidr, [string]$Base, [int]$PrefixLength)

    # Skipping the whole rebuild when the rules are already in the requested state
    # is what makes toggling back and forth feel instant. The name is the only
    # thing that distinguishes the two modes, so its presence is the state.
    $existing = @(Get-RuleCache)
    $haveEgress = ($existing -contains "$script:RulePrefix - subnet egress")
    $haveScope  = ($existing -contains "$script:RulePrefix - client scope")
    if (-not $Enabled -and -not $haveEgress -and -not $haveScope) { return @() }
    if ($Enabled -and $haveEgress -and $haveScope) { return @($existing | Where-Object { $_ -like "$script:RulePrefix*" }) }

    Remove-BlockRules
    if (-not $Enabled) { return @() }

    $created = @()

    # Rule 1 - the documented approach: stop the hotspot subnet from leaving
    # through the adapter being shared. Without this, clients get real internet.
    if ($WifiAlias -and $SubnetCidr) {
        New-NetFirewallRule -DisplayName "$script:RulePrefix - subnet egress" `
            -Description 'Stops devices on the hotspot from reaching the internet.' `
            -Group 'LanSpot' -Direction Outbound -Action Block -Profile Any `
            -Enabled True -InterfaceAlias $WifiAlias -LocalAddress $SubnetCidr -RemoteAddress Any | Out-Null
        $created += "$script:RulePrefix - subnet egress"
    }

    # Rule 2 - belt and braces. If ICS rewrites the source address before rule 1
    # is evaluated, this catches the same traffic on the way in instead.
    if ($HotspotAlias) {
        $ranges = @(Get-OutsideSubnetRanges -Base $Base -PrefixLength $PrefixLength)
        if ($ranges.Count -gt 0) {
            New-NetFirewallRule -DisplayName "$script:RulePrefix - client scope" `
                -Description 'Blocks hotspot clients from reaching anything outside the hotspot subnet.' `
                -Group 'LanSpot' -Direction Inbound -Action Block -Profile Any `
                -Enabled True -InterfaceAlias $HotspotAlias -RemoteAddress $ranges | Out-Null
            $created += "$script:RulePrefix - client scope [$($ranges -join ', ')]"
        }
    }

    Invalidate-RuleCache
    return $created
}

# ---------------------------------------------------------------------------
# Per-device blocking
# ---------------------------------------------------------------------------

# Windows exposes no way to refuse a tethering client, so a blocked device is
# implemented as a firewall rule that drops everything it sends to us. Because
# every packet a client sends has to arrive on the hotspot adapter, blocking
# that one interface severs it completely - both the internet and the rest of
# the network - without touching anyone else.
function Normalize-Mac {
    param([string]$Mac)
    if (-not $Mac) { return '' }
    return ($Mac -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
}

# Rules are named with dashes because that is the form Windows itself uses, so
# the names stay readable in the firewall console.
function Mac-ToRuleToken {
    param([string]$Mac)
    $hex = Normalize-Mac $Mac
    if (-not $hex) { return '' }
    return (($hex -split '(..)' | Where-Object { $_ }) -join '-')
}

function Get-ClientAddressMap {
    param([string]$NicName, [string]$SubnetCidr)

    $map = @{}
    if (-not $NicName) { return $map }

    # arp -a instead of Get-NetNeighbor. The cmdlet is accurate but costs 2.1s on
    # a cold process because it loads the NetTCPIP module, which is most of a
    # status sweep. arp -a reads the same neighbour table straight out of the
    # stack in 80ms and needs no elevation.
    #
    # Only entries on the hotspot subnet are kept, because arp -a lists every
    # interface on the PC and a device's MAC could otherwise be matched against an
    # address on the wrong network.
    #
    # The comparison is on whole leading octets rather than the literal network
    # address. arp -a reports the interface address (192.168.137.1), which does not
    # start with the network address (192.168.137.0), so comparing the full string
    # silently matched nothing at all and every device was left without an address.
    $base = ''
    if ($SubnetCidr -and $SubnetCidr -match '^(.+?)/\d+$') {
        $octets = @($matches[1].Split('.'))
        $lead = [Math]::Min(3, $octets.Count)
        $base = (($octets[0..($lead - 1)]) -join '.') + '.'
    } elseif ($SubnetCidr) {
        $base = "$SubnetCidr."
    }

    $current = ''
    try {
        foreach ($line in @(arp -a 2>$null)) {
            if ($line -match '^\s*Interface:\s+(\S+)') { $current = $matches[1]; continue }
            if ($current -and $base -and -not $current.StartsWith($base)) { continue }
            if ($line -notmatch '^\s+(\d+\.\d+\.\d+\.\d+)\s+([0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5})\s+(\S+)') { continue }
            $ip = $matches[1]
            $mac = Normalize-Mac $matches[2]
            if (-not $mac) { continue }
            # Entries on the hotspot subnet are reported as *static*, not dynamic,
            # because Windows adds them the moment a client associates. Accepting
            # only dynamic rows therefore dropped the address of every device, and
            # a phone sat in the list as a bare hardware address. Broadcast and
            # multicast rows are never clients and are skipped.
            if ($matches[3] -and $matches[3] -notin @('dynamic', 'static')) { continue }
            if ($mac.StartsWith('ffffff') -or $mac.StartsWith('01005e')) { continue }
            $map[$mac] = $ip
        }
    } catch { }
    return $map
}

function Get-BlockedMacs {
    $macs = @()
    foreach ($name in @(Get-RuleCache | Where-Object { $_ -like "$script:ClientRulePrefix - *" })) {
        $macs += Normalize-Mac ($name -replace "^$script:ClientRulePrefix - ", '')
    }
    return $macs
}

function Remove-ClientBlockRule {
    param([string]$Mac)
    $token = Mac-ToRuleToken $Mac
    if (-not $token) { return $false }
    $name = "$script:ClientRulePrefix - $token"
    $existed = @(Get-RuleCache) -contains $name
    [void](Remove-RuleByName -Name $name)
    Invalidate-RuleCache
    return $existed
}

function Remove-ClientBlockRules {
    foreach ($name in @(Get-RuleCache | Where-Object { $_ -like "$script:ClientRulePrefix - *" })) {
        [void](Remove-RuleByName -Name $name)
    }
    Invalidate-RuleCache
}

function Set-ClientBlockRule {
    param([bool]$Enabled, [string]$Mac, [string]$NicName, [string]$Ip)

    $token = Mac-ToRuleToken $Mac
    if (-not $token) { throw 'That device has no usable hardware address, so it cannot be blocked.' }

    Remove-ClientBlockRule -Mac $Mac
    if (-not $Enabled) { return $null }
    if (-not $NicName) { throw 'The hotspot adapter is not available, so the device cannot be blocked yet.' }
    if (-not $Ip) { throw "This device has no address on the hotspot yet, so there is nothing to block. Reconnect it and try again." }

    $rule = New-NetFirewallRule -DisplayName "$script:ClientRulePrefix - $token" `
        -Description "Blocks a single device from the LanSpot hotspot." `
        -Group 'LanSpot' -Direction Inbound -Action Block -Profile Any `
        -Enabled True -InterfaceAlias $NicName -RemoteAddress $Ip
    Invalidate-RuleCache
    return "$script:ClientRulePrefix - $token ($Ip)"
}

function Block-Payload {
    param($Parsed)

    $subnet = Get-SubnetInfo
    $mac = Normalize-Mac $Parsed.mac
    if (-not $mac) { throw 'No device was named to block.' }

    $map = Get-ClientAddressMap -NicName $subnet.Nic.Name -SubnetCidr $subnet.Cidr
    $ip = if ($map.ContainsKey($mac)) { $map[$mac] } else { $null }
    $rule = Set-ClientBlockRule -Enabled $true -Mac $mac -NicName $subnet.Nic.Name -Ip $ip

    return [ordered]@{
        ok      = $true
        mac     = $mac
        ip      = $ip
        rule    = $rule
        blocked = @(Get-BlockedMacs)
        detail  = "Blocked $mac."
    }
}

function Unblock-Payload {
    param($Parsed)

    $mac = Normalize-Mac $Parsed.mac
    if (-not $mac) { throw 'No device was named to unblock.' }
    $removed = Remove-ClientBlockRule -Mac $mac

    return [ordered]@{
        ok      = $true
        mac     = $mac
        removed = $removed
        blocked = @(Get-BlockedMacs)
        detail  = if ($removed) { "Unblocked $mac." } else { "$mac was not blocked." }
    }
}

function ClearBlocks-Payload {
    param($Parsed)

    Remove-ClientBlockRules

    return [ordered]@{
        ok      = $true
        blocked = @()
        detail  = 'Every blocked device was allowed back on.'
    }
}

# ---------------------------------------------------------------------------
# Hotspot state discovery
# ---------------------------------------------------------------------------

# This PC has 34 connection profiles, and creating a tethering manager for each
# one costs about 600ms together. The hotspot is hosted by one profile and stays
# there, so the manager resolved last time is remembered and re-read first: if it
# is still On, the answer costs nothing. A full sweep still happens at least
# every couple of seconds so a hotspot started elsewhere is never missed for
# long, and immediately whenever the remembered profile no longer works.
$script:CachedManager = $null
$script:CachedManagerName = $null
$script:LastFullSweep = [datetime]::MinValue

function Get-HotspotManager {
    param([string]$Hint)

    $fresh = ((Get-Date) - $script:LastFullSweep).TotalSeconds -lt 2.0
    if ($null -ne $script:CachedManager) {
        $cachedState = $null
        try { $cachedState = $script:CachedManager.Manager.TetheringOperationalState.ToString() } catch { $cachedState = $null }
        if ($cachedState -eq 'On') { return $script:CachedManager }
        # An explicit hint naming the remembered profile settles it outright,
        # because the caller is telling us where the hotspot is.
        if ($Hint -and $Hint -eq $script:CachedManagerName) { return $script:CachedManager }
        if ($cachedState -eq 'Off' -and $fresh) { return $script:CachedManager }
    }

    $profiles = @(Get-Profiles)
    $ordered = New-Object System.Collections.ArrayList

    foreach ($name in @($Hint)) {
        foreach ($p in $profiles) {
            if ($p -and $p.ProfileName -eq $name) { [void]$ordered.Add($p) }
        }
    }
    foreach ($p in $profiles) {
        if ($p -and $p.GetNetworkConnectivityLevel().ToString() -eq 'InternetAccess') { [void]$ordered.Add($p) }
    }
    foreach ($p in $profiles) { if ($p) { [void]$ordered.Add($p) } }

    $seen = @{}
    $idle = $null

    foreach ($p in $ordered) {
        if ($seen.ContainsKey($p.ProfileName)) { continue }
        $seen[$p.ProfileName] = $true
        $mgr = $null
        try { $mgr = New-TetheringManager -Profile $p } catch { continue }
        if ($null -eq $mgr) { continue }
        $state = $mgr.TetheringOperationalState.ToString()
        if ($state -eq 'On') {
            $script:CachedManager = [pscustomobject]@{ Profile = $p; Manager = $mgr; State = $state }
            $script:CachedManagerName = $p.ProfileName
            $script:LastFullSweep = Get-Date
            return $script:CachedManager
        }
        if ($null -eq $idle) { $idle = [pscustomobject]@{ Profile = $p; Manager = $mgr; State = $state } }
    }

    $script:LastFullSweep = Get-Date
    if ($idle) {
        $script:CachedManager = $idle
        $script:CachedManagerName = $idle.Profile.ProfileName
    }
    return $idle
}

function Get-StandaloneSources {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    $names = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-Profiles)) {
        if (-not $p) { continue }
        if ($p.GetNetworkConnectivityLevel().ToString() -eq 'InternetAccess') { continue }
        if ($p.IsWlanConnectionProfile) { continue }
        foreach ($a in $adapters) {
            if ($a.Name -eq $p.ProfileName -and -not $names.Contains($p.ProfileName)) {
                [void]$names.Add($p.ProfileName)
            }
        }
    }
    return $names
}

function Get-SubnetInfo {
    $hotspotNic = Get-HotspotAdapter
    $icsAddr = if ($hotspotNic) { Get-IcsAddress -InterfaceAlias $hotspotNic.Name } else { $null }
    $base = '192.168.137.0'
    $prefix = 24
    if ($icsAddr) {
        $base = Get-SubnetBase -IPAddress $icsAddr.IPAddress -PrefixLength $icsAddr.PrefixLength
        $prefix = $icsAddr.PrefixLength
    }
    [pscustomobject]@{
        Nic    = $hotspotNic
        Base   = $base
        Prefix = $prefix
        Cidr   = "$base/$prefix"
    }
}

# WindowsIdentity.GetCurrent() is not free the first time it is called and the
# fast poll asks for this on every request, so the answer is kept.
function Test-Elevated {
    if ($null -ne $script:CachedElevated) { return $script:CachedElevated }
    $elevated = $false
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $elevated  = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    $script:CachedElevated = $elevated
    return $elevated
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Get-StatusPayload {
    param($Parsed)

    $notes = New-Object System.Collections.ArrayList

    $elevated = Test-Elevated
    if (-not $elevated) { [void]$notes.Add('Not running as administrator - the firewall part of this app needs elevation.') }

    $wifi = Get-PhysicalWifiAdapter
    $wifiPayload = [ordered]@{
        present = ($null -ne $wifi)
        alias   = if ($wifi) { $wifi.Name } else { $null }
        status  = if ($wifi) { $wifi.Status.ToString() } else { 'Missing' }
    }

    $subnet = Get-SubnetInfo

    $internetProfile = $null
    foreach ($p in @(Get-Profiles)) {
        if (-not $p) { continue }
        if ($p.GetNetworkConnectivityLevel().ToString() -eq 'InternetAccess') { $internetProfile = $p; break }
    }

    $hotspot = [ordered]@{
        on      = $false
        state   = 'Off'
        clients = 0
        clientList = @()
        ssid    = $null
        passphrase = $null
        band    = $null
        auth    = $null
        source  = $null
        nic     = if ($subnet.Nic) { $subnet.Nic.Name } else { $null }
        subnet  = $subnet.Cidr
    }

    $found = Get-HotspotManager -Hint ([string]$Parsed.hint)
    if ($found) {
        $hotspot.state  = $found.State
        $hotspot.on     = ($found.State -eq 'On')
        $hotspot.source = $found.Profile.ProfileName
        try { $hotspot.clients = [int]$found.Manager.ClientCount } catch { }
        try {
            $cfg = $found.Manager.GetCurrentAccessPointConfiguration()
            if ($cfg) {
                $hotspot.ssid = [string]$cfg.Ssid
                $hotspot.band = $cfg.Band.ToString()
                $hotspot.auth = $cfg.AuthenticationKind.ToString()
                # Windows hands the live password back through WinRT, so the UI
                # can show the real current settings rather than our own copy.
                $hotspot.passphrase = [string]$cfg.Passphrase
            }
        } catch { [void]$notes.Add('Could not read the hotspot name: ' + $_.Exception.Message) }
        if ($hotspot.on) {
            # Resolving each device's address is what lets a single device be
            # blocked, so the full status pays for it while the fast poll does not.
            $addresses = Get-ClientAddressMap -NicName $hotspot.nic -SubnetCidr $hotspot.subnet
            try {
                $list = @($found.Manager.GetTetheringClients())
                $hotspot.clientList = @($list | ForEach-Object {
                    $mac = Normalize-Mac $_.MacAddress
                    [ordered]@{
                        mac = $mac
                        ip  = if ($addresses.ContainsKey($mac)) { $addresses[$mac] } else { $null }
                    }
                })
            } catch { }
        }
    } else {
        [void]$notes.Add('Windows did not report any hotspot-capable connection profile.')
    }

    $icsRunning = $false
    try { $icsRunning = ((Get-Service icssvc -ErrorAction SilentlyContinue).Status -eq 'Running') } catch { }

    $rules = @(Get-BlockRules | Select-Object -ExpandProperty DisplayName)

    return [ordered]@{
        ok                = $true
        elevated          = $elevated
        hostname          = $env:COMPUTERNAME
        hotspot           = $hotspot
        wifi              = $wifiPayload
        internet          = [ordered]@{
            available = ($null -ne $internetProfile)
            profile   = if ($internetProfile) { $internetProfile.ProfileName } else { $null }
        }
        firewall          = [ordered]@{ applied = ($rules.Count -gt 0); rules = $rules }
        blocked           = @(Get-BlockedMacs)
        standaloneSources = @(Get-StandaloneSources)
        noConnectionsTimeout = (Get-NoConnectionsTimeout)
        icsRunning        = $icsRunning
        notes             = @($notes)
    }
}

function Set-ModePayload {
    param([string]$Mode)

    $subnet = Get-SubnetInfo
    $wifi   = Get-PhysicalWifiAdapter
    $starve = ($Mode -eq 'nointernet')

    $rules = Set-BlockRule -Enabled $starve `
                -WifiAlias $(if ($wifi) { $wifi.Name }) `
                -HotspotAlias $(if ($subnet.Nic) { $subnet.Nic.Name }) `
                -SubnetCidr $subnet.Cidr -Base $subnet.Base -PrefixLength $subnet.Prefix

    $notes = New-Object System.Collections.ArrayList
    if ($starve -and @($rules).Count -eq 0) {
        [void]$notes.Add('Could not create the firewall rules. Run this app as administrator.')
    }

    return [ordered]@{ ok = $true; mode = $Mode; rules = @($rules); notes = @($notes) }
}

function Get-ApConfig {
    param($Manager)
    try { return $Manager.GetCurrentAccessPointConfiguration() } catch { return $null }
}

# Windows treats ConfigureAccessPointAsync as a full replacement of the access
# point configuration, not a patch: every field you send wins, and anything you
# leave out gets reset to a default. So the settings Windows already has are read
# first and every field the caller did not explicitly ask to change is copied
# straight back, which keeps us from silently wiping a setting the user made in
# the Windows Settings app.
function Set-ApConfig {
    param($Manager, [hashtable]$Wanted)

    if ($null -eq $Wanted -or $Wanted.Count -eq 0) {
        return @()  # nothing asked for, so nothing to push
    }

    $current = Get-ApConfig -Manager $Manager
    $changed = @()

    $ssid = if ($Wanted.ContainsKey('ssid')) { [string]$Wanted.ssid }
            elseif ($current) { [string]$current.Ssid } else { throw 'Windows did not report a hotspot name, so one must be supplied.' }
    if ($ssid -and [string]$current.Ssid -ne $ssid) { $changed += 'name' }

    $pass = if ($Wanted.ContainsKey('passphrase')) { [string]$Wanted.passphrase }
            elseif ($current) { [string]$current.Passphrase } else { '' }
    if ($pass -and $pass.Length -lt 8) { throw 'The hotspot password must be at least 8 characters.' }
    if ($pass -and [string]$current.Passphrase -ne $pass) { $changed += 'password' }

    # 'band' is only honoured when the key is present, because 'Auto' is a real
    # choice (let Windows decide) rather than a "no change" marker.
    $band = if ($Wanted.ContainsKey('band')) { [string]$Wanted.band }
            elseif ($current) { $current.Band.ToString() } else { 'Auto' }
    $bandValue = Get-BandValue $band
    if ($current -and $current.Band.ToString() -ne $band) { $changed += 'band' }

    # Keep whatever authentication Windows is already using. It knows which
    # WPA version this adapter supports; forcing one here would break adapters
    # that negotiate WPA3.
    $auth = if ($current) { $current.AuthenticationKind } else { $null }
    if ($null -eq $auth) {
        $authType = [Windows.Networking.NetworkOperators.TetheringWiFiAuthenticationKind,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
        $auth = [Enum]::Parse($authType, 'Wpa2')
    }

    # Nothing actually differs, so leave the running hotspot undisturbed.
    if ($changed.Count -eq 0) { return @() }

    $cfg = New-Object -TypeName $script:AccessPointConfigType
    $cfg.Ssid = $ssid
    $cfg.Passphrase = $pass
    $cfg.Band = $bandValue
    $cfg.AuthenticationKind = $auth

    Await-Action ($Manager.ConfigureAccessPointAsync($cfg))
    return $changed
}

function Start-Payload {
    param($Parsed)

    $mode = [string]$Parsed.mode
    if (-not $mode) { $mode = 'normal' }

    # Apply the mode first so the firewall is already in the requested state
    # even if tethering refuses to start.
    $modeResult = Set-ModePayload -Mode $mode
    $notes = @($modeResult.notes)

    $profiles = @(Get-Profiles)
    # Connections worth trying to share from, best first.
    $candidates = New-Object System.Collections.ArrayList
    $reason = ''

    if ($mode -eq 'normal') {
        foreach ($p in $profiles) {
            if ($p -and $p.GetNetworkConnectivityLevel().ToString() -eq 'InternetAccess') { [void]$candidates.Add($p) }
        }
        if ($candidates.Count -eq 0) {
            throw 'There is no internet connection to share, so a normal hotspot cannot start. Use "No internet" mode instead, which starts the hotspot without any internet.'
        }
        $reason = 'sharing your Wi-Fi internet'
    }
    elseif ($mode -eq 'nointernet') {
        # Having no internet is the entire point of this mode, so any connection
        # will do - including the Wi-Fi link itself. Requiring a non-Wi-Fi
        # connection is what made this mode stop working on a laptop that only
        # has Wi-Fi: with no internet to find, the fallback found nothing and the
        # start failed even though a perfectly good Wi-Fi profile was there.
        foreach ($p in $profiles) {
            if ($p -and $p.GetNetworkConnectivityLevel().ToString() -eq 'InternetAccess') { [void]$candidates.Add($p) }
        }
        foreach ($p in $profiles) { if ($p -and -not $p.IsWlanConnectionProfile) { [void]$candidates.Add($p) } }
        foreach ($p in $profiles) { if ($p) { [void]$candidates.Add($p) } }

        if ($candidates.Count -eq 0) {
            throw 'Windows reports no connection of any kind, so it will not start a hotspot. Reconnect to a Wi-Fi network and try again - "No internet" still needs a connection to share from.'
        }
        $reason = 'sharing your Wi-Fi with the internet cut off for clients'
    }
    else {
        throw "Unknown mode '$mode'. Use 'normal' or 'nointernet'."
    }

    # Windows refuses some connections as a tethering source, so each candidate is
    # tried in turn rather than giving up on the first one.
    $mgr = $null
    $chosen = $null
    foreach ($candidate in $candidates) {
        try { $mgr = New-TetheringManager -Profile $candidate } catch { $mgr = $null }
        if ($null -ne $mgr) { $chosen = $candidate; break }
    }
    if ($null -eq $mgr) { throw "Windows refused to create a hotspot for '$($candidates[0].ProfileName)'." }

    # Only pass the settings the caller actually supplied, so whatever Windows
    # already has is preserved for everything else.
    $wanted = @{}
    foreach ($key in 'ssid', 'passphrase', 'band') {
        $value = $Parsed.$key
        if ($null -ne $value -and [string]$value -ne '') { $wanted[$key] = [string]$value }
    }
    [void](Set-ApConfig -Manager $mgr -Wanted $wanted)

    if ($mgr.TetheringOperationalState.ToString() -ne 'On') {
        [void](Await-TetheringOp ($mgr.StartTetheringAsync()))
    }

    $state = $mgr.TetheringOperationalState.ToString()
    if ($state -ne 'On') {
        # A hotspot has to be broadcast by the Wi-Fi hardware even when it shares
        # no internet, so a disabled Wi-Fi adapter is the usual reason Windows
        # says no here. Say so plainly rather than passing on a bare enum name.
        $wifi = Get-PhysicalWifiAdapter
        if ($wifi -and $wifi.Status.ToString() -ne 'Up') {
            throw ("Windows kept the hotspot off because the Wi-Fi adapter '$($wifi.Name)' is $($wifi.Status). " +
                   'The hotspot is broadcast by the Wi-Fi hardware, so that adapter has to be on - but it does not need to be connected to anything or have internet. ' +
                   'Switch Wi-Fi on in this app, then start the hotspot again; offline mode will still share from the in-system connection and clients will get no internet.')
        }
        throw "Windows accepted the request but the hotspot state is '$state'."
    }

    return [ordered]@{ ok = $true; state = $state; source = $chosen.ProfileName; detail = "Hotspot is on, $reason."; notes = $notes }
}

function Stop-Payload {
    param($Parsed)

    $found = Get-HotspotManager -Hint ([string]$Parsed.source)
    if (-not $found) { return [ordered]@{ ok = $true; state = 'Off'; detail = 'The hotspot was already off.' } }
    if ($found.State -ne 'On') { return [ordered]@{ ok = $true; state = $found.State; detail = 'The hotspot was already off.' } }

    [void](Await-TetheringOp ($found.Manager.StopTetheringAsync()))
    return [ordered]@{ ok = $true; state = 'Off'; detail = 'Hotspot turned off.' }
}

function Configure-Payload {
    param($Parsed)

    $found = Get-HotspotManager -Hint ([string]$Parsed.source)
    if (-not $found) { throw 'The hotspot is not available, so its name and password cannot be changed right now.' }

    $wanted = @{}
    foreach ($key in 'ssid', 'passphrase', 'band') {
        $value = $Parsed.$key
        if ($null -ne $value -and [string]$value -ne '') { $wanted[$key] = [string]$value }
    }
    $changed = @(Set-ApConfig -Manager $found.Manager -Wanted $wanted)

    $detail = if ($changed.Count -eq 0) {
        'Already matches what Windows has; nothing was changed.'
    } else {
        'Updated the hotspot ' + ($changed -join ', ') + '.'
    }
    return [ordered]@{ ok = $true; detail = $detail; changed = $changed }
}

function Wifi-Payload {
    param($Parsed)

    $wifi = Get-PhysicalWifiAdapter
    if (-not $wifi) { throw 'No Wi-Fi adapter was found on this PC.' }

    if ($Parsed.on) { Enable-NetAdapter -InterfaceAlias $wifi.Name -Confirm:$false -ErrorAction Stop }
    else { Disable-NetAdapter -InterfaceAlias $wifi.Name -Confirm:$false -ErrorAction Stop }

    return [ordered]@{
        ok     = $true
        alias  = $wifi.Name
        on     = [bool]$Parsed.on
        detail = "The Wi-Fi adapter '$($wifi.Name)' is now $(if ($Parsed.on) { 'on' } else { 'off' })."
    }
}

function Cleanup-Payload {
    param($Parsed)

    Remove-BlockRules
    Remove-ClientBlockRules
    $stopped = $false
    try {
        $found = Get-HotspotManager -Hint ([string]$Parsed.source)
        if ($found -and $found.State -eq 'On') {
            [void](Await-TetheringOp ($found.Manager.StopTetheringAsync()))
            $stopped = $true
        }
    } catch { }

    return [ordered]@{ ok = $true; stopped = $stopped; detail = 'Block rules removed and the hotspot released.' }
}

function Get-NoConnectionsTimeout {
    try {
        [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::IsNoConnectionsTimeoutEnabled()
    } catch { $null }
}

function Diagnose-Payload {
    $rows = New-Object System.Collections.ArrayList

    foreach ($p in @(Get-Profiles)) {
        if (-not $p) { continue }
        $level = $p.GetNetworkConnectivityLevel().ToString()
        if ($level -ne 'InternetAccess' -and -not $p.IsWlanConnectionProfile -and $level -eq 'None') { continue }
        try {
            $cap = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::GetTetheringCapabilityFromConnectionProfile($p)
            if ("$cap" -ne 'Unknown') {
                [void]$rows.Add([ordered]@{ profile = $p.ProfileName; level = $level; canTether = "$cap" })
            }
        } catch { }
    }

    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceDescription -match 'Wireless|Wi-Fi' } |
                    ForEach-Object {
                        [ordered]@{ name = $_.Name; description = $_.InterfaceDescription; status = $_.Status.ToString() }
                    })

    $hosted = ((netsh wlan show drivers | Select-String 'Hosted network supported') -join ' ').Trim()
    $maxClients = $null
    try {
        $found = Get-HotspotManager -Hint $null
        if ($found) { $maxClients = [int]$found.Manager.MaxClientCount }
    } catch { }

    return [ordered]@{
        ok                = $true
        hostedNetwork     = $hosted
        adapters          = $adapters
        capability        = @($rows)
        maxClients        = $maxClients
        noConnectionsTimeout = (Get-NoConnectionsTimeout)
        standaloneSources = @(Get-StandaloneSources)
    }
}

function Timeout-Payload {
    param($Parsed)

    $type = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    if ($Parsed.enabled) { $type::EnableNoConnectionsTimeout() }
    else { $type::DisableNoConnectionsTimeout() }

    $on = [bool]$type::IsNoConnectionsTimeoutEnabled()
    return [ordered]@{
        ok = $true
        enabled = $on
        detail = if ($on) { 'Windows will now turn the hotspot off when nobody is connected.' }
                 else { 'The hotspot will stay on even when no devices are connected.' }
    }
}

# ---------------------------------------------------------------------------
# Fast path
# ---------------------------------------------------------------------------

# The full status action is a broad sweep: adapters, the firewall, the neighbour
# table. None of that is needed to answer "is the hotspot on and who is
# connected", which is the question the UI asks several times a second. This
# action reads the tethering state through WinRT and, when someone new has
# joined, resolves their address with arp so the device list is complete the
# moment it appears rather than on the next slow sweep.
function Get-QuickPayload {
    param($Parsed)

    # Read before the early return below, so the Wi-Fi switch still reports even
    # when Windows could not be asked about the hotspot itself.
    $wifi = Get-WifiLiveState

    $found = Get-HotspotManager -Hint ([string]$Parsed.hint)
    if (-not $found) {
        return [ordered]@{ ok = $true; known = $false; state = 'Unknown'; on = $false; clients = 0; clientList = @(); ssid = $null; source = $null; elevated = (Test-Elevated); wifi = $wifi }
    }

    $clients = 0
    $list = @()
    $macs = @()
    try {
        $clients = [int]$found.Manager.ClientCount
        if ($found.State -eq 'On') {
            $list = @($found.Manager.GetTetheringClients() | ForEach-Object {
                [ordered]@{ mac = [string]$_.MacAddress; ip = $null }
            })
            $macs = @($list | ForEach-Object { Normalize-Mac ([string]$_.mac) } | Where-Object { $_ })
        }
    } catch { }

    # Resolving addresses is only worth doing when somebody is actually
    # connected, and arp -a is cheap enough to sit in the fast path.
    if ($macs.Count -gt 0) {
        $nic = $script:CachedHotspotNic
        if (-not $nic) { $nic = (Get-HotspotAdapter).Name }
        $addresses = Get-ClientAddressMap -NicName $nic -SubnetCidr $script:DefaultSubnet
        if ($addresses.Count -gt 0) {
            $list = @($list | ForEach-Object {
                $mac = Normalize-Mac ([string]$_.mac)
                if ($addresses.ContainsKey($mac)) { [ordered]@{ mac = $mac; ip = $addresses[$mac] } }
                else { [ordered]@{ mac = $mac; ip = $null } }
            })
        }
    }

    $ssid = $null
    $band = $null
    $pass = $null
    try {
        $cfg = Get-ApConfig -Manager $found.Manager
        if ($cfg) {
            $ssid = [string]$cfg.Ssid
            $band = [string]$cfg.Band
            $pass = [string]$cfg.Passphrase
        }
    } catch { }

    return [ordered]@{
        ok     = $true
        known  = $true
        elevated = (Test-Elevated)
        wifi = $wifi
        state  = $found.State
        on     = ($found.State -eq 'On')
        clients = $clients
        clientList = $list
        ssid   = $ssid
        band   = $band
        passphrase = $pass
        source = $found.Profile.ProfileName
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Invoke-Action {
    param([string]$Act, [string]$Body = '{}')
    $parsed = $Body | ConvertFrom-Json

    switch ($Act) {
        'status'    { return Get-StatusPayload -Parsed $parsed }
        'quick'     { return Get-QuickPayload -Parsed $parsed }
        'setmode'   { return Set-ModePayload -Mode ([string]$parsed.mode) }
        'start'     { return Start-Payload -Parsed $parsed }
        'stop'      { return Stop-Payload -Parsed $parsed }
        'configure' { return Configure-Payload -Parsed $parsed }
        'wifi'      { return Wifi-Payload -Parsed $parsed }
        'timeout'   { return Timeout-Payload -Parsed $parsed }
        'cleanup'   { return Cleanup-Payload -Parsed $parsed }
        'block'     { return Block-Payload -Parsed $parsed }
        'unblock'   { return Unblock-Payload -Parsed $parsed }
        'clearblocks' { return ClearBlocks-Payload -Parsed $parsed }
        'diagnose'  { return Diagnose-Payload }
        default     { throw "Unknown action '$Act'." }
    }
}

function ConvertTo-Reply {
    param($Result)
    if ($null -eq $Result) { $Result = [ordered]@{ ok = $true; detail = 'Done.' } }
    return ($Result | ConvertTo-Json -Depth 8 -Compress)
}

function Write-Reply {
    param([string]$Json, $Writer = $null)
    if ($null -ne $Writer) {
        $Writer.WriteLine($Json)
        $Writer.Flush()
    } else {
        [Console]::Out.WriteLine($Json)
        [Console]::Out.Flush()
    }
}

# Connects back to the app on the loopback port it opened, then reads
# {"a":"<action>","p":{...}} one per line and answers one line at a time.
# Anything written to the success stream by a helper other than the final reply
# would corrupt the protocol, so the reply is the only thing sent down the wire.
function Invoke-ServerLoop {
    param([int]$Port)

    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.Connect('127.0.0.1', $Port)
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true

    try {
        Write-Reply '{"ok":true,"ready":true}' -Writer $writer

        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }          # the app went away
            $line = $line.Trim()
            if (-not $line) { continue }

            $reply = $null
            try {
                $req = $line | ConvertFrom-Json
                $act = [string]$req.a
                $body = if ($null -ne $req.p) { $req.p | ConvertTo-Json -Depth 8 -Compress } else { '{}' }
                $reply = ConvertTo-Reply (Invoke-Action -Act $act -Body $body)
            } catch {
                $reply = ConvertTo-Reply ([ordered]@{
                    ok    = $false
                    error = $_.Exception.Message
                    line  = if ($_.InvocationInfo) { "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" } else { '' }
                })
            }
            Write-Reply $reply -Writer $writer
        }
    } finally {
        try { $reader.Dispose() } catch { }
        try { $writer.Dispose() } catch { }
        try { $client.Close() } catch { }
    }
}

if ($Action -eq 'server') {
    Invoke-ServerLoop -Port $Port
    return
}

$result = $null
try {
    $result = Invoke-Action -Act $Action -Body $Payload
} catch {
    $result = [ordered]@{
        ok    = $false
        error = $_.Exception.Message
        line  = if ($_.InvocationInfo) { "$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" } else { '' }
    }
}

$json = ConvertTo-Reply $result
if ($OutFile) {
    [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
} else {
    Write-Output $json
}