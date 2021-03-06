param(
    [String] $ScriptProductName = "PostInstall-Marionettist",
    [String] $ScriptPath = $MyInvocation.MyCommand.Path,
    [String] $ScriptName = $MyInvocation.MyCommand.Name
)

### Global Constants that I use elsewhere

$ArchitectureId = @{
    amd64 = "amd64"
    i386 = "i386"
}
$WindowsVersionId = @{
    w81 = "w81"
    w10 = "w10"
    w10ltsb = "w10ltsb"
    server2012r2 = "server2012r2"
}
$URLs = @{
    SevenZipDownload = @{
        $ArchitectureId.i386  = "http://7-zip.org/a/7z920.msi"
        $ArchitectureId.amd64 = "http://7-zip.org/a/7z920-x64.msi"
    }
    UltraDefragDownload = @{
        $ArchitectureId.i386  = "http://downloads.sourceforge.net/project/ultradefrag/stable-release/6.1.0/ultradefrag-portable-6.1.0.bin.i386.zip"
        $ArchitectureId.amd64 = "http://downloads.sourceforge.net/project/ultradefrag/stable-release/6.1.0/ultradefrag-portable-6.1.0.bin.amd64.zip"
    }
    SdeleteDownload = "http://download.sysinternals.com/files/SDelete.zip"
    WindowsIsoDownload = @{
        $WindowsVersionId.w81 = @{
            $ArchitectureId.i386  = @{
                URL  = "http://care.dlservice.microsoft.com/dl/download/B/9/9/B999286E-0A47-406D-8B3D-5B5AD7373A4A/9600.17050.WINBLUE_REFRESH.140317-1640_X86FRE_ENTERPRISE_EVAL_EN-US-IR3_CENA_X86FREE_EN-US_DV9.ISO"
                SHA1 = "4ddd0881779e89d197cb12c684adf47fd5d9e540"
            }
            $ArchitectureId.amd64 = @{
                URL  = "http://download.microsoft.com/download/B/9/9/B999286E-0A47-406D-8B3D-5B5AD7373A4A/9600.16384.WINBLUE_RTM.130821-1623_X64FRE_ENTERPRISE_EVAL_EN-US-IRM_CENA_X64FREE_EN-US_DV5.ISO"
                SHA1 = "5e4ecb86fd8619641f1d58f96e8561ec"
            }
        }
        $WindowsVersionId.w10 = @{
            $ArchitectureId.i386  = @{
                URL  = "http://care.dlservice.microsoft.com/dl/download/C/3/9/C399EEA8-135D-4207-92C9-6AAB3259F6EF/10240.16384.150709-1700.TH1_CLIENTENTERPRISEEVAL_OEMRET_X86FRE_EN-US.ISO"
                SHA1 = "875b450d67e7176b8b3c72a80c60a0628bf1afac"
            }
            $ArchitectureId.amd64 = @{
                URL  = "http://care.dlservice.microsoft.com/dl/download/C/3/9/C399EEA8-135D-4207-92C9-6AAB3259F6EF/10240.16384.150709-1700.TH1_CLIENTENTERPRISEEVAL_OEMRET_X64FRE_EN-US.ISO"
                SHA1 = "56ab095075be28a90bc0b510835280975c6bb2ce"
            }
        }
    }
}
$script:ScriptPath = $MyInvocation.MyCommand.Path
    
### Private support functions I use behind the scenes

<#
.description
Add a line to a file idempotently; that is, if the line is not already present in the file, add it, but if it is already present, then do nothing
#>
function Add-FileLineIdempotently {
    [CmdletBinding()] param(
        [Parameter(Mandatory=$true)] [String] $file,
        [Parameter(Mandatory=$true)] [String[]] $newLine,
        [Parameter(Mandatory=$true)] [String] $encoding = "UTF8"
    )
    if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file | Out-Null }
    $origContents = Get-Content $file
    $newLine |% {
        if ($origContents -notcontains $_) {
            Out-File -FilePath $file -InputObject $_ -Encoding $encoding -Append
        }
    }
}

<#
.description
Do some very basic filename sanitization
#>
function Get-SanitizedFilename {
    [cmdletbinding()] param(
        [Parameter(Mandatory=$true)] [String] $fileName
    )
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $replacementCharacter = "_"
    $newName = [System.String]::Copy($fileName)
    foreach ($invChar in $invalidChars) {
        $newName = $newName.Replace($invChar, $replacementCharacter)
    }
    return $newName
}

<#
.synopsis
Get a rooted path
.notes
Especially useful for .NET functions, which don't understand Powershell's $pwd, and instead have their own concept of the working directory, which is (in any normal case) always %USERPROFILE%. This means that if you do this:

    cd C:\Windows
    (New-Object System.Net.WebClient).DownloadFile("http://example.com/file.txt", "./file.txt")

... the file will be downloaded to %USERPROFILE%\file.txt, not C:\Windows\file.txt
#>
function Get-RootedPath {
    [cmdletbinding()] param(
        [Parameter(Mandatory=$true)] [String] $path
    )
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path -Path $pwd -ChildPath $path
    }
    try {
        $rootedPath = [System.IO.Path]::GetFullPath($path)
    }
    catch {
        Write-Error "Failed to validate path '$path'"
        throw $_
    }
    return $rootedPath
}

<#
.synopsis
Download a URL from the web
.parameter url
The URL to download
.parameter outDir
Save the file to this directory. The filename will be the last part of the URL. This will make sense for a basic case like http://example.com/file.txt, but might be a little ugly for URLs like http://example.com/?product=exampleProduct&version=exampleVersion
.parameter outFile
Save the file to this exact filename.
.notes
Why not use Invoke-WebRequest or Invoke-RestMethod? Because those are not available before Powershell 3.0, and I still want to be able to use this function on vanilla Windows 7 (hopefully just before applying all updates and getting a more recent Powershell, but still.)
#>
function Get-WebUrl {
    [cmdletbinding(DefaultParameterSetName="outDir")] param(
        [parameter(mandatory=$true)] [string] $url,
        [parameter(mandatory=$true,ParameterSetName="outDir")] [string] $outDir,
        [parameter(mandatory=$true,ParameterSetName="outFile")] [string] $outFile
    )
    if ($PScmdlet.ParameterSetName -match "outDir") {
        # If the URL is http://example.com/whatever/somefile.txt, the last URL component is somefile.txt
        $lastUrlComponent = [System.IO.Path]::GetFileName($url)
        $filename = Get-SanitizedFilename -fileName $lastUrlComponent
        $outFile = Join-Path -Path $outDir -ChildPath $fileName
    }
    $outFile = Get-RootedPath $outFile
    Write-EventLogWrapper "Downloading '$url' to '$outFile'..."
    (New-Object System.Net.WebClient).DownloadFile($url, $outFile)
    return (Get-Item $outFile)
}

