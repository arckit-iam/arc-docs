#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\Publish-IamWefEvents.sample.json",
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$EventCatalog = @{
    "4720" = @{ eventType = "identity.created";       resourceType = "identity" }
    "4722" = @{ eventType = "identity.enabled";       resourceType = "identity" }
    "4725" = @{ eventType = "identity.disabled";      resourceType = "identity" }
    "4726" = @{ eventType = "identity.deleted";       resourceType = "identity" }
    "4727" = @{ eventType = "group.created";          resourceType = "group" }
    "4728" = @{ eventType = "group.member.added";     resourceType = "group" }
    "4729" = @{ eventType = "group.member.removed";   resourceType = "group" }
    "4730" = @{ eventType = "group.deleted";          resourceType = "group" }
    "4731" = @{ eventType = "group.created";          resourceType = "group" }
    "4732" = @{ eventType = "group.member.added";     resourceType = "group" }
    "4733" = @{ eventType = "group.member.removed";   resourceType = "group" }
    "4734" = @{ eventType = "group.deleted";          resourceType = "group" }
    "4738" = @{ eventType = "identity.changed";       resourceType = "identity" }
    "4754" = @{ eventType = "group.created";          resourceType = "group" }
    "4756" = @{ eventType = "group.member.added";     resourceType = "group" }
    "4757" = @{ eventType = "group.member.removed";   resourceType = "group" }
    "4758" = @{ eventType = "group.deleted";          resourceType = "group" }
    "4781" = @{ eventType = "identity.renamed";       resourceType = "identity" }
}

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )

    $stamp = (Get-Date).ToString("s")
    Write-Host "[$stamp] [$Level] $Message"
}

function Read-JsonConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-ObjectProperty {
    param(
        [object]$InputObject,
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $false
    }

    return $InputObject.PSObject.Properties.Name -contains $PropertyName
}

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Get-State {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ lastRecordId = 0 }
    }

    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return @{ lastRecordId = [long]$state.lastRecordId }
}

