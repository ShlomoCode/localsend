function New-ExitReceipt($Process, $Name, $ExpectedPath) {
    try { $cachedHandle = $Process.Handle; $handleError = $null }
    catch { $cachedHandle = [IntPtr]::Zero; $handleError = "$_" }
    $receipt = [ordered]@{ Name = $Name; Pid = $null; ExpectedPath = $ExpectedPath; ActualPath = $null; StartUtc = $null;
        HandleAcquired = $false; HandleValue = $null; WaitBoolean = $null; HasExited = $null;
        ExitCodeIsNull = $true; ExitCodeType = $null; ExitCodeValue = $null; Status = "UNKNOWN"; Errors = @() }
    # Hold the original Process object's handle before waiting. Windows PowerShell's
    # Start-Process redirection path can otherwise expose a null ExitCode (issue 5421).
    $receipt.HandleValue = $cachedHandle.ToInt64()
    $receipt.HandleAcquired = $cachedHandle -ne [IntPtr]::Zero
    if ($handleError) { $receipt.Errors += "Handle: $handleError" }
    try { $receipt.Pid = $Process.Id; $receipt.StartUtc = $Process.StartTime.ToUniversalTime().ToString("o"); $receipt.ActualPath = $Process.Path }
    catch { $receipt.Errors += "Identity: $_" }
    $receipt | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Evidence "$Name-process-exit.json")
    return $receipt
}
function Complete-ExitReceipt($Process, $Receipt, $WaitBoolean) {
    $Receipt.WaitBoolean = $WaitBoolean
    try { $Receipt.HasExited = $Process.HasExited } catch { $Receipt.Errors += "HasExited: $_" }
    try {
        $code = $Process.ExitCode
        $Receipt.ExitCodeIsNull = $null -eq $code
        if ($null -ne $code) { $Receipt.ExitCodeType = $code.GetType().FullName; $Receipt.ExitCodeValue = $code }
    } catch { $Receipt.Errors += "ExitCode: $_" }
    if ($Receipt.HandleAcquired -and $WaitBoolean -eq $true -and $Receipt.HasExited -eq $true -and
        -not $Receipt.ExitCodeIsNull -and $Receipt.ExitCodeType -eq "System.Int32") {
        $Receipt.Status = if ($Receipt.ExitCodeValue -eq 0) { "EXIT_ZERO" } else { "EXIT_NONZERO" }
    } elseif ($WaitBoolean -eq $false -and $Receipt.HasExited -eq $false) { $Receipt.Status = "TIMED_OUT" }
    $Receipt | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Evidence "$($Receipt.Name)-process-exit.json")
}
function Wait-ToolExit($Process, $Receipt, $Milliseconds) {
    $wait = $null
    if (-not $Receipt.HandleAcquired) { throw "ENV_BLOCK: $($Receipt.Name) process handle unknown; exit status unknown" }
    try { $wait = $Process.WaitForExit($Milliseconds) } catch { $Receipt.Errors += "WaitForExit: $_" }
    Complete-ExitReceipt $Process $Receipt $wait
    if ($Receipt.Status -eq "TIMED_OUT") { $Process.Kill(); throw "ENV_BLOCK: $($Receipt.Name) deadline" }
    if ($Receipt.Status -eq "UNKNOWN") { throw "ENV_BLOCK: $($Receipt.Name) process exit status unknown" }
    if ($Receipt.Status -eq "EXIT_NONZERO") { throw "ENV_BLOCK: $($Receipt.Name) exited with exact code $($Receipt.ExitCodeValue)" }
}
