#Requires -Version 5.1
<#
.SYNOPSIS
    GUI tool to generate per-DC Azure Private DNS Conditional Forwarder scripts.
.DESCRIPTION
    Reads zone list from AzureDnsForwarders.zones.json (same folder).
    Generates one self-contained .ps1 per Domain Controller — no external config needed on the DC.
.NOTES
    Runs fully offline. Output scripts require DnsServer module + Domain Admin rights on the DC.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ─── Colours ──────────────────────────────────────────────────────────────────
$C = @{
    Bg        = [System.Drawing.Color]::FromArgb(242,242,240)
    Card      = [System.Drawing.Color]::White
    Border    = [System.Drawing.Color]::FromArgb(200,200,198)
    Accent    = [System.Drawing.Color]::FromArgb(55,138,221)
    AccentDk  = [System.Drawing.Color]::FromArgb(24,95,165)
    AccentTxt = [System.Drawing.Color]::FromArgb(12,68,124)
    Text      = [System.Drawing.Color]::FromArgb(26,26,26)
    Muted     = [System.Drawing.Color]::FromArgb(100,100,100)
    Red       = [System.Drawing.Color]::FromArgb(163,45,45)
    Green     = [System.Drawing.Color]::FromArgb(39,80,10)
}

# ─── Fonts ────────────────────────────────────────────────────────────────────
$F = @{
    UI    = New-Object System.Drawing.Font("Segoe UI", 9)
    Bold  = New-Object System.Drawing.Font("Segoe UI", 9,  [System.Drawing.FontStyle]::Bold)
    Small = New-Object System.Drawing.Font("Segoe UI", 8)
    Mono  = New-Object System.Drawing.Font("Consolas", 8.5)
    H1    = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    H2    = New-Object System.Drawing.Font("Segoe UI", 9,  [System.Drawing.FontStyle]::Bold)
}

# ─── Load zones from JSON ─────────────────────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir -or $scriptDir -eq "") { $scriptDir = (Get-Location).Path }
$zonesJsonPath = Join-Path $scriptDir "AzureDnsForwarders.zones.json"

$loadedZones = [System.Collections.Generic.List[hashtable]]::new()

if (Test-Path $zonesJsonPath) {
    try {
        $json = Get-Content $zonesJsonPath -Raw | ConvertFrom-Json
        foreach ($z in $json.zones) {
            $loadedZones.Add(@{ Name = $z.name; Label = $z.label; Enabled = [bool]$z.enabled; Custom = $false })
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not parse AzureDnsForwarders.zones.json:`n$($_.Exception.Message)`n`nUsing built-in defaults.",
            "Warning","OK","Warning") | Out-Null
    }
}

if ($loadedZones.Count -eq 0) {
    @(
        @{Name="privatelink.blob.core.windows.net";    Label="Storage — Blob";        Enabled=$true; Custom=$false},
        @{Name="privatelink.file.core.windows.net";    Label="Storage — File";        Enabled=$true; Custom=$false},
        @{Name="privatelink.queue.core.windows.net";   Label="Storage — Queue";       Enabled=$true; Custom=$false},
        @{Name="privatelink.table.core.windows.net";   Label="Storage — Table";       Enabled=$true; Custom=$false},
        @{Name="privatelink.database.windows.net";     Label="SQL Database";          Enabled=$true; Custom=$false},
        @{Name="privatelink.mongo.cosmos.azure.com";   Label="Cosmos DB (Mongo)";     Enabled=$true; Custom=$false},
        @{Name="privatelink.mysql.database.azure.com"; Label="MySQL";                 Enabled=$true; Custom=$false},
        @{Name="privatelink.vaultcore.azure.net";      Label="Key Vault";             Enabled=$true; Custom=$false},
        @{Name="privatelink.azurewebsites.net";        Label="App Service";           Enabled=$true; Custom=$false},
        @{Name="privatelink.azurecr.io";               Label="Container Registry";    Enabled=$true; Custom=$false}
    ) | ForEach-Object { $loadedZones.Add($_) }
}

function Import-ZonesFromFile {
    param([string]$Path)
    $loadedZones.Clear()
    try {
        $json = Get-Content $Path -Raw | ConvertFrom-Json
        foreach ($z in $json.zones) {
            $loadedZones.Add(@{ Name = $z.name; Label = $z.label; Enabled = [bool]$z.enabled; Custom = $false })
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not parse $([System.IO.Path]::GetFileName($Path)):`n$($_.Exception.Message)",
            "Warning","OK","Warning") | Out-Null
    }
}

