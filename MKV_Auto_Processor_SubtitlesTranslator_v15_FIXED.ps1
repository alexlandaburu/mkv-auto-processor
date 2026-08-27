function Set-SpanishLanguage {
    Log "[Language] Buscando selector de idioma y seleccionando español..."
    
    # Esperamos a que el selector esté disponible
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $js = @"
(function(){
  var selects = Array.from(document.querySelectorAll('select'));
  
  if (selects.length === 0) {
    return {status: "no_selects", count: 0};
  }
  
  for (var i = 0; i < selects.length; i++) {
    var s = selects[i];
    if (!s || s.options.length < 2) continue;

    var opts = Array.from(s.options);
    var targetIndex = -1;
    
    // Buscar español
    for (var j = 0; j < opts.length; j++) {
      var text = (opts[j].textContent || opts[j].innerText || '').trim().toLowerCase();
      if (text === 'español' || text === 'espanol') {
        targetIndex = j;
        break;
      }
    }

    if (targetIndex < 0) continue;

    // Verificar primera opción
    var firstText = (opts[0].textContent || opts[0].innerText || '').trim().toLowerCase();
    var isTargetSelect = (firstText.indexOf('seleccionar idioma') >= 0 || 
                         firstText.indexOf('select language') >= 0 ||
                         firstText.indexOf('elige') >= 0);
    
    if (!isTargetSelect) continue;

    // Seleccionar
    s.focus();
    s.selectedIndex = targetIndex;
    s.dispatchEvent(new Event('input', {bubbles:true}));
    s.dispatchEvent(new Event('change', {bubbles:true}));
    
    return {
      ok: true,
      text: (s.options[targetIndex].textContent || '').trim()
    };
  }
  
  return {ok: false, selectCount: selects.length};
})()
"@

            $r = Eval-Js $js
            
            if ($r -and $r.ok -eq $true) {
                Log "[Language] OK - Idioma seleccionado: $($r.text)"
                Start-Sleep -Milliseconds 1000
                return $true
            }
            
            Log "[Language] Intento $($attempt+1)/30: Esperando selector..."
            
        } catch {
            Log "[Language] Intento $($attempt+1)/30: $_"
        }
        
        Start-Sleep -Milliseconds 500
    }

    throw "No encontré el selector de idioma después de 30 intentos."
}