<#
.synopsis
Invoke an expression; log the expression, optionally with any output, and the last exit code if appropriate
#>
function Invoke-ExpressionEx {
    [cmdletbinding()] param(
        [parameter(mandatory=$true)] [string] $command,
        [switch] $invokeWithCmdExe,
        [switch] $checkExitCode,
        [switch] $logToStdout,
        [int] $sleepSeconds
    )
    $global:LASTEXITCODE = 0
    if ($invokeWithCmdExe) {
        $commandSb = {cmd /c "$command"}.GetNewClosure()
    }
    else {
        $commandSb = {invoke-expression -command $command}.GetNewClosure()
    }
    Write-EventLogWrapper "Invoke-ExpressionEx called to run command '$command'`r`n`r`nUsing scriptblock: $($commandSb.ToString())"
    $output = $null
    
    try {
        if ($logToStdout) {
            $commandSb.invoke()
            $message = "Expression '$command' exited with code '$LASTEXITCODE'"
        }
        else {
            $output = $commandSb.invoke()
            $message = "Expression '$command' exited with code '$LASTEXITCODE' and output the following to the console:`r`n`r`n$output"
        }
        Write-EventLogWrapper -message $message
    }
    catch {
        $err = Get-ErrorStackAsString -errorStack $_
        Write-EventLogWrapper -message "Invoke-ExpressionEx failed to run command '$command'. Error:`r`n`r`n$err"
        throw $_
    }
    
    if ($checkExitCode -and $global:LASTEXITCODE -ne 0) {
        throw "LASTEXITCODE: ${global:LASTEXITCODE} for command: '${command}'"
    }
    if ($sleepSeconds) { start-sleep $sleepSeconds }
}

### Publicly exported functions called directly from slipstreaming scripts

<#
.synopsis
Create a temporary directory
#>
function New-TemporaryDirectory {
    $dirPath = [System.IO.Path]::GetTempFileName() # creates a file automatically
    rm $dirPath
    mkdir $dirPath # mkdir returns a DirectoryInfo object; not capturing it here returns it to the caller
}

<#
.synopsis
Return an object containing metadata for the trial ISO for a particular version of Windows
.notes
TODO: this sucks but I can't think of anything better to do
#>
function Get-WindowsTrialISO {
    [cmdletbinding()] param(
        $WindowsVersion = ([Environment]::OSVersion.Version),
        $WindowsArchitecture = (Get-OSArchitecture)
    )
    if ($WindowsVersion.Major -eq 6 -and $WindowsVersion.Minor -eq 3) {
        return $URLs.WindowsIsoDownload.w81.$WindowsArchitecture
    }
    elseif ($WindowsVersion.Major -eq 10 -and $WindowsVersion.Minor -eq 0) {
        return $URLs.WindowsIsoDownload.w10.$WindowsArchitecture
    }
    else {
        throw "No URL known for Windows version '$WindowsVersion' and architecture '$WindowsArchitecture'"
    }
}

<#
.synopsis
Wrapper that writes to the event log but also to the screen
#>
function Write-EventLogWrapper {
    [cmdletbinding()] param(
        [parameter(mandatory=$true)] [String] $message,
        [int] $eventId = 0,
        [ValidateSet("Error",'Warning','Information','SuccessAudit','FailureAudit')] $entryType = "Information",
        [String] $EventLogName = $ScriptProductName,
        [String] $EventLogSource = $ScriptName
    )
    if (-not (get-eventlog -logname * |? { $_.Log -eq $eventLogName })) {
        New-EventLog -Source $EventLogSource -LogName $eventLogName
    }
    $messagePlus = "$message`r`n`r`nScript: $($script:ScriptPath)`r`nUser: ${env:USERDOMAIN}\${env:USERNAME}"
    if ($messagePlus.length -gt 32766) { $messagePlus = $messagePlus.SubString(0,32766) } # Because Write-EventLog will die otherwise
    Write-Host -foreground magenta "====Writing to $EvengLogName event log===="
    Write-Host -foreground darkgray (get-date -Format "yyyy-MM-dd HH:mm:ss")              # The event log tracks the date, but writing to host never shows it
    write-host -foreground darkgray "$messagePlus`r`n"
    Write-EventLog -LogName $eventLogName -Source $EventLogSource -EventID $eventId -EntryType $entryType -Message $MessagePlus
}

<#
.synopsis
Invoke a scriptblock. If it throws, write the errors out to the event log and exist with an error code
.notes
This is intended to be a handy wrapper for calling functions in this module that takes care of logging an exception for you.
See the autounattend-postinstall.ps1 and provisioner-postinstall.ps1 scripts for examples.
#>
function Invoke-ScriptblockAndCatch {
    [cmdletbinding()] param(
        [parameter(mandatory=$true)] [ScriptBlock] $scriptBlock,
        [int] $failureExitCode = 666
    )
    try {
        Invoke-Command $scriptBlock
    }
    catch {
        $err = Get-ErrorStackAsString -errorStack $_
        Write-EventLogWrapper -message "Command '$($scriptBlock.ToString())' failed with an error:`r`n`r`n$err"
        exit $failureExitCode
    }
}

function Get-ErrorStackAsString {
    [cmdletbinding()] param(
        $errorStack = $error.ToArray()
    )
    $message = "CAUGHT EXCEPTION. ERROR Report: `$Error.count=$($errorStack.count)`r`n`r`n"
    for ($i=$errorStack.count -1; $i -ge 0; $i-=1) {
        $err = $errorStack[$i]
        $message += "==== `$Error[$i] ====`r`n"

        # $error can contain at least 2 kind of objects - ErrorRecord objects, and things that wrap ErrorRecord objects
        # The information we need is found in the ErrorRecord objects, so unwrap them here if necessary
        if ($err.PSObject.Properties['ErrorRecord']) {$err = $err.ErrorRecord}

        $message += "$($err.ToString())`r`n"
        if ($err.ScriptStackTrace) {
            $message += "StackTrace:`r`n$($err.ScriptStackTrace)`r`n"
        }
        $message += "`r`n"
    }
    return $message
}

function Test-PowershellSyntax {
    [cmdletbinding(DefaultParameterSetName='FromText')]
    param(
        [parameter(mandatory=$true,ParameterSetName='FromText')] [string] $text,
        [parameter(mandatory=$true,ParameterSetName='FromFile')] [string] $fileName
    )
    $tokens = @()
    $parseErrors = @()
    $parser = [System.Management.Automation.Language.Parser]
    if ($pscmdlet.ParameterSetName -eq 'FromText') {
        $parsed = $parser::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
    }
    elseif ($pscmdlet.ParameterSetName -eq 'FromFile') {
        $fileName = resolve-path $fileName
        $parsed = $parser::ParseFile($fileName, [ref]$tokens, [ref]$parseErrors)
    }
    write-verbose "$($tokens.count) tokens found."

    if ($parseErrors.count -gt 0) {
        $message = "$($parseErrors.count) parse errors found in file '$fileName':`r`n"
        $parseErrors |% { $message += "`r`n    $_" }
        write-verbose $message
        return $false
    }
    return $true
}