function Update-ZonesFromMicrosoft {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $lblZoneSource.Text = "Downloading zone list from Microsoft Learn..."
    $form.Refresh()

    $discovered = [System.Collections.Specialized.OrderedDictionary]::new()

    # Primary: parse raw markdown from MicrosoftDocs GitHub repo
    $mdUrl = "https://raw.githubusercontent.com/MicrosoftDocs/azure-docs/main/articles/private-link/private-endpoint-dns.md"
    try {
        $md = (Invoke-WebRequest -Uri $mdUrl -UseBasicParsing -TimeoutSec 20).Content
        $inCommercial = $false; $resType = ""
        foreach ($line in ($md -split "`r?`n")) {
            if ($line -match '^##\s+Commercial')          { $inCommercial = $true;  continue }
            if ($line -match '^##\s+' -and $inCommercial) { break }
            if (-not $inCommercial) { continue }
            if ($line -match '^\|' -and $line -notmatch '^\|\s*[:\-]') {
                $cols = $line -split '\|' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
                if ($cols.Count -lt 3 -or $cols[0] -match 'Private link resource') { continue }
                $rt = ($cols[0] -replace '\s*\(Microsoft\.[^)]+\)', '').Trim()
                if ($rt -ne '') { $resType = $rt }
                [regex]::Matches($cols[2], 'privatelink\.[a-z][a-z0-9\.\-]*') | ForEach-Object {
                    $z = $_.Value.ToLower().TrimEnd('.')
                    if ($z -notmatch '\{' -and -not $discovered.Contains($z)) { $discovered[$z] = $resType }
                }
            }
        }
    } catch { }

    # Fallback: scrape the rendered Learn page for any privatelink zones
    if ($discovered.Count -eq 0) {
        try {
            $html = (Invoke-WebRequest -Uri "https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns" -UseBasicParsing -TimeoutSec 20).Content
            [regex]::Matches($html, 'privatelink\.[a-z][a-z0-9\.\-]{8,}') | ForEach-Object {
                $z = $_.Value.ToLower().TrimEnd('.')
                if ($z -notmatch '\{' -and -not $discovered.Contains($z)) { $discovered[$z] = $z }
            }
        } catch { }
    }

    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    if ($discovered.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not download or parse the zone list.`nCheck your internet connection and try again.",
            "Update Failed","OK","Error") | Out-Null
        $lblZoneSource.Text = "Update failed — using existing zones."
        return
    }

    # Add new zones (disabled by default); existing zones are left unchanged
    $added = 0
    foreach ($zoneName in $discovered.Keys) {
        if (-not ($loadedZones | Where-Object { $_.Name -eq $zoneName })) {
            $loadedZones.Add(@{ Name=$zoneName; Label=$discovered[$zoneName]; Enabled=$false; Custom=$false })
            $added++
        }
    }

    # Save updated JSON with UTF-8 BOM so PowerShell 5.1 reads it correctly
    $zonesArr = @($loadedZones | ForEach-Object { [ordered]@{ name=$_.Name; label=$_.Label; enabled=$_.Enabled } })
    $jsonText  = ([ordered]@{ zones = $zonesArr }) | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($zonesJsonPath, $jsonText, [System.Text.Encoding]::UTF8)

    Build-ZoneTree
    $lblZoneSource.Text = "Updated from Microsoft Learn ($([datetime]::Now.ToString('yyyy-MM-dd'))) — $($loadedZones.Count) zones, $added new"
    [System.Windows.Forms.MessageBox]::Show(
        "Zone list updated from Microsoft Learn.`n`nTotal zones : $($loadedZones.Count)`nNew zones added : $added`n`nNew zones are unchecked by default.",
        "Update Complete","OK","Information") | Out-Null
}

# ─── Helper: Label ────────────────────────────────────────────────────────────
function lbl {
    param($t,$x,$y,$w=260,$h=18,$f=$F.UI,$c=$C.Text,$a="MiddleLeft")
    $l = New-Object System.Windows.Forms.Label
    $l.Text=$t; $l.Location=[System.Drawing.Point]::new($x,$y)
    $l.Size=[System.Drawing.Size]::new($w,$h); $l.Font=$f
    $l.ForeColor=$c; $l.TextAlign=$a; $l.BackColor=[System.Drawing.Color]::Transparent
    $l
}

# ─── Helper: TextBox ──────────────────────────────────────────────────────────
function tbx {
    param($x,$y,$w=220,$h=24,$text="",$f=$F.UI)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location=[System.Drawing.Point]::new($x,$y); $t.Size=[System.Drawing.Size]::new($w,$h)
    $t.Font=$f; $t.Text=$text; $t.BorderStyle="FixedSingle"
    $t.BackColor=$C.Card; $t.ForeColor=$C.Text
    $t
}

