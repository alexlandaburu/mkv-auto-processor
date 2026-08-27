#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURACION
# ============================================================
$script:MkvMergePath = "D:\mkvtoolnix\mkvmerge.exe"
$script:ChromePath = ""
$script:DebugPort = 9222
$script:DownloadDir = Join-Path $env:TEMP "MKV_Auto_SubtitlesTranslator_Downloads"
$script:SiteUrl = "https://subtitlestranslator.com/es/"
$script:TargetUrlHint = "subtitlestranslator.com"

# ============================================================
# UTILIDADES
# ============================================================
function Find-Chrome {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

if ([string]::IsNullOrWhiteSpace($script:ChromePath)) {
    $script:ChromePath = Find-Chrome
}

function Show-Error($msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, "MKV Auto Processor", "OK", "Error") | Out-Null
}
function Show-Info($msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, "MKV Auto Processor", "OK", "Information") | Out-Null
}
function Log($msg) {
    if ($script:txtLog) {
        $script:txtLog.AppendText([string]$msg + "`r`n")
        $script:txtLog.SelectionStart = $script:txtLog.Text.Length
        $script:txtLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Ensure-Tools {
    if (!(Test-Path -LiteralPath $script:MkvMergePath)) {
        throw "No se encuentra mkvmerge.exe:`r`n$($script:MkvMergePath)`r`n`r`nPuedes cambiar la ruta en la parte CONFIGURACION del .ps1."
    }
    if ([string]::IsNullOrWhiteSpace($script:ChromePath) -or !(Test-Path -LiteralPath $script:ChromePath)) {
        throw "No se encuentra Google Chrome. El programa necesita Chrome para automatizar Subtitles Translator."
    }
    if (!(Test-Path -LiteralPath $script:DownloadDir)) {
        New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
    }
}

# ============================================================
# CHROME + CDP
# ============================================================
$script:ChromeProcess = $null
$script:Ws = $null
$script:NextCdpId = 0

function Http-Get($url) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    try { return $wc.DownloadString($url) } finally { $wc.Dispose() }
}

function Start-Chrome {
    $profile = Join-Path $script:DownloadDir "ChromeProfile"
    New-Item -ItemType Directory -Path $profile -Force | Out-Null

    try {
        $targets = @(Http-Get "http://127.0.0.1:$($script:DebugPort)/json/list" | ConvertFrom-Json)
        $page = @($targets | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } | Select-Object -First 1)
        if ($page) { return }
    } catch {}

    Log "[Chrome] Iniciando Chrome con puerto de depuración $($script:DebugPort)..."
    $args = "--remote-debugging-port=$($script:DebugPort) --user-data-dir=`"$profile`" --no-first-run --no-default-browser-check --start-maximized `"$($script:SiteUrl)`""
    $script:ChromeProcess = Start-Process -FilePath $script:ChromePath -ArgumentList $args -PassThru

    $ok = $false
    for ($i=0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $t = @(Http-Get "http://127.0.0.1:$($script:DebugPort)/json/list" | ConvertFrom-Json)
            $page = @($t | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } | Select-Object -First 1)
            if ($page) { $ok = $true; break }
        } catch {}
    }
    if (!$ok) { throw "No se pudo iniciar Chrome con el puerto de automatización $($script:DebugPort)." }
    Log "[Chrome] Chrome iniciado correctamente."
}

function Get-PageTarget {
    $json = Http-Get "http://127.0.0.1:$($script:DebugPort)/json/list"
    $items = @($json | ConvertFrom-Json)
    $page = @($items | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl -and $_.url -match $script:TargetUrlHint } | Select-Object -First 1)
    if (!$page) {
        $page = @($items | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } | Select-Object -First 1)
    }
    if (!$page) { throw "No se encontró una pestaña de Chrome controlable." }
    return $page
}

function Connect-Cdp {
    Log "[CDP] Conectando a Chrome DevTools Protocol..."
    $page = Get-PageTarget
    $script:Ws = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = New-Object System.Uri($page.webSocketDebuggerUrl)
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(15000)
    $script:Ws.ConnectAsync($uri, $cts.Token).GetAwaiter().GetResult()
    if ($script:Ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw "No se pudo conectar al Chrome DevTools Protocol."
    }
    Log "[CDP] Conexión establecida."
}