<#
.description
Set a scheduled task to run on next logon of the calling user. Intended for tasks that need to reboot and then be restarted such as applying Windows Updates
.notes
The Powershell New-ScheduledTask cmdlet is broken for me on Win81, but SchTasks.exe doesn't support actions with long arguments (requires a command line of < 200something characters). lmfao.
My workaround is to take a scriptblock, and then just save it to a file and call the file from Powershell.
I create the scheduled task with SchTasks.exe, then modify it with Powershell cmdlets that can handle long arguments just fine
#>
function Set-RestartScheduledTask {
    [cmdletbinding()] param(
        [Parameter(Mandatory=$true)] [string] $restartCommand,
        [string] $tempRestartScriptPath = "${env:temp}\$ScriptProductName-TempRestartScript.ps1",
        [string] $taskName = "$ScriptProductName-RestartTask"
    )
    Remove-RestartScheduledTask -taskName $taskName
    
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    
    Out-File -InputObject $restartCommand -FilePath $tempRestartScriptPath -Encoding utf8
    "Unregister-ScheduledTask -taskName '$taskName' -Confirm:`$false" | Out-File -Append -FilePath $tempRestartScriptPath -Encoding utf8
    if (-not (Test-PowershellSyntax -FileName $tempRestartScriptPath)) {
        throw "Invalid Powershell syntax in '$tempRestartScriptPath'"
    }
    
    $schTasksCmd = 'SchTasks.exe /create /sc ONLOGON /tn "{0}" /tr "cmd.exe /c echo TemporparyPlaceholderCommand" /ru "{1}" /it /rl HIGHEST /f' -f $taskName,$currentUser
    Invoke-ExpressionEx -command $schTasksCmd -invokeWithCmdExe -checkExitCode
    
    # schtasks.exe cannot modify specific battery arguments without importing XML (not gonna do.dat). Modify it here:

    $settings = New-ScheduledTaskSettingsSet -allowStartIfonBatteries -dontStopIfGoingOnBatteries
    # SchTasks.exe cannot specify a user for the LOGON schedule - it applies to all users. Modify it here:
    $trigger = New-ScheduledTaskTrigger -AtLogon -User $currentUser
    # SchTasks.exe cannot specify an action with long arguments (maxes out at like 200something chars). Modify it here:
    $action = New-ScheduledTaskAction -Execute "$PSHome\Powershell.exe" -Argument "-File `"$tempRestartScriptPath`""
    Set-ScheduledTask -taskname $taskName -settings $settings -action $action -trigger $trigger | Out-Null
    
    $message  = "Created scheduled task called '$taskName', which will run a temp file at '$tempRestartScriptPath', containing:`r`n`r`n"
    $message += (Get-Content $tempRestartScriptPath) -join "`r`n"
    Write-EventLogWrapper -message $message
}

function Get-RestartScheduledTask {
    [cmdletbinding()] param(
        [string] $taskName = $ScriptProductName
    )
    Get-ScheduledTask |? -Property TaskName -match $taskName
}

function Remove-RestartScheduledTask {
    [cmdletbinding()] param(
        [string] $taskName = $ScriptProductName
    )
    $existingTask = Get-RestartScheduledTask -taskName $taskName
    if ($existingTask) {
        Write-EventLogWrapper -message "Found existing task named '$taskName'; deleting..."
        Unregister-ScheduledTask -InputObject $existingTask -Confirm:$false | out-null
    }
    else {
        Write-EventLogWrapper -message "Did not find any existing task named '$taskName'"
    }
}

<#
.description
Return the OS Architecture of the current system, as determined by WMI
Will return either "i386" or "amd64"
TODO: this isn't a great method but I'm tired of trying to find the totally correct one. This one isn't ideal because OSArchitecture can be localized.
I've seen some advice that you should call into the registry
- reg Query "HKLM\Hardware\Description\System\CentralProcessor\0" | find /i "x86" > NUL && set OSARCHITECTURE=32BIT || set OSARCHITECTURE=64BIT
- http://stackoverflow.com/a/24590583/868206
- https://support.microsoft.com/en-us/kb/556009
... however, this lets you know about the HARDWARE, not the OPERATING SYSTEM - we care about the latter
#>
function Get-OSArchitecture {
    $OSArch = Get-WmiObject -class win32_operatingsystem -property osarchitecture | select -expand OSArchitecture
    if ($OSArch -match "64") { return $ArchitectureId.amd64 }
    elseif ($OSArch -match "32") { return $ArchitectureId.i386 }
    else { throw "Could not determine OS Architecture from string '$OSArch'" }
}

function Test-AdminPrivileges {
    [cmdletbinding()] param(
        [switch] $ThrowIfNotElevated
    )
    $me = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = $me.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if ($ThrowIfNotElevated -and (! $elevated)) { throw "Administrative privileges are required" }
    return $elevated
}

function Install-SevenZip {
    $OSArch = Get-OSArchitecture
    $szDlPath = Get-WebUrl -url $URLs.SevenZipDownload.$OSArch -outDir $env:temp
    try {
        Write-EventLogWrapper "Downloaded '$($URLs.SevenZipDownload.$OSArch)' to '$szDlPath', now running msiexec..."
        $msiCall = '& msiexec /qn /i "{0}"' -f $szDlPath
        # Windows suxxx so msiexec sometimes returns right away? or something idk. fuck
        Invoke-ExpressionEx -checkExitCode -command $msiCall -sleepSeconds 30
    }
    finally {
        rm -force $szDlPath
    }
}
set-alias sevenzip "${env:ProgramFiles}\7-Zip\7z.exe"

function Install-VBoxAdditions {
    [cmdletbinding(DefaultParameterSetName="InstallFromDisc")] param(
        [parameter(ParameterSetName="InstallFromIsoPath",mandatory=$true)] [string] $isoPath,
        [parameter(ParameterSetName="InstallFromDisc",mandatory=$true)] [switch] $fromDisc
    )
        
    function InstallVBoxAdditionsFromDir {
        param([Parameter(Mandatory=$true)][String]$baseDir)
        $baseDir = resolve-path $baseDir | select -expand Path
        Write-EventLogWrapper "Installing VBox Additions from '$baseDir'"
        Write-EventLogWrapper "Installing the Oracle certificate..."
        $oracleCert = resolve-path "$baseDir\cert\*sha*" | select -expand path
        foreach($cert in $oracleCert)   {
            Invoke-ExpressionEx -checkExitCode -command ('& "{0}" add-trusted-publisher "{1}" --root "{1}"' -f "$baseDir\cert\VBoxCertUtil.exe",$cert)
        }
        # NOTE: Checking for exit code, but this command will fail with an error if the cert is already installed
        Write-EventLogWrapper "Installing the virtualbox additions"
        Invoke-ExpressionEx -checkExitCode -command ('& "{0}" /with_wddm /S' -f "$baseDir\VBoxWindowsAdditions.exe") # returns IMMEDIATELY, goddamn fuckers
        while (get-process -Name VBoxWindowsAdditions*) { write-host 'Waiting for VBox install to finish...'; sleep 1; }
        Write-EventLogWrapper "virtualbox additions have now been installed"
    }
    switch ($PSCmdlet.ParameterSetName) {
        "InstallFromIsoPath" {
            $isoPath = resolve-path $isoPath | select -expand Path
            $vbgaPath = mkdir -force "${env:Temp}\InstallVbox" | select -expand fullname
            try {
                Write-EventLogWrapper "Extracting iso at '$isoPath' to directory at '$vbgaPath'..."
                Invoke-ExpressionEx -checkExitCode -command ('sevenzip x "{0}" -o"{1}"' -f $isoPath, $vbgaPath)
                InstallVBoxAdditionsFromDir $vbgaPath
            }
            finally {
                rm -recurse -force $vbgaPath
            }
        }
        "InstallFromDisc" {
            $vboxDiskDrive = get-psdrive -PSProvider Filesystem |? { test-path "$($_.Root)\VBoxWindowsAdditions.exe" }
            if ($vboxDiskDrive) { 
                Write-EventLogWrapper "Found VBox Windows Additions disc at $vboxDiskDrive"
                InstallVBoxAdditionsFromDir $vboxDiskDrive.Root
            }
            else {
                $message = "Could not find VBox Windows Additions disc"
                Write-EventLogWrapper $message
                throw $message
            }
        }
    }
}

function Set-AutoAdminLogon {
    [CmdletBinding(DefaultParameterSetName="Enable")] param(
        [Parameter(Mandatory=$true,ParameterSetName="Enable")] [String] $Username,
        [Parameter(Mandatory=$true,ParameterSetName="Enable")] [String] $Password,
        [Parameter(Mandatory=$true,ParameterSetName="Disable")] [Switch] $Disable
    )
    if ($PsCmdlet.ParameterSetName -Match "Disable") {
        Write-EventLogWrapper "Disabling auto admin logon"
        $AutoAdminLogon = 0
        $Username = ""
        $Password = ""
    }
    elseif ($PsCmdlet.ParameterSetName -Match "Enable") {
        Write-EventLogWrapper "Enabling auto admin logon for user '$Username'"
        $AutoAdminLogon = 1
    }
    else {
        throw "Invalid parameter set name"
    }
    $winLogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $winLogonKey -Name "AutoAdminLogon"  -Value $AutoAdminLogon
    Set-ItemProperty -Path $winLogonKey -Name "DefaultUserName" -Value $Username
    Set-ItemProperty -Path $winLogonKey -Name "DefaultPassword" -Value $Password
}

function Enable-RDP {
    Write-EventLogWrapper "Enabling RDP"
    netsh advfirewall firewall add rule name="Open Port 3389" dir=in action=allow protocol=TCP localport=3389
    reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
}

function Install-CompiledDotNetAssemblies {
    # http://support.microsoft.com/kb/2570538
    # http://robrelyea.wordpress.com/2007/07/13/may-be-helpful-ngen-exe-executequeueditems/
    # Don't check the return value - sometimes it fails and that's fine
    
    $ngen32path = "${env:WinDir}\microsoft.net\framework\v4.0.30319\ngen.exe"
    # Invoke-ExpressionEx "$ngen32path update /force /queue"
    # Invoke-ExpressionEx "$ngen32path executequeueditems"
    set-alias ngen32 $ngen32path
    ngen32 update /force /queue
    ngen32 executequeueditems
        
    if ((Get-OSArchitecture) -match $ArchitectureId.amd64) {
        $ngen64path = "${env:WinDir}\microsoft.net\framework64\v4.0.30319\ngen.exe"
        # Invoke-ExpressionEx "$ngen64path update /force /queue"
        # Invoke-ExpressionEx "$ngen64path executequeueditems"
        set-alias ngen64 $ngen64path
        ngen64 update /force /queue
        ngen64 executequeueditems
    }
}

function Compress-WindowsInstall {
    $OSArch = Get-OSArchitecture
    try {
        $udfZipPath = Get-WebUrl -url $URLs.UltraDefragDownload.$OSArch -outDir $env:temp
        $udfExPath = "${env:temp}\ultradefrag-portable-6.1.0.$OSArch"
        # This archive contains a folder - extract it directly to the temp dir
        Invoke-ExpressionEx -command ('sevenzip x "{0}" "-o{1}"' -f $udfZipPath,$env:temp)

        $sdZipPath = Get-WebUrl -url $URLs.SdeleteDownload -outDir $env:temp
        $sdExPath = "${env:temp}\SDelete"
        # This archive does NOT contain a folder - extract it to a subfolder (will create if necessary)
        Invoke-ExpressionEx -command ('sevenzip x "{0}" "-o{1}"' -f $sdZipPath,$sdExPath)

        stop-service wuauserv
        rm -recurse -force ${env:WinDir}\SoftwareDistribution\Download
        start-service wuauserv

        Invoke-ExpressionEx -logToStdout -command ('& {0} --optimize --repeat "{1}"' -f "$udfExPath\udefrag.exe","$env:SystemDrive")
        Invoke-ExpressionEx -command ('& {0} /accepteula -q -z "{1}"' -f "$sdExPath\SDelete.exe",$env:SystemDrive)
    }
    finally {
        rm -recurse -force $udfZipPath,$udfExPath,$sdZipPath,$sdExPath -ErrorAction Continue
    }
}

function Disable-WindowsUpdates {
    Test-AdminPrivileges -ThrowIfNotElevated

    $Updates = (New-Object -ComObject "Microsoft.Update.AutoUpdate").Settings
    if ($Updates.ReadOnly) {
        throw "Cannot update Windows Update settings due to GPO restrictions."
    }

    $Updates.NotificationLevel = 1 # 1 = Disabled lol
    $Updates.Save()
    $Updates.Refresh()
}

function Enable-MicrosoftUpdate {
    [cmdletbinding()] param()
    Write-EventLogWrapper "Enabling Microsoft Update..."
    stop-service wuauserv
    $auKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"
    Set-ItemProperty -path $auKey -name EnableFeaturedSoftware -value 1
    Set-ItemProperty -path $auKey -name IncludeRecommendedUpdates -value 1

    $ServiceManager = New-Object -ComObject "Microsoft.Update.ServiceManager"
    $ServiceManager.AddService2("7971f918-a847-4430-9279-4a52d1efe18d",7,"") | out-null

    start-service wuauserv
}

function Install-Chocolatey {
    [cmdletbinding()] param()
    
    $chocoExePath = "${env:ProgramData}\Chocolatey\bin"
    if ($($env:Path).ToLower().Contains($($chocoExePath).ToLower())) {
        Write-EventLogWrapper "Attempting to install Chocolatey but it's already in path, exiting..."
        return
    }

    $systemPath = [Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Machine)
    $systemPath += ";$chocoExePath"
    [Environment]::SetEnvironmentVariable("PATH", $systemPath, [System.EnvironmentVariableTarget]::Machine)

    $env:Path = $systemPath
    $userPath = [Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::User)
    if ($userPath) { $env:Path += ";$userPath" }

    # TODO: capture and log output
    $chocoOutput = iex ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1'))
    Write-EventLogWrapper "Chocolatey install process completed:`r`n`r`n$chocoOutput"
}

function Get-FirefoxInstallDirectory {
    [cmdletbinding()] param()
    @($env:ProgramFiles,${env:ProgramFiles(x86)}) |% {
        $testPath = "$_\Mozilla Firefox"
        if (Test-Path "$testPath\firefox.exe") {$ffDir = $testPath}
    }
    if (-not $ffDir) {
        throw "Could not find the Firefox install location."
    }
    else {
        return $ffDir
    }
}

<#
.notes
One nice thing about FF and Chrome is that you don't have to handle updates yourself - they both install services that update the browser for you
#>
function Install-Firefox {
    [cmdletbinding()] param(
        [ValidateSet("Standard","ESR")] [String] $edition = "Standard",
        [String] $language = "en-US"
    )
    switch ($edition) {
        "Standard" {$downloadPageUrl = 'https://www.mozilla.org/en-US/firefox/all/'}
        "ESR"      {$downloadPageUrl = 'https://www.mozilla.org/en-US/firefox/organizations/all'}
    }
    $osarch = Get-OSArchitecture
    switch ($osarch) {
        $ArchitectureId.amd64 {$os = 'win64'}
        $ArchitectureId.i386 {$os = 'win'}
    }
    $firefoxIniFile = "${env:temp}\firefox-installer.ini"

    try {
        Write-EventLogWrapper "Finding download location for $edition edition of Firefox..."
        $response = Invoke-WebRequest -Uri $downloadPageUrl
        $downloadUrl = $response.ParsedHtml.getElementById($language).getElementsByClassName("download $os")[0].getElementsByTagName('a') | Select -Expand href
        $firefoxInstallerFile = Get-WebUrl -url $downloadUrl -outFile "${env:temp}\firefox-installer.exe"

        $firefoxIniContents = @(
            "QuickLaunchShortcut=false"
            "DesktopShortcut=false"
        )
        Out-File -FilePath $firefoxIniFile -InputObject $firefoxIniContents -Encoding UTF8
        Write-EventLogWrapper "Beginning Firefox installation process..."
        $process = Start-Process -FilePath $firefoxInstallerFile.FullName -ArgumentList @("/INI=`"$firefoxIniFile`"") -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Firefox installer at $($firefoxInstallerFile.FullName) exited with code $($process.ExitCode)"
        }
    }
    catch {
        @($firefoxInstallerFile,$firefoxIniFile) |% { if ($_ -and (Test-Path $_)) { Remove-Item $_ } }
        throw $_
    }

    Write-EventLogWrapper "Firefox installation process complete"
    Remove-Item @($firefoxInstallerFile,$firefoxIniFile)
}