# ─── Helper: Button ───────────────────────────────────────────────────────────
function btn {
    param($t,$x,$y,$w=110,$h=27,$primary=$false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text=$t; $b.Location=[System.Drawing.Point]::new($x,$y)
    $b.Size=[System.Drawing.Size]::new($w,$h); $b.FlatStyle="Flat"; $b.Cursor="Hand"
    if ($primary) {
        $b.Font=$F.Bold; $b.BackColor=$C.Accent; $b.ForeColor=[System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize=0
        $b.Add_MouseEnter({ $this.BackColor=$C.AccentDk }); $b.Add_MouseLeave({ $this.BackColor=$C.Accent })
    } else {
        $b.Font=$F.Small; $b.BackColor=$C.Card; $b.ForeColor=$C.Text
        $b.FlatAppearance.BorderSize=1; $b.FlatAppearance.BorderColor=$C.Border
        $b.Add_MouseEnter({ $this.BackColor=$C.Bg }); $b.Add_MouseLeave({ $this.BackColor=$C.Card })
    }
    $b
}

# ─── Helper: separator line ───────────────────────────────────────────────────
function sep { param($x,$y,$w)
    $s=New-Object System.Windows.Forms.Label
    $s.Location=[System.Drawing.Point]::new($x,$y); $s.Size=[System.Drawing.Size]::new($w,1)
    $s.BackColor=$C.Border; $s
}

# ══════════════════════════════════════════════════════════════════════════════
# FORM
# ══════════════════════════════════════════════════════════════════════════════
$form = New-Object System.Windows.Forms.Form
$form.Text = "Azure DNS Conditional Forwarder — Script Generator"
$form.ClientSize = [System.Drawing.Size]::new(980, 790)
$form.MinimumSize = [System.Drawing.Size]::new(980, 790)
$form.StartPosition = "CenterScreen"
$form.BackColor = $C.Bg; $form.Font = $F.UI

# ─── Blue header panel (docked top, fixed 68px) ───────────────────────────────
$hdr = New-Object System.Windows.Forms.Panel
$hdr.Dock="Top"; $hdr.Height=68; $hdr.BackColor=$C.Accent
$form.Controls.Add($hdr)

$hdrTitle = lbl "  Azure DNS Conditional Forwarder — Script Generator" 0 6 960 30 $F.H1 ([System.Drawing.Color]::White)
$hdrSub   = lbl "  Configure below and click Generate Scripts to create a ready-to-run PowerShell script per Domain Controller" 0 40 960 22 $F.Small ([System.Drawing.Color]::FromArgb(210,230,248))
$hdr.Controls.AddRange(@($hdrTitle,$hdrSub))

# ─── Bottom bar (docked bottom, fixed 54px) ───────────────────────────────────
$bot = New-Object System.Windows.Forms.Panel
$bot.Dock="Bottom"; $bot.Height=54; $bot.BackColor=$C.Card
$form.Controls.Add($bot)

$bot.Controls.Add((lbl "Output folder:" 14 17 100 22 $F.Bold $C.Text))
$tbOut = tbx 118 14 530 26 ([Environment]::GetFolderPath("Desktop")+"\AzureDnsForwarders") $F.UI
$bot.Controls.Add($tbOut)

$btnBrowse = btn "Browse..." 656 14 82 26
$btnBrowse.Add_Click({
    $d=New-Object System.Windows.Forms.FolderBrowserDialog
    $d.SelectedPath=$tbOut.Text
    if($d.ShowDialog()-eq"OK"){$tbOut.Text=$d.SelectedPath}
})
$bot.Controls.Add($btnBrowse)

$btnGen = btn "⚡  Generate Scripts" 748 10 218 36 $true
$btnGen.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$bot.Controls.Add($btnGen)

# ─── Scrollable content area ──────────────────────────────────────────────────
$scroll = New-Object System.Windows.Forms.Panel
$scroll.Dock="Fill"; $scroll.AutoScroll=$true; $scroll.BackColor=$C.Bg
$form.Controls.Add($scroll)

# ── Inner fixed-width panel inside scroll (so controls don't stretch) ─────────
$inner = New-Object System.Windows.Forms.Panel
$inner.Location=[System.Drawing.Point]::new(0,0)
$inner.Size=[System.Drawing.Size]::new(960,720)
$inner.BackColor=$C.Bg
$scroll.Controls.Add($inner)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1: Domain Controllers  (left card, top)
# ══════════════════════════════════════════════════════════════════════════════
$pDC = New-Object System.Windows.Forms.Panel
$pDC.Location=[System.Drawing.Point]::new(14,14)
$pDC.Size=[System.Drawing.Size]::new(456,270)
$pDC.BackColor=$C.Card; $pDC.BorderStyle="FixedSingle"
$inner.Controls.Add($pDC)

$pDC.Controls.Add((lbl "DOMAIN CONTROLLERS" 12 10 300 18 $F.H2 $C.AccentTxt))
$pDC.Controls.Add((lbl "One row per on-premise DC. Name is used for the output filename." 12 30 430 15 $F.Small $C.Muted))
$pDC.Controls.Add((sep 12 50 430))

# Column headers
$pDC.Controls.Add((lbl "DC Name  (filename)" 12 56 200 15 $F.Small $C.Muted))
$pDC.Controls.Add((lbl "DC IP  (optional)" 222 56 170 15 $F.Small $C.Muted))

# Scrollable rows sub-panel
$pDCRows = New-Object System.Windows.Forms.Panel
$pDCRows.Location=[System.Drawing.Point]::new(12,74)
$pDCRows.Size=[System.Drawing.Size]::new(430,150)
$pDCRows.BackColor=$C.Card; $pDCRows.AutoScroll=$true; $pDCRows.BorderStyle="None"
$pDC.Controls.Add($pDCRows)

$dcList = [System.Collections.Generic.List[hashtable]]::new()

function Render-DCs {
    $pDCRows.Controls.Clear(); $y=2
    for ($i=0;$i -lt $dcList.Count;$i++) {
        $idx=$i; $e=$dcList[$idx]
        $tn = tbx 0 $y 198 23 $e.Name $F.UI
        $tn.Add_TextChanged({ $dcList[$idx].Name=$tn.Text }.GetNewClosure())
        $ti = tbx 206 $y 168 23 $e.IP $F.Mono
        $ti.Add_TextChanged({ $dcList[$idx].IP=$ti.Text }.GetNewClosure())
        $td = New-Object System.Windows.Forms.Button
        $td.Text="✕"; $td.Location=[System.Drawing.Point]::new(382,$y)
        $td.Size=[System.Drawing.Size]::new(30,23); $td.Font=$F.Small
        $td.FlatStyle="Flat"; $td.ForeColor=$C.Red; $td.BackColor=$C.Card
        $td.FlatAppearance.BorderSize=1; $td.FlatAppearance.BorderColor=$C.Border
        $td.Cursor="Hand"
        $td.Add_Click({ if($dcList.Count-gt1){$dcList.RemoveAt($idx);Render-DCs} }.GetNewClosure())
        $pDCRows.Controls.AddRange(@($tn,$ti,$td)); $y+=27
    }
}

function Add-DC { $n=$dcList.Count+1; $dcList.Add(@{Name="DC0$n";IP=""}); Render-DCs }
Add-DC

$bAddDC = btn "+ Add Domain Controller" 12 234 200 26
$bAddDC.Add_Click({ Add-DC })
$pDC.Controls.Add($bAddDC)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2: Azure IPs + Scope  (right card, top)
# ══════════════════════════════════════════════════════════════════════════════
$pAZ = New-Object System.Windows.Forms.Panel
$pAZ.Location=[System.Drawing.Point]::new(484,14)
$pAZ.Size=[System.Drawing.Size]::new(462,270)
$pAZ.BackColor=$C.Card; $pAZ.BorderStyle="FixedSingle"
$inner.Controls.Add($pAZ)

$pAZ.Controls.Add((lbl "AZURE DC FORWARDER IPs" 12 10 380 18 $F.H2 $C.AccentTxt))
$pAZ.Controls.Add((lbl "Queries will be forwarded to these Azure Domain Controllers." 12 30 440 15 $F.Small $C.Muted))
$pAZ.Controls.Add((sep 12 50 436))

$pAZ.Controls.Add((lbl "Primary Azure DC IP" 12 58 220 15 $F.Small $C.Muted))
$tbIP1 = tbx 12 75 224 24 "10.0.1.36" $F.Mono
$pAZ.Controls.Add($tbIP1)

$pAZ.Controls.Add((lbl "Secondary Azure DC IP  (optional)" 12 108 240 15 $F.Small $C.Muted))
$tbIP2 = tbx 12 125 224 24 "10.0.1.37" $F.Mono
$pAZ.Controls.Add($tbIP2)

$pAZ.Controls.Add((sep 12 160 436))
$pAZ.Controls.Add((lbl "AD REPLICATION SCOPE" 12 168 300 18 $F.H2 $C.AccentTxt))

$rbDomain = New-Object System.Windows.Forms.RadioButton
$rbDomain.Text="Domain  (recommended — replicate to all DCs in the domain)"
$rbDomain.Location=[System.Drawing.Point]::new(12,190); $rbDomain.Size=[System.Drawing.Size]::new(436,20)
$rbDomain.Checked=$true; $rbDomain.BackColor=$C.Card; $rbDomain.Font=$F.UI

$rbForest = New-Object System.Windows.Forms.RadioButton
$rbForest.Text="Forest  (replicate to all DCs in the entire AD forest)"
$rbForest.Location=[System.Drawing.Point]::new(12,214); $rbForest.Size=[System.Drawing.Size]::new(436,20)
$rbForest.BackColor=$C.Card; $rbForest.Font=$F.UI

$rbNone = New-Object System.Windows.Forms.RadioButton
$rbNone.Text="None  (local DC only, not AD-replicated)"
$rbNone.Location=[System.Drawing.Point]::new(12,238); $rbNone.Size=[System.Drawing.Size]::new(436,20)
$rbNone.BackColor=$C.Card; $rbNone.Font=$F.UI

$pAZ.Controls.AddRange(@($rbDomain,$rbForest,$rbNone))

$lblSN = lbl "Zone will be replicated to all DCs in the domain via AD." 12 260 440 18 $F.Small $C.Muted
$pAZ.Controls.Add($lblSN)
$rbDomain.Add_CheckedChanged({ if($rbDomain.Checked){$lblSN.Text="Zone will be replicated to all DCs in the domain via AD."} })
$rbForest.Add_CheckedChanged({ if($rbForest.Checked){$lblSN.Text="Zone will be replicated to all DCs in the entire AD forest."} })
$rbNone.Add_CheckedChanged({   if($rbNone.Checked)  {$lblSN.Text="Zone is created only on the local DC. Not replicated via AD."} })

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3: Private DNS Zones  (full-width card, bottom)
# ══════════════════════════════════════════════════════════════════════════════
$pZones = New-Object System.Windows.Forms.Panel
$pZones.Location=[System.Drawing.Point]::new(14,298)
$pZones.Size=[System.Drawing.Size]::new(932,392)
$pZones.BackColor=$C.Card; $pZones.BorderStyle="FixedSingle"
$inner.Controls.Add($pZones)

$pZones.Controls.Add((lbl "PRIVATE DNS ZONES" 12 10 480 18 $F.H2 $C.AccentTxt))

$bUpdateZones = btn "↻  Update zones from Microsoft" 502 6 410 26
$bUpdateZones.Add_Click({ Update-ZonesFromMicrosoft })
$pZones.Controls.Add($bUpdateZones)

$zoneSource = if (Test-Path $zonesJsonPath) { "Loaded from AzureDnsForwarders.zones.json — edit that file or load a custom one below." } else { "Using built-in defaults (AzureDnsForwarders.zones.json not found next to the script)." }
$lblZoneSource = lbl $zoneSource 12 30 900 15 $F.Small $C.Muted
$pZones.Controls.Add($lblZoneSource)
$pZones.Controls.Add((sep 12 50 906))

# ── Category map ──────────────────────────────────────────────────────────────
$zoneCatMap = @{
    "privatelink.blob.core.windows.net"             = "Storage"
    "privatelink.file.core.windows.net"             = "Storage"
    "privatelink.queue.core.windows.net"            = "Storage"
    "privatelink.table.core.windows.net"            = "Storage"
    "privatelink.dfs.core.windows.net"              = "Storage"
    "privatelink.web.core.windows.net"              = "Storage"
    "privatelink.database.windows.net"              = "Databases"
    "privatelink.documents.azure.com"               = "Databases"
    "privatelink.mongo.cosmos.azure.com"            = "Databases"
    "privatelink.cassandra.cosmos.azure.com"        = "Databases"
    "privatelink.gremlin.cosmos.azure.com"          = "Databases"
    "privatelink.table.cosmos.azure.com"            = "Databases"
    "privatelink.mysql.database.azure.com"          = "Databases"
    "privatelink.postgres.database.azure.com"       = "Databases"
    "privatelink.mariadb.database.azure.com"        = "Databases"
    "privatelink.vaultcore.azure.net"               = "Security"
    "privatelink.managedhsm.azure.net"              = "Security"
    "privatelink.azurewebsites.net"                 = "App Services & Containers"
    "privatelink.azurecr.io"                        = "App Services & Containers"
    "privatelink.azurestaticapps.net"               = "App Services & Containers"
    "privatelink.azurecontainerapps.io"             = "App Services & Containers"
    "privatelink.servicebus.windows.net"            = "Integration"
    "privatelink.eventgrid.azure.net"               = "Integration"
    "privatelink.azure-automation.net"              = "Management & Monitoring"
    "privatelink.agentsvc.azure-automation.net"     = "Management & Monitoring"
    "privatelink.monitor.azure.com"                 = "Management & Monitoring"
    "privatelink.oms.opinsights.azure.com"          = "Management & Monitoring"
    "privatelink.ods.opinsights.azure.com"          = "Management & Monitoring"
    "privatelink.cognitiveservices.azure.com"       = "AI & Cognitive"
    "privatelink.openai.azure.com"                  = "AI & Cognitive"
    "privatelink.search.windows.net"                = "AI & Cognitive"
    "privatelink.redis.cache.windows.net"           = "Data & Analytics"
    "privatelink.redisenterprise.cache.azure.net"   = "Data & Analytics"
    "privatelink.sql.azuresynapse.net"              = "Data & Analytics"
    "privatelink.dev.azuresynapse.net"              = "Data & Analytics"
    "privatelink.azuresynapse.net"                  = "Data & Analytics"
    "privatelink.datafactory.azure.net"             = "Data & Analytics"
    "privatelink.adf.azure.com"                     = "Data & Analytics"
    "privatelink.purview.azure.com"                 = "Data & Analytics"
    "privatelink.purviewstudio.azure.com"           = "Data & Analytics"
    "privatelink.digitaltwins.azure.net"            = "IoT & Digital Twins"
    "privatelink.azure-devices.net"                 = "IoT & Digital Twins"
    "privatelink.azure-devices-provisioning.net"    = "IoT & Digital Twins"
    "privatelink.api.azureml.ms"                    = "ML & HDInsight"
    "privatelink.notebooks.azure.net"               = "ML & HDInsight"
    "privatelink.azurehdinsight.net"                = "ML & HDInsight"
    "privatelink.media.azure.net"                   = "Other"
    "privatelink.azconfig.io"                       = "Other"
    "privatelink.signalr.net"                       = "Other"
    "privatelink.webpubsub.azure.com"               = "Other"
    "privatelink.workspace.azurehealthcareapis.com" = "Other"
    "privatelink.backup.windowsazure.com"           = "Other"
    "privatelink.siterecovery.windowsazure.com"     = "Other"
}

# ── TreeView ──────────────────────────────────────────────────────────────────
$tv = New-Object System.Windows.Forms.TreeView
$tv.Location   = [System.Drawing.Point]::new(12, 56)
$tv.Size       = [System.Drawing.Size]::new(906, 288)
$tv.Font       = $F.Mono
$tv.BackColor  = $C.Card
$tv.BorderStyle= "None"
$tv.CheckBoxes = $true
$tv.ShowLines  = $false
$tv.ShowPlusMinus = $true
$tv.ItemHeight = 22
$pZones.Controls.Add($tv)

$script:tvLock = $false
$tv.Add_AfterCheck({
    param($s,$e)
    if ($script:tvLock) { return }
    if ($e.Node.Level -eq 0) {
        $script:tvLock = $true
        foreach ($child in $e.Node.Nodes) { $child.Checked = $e.Node.Checked }
        $script:tvLock = $false
    }
})

function Build-ZoneTree {
    # Persist current check states back into $loadedZones before rebuilding
    foreach ($catNode in $tv.Nodes) {
        foreach ($leaf in $catNode.Nodes) {
            $tag = $leaf.Tag
            $entry = $loadedZones | Where-Object { $_.Name -eq $tag } | Select-Object -First 1
            if ($entry) { $entry['Enabled'] = $leaf.Checked }
        }
    }

    $script:tvLock = $true
    $tv.BeginUpdate(); $tv.Nodes.Clear()

    $groups = [System.Collections.Specialized.OrderedDictionary]::new()
    foreach ($z in $loadedZones) {
        $cat = if ($zoneCatMap.ContainsKey($z.Name)) { $zoneCatMap[$z.Name] } else { "Custom" }
        if (-not $groups.Contains($cat)) { $groups[$cat] = [System.Collections.Generic.List[hashtable]]::new() }
        $groups[$cat].Add($z)
    }

    foreach ($cat in $groups.Keys) {
        $zones       = $groups[$cat]
        $onCount     = @($zones | Where-Object { $_.Enabled }).Count
        $catNode     = New-Object System.Windows.Forms.TreeNode("  $cat  ($onCount / $($zones.Count))")
        $catNode.NodeFont   = $F.Bold
        $catNode.ForeColor  = $C.AccentTxt
        $catNode.Checked    = ($onCount -eq $zones.Count -and $zones.Count -gt 0)

        foreach ($z in $zones) {
            $leaf = New-Object System.Windows.Forms.TreeNode("  $($z.Name)   [$($z.Label)]")
            $leaf.Tag      = $z.Name
            $leaf.Checked  = $z.Enabled
            $leaf.ForeColor= if ($z.Custom) { $C.AccentDk } else { $C.Text }
            $catNode.Nodes.Add($leaf) | Out-Null
        }

        if ($onCount -gt 0) { $catNode.Expand() }
        $tv.Nodes.Add($catNode) | Out-Null
    }

    $tv.EndUpdate()
    $script:tvLock = $false
}
Build-ZoneTree

# ── Toolbar ───────────────────────────────────────────────────────────────────
$bSelAll = btn "Select All" 12 354 90 26
$bSelAll.Add_Click({
    $script:tvLock = $true
    foreach ($cat in $tv.Nodes) {
        $cat.Checked = $true
        foreach ($leaf in $cat.Nodes) { $leaf.Checked = $true }
    }
    $script:tvLock = $false
})
$pZones.Controls.Add($bSelAll)

$bSelNone = btn "Select None" 108 354 90 26
$bSelNone.Add_Click({
    $script:tvLock = $true
    foreach ($cat in $tv.Nodes) {
        $cat.Checked = $false
        foreach ($leaf in $cat.Nodes) { $leaf.Checked = $false }
    }
    $script:tvLock = $false
})
$pZones.Controls.Add($bSelNone)

$pZones.Controls.Add((lbl "Add custom zone:" 210 358 112 20 $F.Small $C.Muted "MiddleLeft"))
$tbCZ = tbx 326 355 260 26 "" $F.Mono
$pZones.Controls.Add($tbCZ)

$bAddZ = btn "+ Add" 592 355 68 26
$bAddZ.Add_Click({
    $z = $tbCZ.Text.Trim().ToLower()
    if ($z -eq "" -or ($loadedZones | Where-Object { $_.Name -eq $z })) { return }
    $loadedZones.Add(@{ Name=$z; Label="custom"; Enabled=$true; Custom=$true })
    $tbCZ.Text = ""; Build-ZoneTree
})
$pZones.Controls.Add($bAddZ)

$bLoadJson = btn "Load zones from file..." 666 355 218 26
$bLoadJson.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Select zones JSON file"
    $dlg.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    $dlg.InitialDirectory = $scriptDir
    if ($dlg.ShowDialog() -eq "OK") {
        Import-ZonesFromFile $dlg.FileName
        if ($loadedZones.Count -gt 0) {
            $lblZoneSource.Text = "Loaded from: $([System.IO.Path]::GetFileName($dlg.FileName))"
            Build-ZoneTree
        }
    }
})
$pZones.Controls.Add($bLoadJson)