function Receive-WebSocketMessage {
    $buffer = New-Object byte[] 65536
    $ms = New-Object System.IO.MemoryStream
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(30000)
    do {
        $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)
        $r = $script:Ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
        if ($r.Count -gt 0) { $ms.Write($buffer, 0, $r.Count) }
    } while (-not $r.EndOfMessage)
    $txt = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $ms.Dispose()
    return $txt
}

function Send-Cdp($method, $params) {
    $script:NextCdpId++
    $id = $script:NextCdpId
    $obj = [ordered]@{ id = $id; method = $method }
    if ($null -ne $params) { $obj.params = $params }
    $json = $obj | ConvertTo-Json -Compress -Depth 20
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)

    $sendCts = New-Object System.Threading.CancellationTokenSource
    $sendCts.CancelAfter(15000)
    try {
        $script:Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $sendCts.Token).GetAwaiter().GetResult() | Out-Null
    } finally {
        $sendCts.Dispose()
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $raw = Receive-WebSocketMessage
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $resp = $raw | ConvertFrom-Json
            if ($null -ne $resp.id -and ([int64]$resp.id) -eq ([int64]$id)) {
                return $resp
            }
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) { break }
        }
    }
    throw "Chrome no respondió al comando CDP: $method"
}

function Eval-Js($expression) {
    $r = Send-Cdp "Runtime.evaluate" @{
        expression = $expression
        returnByValue = $true
        awaitPromise = $false
    }
    if ($r.error) { throw ("CDP Runtime.evaluate: " + ($r.error | ConvertTo-Json -Compress)) }
    if ($r.result.exceptionDetails) {
        throw ("JavaScript: " + ($r.result.exceptionDetails.text))
    }
    if ($r.result.result -and $r.result.result.value) { return $r.result.result.value }
    return $null
}