function Uninstall-Firefox {
    [cmdletbinding()] param()
    $ffDir = Get-FirefoxInstallDirectory
    $ffUninstallHelper = Get-Item "$ffDir\uninstall\helper.exe"
    $process = Start-Process -FilePath $ffUninstallHelper.FullName -ArgumentList "/S" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Firefox uninstall helper at $($ffUninstallHelper.FullName) exited with code $($process.ExitCode)"
    }
    Remove-Item -Recurse -Force $ffDir
}

<#
.parameter systemDisableImportWizard
Don't run the import wizard when starting Firefox for the first time
.parameter systemDisableWhatsNew
Don't open dumb tabs that no one needs when starting Firefox for the first time
See also: http://kb.mozillazine.org/Browser.startup.homepage_override.mstone
.parameter systemEnableGlobalAddOns
By default, add-ons that are installed to the global Firefox application directory are available to users, but disabled by default. Enable them by default instead.
.parameter userDeleteConfiguration
Wipe out the configuration, including profiles, of the current user
.parameter userSetDefaultBrowser
Set Firefox to be the default browser for the current user
.notes
Parameters prepended with "system" affect all Firefox users on the entire machine

Parameters prepended with "user" affect only the current user's Firefox configuration
#>
function Set-FirefoxOptions {
    [cmdletbinding()] param(
        [switch] $systemDisableImportWizard,
        [switch] $systemDisableWhatsNew,
        [switch] $systemEnableGlobalAddOns,
        [string[]] $systemInstallAddOnsFromUrl,
        [switch] $userDeleteConfiguration,
        [switch] $userSetDefaultBrowser
    )
    $ffDir = Get-FirefoxInstallDirectory
    $ffPath = "$ffDir\firefox.exe"

    function Test-LockCfgSetting {
        param(
            [String] $name,
            [String] $lockFile = "$(Get-FirefoxInstallDirectory)\mozilla.cfg"
        )
        if (-not (Test-Path $lockFile)) { return $false }
        foreach ($line in (Get-Content $lockFile)) {
            if ($line -match "`"$name`"") {
                return $true
            }
        }
        return $false
    }

    function Remove-LockCfgSetting {
        param(
            [String] $name,
            [String] $lockFile = "$(Get-FirefoxInstallDirectory)\mozilla.cfg"
        )
        $newLockFileContents = @()
        foreach ($line in (Get-Content $lockFile)) {
            if ($line -notmatch "`"$name`"") {
                $newLockFileContents += @($line)
            }
        }
        Out-File -InputObject $newLockFileContents -FilePath $lockFile -Encoding ASCII -Force
    }

    function Add-LockCfgSetting {
        param(
            [String] $name,
            $value,
            [String] $lockFile = "$(Get-FirefoxInstallDirectory)\mozilla.cfg"
        )

        if ($value.GetType().FullName -match "System.Int*") {
            $wrappedValue = $value
        }
        else {
            $wrappedValue = "`"$value`""
        }
        $newSettingLine = 'pref("{0}", {1});' -f $name, $wrappedValue

        if (-not (Test-Path $lockFile)) {
            Out-File -InputObject "//" -FilePath $lockFile -Encoding "ASCII"
        }
        if (Test-LockCfgSetting -name $name -lockFile $lockFile) {Remove-LockCfgSetting -name $name -lockFile $lockFile}
        Add-FileLineIdempotently -file $lockFile -Encoding ASCII -newLine $newSettingLine
    }

    <#
    .notes
    We assume that $lockPrefFile is unique to us and we can always overwrite it
    See also: http://kb.mozillazine.org/Locking_preferences
    #>
    function Enable-LockCfg {
        [cmdletbinding()] param(
            [String] $lockPrefFile = "$(Get-FirefoxInstallDirectory)\defaults\pref\marionettist-locked-configuration.js"
        )
        $lockPrefContents = @(
            'pref("general.config.obscure_value", 0);' # only needed if you do not want to obscure the content with ROT-13
            'pref("general.config.filename", "mozilla.cfg");'
        )
        Out-File -InputObject $lockPrefContents -FilePath $lockPrefFile -Encoding ASCII -Force
    }

    if ($systemDisableImportWizard) {
        $overrideIniContents = @(
            '[XRE]'
            'EnableProfileMigrator=false'
        )
        Out-File -InputObject $overrideIniContents -FilePath "$ffDir\browser\override.ini" -Encoding UTF8
    }
    if ($systemDisableWhatsNew) {
        Add-LockCfgSetting -name "browser.startup.homepage_override.mstone" -value "ignore"
        Enable-LockCfg
    }
    if ($systemEnableGlobalAddOns) {
        $globalAddOnsPrefFile = "$ffDir\defaults\pref\marionettist-enable-global-add-ons.js"
        # See also: https://mike.kaply.com/2012/02/21/understanding-add-on-scopes/
        Add-FileLineIdempotently -file "$globalAddOnsPrefFile" -Encoding ASCII -newLine @(
            'pref("extensions.enabledScopes", "15");'
            'pref("extensions.autoDisableScopes", 0);'
            'pref("extensions.shownSelectionUI", true);'
        )
    }
    if ($systemInstallAddOnsFromUrl) {
        foreach ($url in $systemInstallAddOnsFromUrl) {
            Install-FirefoxAddOnGlobally $url
        }
    }
    if ($userDeleteConfiguration) {
        Get-Process |? Name -eq "firefox" | Stop-Process
        @("${env:AppData}\Mozilla\Firefox", "${env:LocalAppData}\Mozilla\Firefox") |% { if (test-path $_) {Remove-Item -Recurse -Force $_} }
    }
    if ($userSetDefaultBrowser) {
        Start-Process -FilePath $ffPath -ArgumentList @("-silent", "-setDefaultBrowser") -Wait -Verb RunAs
        # This didn't appear to work:
        # $defaultBrowserPath = "HKCU:\Software\Classes\http\shell\open\command"
        # $defaultBrowserValue = '"{0}" -osint -url "%1"' -f $ffPath
        # Set-ItemProperty -path $defaultBrowserPath -name "(default)" -value $defaultBrowserValue
    }
}

<#
.parameter latestDownloadUrl
Obtain this parameter by going to the site for the add-on at addons.mozilla.org and copying the link from under the "Add to Firefox" button
.notes
Since recent versions of Firefox, you must use only signed add-ons, which typically means you have to get them from addons.mozilla.org

See also: https://support.mozilla.org/en-US/questions/966922
#>
function Install-FirefoxAddOnGlobally {
    [CmdletBinding(DefaultParameterSetName="Name")] param(
        [Parameter(ParameterSetName="Url", Mandatory=$true)] [String] $latestDownloadUrl,
        [Parameter(ParameterSetName="Name", Mandatory=$true)] [String] $addOnName
    )
    $ffDir = Get-FirefoxInstallDirectory
    $ffSystemExtensionsDir = "$ffDir\browser\extensions"

    if ($addOnName) {
        $downloadPageUrl = "https://addons.mozilla.org/en-US/firefox/addon/$addOnName/"
        $downloadPageResponse = Invoke-WebRequest -Uri $downloadPageUrl
        #$downloadUrl = $downloadPageResponse.ParsedHtml.getElementById("addon").getElementsByClassName("install-button")[0].getElementsByTagName('a')[0] | Select -Expand href
        $addOnId = $downloadPageResponse.ParsedHtml.getElementById("addon").attributes |? { $_.nodeName -eq "data-id" } | Select -Expand nodeValue
        $latestDownloadUrl = "https://addons.mozilla.org/firefox/downloads/latest/$addOnId/addon-$addOnId-latest.xpi"
    }

    # Cannot install from GitHub, because the version posted there is not signed
    # $latestReleaseUrl = "https://api.github.com/repos/gorhill/uBlock/releases/latest"
    # $uboXpiInfo = Invoke-RestMethod -Uri $latestReleaseUrl | Select -Expand assets |? -Property content_type -eq "application/x-xpinstall"
    # $downloadedXpiPath = Get-WebUrl -url $uboXpiInfo.browser_download_url -outDir $ffSystemExtensionsDir

    # Instead, install from addons.mozilla.org:
    $downloadedXpiPath = Get-WebUrl -url $latestDownloadUrl -outDir $ffSystemExtensionsDir

    $tempExtractDir = Join-Path ${env:temp} $downloadedXpiPath.BaseName
    sevenzip x -y "-o$tempExtractDir" $downloadedXpiPath

    # For automatic installation, you must install the extension to a folder named after its id, which can be found in the install.rdf of the extension itself:
    [System.Xml.XmlDocument] $installRdfXml = Get-Content "$tempExtractDir\install.rdf"
    $deployedExtractDir = Join-Path $ffSystemExtensionsDir $installrdfxml.RDF.Description.id
    if (Test-Path $deployedExtractDir) { Remove-Item -Force -Recurse $deployedExtractDir }
    mv $tempExtractDir $deployedExtractDir

    Set-FirefoxOptions -systemEnableGlobalAddOns
}

<#
.parameter uniquePreferenceFileName
We assume that this file is unique to us and we can always overwrite it
.notes
See also: https://support.mozilla.org/en-US/questions/966922
#>
function Install-FirefoxUBlockOrigin {
    [CmdletBinding()] param()
    $ffDir = Get-FirefoxInstallDirectory
    $ffSystemExtensionsDir = "$ffDir\browser\extensions"
    $tempExtractDir = Join-Path ${env:temp} 'uBlockOrigin'

    # Cannot install from GitHub, because the version posted there is not signed
    # $latestReleaseUrl = "https://api.github.com/repos/gorhill/uBlock/releases/latest"
    # $uboXpiInfo = Invoke-RestMethod -Uri $latestReleaseUrl | Select -Expand assets |? -Property content_type -eq "application/x-xpinstall"
    # $downloadedXpiPath = Join-Path $ffSystemExtensionsDir $uboXpiInfo.name
    # Get-WebUrl -url $uboXpiInfo.browser_download_url -outFile $downloadedXpiPath
    # Instead, install from addons.mozilla.org:
    Get-WebUrl -url "https://addons.mozilla.org/firefox/downloads/latest/607454/addon-607454-latest.xpi"

    sevenzip x -y "-o$tempExtractDir" $downloadedXpiPath

    # For automatic installation, you must install the extension to a folder named after its id, which can be found in the install.rdf of the extension itself:
    [System.Xml.XmlDocument] $installRdfXml = Get-Content "$tempExtractDir\install.rdf"
    $deployedExtractDir = Join-Path $ffSystemExtensionsDir $installrdfxml.RDF.Description.id
    if (Test-Path $deployedExtractDir) { Remove-Item -Force -Recurse $deployedExtractDir }
    mv $tempExtractDir $deployedExtractDir

    Set-FirefoxOptions -systemEnableGlobalAddOns
}

function Set-UserOptions {
    [cmdletbinding()] param(
        [switch] $ShowHiddenFiles,
        [switch] $ShowSystemFiles,
        [switch] $ShowFileExtensions,
        [switch] $ShowStatusBar,
        [switch] $DisableSharingWizard,
        [switch] $EnablePSOnWinX,
        [switch] $EnableQuickEdit,
        [switch] $DisableSystrayHide,
        [switch] $DisableIEFirstRunCustomize
    )
    $explorerAdvancedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if ($ShowHiddenFiles)      { Set-ItemProperty -path $explorerAdvancedKey -name Hidden -value 1 }
    if ($ShowSystemFiles)      { Set-ItemProperty -path $explorerAdvancedKey -name ShowSuperHidden -value 1 }
    if ($ShowFileExtensions)   { Set-ItemProperty -path $explorerAdvancedKey -name HideFileExt -value 0 }
    if ($ShowStatusBar)        { Set-ItemProperty -path $explorerAdvancedKey -name ShowStatusBar -value 1 }
    if ($DisableSharingWizard) { Set-ItemProperty -path $explorerAdvancedKey -name SharingWizardOn -value 0 }
    if ($EnablePSOnWinX)       { Set-ItemProperty -path $explorerAdvancedKey -name DontUsePowerShellOnWinX -value 0 }
    
    $explorerKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
    if ($DisableSystrayHide)   { Set-ItemProperty -path $explorerKey -name EnableAutoTray -value 0 }

    $consoleKey = "HKCU:\Console"
    if ($EnableQuickEdit) { Set-ItemProperty -path $consoleKey -name QuickEdit -value 1 }
    
    $internetExplorerKey = "HKCU:\Software\Policies\Microsoft\Internet Explorer\Main"
    mkdir -Force $internetExplorerKey
    if ($DisableIEFirstRunCustomize) { Set-ItemProperty -path $internetExplorerKey -name DisableFirstRunCustomize -value 1 }
}

<#
.SYNOPSIS
This function are used to pin and unpin programs from the taskbar and Start-menu in Windows 7 and Windows Server 2008 R2
.DESCRIPTION
The function have to parameteres which are mandatory:
Action: PinToTaskbar, PinToStartMenu, UnPinFromTaskbar, UnPinFromStartMenu
FilePath: The path to the program to perform the action on
.notes
from: https://gallery.technet.microsoft.com/scriptcenter/b66434f1-4b3f-4a94-8dc3-e406eb30b750
TODO: I hate it when things pollute the global variable space!
.EXAMPLE
Set-PinnedApplication -Action PinToTaskbar -FilePath "C:\WINDOWS\system32\notepad.exe"
.EXAMPLE
Set-PinnedApplication -Action UnPinFromTaskbar -FilePath "C:\WINDOWS\system32\notepad.exe"
#>
function Set-PinnedApplication {
    [CmdletBinding()] param(
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$FilePath
    )
    if (-not (test-path $FilePath)) { throw "No file at '$FilePath'" }
    
    function InvokeVerb {
        param([string]$FilePath,$verb)
        $verb = $verb.Replace("&","")
        $path = split-path $FilePath
        $shell = new-object -com "Shell.Application"
        $folder = $shell.Namespace($path)
        $item = $folder.Parsename((split-path $FilePath -leaf))
        $itemVerb = $item.Verbs() | ? {$_.Name.Replace("&","") -eq $verb}
        if ($itemVerb) { $itemVerb.DoIt() } else { throw "Verb $verb not found." }
    }
    function GetVerb {
        param([int]$verbId)
        try { $t = [type]"CosmosKey.Util.MuiHelper" }
        catch {
            $def = [Text.StringBuilder]""
            [void]$def.AppendLine('[DllImport("user32.dll")]')
            [void]$def.AppendLine('public static extern int LoadString(IntPtr h,uint id, System.Text.StringBuilder sb,int maxBuffer);')
            [void]$def.AppendLine('[DllImport("kernel32.dll")]')
            [void]$def.AppendLine('public static extern IntPtr LoadLibrary(string s);')
            add-type -MemberDefinition $def.ToString() -name MuiHelper -namespace CosmosKey.Util
        }
        if($global:CosmosKey_Utils_MuiHelper_Shell32 -eq $null){
            $global:CosmosKey_Utils_MuiHelper_Shell32 = [CosmosKey.Util.MuiHelper]::LoadLibrary("shell32.dll")
        }
        $maxVerbLength = 255
        $verbBuilder = new-object Text.StringBuilder "",$maxVerbLength
        [void][CosmosKey.Util.MuiHelper]::LoadString($CosmosKey_Utils_MuiHelper_Shell32,$verbId,$verbBuilder,$maxVerbLength)
        return $verbBuilder.ToString()
    }
    $verbs = @{
        "PintoStartMenu"=5381
        "UnpinfromStartMenu"=5382
        "PintoTaskbar"=5386
        "UnpinfromTaskbar"=5387
    }
    if ($verbs.$Action -eq $null) {
        throw "Action $action not supported`nSupported actions are:`n`tPintoStartMenu`n`tUnpinfromStartMenu`n`tPintoTaskbar`n`tUnpinfromTaskbar"
    }
    InvokeVerb -FilePath $FilePath -Verb $(GetVerb -VerbId $verbs.$action)
}

function Disable-HibernationFile {
    [cmdletbinding()] param()
    Write-EventLogWrapper "Removing Hibernation file..."
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    Set-ItemProperty -path $powerKey -name HibernateFileSizePercent -value 0  # hiberfil is zero bytes
    Set-ItemProperty -path $powerKey -name HibernateEnabled -value 0          # disable hibernation altogether
}

<#
.synopsis
Forcibly enable WinRM
.notes
TODO: Rewrite in pure Powershell
#>
function Enable-WinRM {
    [cmdletbinding()] param()
    Write-EventLogWrapper "Enabling WinRM..."

    # I've had the best luck doing it this way - NOT doing it in a single batch script
    # Sometimes one of these commands will stop further execution in a batch script, but when I
    # call cmd.exe over and over like this, that problem goes away.
    # Note: order is important. This order makes sure that any time packer can successfully
    # connect to WinRm, it won't later turn winrm back off or make it unavailable.
    Stop-Service WinRM
    Invoke-ExpressionEx -invokeWithCmdExe -command 'sc.exe config winrm start= auto'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm quickconfig -q'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm quickconfig -transport:http'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm set winrm/config @{MaxTimeoutms="1800000"}'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm set winrm/config/winrs @{MaxMemoryPerShellMB="2048"}'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm set winrm/config/service @{AllowUnencrypted="true"}'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm set winrm/config/client @{AllowUnencrypted="true"}'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm set winrm/config/service/auth @{Basic="true"}'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm set winrm/config/client/auth @{Basic="true"}'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm set winrm/config/service/auth @{CredSSP="true"}'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'winrm set winrm/config/listener?Address=*+Transport=HTTP @{Port="5985"}'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'netsh advfirewall firewall set rule group="remote administration" new enable=yes'
    Invoke-ExpressionEx -invokeWithCmdExe -command 'netsh firewall add portopening TCP 5985 "Port 5985"'
    Start-Service WinRM
}

function Add-LocalSamUser {
    [cmdletbinding()] param(
        [Parameter(Mandatory=$true)] [string] $userName,
        [Parameter(Mandatory=$true)] [string] $password,
        [string] $fullName,
        [switch] $PassThru
    )
    Write-EventLogWrapper "Creating a new local user called '$userName'"
    $computer = [ADSI]"WinNT://$env:COMPUTERNAME,Computer"
    $newUser = $computer.Create("User", $userName)
    $newUser.SetPassword($password)
    $newUser.SetInfo()
    $newUser.FullName = $fullName
    $newUser.SetInfo()
    Add-LocalSamUserToGroup -userName $userName -groupName "Users"
    if ($PassThru) { return $newUser }
}

function Add-LocalSamUserToGroup {
    [cmdletbinding()] param(
        [parameter(mandatory=$true)] [string] $userName,
        [parameter(mandatory=$true)] [string] $groupName
    )
    Write-EventLogWrapper "Adding '$userName' to the local '$groupName' group"
    $localAdmins = [ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group"
    $localAdmins.Add("WinNT://$userName")
}

function Set-PasswordExpiry { # TODO fixme use pure Powershell
    [cmdletbinding()] param(
        [parameter(mandatory=$true)] [string] $accountName,
        [parameter(mandatory=$true,ParameterSetName="EnablePasswordExpiry")] [switch] $enable,
        [parameter(mandatory=$true,ParameterSetName="DisablePasswordExpiry")] [switch] $disable
    )
    $passwordExpires = if ($PsCmdlet.ParameterSetName -match "EnablePasswordExpiry") {"TRUE"} else {"FALSE"}
    $command = @"
wmic useraccount where "name='{0}'" set "PasswordExpires={1}"
"@
    $command = $command -f $accountName,$passwordExpires
    Invoke-ExpressionEx -command $command
}

<#
.description
Test whether the machine is joined to a domain
#>
function Test-DomainJoined {
    [CmdletBinding()] Param()
    return (Get-WmiObject win32_computersystem).DomainRole -in @(1,3,4,5)
}

<#
.synopsis
Set all attached networks to Private
.description
(On some OSes) you cannot enable Windows PowerShell Remoting on network connections that are set to Public
Spin through all the network locations and if they are set to Public, set them to Private
using the INetwork interface:
http://msdn.microsoft.com/en-us/library/windows/desktop/aa370750(v=vs.85).aspx
For more info, see:
http://blogs.msdn.com/b/powershell/archive/2009/04/03/setting-network-location-to-private.aspx
#>
function Set-AllNetworksToPrivate {
    [cmdletbinding()] param()

    # Network location feature was only introduced in Windows Vista - no need to bother with this
    # if the operating system is older than Vista
    if([environment]::OSVersion.version.Major -lt 6) {
        Write-EventLogWrapper "Set-AllNetworksToPrivate: Running on pre-Vista machine, no changes necessary"
        return
    }
    Write-EventLogWrapper "Setting all networks to private..."
    
    if (Test-DomainJoined) {
        $message = "Cannot change network location on a domain-joined computer"
        Write-EventLogWrapper -message $message
        throw $message
    }
    else {
        Write-EventLogWrapper "Not joined to domain, continuing..."
    }

    # Disable the GUI which will modally pop up (at least on Win10) lol
    New-Item "HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff" -force | out-null
    
    # Get network connections
    $sleepIntervalSeconds = 5
    $sleepMaxSeconds = 120

    # First we have to make sure the network connections are ready
    $sleepCount = 0
    $successful = $false
    while (-not $successful) {
        $networkListIndex = 0
        # Wrap getting a new $networkListManager and the foreach($connection...) statement in the while loop
        # This ensures that we don't have stale pointers to $networkListManager or the $connection objects
        $networkListManager = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]"{DCB00C01-570F-4A9B-8D69-199FDBA5723B}"))
        foreach ($connection in $networkListManager.GetNetworkConnections()) {
            $successful = $true
            try {
                # .GetNetwork().GetName() sometimes throws
                $networkName = $connection.GetNetwork().GetName()
                # Sometimes it doesn't throw, but it's still identifying the connection, so we throw to move into the catch block
                if ($networkName -eq "Identifying...") {
                    throw "Still identifying"
                }
            }
            catch {
                $successful = $false
                if ($sleepCount -gt $sleepMaxSeconds) {
                    throw "Could not identify the network connection for network #$networkListIndex after $sleepCount seconds"
                }
                Write-EventLogWrapper -message "Network name found to be '$networkName' for network #$networkListIndex after $sleepCount seconds, sleeping for $sleepIntervalSeconds more seconds before trying again..."
                $sleepCount += $sleepIntervalSeconds
                Start-Sleep -Seconds $sleepIntervalSeconds
            }
            $networkListIndex += 1
        }
    }

    $networkListIndex = 0
    foreach ($connection in $networkListManager.GetNetworkConnections()) {
        $message = "Changing connection for network named '$networkName' (network #$networkListIndex) to private... "
        $oldCategory = $connection.GetNetwork().GetCategory()
        $connection.GetNetwork().SetCategory(1)
        $newCategory = $connection.GetNetwork().GetCategory()
        $message += "Successful. Changed connection category from '$oldCategory' to '$newCategory'"
        Write-EventLogWrapper -message $message
        $networkListIndex += 1
    }
}