# Status label
$lblStatus = lbl "" 14 700 932 20 $F.Small $C.Muted "MiddleLeft"
$lblStatus.BackColor=$C.Bg
$inner.Controls.Add($lblStatus)

# ══════════════════════════════════════════════════════════════════════════════
# GENERATION  — one self-contained .ps1 per DC, zones embedded
# ══════════════════════════════════════════════════════════════════════════════
function Get-Scope {
    if($rbDomain.Checked){"Domain"} elseif($rbForest.Checked){"Forest"} else{""}
}

function Write-DCScript {
    param($OutDir, $DC, $Zones, $IP1, $IP2, $Scope)

    $safe = $DC.Name -replace '[^a-zA-Z0-9_\-]','_'
    $dcInfo = if($DC.IP-ne""){"$($DC.Name) ($($DC.IP))"}else{$DC.Name}
    $ipsArr = if($IP2-ne""){"@(`"$IP1`",`"$IP2`")"}else{"@(`"$IP1`")"}

    $zoneLines = $Zones | ForEach-Object {
        "    `"$($_.Name)`""
    }
    $scopeLine   = if($Scope-ne""){"`"$Scope`""}else{"`"`""}
    $scopeApply  = if($Scope-ne""){"    if (`$Scope) { `$p['ReplicationScope'] = `$Scope }"}else{"    # No AD replication"}

    $content = @"
#Requires -Modules DnsServer
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Apply Azure Private DNS conditional forwarders — $dcInfo
.DESCRIPTION
    Creates or updates conditional forwarder zones for Azure Private DNS on this DC.
    All zone and forwarder configuration is embedded in this script.

    Target DC  : $dcInfo
    Scope      : $(if($Scope-ne""){"AD-integrated — $Scope"}else{"Local DC only (not AD-replicated)"})
    Generated  : $(Get-Date -Format 'yyyy-MM-dd HH:mm')
    Reference  : https://learn.microsoft.com/azure/private-link/private-endpoint-dns-integration

.NOTES
    Run as Domain Administrator directly on the target Domain Controller.
    Exit code 0 = success, 1 = one or more zones failed.
#>
[CmdletBinding(SupportsShouldProcess)]
param()

# ── Embedded configuration ────────────────────────────────────────────────────
`$MasterServers = $ipsArr
`$Scope         = $scopeLine
`$Zones         = @(
$($zoneLines -join "`r`n")
)

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-OK   { param(`$m) Write-Host "  [OK]   `$m" -ForegroundColor Green }
function Write-SKIP { param(`$m) Write-Host "  [--]   `$m" -ForegroundColor Yellow }
function Write-FAIL { param(`$m) Write-Host "  [ERR]  `$m" -ForegroundColor Red }

# ── Banner ────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  Azure Private DNS - Conditional Forwarder Setup" -ForegroundColor Cyan
Write-Host "  ------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Target DC      : $dcInfo" -ForegroundColor White
Write-Host "  Forwarder IPs  : `$(`$MasterServers -join ', ')" -ForegroundColor White
Write-Host "  Scope          : `$(if(`$Scope){"AD-integrated - `$Scope"}else{"Local DC only"})" -ForegroundColor White
Write-Host "  Zones          : `$(`$Zones.Count)" -ForegroundColor White
Write-Host ""

# ── Connectivity check ────────────────────────────────────────────────────────
Write-Host "  Checking port 53 connectivity to Azure DC forwarders..." -ForegroundColor Gray
foreach (`$ip in `$MasterServers) {
    `$r = Test-NetConnection -ComputerName `$ip -Port 53 -WarningAction SilentlyContinue -InformationLevel Quiet
    if (`$r) { Write-OK "Reachable: `$ip`:53" }
    else     { Write-FAIL "Cannot reach `$ip`:53  - check VPN/ExpressRoute/firewall" }
}
Write-Host ""

# ── Apply zones ───────────────────────────────────────────────────────────────
`$created=0; `$updated=0; `$failed=0

foreach (`$zoneName in `$Zones) {
    `$existing = Get-DnsServerZone -Name `$zoneName -ErrorAction SilentlyContinue

    if (`$existing) {
        try {
            `$p = @{ Name=`$zoneName; MasterServers=`$MasterServers; ErrorAction='Stop' }
$scopeApply
            Set-DnsServerConditionalForwarderZone @p
            Write-SKIP "`$zoneName  (updated)"
            `$updated++
        } catch { Write-FAIL "`$zoneName - `$(`$_.Exception.Message)"; `$failed++ }
    } else {
        try {
            `$p = @{ Name=`$zoneName; MasterServers=`$MasterServers; PassThru=`$true; ErrorAction='Stop' }
$scopeApply
            `$null = Add-DnsServerConditionalForwarderZone @p
            Write-OK `$zoneName
            `$created++
        } catch { Write-FAIL "`$zoneName - `$(`$_.Exception.Message)"; `$failed++ }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Created : `$created zone(s)" -ForegroundColor Green
Write-Host "  Updated : `$updated zone(s)" -ForegroundColor Yellow
Write-Host "  Failed  : `$failed zone(s)"  -ForegroundColor `$(if(`$failed-gt 0){'Red'}else{'Gray'})
Write-Host ""