function Navigate($url) {
    Log "[Navigate] Abriendo Subtitles Translator..."
    Send-Cdp "Page.navigate" @{ url = $url } | Out-Null
    $loaded = $false
    for($i=0;$i -lt 60;$i++) {
        try {
            $href = Eval-Js "location.href"
            if($href -and $href -match 'subtitlestranslator\.com') { $loaded=$true; break }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    if(!$loaded) { throw "Chrome no ha cargado Subtitles Translator." }
    Wait-PageReady
}

function Wait-PageReady {
    Log "[Page] Esperando a que la página esté lista..."
    for ($i=0; $i -lt 120; $i++) {
        try {
            $state = Eval-Js "document.readyState"
            $hasBody = Eval-Js "!!document.body"
            if($hasBody -eq $true -and ($state -eq "complete" -or $state -eq "interactive")) {
                Start-Sleep -Milliseconds 700
                Log "[Page] Página lista."
                return
            }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    throw "La página de Subtitles Translator no terminó de cargar."
}

function Wait-ForText($text, $timeoutSec = 30) {
    $needle = $text.ToLowerInvariant()
    $steps = [int]($timeoutSec * 4)
    for ($i=0; $i -lt $steps; $i++) {
        try {
            $found = Eval-Js @"
(function(){
  var n = "$($needle.Replace('\','\\').Replace('"','\"'))";
  return document.body && document.body.innerText.toLowerCase().indexOf(n) >= 0;
})()
"@
            if ($found -eq $true) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Click-ByText($patterns, $timeoutSec = 20) {
    $jsPatterns = ($patterns | ForEach-Object { '"' + ($_.ToLowerInvariant().Replace('\','\\').Replace('"','\"')) + '"' }) -join ","
    $js = @"
(function(){
  var pats = [$jsPatterns];
  var els = Array.from(document.querySelectorAll('button,input[type=button],input[type=submit],a,[role=button],div'));
  function visible(e){ var r=e.getBoundingClientRect(); return r.width>0 && r.height>0; }
  function txt(e){ return ((e.innerText||e.value||e.getAttribute('aria-label')||e.title||'')+'').trim().toLowerCase(); }
  for (var i=0;i<els.length;i++){
    if (!visible(els[i])) continue;
    var t=txt(els[i]);
    for (var j=0;j<pats.length;j++){
      if (t===pats[j] || t.indexOf(pats[j])>=0){
        els[i].click();
        return {ok:true,text:t};
      }
    }
  }
  return {ok:false};
})()
"@
    for ($i=0; $i -lt ($timeoutSec*4); $i++) {
        $r = Eval-Js $js
        if ($r -and $r.ok) { return $r }
        Start-Sleep -Milliseconds 250
    }
    throw "No se encontró el botón/enlace: $($patterns -join ' / ')"
}

function Close-StartupDonationPopup {
    Log "[Popup] Cerrando popup de donación si existe..."
    $js = @"
(function(){
  var els=Array.from(document.querySelectorAll('button,a,[role=button],input[type=button],[aria-label*=close],[aria-label*=cerrar]'));
  for(var i=0;i<els.length;i++){
    var e=els[i], r=e.getBoundingClientRect();
    if(r.width<=0 || r.height<=0) continue;
    var t=((e.innerText||e.value||e.getAttribute('aria-label')||e.title||'')+'').trim().toLowerCase();
    if(t==='x' || t==='×' || t==='cerrar' || t==='close'){ 
      e.click(); 
      return true; 
    }
  }
  return false;
})()
"@
    try { [void](Eval-Js $js) } catch {}
    Start-Sleep -Milliseconds 500
}

function Set-FileInput($filePath) {
    Log "[Upload] Buscando input de archivo..."
    $doc = Send-Cdp "DOM.getDocument" @{ depth = -1; pierce = $true }
    $rootId = $doc.result.root.nodeId

    $q = Send-Cdp "DOM.querySelector" @{ nodeId = $rootId; selector = "input[type=file]" }
    if (!$q.result.nodeId) {
        Log "[Upload] Input no encontrado, pulsando botón AÑADIR..."
        try { Click-ByText @("+ AÑADIR","AÑADIR","SUBIR","UPLOAD") 10 | Out-Null } catch {}
        Start-Sleep -Milliseconds 500
        $doc = Send-Cdp "DOM.getDocument" @{ depth = -1; pierce = $true }
        $rootId = $doc.result.root.nodeId
        $q = Send-Cdp "DOM.querySelector" @{ nodeId = $rootId; selector = "input[type=file]" }
    }

    if (!$q.result.nodeId) { throw "No se encontró el selector de archivos de Subtitles Translator." }

    Log "[Upload] Input encontrado, subiendo archivo..."
    Send-Cdp "DOM.setFileInputFiles" @{
        nodeId = $q.result.nodeId
        files = @($filePath)
    } | Out-Null
    Log "[Upload] Archivo subido."
}

function Set-DownloadBehavior {
    try {
        Send-Cdp "Browser.setDownloadBehavior" @{
            behavior = "allow"
            downloadPath = $script:DownloadDir
        } | Out-Null
    } catch {
        try {
            Send-Cdp "Page.setDownloadBehavior" @{
                behavior = "allow"
                downloadPath = $script:DownloadDir
            } | Out-Null
        } catch {}
    }
}

function Wait-NewZip($before, $timeoutSec = 120) {
    Log "[Download] Esperando descarga del ZIP (máximo $timeoutSec segundos)..."
    $startTime = Get-Date
    for ($i=0; $i -lt ($timeoutSec*2); $i++) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($i % 8 -eq 0) {
            Log "[Download] Esperando... ${elapsed:F0}s / ${timeoutSec}s"
        }
        
        $zips = @(Get-ChildItem -LiteralPath $script:DownloadDir -Filter "*.zip" -File -ErrorAction SilentlyContinue)
        foreach ($z in $zips) {
            if ($before -notcontains $z.FullName -and $z.Length -gt 0) {
                Log "[Download] ZIP encontrado: $($z.Name) ($($z.Length) bytes)"
                return $z.FullName
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "No se detectó el ZIP descargado después de $timeoutSec segundos."
}

function Get-TranslatedSubtitleFromZip($zipPath, $sourceSubtitle) {
    $extractDir = Join-Path $script:DownloadDir ("Extract_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Log "[Extract] Extrayendo ZIP: $zipPath"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $files = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File)
    if ($files.Count -eq 0) { throw "El ZIP descargado no contiene ningún archivo." }

    $subs = @($files | Where-Object { $_.Extension.ToLowerInvariant() -in @(".ass",".ssa",".srt",".vtt",".stl",".sbv",".sub") })
    if ($subs.Count -eq 0) { throw "El ZIP no contiene un subtítulo reconocido." }

    $preferredBase = [System.IO.Path]::GetFileNameWithoutExtension($sourceSubtitle).ToLowerInvariant()
    $sameBase = @($subs | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name).ToLowerInvariant() -eq $preferredBase })
    if ($sameBase.Count -gt 0) { 
        $result = ($sameBase | Select-Object -First 1).FullName
        Log "[Extract] Subtítulo encontrado: $result"
        return $result 
    }

    $result = ($subs | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    Log "[Extract] Subtítulo más reciente: $result"
    return $result
}

function Add-SubtitleToMkv($mkv, $subtitle, $output) {
    Log "[Merge] Añadiendo subtítulo traducido al MKV..."
    $args = @(
        "--output", $output,
        $mkv,
        "--language", "0:es",
        "--track-name", "0:Español",
        $subtitle
    )
    $p = Start-Process -FilePath $script:MkvMergePath -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0 -or !(Test-Path -LiteralPath $output)) {
        throw "mkvmerge.exe falló al crear el MKV final. Código: $($p.ExitCode)"
    }
    Log "[Merge] MKV creado: $output"
}

function Set-SpanishLanguage {
    Log "[Language] Buscando selector de idioma y seleccionando español..."
    
    # Esperamos a que el selector esté disponible
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $js = @'
(function(){
  // Diagnosticar: contar selectores
  var selects = Array.from(document.querySelectorAll('select'));
  
  if (selects.length === 0) {
    return {status: "no_selects", count: 0};
  }
  
  var found = false;
  
  for (var i = 0; i < selects.length; i++) {
    var s = selects[i];
    if (!s || s.options.length < 2) continue;

    var opts = Array.from(s.options);
    var targetIndex = -1;
    
    // Buscar "español"
    for (var j = 0; j < opts.length; j++) {
      var text = (opts[j].textContent || opts[j].innerText || '').trim().toLowerCase();
      if (text === 'español' || text === 'espanol') {
        targetIndex = j;
        break;
      }
    }

    if (targetIndex < 0) continue;

    // Verificar que la primera opción es "Seleccionar idioma"
    var firstText = (opts[0].textContent || opts[0].innerText || '').trim().toLowerCase();
    var isTargetSelect = (firstText.indexOf('seleccionar idioma') >= 0 || 
                         firstText.indexOf('select language') >= 0 ||
                         firstText.indexOf('elige') >= 0);
    
    if (!isTargetSelect) continue;

    // Seleccionar
    try {
      s.focus();
      s.selectedIndex = targetIndex;
      s.dispatchEvent(new Event('input', {bubbles:true}));
      s.dispatchEvent(new Event('change', {bubbles:true}));
      s.dispatchEvent(new Event('click', {bubbles:true}));
      
      // Esperar a que cambie en el DOM
      var attempts = 0;
      while (s.selectedIndex !== targetIndex && attempts < 10) {
        s.selectedIndex = targetIndex;
        attempts++;
      }
      
      found = true;
      return {
        status: 'success',
        index: targetIndex,
        text: (s.options[targetIndex].textContent || '').trim(),
        value: s.value,
        selectCount: selects.length
      };
    } catch (e) {
      return {status: 'error', error: e.message};
    }
  }
  
  if (!found) {
    return {status: 'not_found', selectCount: selects.length, details: 'No encontré el select correcto'};
  }
  
  return {status: 'unknown_error'};
})()
'@

            $r = Eval-Js $js
            
            if ($r.status -eq 'success') {
                Log "[Language] ✓ Idioma seleccionado: $($r.text)"
                Start-Sleep -Milliseconds 1000
                return $true
            }
            
            if ($r.status -eq 'no_selects') {
                Log "[Language] Intento $($attempt+1)/30: No hay selectores. Esperando..."
            }
            elseif ($r.status -eq 'not_found') {
                Log "[Language] Intento $($attempt+1)/30: Selectores encontrados ($($r.selectCount)) pero no el correcto."
            }
            else {
                Log "[Language] Intento $($attempt+1)/30: $($r.status) - $($r.error)"
            }
            
        } catch {
            Log "[Language] Intento $($attempt+1)/30: Error JavaScript - $($_.Exception.Message)"
        }
        
        Start-Sleep -Milliseconds 500
    }

    throw "No encontré el selector de idioma de destino (opción Español) después de 30 intentos."
}

function Translate-OnePair($mkv, $subtitle) {
    $before = @(Get-ChildItem -LiteralPath $script:DownloadDir -Filter "*.zip" -File -ErrorAction SilentlyContinue | ForEach-Object FullName)

    Log ""
    Log "========================================"
    Log "MKV: $mkv"
    Log "SUB: $subtitle"
    Log "========================================"

    Navigate $script:SiteUrl
    Set-DownloadBehavior

    Close-StartupDonationPopup

    Log "[Process] Subiendo subtítulo..."
    Set-FileInput $subtitle

    if (!(Wait-ForText "SIGUIENTE" 20)) {
        if (!(Wait-ForText "NEXT" 10)) {
            throw "El subtítulo se cargó, pero no apareció el paso Siguiente."
        }
    }
    Log "[Process] Página de revisión detectada."
    Click-ByText @("SIGUIENTE","NEXT") 20
    Start-Sleep -Milliseconds 1000

    Set-SpanishLanguage

    Log "[Process] Iniciando traducción..."
    Click-ByText @("TRADUCIR","TRANSLATE") 20

    if (Wait-ForText "¿LE GUSTARÍA EDITAR" 60 -or (Wait-ForText "CANCELAR" 5)) {
        try { 
            Log "[Process] Cancelando edición..."
            Click-ByText @("CANCELAR","CANCEL") 10 
        } catch {}
    }

    Wait-ForText "DESCARGAR" 120 | Out-Null
    Log "[Process] Página de descarga detectada."
    Click-ByText @("DESCARGAR","DOWNLOAD") 20

    Start-Sleep -Milliseconds 500
    try {
        Click-ByText @("NO GRACIAS, NO QUIERO APOYAR","NO THANKS") 15
    } catch {
        # Puede no aparecer el popup
    }

    $zip = Wait-NewZip $before 180
    $translated = Get-TranslatedSubtitleFromZip $zip $subtitle

    $dir = Split-Path $mkv -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($mkv)
    $output = Join-Path $dir ($base + "_ES.mkv")

    if (Test-Path -LiteralPath $output) {
        $n=2
        do {
            $output = Join-Path $dir ($base + "_ES_$n.mkv")
            $n++
        } while (Test-Path -LiteralPath $output)
    }

    Add-SubtitleToMkv $mkv $translated $output
    Log "[Process] ✓ RESULTADO: $output"

    return $output
}

function Close-Cdp {
    try {
        if ($script:Ws) {
            $script:Ws.Abort()
            $script:Ws.Dispose()
        }
    } catch {}
    $script:Ws = $null
}

# ============================================================
# INTERFAZ
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "MKV Auto Processor - Subtitles Translator v15 (FIXED)"
$form.Size = New-Object System.Drawing.Size(1020,780)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(900,700)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Procesador automático de MKV"
$title.Font = New-Object System.Drawing.Font("Arial",16,[System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(30,20)
$title.AutoSize = $true
$form.Controls.Add($title)

$desc = New-Object System.Windows.Forms.Label
$desc.Text = "Añade los MKV a la izquierda y los subtítulos a la derecha. Se emparejan por orden: MKV 1 + subtítulo 1, MKV 2 + subtítulo 2, etc."
$desc.Location = New-Object System.Drawing.Point(30,55)
$desc.AutoSize = $true
$form.Controls.Add($desc)

# Columna MKV
$labM = New-Object System.Windows.Forms.Label
$labM.Text = "VÍDEOS MKV"
$labM.Font = New-Object System.Drawing.Font("Arial",10,[System.Drawing.FontStyle]::Bold)
$labM.Location = New-Object System.Drawing.Point(30,100)
$labM.AutoSize = $true
$form.Controls.Add($labM)

$listM = New-Object System.Windows.Forms.ListBox
$listM.Location = New-Object System.Drawing.Point(30,125)
$listM.Size = New-Object System.Drawing.Size(440,260)
$form.Controls.Add($listM)

$btnMAdd = New-Object System.Windows.Forms.Button
$btnMAdd.Text = "AÑADIR MKV"
$btnMAdd.Location = New-Object System.Drawing.Point(30,395)
$btnMAdd.Size = New-Object System.Drawing.Size(120,35)
$form.Controls.Add($btnMAdd)

$btnMRemove = New-Object System.Windows.Forms.Button
$btnMRemove.Text = "QUITAR"
$btnMRemove.Location = New-Object System.Drawing.Point(160,395)
$btnMRemove.Size = New-Object System.Drawing.Size(100,35)
$form.Controls.Add($btnMRemove)

$btnMClear = New-Object System.Windows.Forms.Button
$btnMClear.Text = "LIMPIAR"
$btnMClear.Location = New-Object System.Drawing.Point(270,395)
$btnMClear.Size = New-Object System.Drawing.Size(100,35)
$form.Controls.Add($btnMClear)

# Columna subtítulos
$labS = New-Object System.Windows.Forms.Label
$labS.Text = "SUBTÍTULOS"
$labS.Font = New-Object System.Drawing.Font("Arial",10,[System.Drawing.FontStyle]::Bold)
$labS.Location = New-Object System.Drawing.Point(520,100)
$labS.AutoSize = $true
$form.Controls.Add($labS)

$listS = New-Object System.Windows.Forms.ListBox
$listS.Location = New-Object System.Drawing.Point(520,125)
$listS.Size = New-Object System.Drawing.Size(440,260)
$form.Controls.Add($listS)

$btnSAdd = New-Object System.Windows.Forms.Button
$btnSAdd.Text = "AÑADIR SUBTÍTULOS"
$btnSAdd.Location = New-Object System.Drawing.Point(520,395)
$btnSAdd.Size = New-Object System.Drawing.Size(145,35)
$form.Controls.Add($btnSAdd)

$btnSRemove = New-Object System.Windows.Forms.Button
$btnSRemove.Text = "QUITAR"
$btnSRemove.Location = New-Object System.Drawing.Point(675,395)
$btnSRemove.Size = New-Object System.Drawing.Size(100,35)
$form.Controls.Add($btnSRemove)

$btnSClear = New-Object System.Windows.Forms.Button
$btnSClear.Text = "LIMPIAR"
$btnSClear.Location = New-Object System.Drawing.Point(785,395)
$btnSClear.Size = New-Object System.Drawing.Size(100,35)
$form.Controls.Add($btnSClear)

$status = New-Object System.Windows.Forms.Label
$status.Text = "0 MKV / 0 subtítulos"
$status.Location = New-Object System.Drawing.Point(30,445)
$status.AutoSize = $true
$form.Controls.Add($status)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Multiline = $true
$script:txtLog.ScrollBars = "Vertical"
$script:txtLog.ReadOnly = $true
$script:txtLog.Location = New-Object System.Drawing.Point(30,475)
$script:txtLog.Size = New-Object System.Drawing.Size(930,190)
$script:txtLog.Font = New-Object System.Drawing.Font("Courier New",9)
$form.Controls.Add($script:txtLog)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(30,680)
$progress.Size = New-Object System.Drawing.Size(700,25)
$form.Controls.Add($progress)

$btnProcess = New-Object System.Windows.Forms.Button
$btnProcess.Text = "PROCESAR TODOS"
$btnProcess.Font = New-Object System.Drawing.Font("Arial",10,[System.Drawing.FontStyle]::Bold)
$btnProcess.Location = New-Object System.Drawing.Point(750,675)
$btnProcess.Size = New-Object System.Drawing.Size(210,35)
$form.Controls.Add($btnProcess)

function Update-Status {
    $status.Text = "$($listM.Items.Count) MKV / $($listS.Items.Count) subtítulos"
    $btnProcess.Enabled = ($listM.Items.Count -gt 0 -and $listM.Items.Count -eq $listS.Items.Count)
}

$btnMAdd.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = "Selecciona uno o varios MKV"
    $d.Filter = "Archivos MKV (*.mkv)|*.mkv"
    $d.Multiselect = $true
    if ($d.ShowDialog() -eq "OK") {
        foreach ($f in $d.FileNames) { [void]$listM.Items.Add($f) }
        Update-Status
    }
})

$btnMRemove.Add_Click({
    while ($listM.SelectedItems.Count -gt 0) {
        $idx = $listM.SelectedIndex
        $listM.Items.RemoveAt($idx)
    }
    Update-Status
})
$btnMClear.Add_Click({ $listM.Items.Clear(); Update-Status })

$btnSAdd.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = "Selecciona uno o varios subtítulos"
    $d.Filter = "Subtítulos (*.srt;*.ass;*.ssa;*.vtt;*.stl;*.sbv;*.sub)|*.srt;*.ass;*.ssa;*.vtt;*.stl;*.sbv;*.sub|Todos los archivos (*.*)|*.*"
    $d.Multiselect = $true
    if ($d.ShowDialog() -eq "OK") {
        foreach ($f in $d.FileNames) { [void]$listS.Items.Add($f) }
        Update-Status
    }
})
$btnSRemove.Add_Click({
    while ($listS.SelectedItems.Count -gt 0) {
        $idx = $listS.SelectedIndex
        $listS.Items.RemoveAt($idx)
    }
    Update-Status
})
$btnSClear.Add_Click({ $listS.Items.Clear(); Update-Status })

$btnProcess.Add_Click({
    try {
        Ensure-Tools
        if ($listM.Items.Count -eq 0 -or $listM.Items.Count -ne $listS.Items.Count) {
            throw "Debe haber el mismo número de MKV y subtítulos."
        }

        $btnProcess.Enabled = $false
        $btnMAdd.Enabled = $false
        $btnSAdd.Enabled = $false
        $progress.Value = 0
        $script:txtLog.Clear()

        Log "==================================="
        Log "INICIANDO PROCESAMIENTO"
        Log "==================================="

        Start-Chrome
        Connect-Cdp
        Set-DownloadBehavior

        $total = $listM.Items.Count
        $results = @()

        for ($i=0; $i -lt $total; $i++) {
            $mkv = [string]$listM.Items[$i]
            $sub = [string]$listS.Items[$i]
            $status.Text = "Procesando pareja $($i+1) de $total..."
            [System.Windows.Forms.Application]::DoEvents()

            try {
                $results += Translate-OnePair $mkv $sub
            } catch {
                Log "❌ ERROR EN ESTA PAREJA: $($_.Exception.Message)"
                throw
            }

            $progress.Value = [int](($i+1)*100/$total)
        }

        $status.Text = "✓ TERMINADO - $total pareja(s) procesada(s)."
        Log ""
        Log "==================================="
        Log "✓ TODO TERMINADO."
        Log "MKV creados: $($results.Count)"
        foreach ($r in $results) { Log "  → $r" }
        Log "==================================="
        Show-Info "Proceso terminado correctamente.`r`n`r`nSe han creado $($results.Count) MKV con el subtítulo traducido."
    } catch {
        $status.Text = "❌ ERROR."
        Log ""
        Log "❌ ERROR: $($_.Exception.Message)"
        Show-Error $_.Exception.Message
    } finally {
        Close-Cdp
        $btnMAdd.Enabled = $true
        $btnSAdd.Enabled = $true
        $btnProcess.Enabled = $true
        Update-Status
    }
})

$form.Add_FormClosing({
    Close-Cdp
})

Update-Status
[void]$form.ShowDialog()