function Save-State {
    param(
        [string]$Path,
        [long]$LastRecordId
    )

    Ensure-Directory -Path $Path
    @{ lastRecordId = $LastRecordId } | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Sha256Hex {
    param([string]$InputString)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Convert-EventDataToMap {
    param([xml]$XmlDocument)

    $map = [ordered]@{}

    $nodes = $XmlDocument.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']")
    foreach ($node in $nodes) {
        $nameAttr = $node.Attributes["Name"]
        if ($null -eq $nameAttr) {
            continue
        }

        $name = [string]$nameAttr.Value
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $map[$name] = [string]$node.InnerText
    }

    return $map
}

function Get-EventNodeText {
    param(
        [xml]$XmlDocument,
        [string]$Path,
        [string]$AttributeName
    )

    $node = $XmlDocument.SelectSingleNode($Path)
    if ($null -eq $node) {
        return $null
    }

    if ($AttributeName) {
        $attribute = $node.Attributes[$AttributeName]
        if ($null -eq $attribute) {
            return $null
        }

        return [string]$attribute.Value
    }

    return [string]$node.InnerText
}

function Get-ParsedView {
    param(
        [string]$EventId,
        [hashtable]$EventData,
        [hashtable]$Metadata
    )

    $catalog = $EventCatalog[$EventId]
    $parsed = [ordered]@{
        eventType = $catalog.eventType
        actor = [ordered]@{
            login = $EventData["SubjectUserName"]
            domain = $EventData["SubjectDomainName"]
            sid = $EventData["SubjectUserSid"]
            logonId = $EventData["SubjectLogonId"]
        }
        target = [ordered]@{
            login = $EventData["TargetUserName"]
            domain = $EventData["TargetDomainName"]
            sid = $EventData["TargetSid"]
            oldLogin = $EventData["OldTargetUserName"]
            newLogin = $EventData["NewTargetUserName"]
        }
        group = [ordered]@{
            name = $EventData["TargetUserName"]
            domain = $EventData["TargetDomainName"]
            sid = $EventData["TargetSid"]
            scope = switch ($EventId) {
                { $_ -in @("4727","4728","4729","4730") } { "global"; break }
                { $_ -in @("4731","4732","4733","4734") } { "local"; break }
                { $_ -in @("4754","4756","4757","4758") } { "universal"; break }
                default { $null }
            }
        }
        member = [ordered]@{
            dn = $EventData["MemberName"]
            sid = $EventData["MemberSid"]
        }
        source = [ordered]@{
            computer = $Metadata.Computer
            channel = $Metadata.Channel
            provider = $Metadata.Provider
        }
    }

    return $parsed
}

function Convert-WefRecordToKafkaMessage {
    param(
        [System.Diagnostics.Eventing.Reader.EventRecord]$EventRecord,
        [pscustomobject]$Config
    )

    $rawXml = $EventRecord.ToXml()
    $xml = [xml]$rawXml

    # Prefer strongly-typed EventRecord properties to avoid XML namespace pitfalls.
    $eventId = [string]$EventRecord.Id
    $recordId = [long]$EventRecord.RecordId
    $computer = [string]$EventRecord.MachineName
    $channel = [string]$EventRecord.LogName
    $provider = [string]$EventRecord.ProviderName

    $timeCreated = $EventRecord.TimeCreated
    if ($null -eq $timeCreated) {
        $timeCreatedText = Get-EventNodeText -XmlDocument $xml -Path "/*[local-name()='Event']/*[local-name()='System']/*[local-name()='TimeCreated']" -AttributeName "SystemTime"
        if (-not [string]::IsNullOrWhiteSpace($timeCreatedText)) {
            $timeCreated = [datetime]$timeCreatedText
        }
    }

    if ($null -eq $timeCreated) {
        $timeCreated = [datetime]::UtcNow
    }
    $eventData = Convert-EventDataToMap -XmlDocument $xml
    $metadata = @{
        Computer = $computer
        Channel = $channel
        Provider = $provider
    }
    $catalog = $EventCatalog[[string]$eventId]
    if ($null -eq $catalog) {
        throw "Unsupported eventId '$eventId'"
    }
    $parsed = Get-ParsedView -EventId ([string]$eventId) -EventData $eventData -Metadata $metadata
    $nativeEventId = "$recordId@$computer"
    $truncated = $timeCreated.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $dedup = Get-Sha256Hex -InputString ($Config.source.sourceId + "|" + $nativeEventId + "|" + $truncated)

    $resourceRef = switch ($catalog.resourceType) {
        "identity" { if ($parsed.target.newLogin) { $parsed.target.newLogin } else { $parsed.target.login } }
        "group" { $parsed.group.name }
        default { $null }
    }

    $data = [ordered]@{
        sourceId = $Config.source.sourceId
        sourceType = $Config.source.sourceType
        nativeEventId = $nativeEventId
        nativeEventType = [string]$eventId
        detectedAt = $timeCreated.ToUniversalTime().ToString("o")
        deduplicationKey = $dedup
        resourceType = $catalog.resourceType
        resourceRef = $resourceRef
        system = [ordered]@{
            eventId = [int]$eventId
            recordId = $recordId
            timeCreated = $timeCreated.ToUniversalTime().ToString("o")
            computer = $computer
            channel = $channel
            provider = $provider
        }
        eventData = $eventData
        parsed = $parsed
        nativePayload = $rawXml
    }

    $message = [ordered]@{
        specversion = "1.0"
        id = [guid]::NewGuid().ToString()
        source = $Config.source.sourceId
        type = "com.instantaccessprovider.iam.raw.event"
        time = $timeCreated.ToUniversalTime().ToString("o")
        datacontenttype = "application/json"
        iamsourcetype = $Config.source.sourceType
        data = $data
    }

    return [ordered]@{
        Key = $dedup
        Json = $message | ConvertTo-Json -Depth 20 -Compress
        RecordId = $recordId
        EventId = [string]$eventId
    }
}

function Get-FilterXPath {
    param(
        [long]$LastRecordId,
        [int[]]$EventIds
    )

    $parts = foreach ($eventId in $EventIds) {
        "EventID=$eventId"
    }

    $idClause = ($parts -join " or ")
    return "*[System[(EventRecordID > $LastRecordId) and ($idClause)]]"
}

function Publish-WithRpk {
    param(
        [string]$RpkPath,
        [string[]]$RpkConfigOptions,
        [string]$Topic,
        [string]$Key,
        [string]$Json
    )

    if (-not (Test-Path -LiteralPath $RpkPath)) {
        throw "rpk executable not found: $RpkPath"
    }

    $args = @()
    foreach ($opt in $RpkConfigOptions) {
        $args += "-X"
        $args += $opt
    }
    $args += @("topic", "produce", $Topic, "-k", $Key, "-f", "%v\n", "-o", "")

    $result = $Json + [Environment]::NewLine | & $RpkPath @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "rpk publish failed: $result"
    }
}

function Publish-WithSshRpk {
    param(
        [string]$SshPath,
        [string]$SshHost,
        [string[]]$SshOptions,
        [string]$RemoteProduceCommand,
        [string]$Topic,
        [string]$Key,
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($SshPath)) {
        $SshPath = "ssh.exe"
    }

    if ([string]::IsNullOrWhiteSpace($SshHost)) {
        throw "kafka.sshHost is required for ssh-rpk mode"
    }

    if ([string]::IsNullOrWhiteSpace($RemoteProduceCommand)) {
        throw "kafka.remoteProduceCommand is required for ssh-rpk mode"
    }

    if ($null -eq $SshOptions -or $SshOptions.Count -eq 0) {
        # Non-interactive defaults so scheduled tasks fail fast instead of hanging on password prompts.
        $SshOptions = @(
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new"
        )
    }

    # The remote command reads one record from STDIN and produces it to Kafka.
    $remote = "$RemoteProduceCommand $Topic -k $Key -f '%v\\n' -o ''"
    $result = $Json + [Environment]::NewLine | & $SshPath @SshOptions $SshHost $remote 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ssh-rpk publish failed: $result"
    }
}