Get-DnsServerZone |
    Where-Object { `$_.ZoneType -eq 'Forwarder' } |
    Sort-Object ZoneName |
    Select-Object ZoneName, MasterServers, IsDsIntegrated, ReplicationScope |
    Format-Table -AutoSize

if (`$failed -gt 0) { exit 1 } else { exit 0 }
"@
    $path = Join-Path $OutDir "Apply-AzureDnsForwarders_${safe}.ps1"
    $content | Set-Content -Path $path -Encoding UTF8
    return $path
}

# ── Generate button click ──────────────────────────────────────────────────────
$btnGen.Add_Click({
    $lblStatus.ForeColor=$C.Muted; $lblStatus.Text=""

    $ip1=$tbIP1.Text.Trim(); $ip2=$tbIP2.Text.Trim()
    if($ip1 -notmatch '^\d{1,3}(\.\d{1,3}){3}$'){
        [System.Windows.Forms.MessageBox]::Show("Enter a valid primary Azure DC IP.","Validation","OK","Warning")|Out-Null; return}
    if($ip2-ne""-and $ip2 -notmatch '^\d{1,3}(\.\d{1,3}){3}$'){
        [System.Windows.Forms.MessageBox]::Show("Secondary IP is not a valid IPv4 address.","Validation","OK","Warning")|Out-Null; return}

    $selZones = @($tv.Nodes | ForEach-Object {
        $_.Nodes | Where-Object { $_.Checked } | ForEach-Object {
            $tag = $_.Tag; $loadedZones | Where-Object { $_.Name -eq $tag }
        }
    })
    if($selZones.Count-eq 0){
        [System.Windows.Forms.MessageBox]::Show("Select at least one DNS zone.","Validation","OK","Warning")|Out-Null; return}

    $validDCs=@($dcList|Where-Object{$_.Name.Trim()-ne""})
    if($validDCs.Count-eq 0){
        [System.Windows.Forms.MessageBox]::Show("Add at least one Domain Controller.","Validation","OK","Warning")|Out-Null; return}

    $outDir=$tbOut.Text.Trim()
    if($outDir-eq""){
        [System.Windows.Forms.MessageBox]::Show("Specify an output folder.","Validation","OK","Warning")|Out-Null; return}
    if(-not(Test-Path $outDir)){New-Item -ItemType Directory -Path $outDir -Force|Out-Null}

    $scope=Get-Scope
    $written=[System.Collections.Generic.List[string]]::new()

    try {
        foreach($dc in $validDCs){
            $p=Write-DCScript -OutDir $outDir -DC $dc -Zones $selZones -IP1 $ip1 -IP2 $ip2 -Scope $scope
            $written.Add([System.IO.Path]::GetFileName($p))
        }
        $msg="Generated $($written.Count) script(s) in:`n$outDir`n`n"+($written-join"`n")+"`n`nOpen output folder?"
        $r=[System.Windows.Forms.MessageBox]::Show($msg,"Done!","YesNo","Information")
        if($r-eq"Yes"){Start-Process explorer.exe $outDir}
        $lblStatus.ForeColor=$C.Green
        $lblStatus.Text="  OK  $($written.Count) script(s) written to: $outDir"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error:`n$($_.Exception.Message)","Error","OK","Error")|Out-Null
        $lblStatus.ForeColor=$C.Red
        $lblStatus.Text="  Error: $($_.Exception.Message)"
    }
})

$form.Add_Shown({ $form.Activate() })
[System.Windows.Forms.Application]::Run($form)