<#
function Get-PowerScheme {
    [cmdletbinding(DefaultParameterSetName("Active"))] param(
        [Parameter(Mandatory=$true,ParameterSetName="Active")] [switch] $Active,
        [Parameter(Mandatory=$true,ParameterSetName="ByGuid")] [switch] $ByGuid,
        [Parameter(Mandatory=$true,ParameterSetName="ByName")] [switch] $ByName,
    )
    $powerScheme = New-Object PSObject -Property @{Name="";GUID="";}
    $psre = '^Power Scheme GUID\:\s+([A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12})\s+\((.*)\)'
        
    switch ($PsCmdlet.ParameterSetName) {
        "Active" {
            $activeSchemeString = powercfg /getactivescheme
            if ($activeSchemeString -match $psre) {
                $powerScheme.Name = $matches[2]
                $powerScheme.GUID = $matches[1]
            }
            else { write-error "Error: could not find active power configuration"}
        }
        "ByGuid" {
            foreach ($powerSchemeString in (powercfg /list)) {
                $
            }
        }
        "ByName" {}
        default {write-error "Error: not sure how to process a parameter set named $($PsCmdlet.ParameterSetName)"}
    }


    return $powerScheme
}
#>

<#
.synopsis
Set the idle time that must elapse before Windows will power off a display
.parameter seconds
The number of seconds before poweroff. A value of 0 means never power off.
.notes
AFAIK, this cannot be done without shelling out to powercfg
#>
function Set-IdleDisplayPoweroffTime {
    [cmdletbinding()] param(
        [parameter(mandatory=$true)] [int] $seconds
    )
    $currentScheme = (powercfg /getactivescheme).split()[3]
    $DisplaySubgroupGUID = "7516b95f-f776-4464-8c53-06167f40cc99"
    $TurnOffAfterGUID = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"
    set-alias powercfg "${env:SystemRoot}\System32\powercfg.exe"
    powercfg /setacvalueindex $currentScheme $DisplaySubgroupGUID $TurnOffAfterGUID 0
}

<#
.description
Allow connecting to HTTPS WinRM servers (used with, for example, Enter-PSSession) without checking the certificate. This is not recommended, but can be useful for non-domain-joined VMs that will connect to a remote network over a VPN. (Note that not checking the RDP certificate is no improvement over not checking the WinRM certificate.)
#>
function Enable-UntrustedOutboundWinRmConnections {
    [CmdletBinding()] Param()
    Set-Item WSMan:\localhost\Client\Auth\CredSSP $True
    Set-Item WSMan:\localhost\Service\Auth\CredSSP $True
    set-item WSMan:\localhost\Client\TrustedHosts *
    Restart-Service WinRm
}

# Exports: #TODO
$emmParams = @{
    Alias = @("sevenzip")
    Variable = @("ArchitectureId")
    Function = "*"
    # Function =  @(
    #     "Get-OSArchitecture"
    #     "Get-LabTempDir"
    #     "Install-SevenZip"
    #     "Install-VBoxAdditions"
    # )
}
export-modulemember @emmParams