function Publish-KafkaMessage {
    param(
        [pscustomobject]$Config,
        [string]$Topic,
        [string]$Key,
        [string]$Json
    )

    $mode = "local-rpk"
    if ((Test-ObjectProperty -InputObject $Config -PropertyName "kafka") -and
        (Test-ObjectProperty -InputObject $Config.kafka -PropertyName "mode")) {
        $configuredMode = [string]$Config.kafka.mode
        if (-not [string]::IsNullOrWhiteSpace($configuredMode)) {
            $mode = $configuredMode
        }
    }

    switch ($mode) {
        "local-rpk" {
            Publish-WithRpk `
                -RpkPath $Config.kafka.rpkPath `
                -RpkConfigOptions $Config.kafka.rpkConfigOptions `
                -Topic $Topic `
                -Key $Key `
                -Json $Json
            break
        }
        "ssh-rpk" {
            Publish-WithSshRpk `
                -SshPath $Config.kafka.sshPath `
                -SshHost $Config.kafka.sshHost `
                -SshOptions $Config.kafka.sshOptions `
                -RemoteProduceCommand $Config.kafka.remoteProduceCommand `
                -Topic $Topic `
                -Key $Key `
                -Json $Json
            break
        }
        default {
            throw "Unsupported kafka.mode '$mode'. Allowed values: local-rpk, ssh-rpk"
        }
    }
}

function Invoke-CollectorLoop {
    param([pscustomobject]$Config)

    $channel = [string]$Config.source.channel
    $eventIds = [int[]]$Config.source.eventIds
    $maxEvents = [int]$Config.runtime.maxEventsPerPoll
    $pollSeconds = [int]$Config.runtime.pollIntervalSeconds

    Ensure-Directory -Path $Config.runtime.statePath
    $stateFileExists = Test-Path -LiteralPath $Config.runtime.statePath
    $state = Get-State -Path $Config.runtime.statePath
    $lastRecordId = [long]$state.lastRecordId

    $bootstrapToLatest = $true
    if (Test-ObjectProperty -InputObject $Config.runtime -PropertyName "bootstrapToLatestOnFirstRun") {
        $bootstrapToLatest = [bool]$Config.runtime.bootstrapToLatestOnFirstRun
    }

    if ((-not $stateFileExists) -and $bootstrapToLatest -and ($lastRecordId -le 0)) {
        $latest = Get-WinEvent -LogName $channel -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($null -ne $latest) {
            $lastRecordId = [long]$latest.RecordId
            Save-State -Path $Config.runtime.statePath -LastRecordId $lastRecordId
            Write-Log -Level "INFO" -Message "Bootstrap first run to latest recordId=$lastRecordId (set runtime.bootstrapToLatestOnFirstRun=false to replay history)"
        }
    }

    Write-Log -Level "INFO" -Message "Collector started channel=$channel lastRecordId=$lastRecordId topic=$($Config.kafka.topic)"

    do {
        $xpath = Get-FilterXPath -LastRecordId $lastRecordId -EventIds $eventIds
        Write-Log -Level "INFO" -Message "Polling channel=$channel fromRecordId>$lastRecordId"
        $events = @(Get-WinEvent -LogName $channel -FilterXPath $xpath -MaxEvents $maxEvents -Oldest -ErrorAction Stop)
        $eventCount = $events.Count
        if ($eventCount -eq 0) {
            Write-Log -Level "INFO" -Message "No matching IAM events in this poll"
        }

        foreach ($event in $events) {
            $message = Convert-WefRecordToKafkaMessage -EventRecord $event -Config $Config
            Publish-KafkaMessage -Config $Config -Topic $Config.kafka.topic -Key $message.Key -Json $message.Json
            $lastRecordId = [long]$message.RecordId
            Save-State -Path $Config.runtime.statePath -LastRecordId $lastRecordId
            Write-Log -Level "INFO" -Message ("Published eventId={0} recordId={1}" -f $message.EventId, $message.RecordId)
        }

        if (-not $Once) {
            Start-Sleep -Seconds $pollSeconds
        }
    } while (-not $Once)
}

$config = Read-JsonConfig -Path $ConfigPath
Invoke-CollectorLoop -Config $config