$ErrorActionPreference = "Stop"

$AppId = "784150"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\WRFreeMouse"

$StatePath = Join-Path $InstallDir "WR FreeMouse state.json"

$BackupDir = Join-Path $InstallDir "Backup"
$SteamBackupPath = Join-Path $BackupDir "Steam localconfig before last change.vdf"

$PayloadDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Files"
$PackageVersionPath = Join-Path $PayloadDir "Package version.json"

if (-not (Test-Path -LiteralPath $PackageVersionPath)) {
    throw "Package version manifest is missing: $PackageVersionPath"
}

$PackageVersionInfo = Get-Content -Raw -LiteralPath $PackageVersionPath | ConvertFrom-Json
$Version = [string]$PackageVersionInfo.Version
$BuildId = [int64]$PackageVersionInfo.BuildId
$RuntimeScriptName = "WR FreeMouse Runtime.ps1"
$LaunchScriptName = "WR FreeMouse Launch.ps1"
$LaunchVbsName = "WR FreeMouse Launch.vbs"
$ObserverScriptName = "WR FreeMouse Observer.ps1"
$DebugCmdName = "WR FreeMouse Debug.cmd"

$LaunchScriptPath = Join-Path $InstallDir $LaunchScriptName
$LaunchVbsPath = Join-Path $InstallDir $LaunchVbsName
$WScriptExe = Join-Path $env:SystemRoot "System32\wscript.exe"

# wscript.exe is a Windows GUI-subsystem executable. It creates no console
# window. //B suppresses script UI; //Nologo suppresses the WSH banner.
$LaunchPrefix =
    '"' + $WScriptExe + '"' +
    ' //B //Nologo ' +
    '"' + $LaunchVbsPath + '"'

$script:SkipFinalPause = $false

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class SteamVdfTools
{
    private enum TokenType
    {
        String,
        OpenBrace,
        CloseBrace
    }

    private sealed class Token
    {
        public TokenType Type;
        public string Value;
        public int Start;
        public int End;
    }

    private sealed class Pair
    {
        public string Key;
        public Token KeyToken;
        public Token ValueToken;
        public Token OpenToken;
        public Token CloseToken;
        public List<Pair> Children = new List<Pair>();

        public bool IsBlock
        {
            get { return OpenToken != null; }
        }
    }

    private static List<Token> Tokenize(string text)
    {
        List<Token> tokens = new List<Token>();
        int i = 0;

        while (i < text.Length)
        {
            char c = text[i];

            if (Char.IsWhiteSpace(c))
            {
                i++;
                continue;
            }

            if (
                c == '/' &&
                i + 1 < text.Length &&
                text[i + 1] == '/'
            )
            {
                i += 2;
                while (
                    i < text.Length &&
                    text[i] != '\r' &&
                    text[i] != '\n'
                )
                {
                    i++;
                }
                continue;
            }

            if (c == '{')
            {
                tokens.Add(
                    new Token {
                        Type = TokenType.OpenBrace,
                        Value = "{",
                        Start = i,
                        End = i + 1
                    }
                );
                i++;
                continue;
            }

            if (c == '}')
            {
                tokens.Add(
                    new Token {
                        Type = TokenType.CloseBrace,
                        Value = "}",
                        Start = i,
                        End = i + 1
                    }
                );
                i++;
                continue;
            }

            if (c == '"')
            {
                int start = i;
                i++;
                StringBuilder value = new StringBuilder();

                while (i < text.Length)
                {
                    char q = text[i];

                    if (q == '\\' && i + 1 < text.Length)
                    {
                        char next = text[i + 1];

                        if (next == '\\' || next == '"')
                        {
                            value.Append(next);
                            i += 2;
                            continue;
                        }

                        value.Append(q);
                        i++;
                        continue;
                    }

                    if (q == '"')
                    {
                        i++;
                        break;
                    }

                    value.Append(q);
                    i++;
                }

                tokens.Add(
                    new Token {
                        Type = TokenType.String,
                        Value = value.ToString(),
                        Start = start,
                        End = i
                    }
                );
                continue;
            }

            // Bare token fallback.
            int bareStart = i;
            StringBuilder bare = new StringBuilder();

            while (
                i < text.Length &&
                !Char.IsWhiteSpace(text[i]) &&
                text[i] != '{' &&
                text[i] != '}'
            )
            {
                bare.Append(text[i]);
                i++;
            }

            tokens.Add(
                new Token {
                    Type = TokenType.String,
                    Value = bare.ToString(),
                    Start = bareStart,
                    End = i
                }
            );
        }

        return tokens;
    }

    private static List<Pair> ParseItems(
        List<Token> tokens,
        ref int index,
        out Token closeToken
    )
    {
        List<Pair> result = new List<Pair>();
        closeToken = null;

        while (index < tokens.Count)
        {
            Token current = tokens[index];

            if (current.Type == TokenType.CloseBrace)
            {
                closeToken = current;
                index++;
                break;
            }

            if (current.Type != TokenType.String)
            {
                index++;
                continue;
            }

            Token keyToken = current;
            index++;

            if (index >= tokens.Count)
            {
                break;
            }

            Token next = tokens[index];

            if (next.Type == TokenType.String)
            {
                index++;

                result.Add(
                    new Pair {
                        Key = keyToken.Value,
                        KeyToken = keyToken,
                        ValueToken = next
                    }
                );

                continue;
            }

            if (next.Type == TokenType.OpenBrace)
            {
                index++;
                Token childClose;
                List<Pair> children =
                    ParseItems(
                        tokens,
                        ref index,
                        out childClose
                    );

                result.Add(
                    new Pair {
                        Key = keyToken.Value,
                        KeyToken = keyToken,
                        OpenToken = next,
                        CloseToken = childClose,
                        Children = children
                    }
                );

                continue;
            }

            index++;
        }

        return result;
    }

    private static List<Pair> Parse(string text)
    {
        List<Token> tokens = Tokenize(text);
        int index = 0;
        Token ignored;
        return ParseItems(tokens, ref index, out ignored);
    }

    private static Pair Child(
        List<Pair> pairs,
        string key
    )
    {
        foreach (Pair pair in pairs)
        {
            if (
                String.Equals(
                    pair.Key,
                    key,
                    StringComparison.OrdinalIgnoreCase
                )
            )
            {
                return pair;
            }
        }

        return null;
    }

    private static Pair FindBlock(
        List<Pair> roots,
        string[] path
    )
    {
        List<Pair> current = roots;
        Pair found = null;

        foreach (string part in path)
        {
            found = Child(current, part);

            if (
                found == null ||
                !found.IsBlock
            )
            {
                return null;
            }

            current = found.Children;
        }

        return found;
    }

    private static Pair FindLaunchPair(
        Pair app
    )
    {
        if (app == null) return null;
        return Child(app.Children, "LaunchOptions");
    }

    private static string[] AppPath(string appId)
    {
        return new string[] {
            "UserLocalConfigStore",
            "Software",
            "Valve",
            "Steam",
            "apps",
            appId
        };
    }

    private static string[] AppsPath()
    {
        return new string[] {
            "UserLocalConfigStore",
            "Software",
            "Valve",
            "Steam",
            "apps"
        };
    }

    private static string ReadText(
        string path,
        out bool hadBom
    )
    {
        byte[] data = File.ReadAllBytes(path);

        hadBom =
            data.Length >= 3 &&
            data[0] == 0xEF &&
            data[1] == 0xBB &&
            data[2] == 0xBF;

        int offset = hadBom ? 3 : 0;

        return Encoding.UTF8.GetString(
            data,
            offset,
            data.Length - offset
        );
    }

    private static void WriteText(
        string path,
        string text,
        bool withBom
    )
    {
        UTF8Encoding encoding =
            new UTF8Encoding(
                withBom
            );

        string temp =
            path + ".wrfm.tmp";

        File.WriteAllText(
            temp,
            text,
            encoding
        );

        if (File.Exists(path))
        {
            File.Delete(path);
        }

        File.Move(
            temp,
            path
        );
    }

    private static string Quote(string value)
    {
        return
            "\"" +
            value
                .Replace("\\", "\\\\")
                .Replace("\"", "\\\"") +
            "\"";
    }

    private static string NewLine(string text)
    {
        return
            text.Contains("\r\n")
            ? "\r\n"
            : "\n";
    }

    private static int LineStart(
        string text,
        int position
    )
    {
        int p =
            Math.Max(
                0,
                position - 1
            );

        while (
            p > 0 &&
            text[p - 1] != '\n' &&
            text[p - 1] != '\r'
        )
        {
            p--;
        }

        return p;
    }

    private static string IndentAt(
        string text,
        int position
    )
    {
        int start =
            LineStart(
                text,
                position
            );

        int i = start;

        while (
            i < position &&
            (
                text[i] == ' ' ||
                text[i] == '\t'
            )
        )
        {
            i++;
        }

        return text.Substring(
            start,
            i - start
        );
    }

    public static bool HasApp(
        string path,
        string appId
    )
    {
        bool bom;
        string text = ReadText(path, out bom);
        List<Pair> roots = Parse(text);

        return
            FindBlock(
                roots,
                AppPath(appId)
            ) != null;
    }

    public static string GetLaunchOptions(
        string path,
        string appId
    )
    {
        bool bom;
        string text = ReadText(path, out bom);
        List<Pair> roots = Parse(text);

        Pair app =
            FindBlock(
                roots,
                AppPath(appId)
            );

        Pair launch =
            FindLaunchPair(app);

        return
            launch != null &&
            launch.ValueToken != null
            ? launch.ValueToken.Value
            : "";
    }

    public static void SetLaunchOptions(
        string path,
        string appId,
        string value
    )
    {
        bool bom;
        string text = ReadText(path, out bom);
        List<Pair> roots = Parse(text);

        Pair app =
            FindBlock(
                roots,
                AppPath(appId)
            );

        string quoted =
            Quote(value);

        if (app != null)
        {
            Pair launch =
                FindLaunchPair(app);

            if (
                launch != null &&
                launch.ValueToken != null
            )
            {
                text =
                    text.Substring(
                        0,
                        launch.ValueToken.Start
                    ) +
                    quoted +
                    text.Substring(
                        launch.ValueToken.End
                    );

                WriteText(path, text, bom);
                return;
            }

            if (app.CloseToken == null)
            {
                throw new InvalidDataException(
                    "The W&R app block has no closing brace."
                );
            }

            string nl = NewLine(text);
            int insertAt =
                LineStart(
                    text,
                    app.CloseToken.Start
                );

            string closeIndent =
                IndentAt(
                    text,
                    app.CloseToken.Start
                );

            string childIndent =
                closeIndent + "\t";

            string insert =
                childIndent +
                "\"LaunchOptions\"\t\t" +
                quoted +
                nl;

            text =
                text.Substring(0, insertAt) +
                insert +
                text.Substring(insertAt);

            WriteText(path, text, bom);
            return;
        }

        Pair apps =
            FindBlock(
                roots,
                AppsPath()
            );

        if (
            apps == null ||
            apps.CloseToken == null
        )
        {
            throw new InvalidDataException(
                "Could not locate UserLocalConfigStore/Software/Valve/Steam/apps."
            );
        }

        string newline = NewLine(text);
        int appInsertAt =
            LineStart(
                text,
                apps.CloseToken.Start
            );

        string appsCloseIndent =
            IndentAt(
                text,
                apps.CloseToken.Start
            );

        string appIndent =
            appsCloseIndent + "\t";

        string launchIndent =
            appIndent + "\t";

        string appInsert =
            appIndent +
            Quote(appId) +
            newline +
            appIndent +
            "{" +
            newline +
            launchIndent +
            "\"LaunchOptions\"\t\t" +
            quoted +
            newline +
            appIndent +
            "}" +
            newline;

        text =
            text.Substring(0, appInsertAt) +
            appInsert +
            text.Substring(appInsertAt);

        WriteText(path, text, bom);
    }
}
"@

function Write-Title {
    Clear-Host
    Write-Host ("WR FreeMouse {0} Setup  (build {1})" -f $Version, $BuildId)
    Write-Host "========================="
    Write-Host ""
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string]$Default
    )

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Get-SteamRoot {
    $candidates = @()

    try {
        $p = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
        if ($p) { $candidates += $p }
    }
    catch { }

    try {
        $p = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction Stop).InstallPath
        if ($p) { $candidates += $p }
    }
    catch { }

    try {
        $p = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Valve\Steam" -ErrorAction Stop).InstallPath
        if ($p) { $candidates += $p }
    }
    catch { }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Steam installation could not be located."
}

function Get-SteamConfigCandidates {
    param([string]$SteamRoot)

    $userdata = Join-Path $SteamRoot "userdata"
    if (-not (Test-Path -LiteralPath $userdata)) {
        throw "Steam userdata folder was not found: $userdata"
    }

    $items = @()

    foreach ($dir in (Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction Stop)) {
        $config = Join-Path $dir.FullName "config\localconfig.vdf"

        if (Test-Path -LiteralPath $config) {
            $hasApp = $false
            try {
                $hasApp = [SteamVdfTools]::HasApp($config, $AppId)
            }
            catch { }

            $items += [pscustomobject]@{
                UserId = $dir.Name
                Path = $config
                HasApp = $hasApp
                LastWrite = (Get-Item -LiteralPath $config).LastWriteTime
            }
        }
    }

    return @($items)
}

function Select-SteamConfig {
    param(
        [string]$SteamRoot,
        $ExistingState
    )

    if ($ExistingState -and $ExistingState.SteamConfigPath) {
        if (Test-Path -LiteralPath $ExistingState.SteamConfigPath) {
            return [string]$ExistingState.SteamConfigPath
        }
    }

    $all = @(Get-SteamConfigCandidates -SteamRoot $SteamRoot)

    if ($all.Count -eq 0) {
        throw "No Steam localconfig.vdf files were found."
    }

    if ($all.Count -eq 1) {
        return $all[0].Path
    }

    $withApp = @($all | Where-Object { $_.HasApp })

    if ($withApp.Count -eq 1) {
        return $withApp[0].Path
    }

    Write-Host "More than one Steam user profile exists on this PC."
    Write-Host "Select the account whose W&R Launch Options should be updated:"
    Write-Host ""

    $i = 1
    foreach ($item in $all) {
        $marker = if ($item.HasApp) { "W&R entry found" } else { "no W&R entry" }
        Write-Host ("  [{0}] Steam userdata {1} - {2} - modified {3}" -f
            $i, $item.UserId, $marker, $item.LastWrite)
        $i++
    }

    while ($true) {
        $choice = Read-Host "Account number"
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $all.Count) {
            return $all[$n - 1].Path
        }
    }
}

function Get-VersionComparison {
    param($State)

    if (-not $State) {
        return [pscustomobject]@{
            Status = "NotInstalled"
            InstalledVersion = ""
            InstalledBuildId = 0
        }
    }

    $installedVersionText =
        if ($State.Version) {
            [string]$State.Version
        }
        else {
            "0.0.0"
        }

    $installedBuildId = 0
    if (
        $State.PSObject.Properties.Name -contains "BuildId" -and
        $null -ne $State.BuildId
    ) {
        try {
            $installedBuildId = [int64]$State.BuildId
        }
        catch {
            $installedBuildId = 0
        }
    }

    try {
        $installedVersion = [version]$installedVersionText
        $packageVersion = [version]$Version
    }
    catch {
        return [pscustomobject]@{
            Status = "Unknown"
            InstalledVersion = $installedVersionText
            InstalledBuildId = $installedBuildId
        }
    }

    $versionCompare =
        $installedVersion.CompareTo(
            $packageVersion
        )

    if ($versionCompare -lt 0) {
        $status = "Older"
    }
    elseif ($versionCompare -gt 0) {
        $status = "Newer"
    }
    elseif ($installedBuildId -lt $BuildId) {
        $status = "Older"
    }
    elseif ($installedBuildId -gt $BuildId) {
        $status = "Newer"
    }
    else {
        $status = "Current"
    }

    return [pscustomobject]@{
        Status = $status
        InstalledVersion = $installedVersionText
        InstalledBuildId = $installedBuildId
    }
}

function Get-InstallState {
    $readPath = $null

    if (Test-Path -LiteralPath $StatePath) {
        $readPath = $StatePath
    }

    if (-not $readPath) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $readPath | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Save-InstallState {
    param($State)

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    $State |
        ConvertTo-Json -Depth 8 |
        Set-Content -Encoding UTF8 -LiteralPath $StatePath
}

function Get-StateLaunchPrefix {
    param($State)

    if (-not $State) {
        return $null
    }

    if (
        $State.PSObject.Properties.Name -contains "LaunchPrefix" -and
        $State.LaunchPrefix
    ) {
        return [string]$State.LaunchPrefix
    }

    return $null
}

function Test-WrfmWrapperPresent {
    param(
        [string]$Options,
        [string]$Prefix = ""
    )

    if ([string]::IsNullOrWhiteSpace($Options)) {
        return $false
    }

    $trimmed = $Options.TrimStart()

    if ($Prefix) {
        return $trimmed.StartsWith(
            $Prefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }

    return $trimmed.StartsWith(
        $LaunchPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-ComplexLaunchOptions {
    param([string]$Options)

    if ([string]::IsNullOrWhiteSpace($Options)) { return $false }

    if ($Options -match "[`r`n]") { return $true }

    # Shell control operators can change meaning when passed through a wrapper.
    if ($Options.IndexOfAny([char[]]"&|<>^") -ge 0) { return $true }

    $commandTokens = [regex]::Matches(
        $Options,
        [regex]::Escape("%command%"),
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    return ($commandTokens.Count -gt 1)
}

function New-WrappedLaunchOptions {
    param([string]$BaseOptions)

    $base = if ($null -eq $BaseOptions) { "" } else { $BaseOptions.Trim() }

    $hasCommand = $base.IndexOf(
        "%command%",
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0

    if ($hasCommand) {
        return [pscustomobject]@{
            Mode = "PrefixExistingExpression"
            Value = if ($base) { "$LaunchPrefix $base" } else { "$LaunchPrefix %command%" }
        }
    }

    return [pscustomobject]@{
        Mode = "InsertCommand"
        Value = if ($base) { "$LaunchPrefix %command% $base" } else { "$LaunchPrefix %command%" }
    }
}

function Remove-WrfmWrapper {
    param(
        [string]$CurrentOptions,
        [string]$WrapMode,
        [string]$Prefix
    )

    if (-not $Prefix) {
        return $null
    }

    $current = if ($null -eq $CurrentOptions) { "" } else { $CurrentOptions.Trim() }

    if ($WrapMode -eq "InsertCommand") {
        $wrappedPrefix = "$Prefix %command%"

        if ($current.StartsWith($wrappedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $current.Substring($wrappedPrefix.Length).TrimStart()
        }

        return $null
    }

    if ($WrapMode -eq "PrefixExistingExpression") {
        $wrappedPrefix = "$Prefix "

        if ($current.StartsWith($wrappedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $current.Substring($wrappedPrefix.Length)
        }

        return $null
    }

    return $null
}

function Invoke-WrapperSelfTest {
    $examples = @(
        [pscustomobject]@{ Base = ""; ExpectedMode = "InsertCommand" },
        [pscustomobject]@{ Base = "-windowed"; ExpectedMode = "InsertCommand" },
        [pscustomobject]@{ Base = '%command% -windowed'; ExpectedMode = "PrefixExistingExpression" },
        [pscustomobject]@{ Base = '-foo "quoted value"'; ExpectedMode = "InsertCommand" }
    )

    foreach ($example in $examples) {
        $wrapped = New-WrappedLaunchOptions -BaseOptions $example.Base

        if ($wrapped.Mode -ne $example.ExpectedMode) {
            throw "Internal wrapper self-test failed (mode)."
        }

        $restored = Remove-WrfmWrapper -CurrentOptions $wrapped.Value -WrapMode $wrapped.Mode -Prefix $LaunchPrefix

        if ($restored -cne $example.Base) {
            throw "Internal wrapper self-test failed. Expected '$($example.Base)', got '$restored'."
        }
    }
}

function Remove-TransientArtifacts {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        return
    }

    foreach ($name in @(
        "stop requested.flag",
        "runtime status.json",
        "WR FreeMouse error.txt",
        "WR FreeMouse launch error.txt"
    )) {
        Remove-Item `
            -Force `
            -ErrorAction SilentlyContinue `
            -LiteralPath (Join-Path $InstallDir $name)
    }
}

function Assert-PowerShellSyntax {
    param([string]$Path)

    $tokens = $null
    $errors = $null

    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors -and $errors.Count -gt 0) {
        $message =
            ($errors |
                ForEach-Object {
                    $_.Message
                }) -join "; "

        throw "PowerShell syntax self-test failed for '$Path': $message"
    }
}

function Invoke-RuntimeCoreCompileSelfTest {
    $runtimePath =
        Join-Path $PayloadDir $RuntimeScriptName

    $source =
        Get-Content -Raw -LiteralPath $runtimePath

    $beginMarker =
        '# WRFM_CORE_CSHARP_BEGIN'

    $startMarker =
        'Add-Type -TypeDefinition @"'

    $endMarker =
        '"@ -ReferencedAssemblies $wrReferences'

    $finishMarker =
        '# WRFM_CORE_CSHARP_END'

    $begin =
        $source.IndexOf(
            $beginMarker,
            [System.StringComparison]::Ordinal
        )

    if ($begin -lt 0) {
        throw "Runtime C# compile self-test could not find WRFM_CORE_CSHARP_BEGIN."
    }

    $finish =
        $source.IndexOf(
            $finishMarker,
            $begin + $beginMarker.Length,
            [System.StringComparison]::Ordinal
        )

    if ($finish -lt 0) {
        throw "Runtime C# compile self-test could not find WRFM_CORE_CSHARP_END."
    }

    $start =
        $source.IndexOf(
            $startMarker,
            $begin + $beginMarker.Length,
            [System.StringComparison]::Ordinal
        )

    if (
        $start -lt 0 -or
        $start -ge $finish
    ) {
        throw "Runtime C# compile self-test could not find the core Add-Type start inside its markers."
    }

    $codeStart =
        $start +
        $startMarker.Length

    $end =
        $source.IndexOf(
            $endMarker,
            $codeStart,
            [System.StringComparison]::Ordinal
        )

    if (
        $end -lt 0 -or
        $end -ge $finish
    ) {
        throw "Runtime C# compile self-test could not find the core Add-Type end inside its markers."
    }

    $code =
        $source.Substring(
            $codeStart,
            $end - $codeStart
        )

    # Guard against accidentally extracting the small startup probe or
    # swallowing PowerShell between C# blocks.
    if (
        $code.IndexOf(
            'public static class WRFreeMouse',
            [System.StringComparison]::Ordinal
        ) -lt 0
    ) {
        throw "Runtime C# compile self-test extracted a block that is not WRFreeMouse."
    }

    if (
        $code.IndexOf(
            'WRGameWindowProbe',
            [System.StringComparison]::Ordinal
        ) -ge 0 -or
        $code.IndexOf(
            'Add-Type -TypeDefinition',
            [System.StringComparison]::Ordinal
        ) -ge 0
    ) {
        throw "Runtime C# compile self-test extracted mixed/non-core source."
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $references = @(
            [System.Windows.Forms.Form].Assembly.Location,
            [System.Drawing.Bitmap].Assembly.Location
        )

        Add-Type `
            -TypeDefinition $code `
            -ReferencedAssemblies $references `
            -ErrorAction Stop
    }
    catch {
        throw (
            "Runtime C# compile self-test failed BEFORE installation: " +
            $_.Exception.Message
        )
    }
}

function Invoke-PayloadSelfTests {
    Assert-PowerShellSyntax -Path (Join-Path $PayloadDir $RuntimeScriptName)
    Assert-PowerShellSyntax -Path (Join-Path $PayloadDir $LaunchScriptName)

    $observerPath =
        Join-Path $PayloadDir $ObserverScriptName

    if (Test-Path -LiteralPath $observerPath) {
        Assert-PowerShellSyntax -Path $observerPath
    }

    Invoke-RuntimeCoreCompileSelfTest
}

function Assert-CorePayload {
    foreach ($name in @(
        $RuntimeScriptName,
        $LaunchScriptName,
        $LaunchVbsName,
        "Package version.json"
    )) {
        $path = Join-Path $PayloadDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Setup payload is incomplete: $name is missing."
        }
    }
}

function Assert-DebugPayload {
    foreach ($name in @(
        $ObserverScriptName,
        $DebugCmdName
    )) {
        $path = Join-Path $PayloadDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            throw "The optional debug payload is not in this package: $name is missing. Re-download the release to install debug tools."
        }
    }
}

function Install-Files {
    param([bool]$IncludeDebug)

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    Remove-TransientArtifacts

    Copy-Item -Force -LiteralPath (Join-Path $PayloadDir $RuntimeScriptName) -Destination (Join-Path $InstallDir $RuntimeScriptName)
    Copy-Item -Force -LiteralPath (Join-Path $PayloadDir $LaunchScriptName) -Destination (Join-Path $InstallDir $LaunchScriptName)
    Copy-Item -Force -LiteralPath (Join-Path $PayloadDir $LaunchVbsName) -Destination (Join-Path $InstallDir $LaunchVbsName)

    if ($IncludeDebug) {
        Assert-DebugPayload
        Copy-Item -Force -LiteralPath (Join-Path $PayloadDir $ObserverScriptName) -Destination (Join-Path $InstallDir $ObserverScriptName)
        Copy-Item -Force -LiteralPath (Join-Path $PayloadDir $DebugCmdName) -Destination (Join-Path $InstallDir $DebugCmdName)
    }
    else {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $InstallDir $ObserverScriptName)
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $InstallDir $DebugCmdName)
    }
}

function Assert-WRClosed {
    $wr = Get-Process -Name "SOVIET64","SOVIET" -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($wr) {
        Write-Host ""
        Write-Host "Workers & Resources is currently running."
        Write-Host "Close the game before installing, repairing, or uninstalling WR FreeMouse."
        Write-Host "No changes have been made."
        throw "W&R is running."
    }
}

function Stop-SteamForConfigEdit {
    param(
        [string]$SteamExe
    )

    $steam = Get-Process -Name "steam" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $steam) {
        return $false
    }

    Write-Host ""
    Write-Host "Steam is running."
    Write-Host "Setup must restart Steam once so Launch Options are not overwritten."
    $answer = Read-Choice -Prompt "Continue and restart Steam?" -Default "Y"

    if ($answer -notin @("Y","y","YES","Yes","yes")) {
        throw "Cancelled before changing Steam."
    }

    Write-Host "Closing Steam..."
    try {
        Start-Process -FilePath $SteamExe -ArgumentList "-shutdown" -WindowStyle Hidden
    }
    catch {
        throw "Steam could not be asked to shut down: $($_.Exception.Message)"
    }

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Process -Name "steam" -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }

    if (Get-Process -Name "steam" -ErrorAction SilentlyContinue) {
        Write-Host ""
        Write-Host "Steam is still running. Exit Steam completely, then press Enter."
        [void](Read-Host)

        if (Get-Process -Name "steam" -ErrorAction SilentlyContinue) {
            throw "Steam is still running; Launch Options were not changed."
        }
    }

    Start-Sleep -Milliseconds 750
    return $true
}

function Set-SteamLaunchOptionsSafely {
    param(
        [string]$SteamRoot,
        [string]$ConfigPath,
        [string]$NewValue
    )

    $steamExe = Join-Path $SteamRoot "steam.exe"
    if (-not (Test-Path -LiteralPath $steamExe)) {
        throw "steam.exe was not found at $steamExe"
    }

    $current = [SteamVdfTools]::GetLaunchOptions($ConfigPath, $AppId)

    if ($current -ceq $NewValue) {
        return [pscustomobject]@{
            Changed = $false
            SteamWasRunning = $false
        }
    }

    $steamWasRunning = Stop-SteamForConfigEdit -SteamExe $steamExe

    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $backup = $SteamBackupPath
    Copy-Item -Force -LiteralPath $ConfigPath -Destination $backup

    try {
        [SteamVdfTools]::SetLaunchOptions($ConfigPath, $AppId, $NewValue)

        $verify = [SteamVdfTools]::GetLaunchOptions($ConfigPath, $AppId)
        if ($verify -cne $NewValue) {
            throw "Steam Launch Options verification failed after writing."
        }
    }
    catch {
        Copy-Item -Force -LiteralPath $backup -Destination $ConfigPath

        if ($steamWasRunning) {
            Start-Process -FilePath $steamExe
        }

        throw
    }

    if ($steamWasRunning) {
        Write-Host "Starting Steam again..."
        Start-Process -FilePath $steamExe
    }

    return [pscustomobject]@{
        Changed = $true
        SteamWasRunning = $steamWasRunning
    }
}

function Get-CurrentBaseOptions {
    param(
        [string]$Current,
        $State
    )

    if ($State) {
        # Strongest/safest path: if Steam still has exactly what the previous
        # installer wrote, trust the previously stored base value.
        if (
            $State.PSObject.Properties.Name -contains "InstalledLaunchOptions" -and
            $State.InstalledLaunchOptions -and
            $Current -ceq [string]$State.InstalledLaunchOptions
        ) {
            return [string]$State.BaseLaunchOptions
        }

        $statePrefix =
            Get-StateLaunchPrefix -State $State

        if (
            $State.WrapMode -and
            $statePrefix -and
            (Test-WrfmWrapperPresent -Options $Current -Prefix $statePrefix)
        ) {
            $unwrapped =
                Remove-WrfmWrapper `
                    -CurrentOptions $Current `
                    -WrapMode $State.WrapMode `
                    -Prefix $statePrefix

            if ($null -ne $unwrapped) {
                return $unwrapped
            }
        }
    }

    return $Current
}

function Install-WRFreeMouse {
    param(
        [bool]$IncludeDebug,
        [bool]$Repair
    )

    Assert-WRClosed
    Assert-CorePayload
    Invoke-WrapperSelfTest
    Invoke-PayloadSelfTests

    $steamRoot = Get-SteamRoot
    $state = Get-InstallState
    $config = Select-SteamConfig -SteamRoot $steamRoot -ExistingState $state
    $current = [SteamVdfTools]::GetLaunchOptions($config, $AppId)

    if (
        -not $state -and
        (Test-WrfmWrapperPresent -Options $current)
    ) {
        throw @"
Steam already contains a WR FreeMouse wrapper, but this Setup has no matching
installation state. Nothing was changed. Restore or remove that old wrapper
manually, or use the release that created it.
"@
    }

    $base = Get-CurrentBaseOptions -Current $current -State $state

    if (Test-ComplexLaunchOptions -Options $base) {
        throw @"
Your existing Steam Launch Options contain shell control operators or multiple
%command% tokens. Setup will not guess how to wrap that expression.

Nothing was changed. Your existing Launch Options are:
$base
"@
    }

    $wrapped = New-WrappedLaunchOptions -BaseOptions $base

    Write-Host ""
    Write-Host $(if ($Repair) { "Operation: update / repair" } else { "Operation: fresh install" })
    Write-Host "Install folder:"
    Write-Host "  $InstallDir"
    Write-Host ""
    Write-Host "Existing Launch Options will be preserved as:"
    Write-Host "  $base"
    Write-Host ""
    Write-Host "Steam will use:"
    Write-Host "  $($wrapped.Value)"
    Write-Host ""

    # Copy files before Steam is edited, so the configured wrapper always exists.
    Install-Files -IncludeDebug $IncludeDebug

    try {
        $result = Set-SteamLaunchOptionsSafely -SteamRoot $steamRoot -ConfigPath $config -NewValue $wrapped.Value
    }
    catch {
        # Do not leave a brand-new partial install after a failed first install.
        if (-not $state) {
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $InstallDir
        }
        throw
    }

    $newState = [pscustomobject]@{
        Product = "WR FreeMouse"
        StateSchemaVersion = 1
        Version = $Version
        BuildId = $BuildId
        InstalledAt = (Get-Date -Format o)
        DebugToolsInstalled = $IncludeDebug
        InstallDir = $InstallDir
        SteamRoot = $steamRoot
        SteamConfigPath = $config
        WrapperPath = $LaunchVbsPath
        LaunchScriptPath = $LaunchScriptPath
        LaunchVbsPath = $LaunchVbsPath
        LaunchPrefix = $LaunchPrefix
        WrapMode = $wrapped.Mode
        BaseLaunchOptions = $base
        InstalledLaunchOptions = $wrapped.Value
    }

    Save-InstallState -State $newState

    Write-Host ""
    Write-Host "WR FreeMouse is installed."
    if ($IncludeDebug) {
        Write-Host "Optional debug tools are installed but do NOT run during normal play."
    }
    else {
        Write-Host "Debug tools were NOT copied to the installed folder."
    }
    Write-Host "Start Workers & Resources normally with the Steam Play button."
}

function Add-DebugTools {
    Assert-DebugPayload
    $state = Get-InstallState
    if (-not $state) { throw "Installation state is missing." }

    Assert-PowerShellSyntax -Path (Join-Path $PayloadDir $ObserverScriptName)

    Copy-Item `
        -Force `
        -LiteralPath (Join-Path $PayloadDir $ObserverScriptName) `
        -Destination (Join-Path $InstallDir $ObserverScriptName)

    Copy-Item `
        -Force `
        -LiteralPath (Join-Path $PayloadDir $DebugCmdName) `
        -Destination (Join-Path $InstallDir $DebugCmdName)

    $state.DebugToolsInstalled = $true
    Save-InstallState -State $state

    Write-Host ""
    Write-Host "Debug tools added."
    Write-Host "They do not run unless you explicitly start a debug session."
}

function Remove-DebugTools {
    $state = Get-InstallState
    if (-not $state) { throw "Installation state is missing." }

    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $InstallDir $ObserverScriptName)
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $InstallDir $DebugCmdName)

    $state.DebugToolsInstalled = $false
    Save-InstallState -State $state

    Write-Host ""
    Write-Host "Debug tools removed from the local WR FreeMouse installation."
    Write-Host "The installed runtime contains no diagnostic keyboard/mouse logger."
    Write-Host ""
    Write-Host "Note: the release ZIP you downloaded still contains the optional debug"
    Write-Host "payload until you delete that downloaded/extracted copy yourself."
}

function Start-DebugSession {
    $debugCmd = Join-Path $InstallDir $DebugCmdName
    if (-not (Test-Path -LiteralPath $debugCmd)) {
        throw "Debug tools are not installed."
    }

    Start-Process -FilePath $debugCmd

    # A new task/window is now active. Do not keep the Setup console around
    # merely to ask the user for an extra Enter.
    $script:SkipFinalPause = $true
}

function Stop-InstalledRuntime {
    if (-not (Test-Path -LiteralPath $InstallDir)) { return }

    $stop = Join-Path $InstallDir "stop requested.flag"
    Set-Content -Encoding ASCII -LiteralPath $stop -Value "stop"

    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        try {
            $m = [System.Threading.Mutex]::OpenExisting("Local\WRFreeMouse.Runtime.784150")
            $m.Dispose()
            Start-Sleep -Milliseconds 100
        }
        catch {
            break
        }
    }

    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $stop
}

function Uninstall-WRFreeMouse {
    Assert-WRClosed

    $state = Get-InstallState
    if (-not $state) {
        throw "Installation state is missing. Setup will not guess what to remove from Steam."
    }

    $steamRoot = if ($state.SteamRoot) { [string]$state.SteamRoot } else { Get-SteamRoot }
    $config = if ($state.SteamConfigPath) { [string]$state.SteamConfigPath } else { Select-SteamConfig -SteamRoot $steamRoot -ExistingState $null }

    if (-not (Test-Path -LiteralPath $config)) {
        throw "Stored Steam configuration no longer exists: $config"
    }

    $current = [SteamVdfTools]::GetLaunchOptions($config, $AppId)
    $statePrefix = Get-StateLaunchPrefix -State $state
    $restored =
        Remove-WrfmWrapper `
            -CurrentOptions $current `
            -WrapMode $state.WrapMode `
            -Prefix $statePrefix

    if ($null -eq $restored) {
        if ($current -ceq $state.BaseLaunchOptions) {
            $restored = $current
        }
        elseif (-not (Test-WrfmWrapperPresent -Options $current -Prefix $statePrefix)) {
            Write-Host ""
            Write-Host "WR FreeMouse's wrapper is no longer present in Steam Launch Options."
            Write-Host "Setup will leave the current Launch Options untouched:"
            Write-Host "  $current"
            $restored = $current
        }
        else {
            throw @"
The current Steam Launch Options still appear to contain WR FreeMouse, but
Setup cannot safely remove the wrapper without risking other user options.
Nothing was changed.
"@
        }
    }

    Write-Host ""
    Write-Host "Steam Launch Options after uninstall will be:"
    Write-Host "  $restored"

    Stop-InstalledRuntime

    [void](Set-SteamLaunchOptionsSafely -SteamRoot $steamRoot -ConfigPath $config -NewValue $restored)

    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $InstallDir

    Write-Host ""
    Write-Host "WR FreeMouse has been uninstalled."
    Write-Host "Only the WR FreeMouse wrapper was removed from Steam Launch Options."
    Write-Host "Other Launch Options were preserved."
}

# ------------------------------ main ------------------------------

try {
    Write-Title
    Invoke-WrapperSelfTest
    Assert-CorePayload

    $state = Get-InstallState

    $observerPresent =
        Test-Path -LiteralPath (Join-Path $InstallDir $ObserverScriptName)

    # Reconcile the recorded debug-tools choice with what is actually on disk.
    # If the state claims debug tools but the installed observer was removed by
    # hand, the tools are effectively gone; treat them as not installed so the
    # menu offers to add them again instead of a session that would fail.
    if (
        $state -and
        ($state.PSObject.Properties.Name -contains "DebugToolsInstalled") -and
        [bool]$state.DebugToolsInstalled -and
        -not $observerPresent
    ) {
        $state.DebugToolsInstalled = $false
    }

    $installed =
        ($null -ne $state) -or
        (Test-Path -LiteralPath (Join-Path $InstallDir $RuntimeScriptName))

    $debugInstalled =
        (
            $state -and
            $state.PSObject.Properties.Name -contains "DebugToolsInstalled" -and
            [bool]$state.DebugToolsInstalled
        ) -or
        $observerPresent

    $versionStatus = Get-VersionComparison -State $state

    if (-not $installed) {
        Write-Host "Status: WR FreeMouse is not installed."
        Write-Host ""
        Write-Host "  [1] Install (recommended)"
        Write-Host "      Installs the runtime plus the optional observation-only debugger."
        Write-Host "      The debugger never runs during normal play."
        Write-Host ""
        Write-Host "  [2] Install without debug tools"
        Write-Host "      Installs only the runtime. No diagnostic keyboard/mouse logging"
        Write-Host "      code is copied to the local WR FreeMouse installation."
        Write-Host ""
        Write-Host "Privacy: the optional debugger can log mouse buttons/positions and"
        Write-Host "selected NON-TEXT keys only when you explicitly start a debug session."
        Write-Host ""

        $choice = Read-Choice -Prompt "Choose" -Default "1"

        switch ($choice) {
            "1" { Install-WRFreeMouse -IncludeDebug $true -Repair $false }
            "2" { Install-WRFreeMouse -IncludeDebug $false -Repair $false }
            default { Write-Host "Cancelled." }
        }
    }
    elseif ($versionStatus.Status -eq "Older") {
        Write-Host (
            "Status: UPDATE AVAILABLE - installed {0} build {1}; package {2} build {3}." -f
            $versionStatus.InstalledVersion,
            $versionStatus.InstalledBuildId,
            $Version,
            $BuildId
        )
        Write-Host ""
        Write-Host "  [1] Update (recommended)"
        Write-Host "      Keeps the current debug-tool choice and preserves Steam Launch Options."
        Write-Host "  [2] Uninstall WR FreeMouse"
        Write-Host ""

        $choice = Read-Choice -Prompt "Choose" -Default "1"

        switch ($choice) {
            "1" { Install-WRFreeMouse -IncludeDebug $debugInstalled -Repair $true }
            "2" { Uninstall-WRFreeMouse }
            default { Write-Host "Cancelled." }
        }
    }
    elseif ($versionStatus.Status -eq "Newer") {
        Write-Host (
            "Status: a NEWER WR FreeMouse build is already installed ({0} build {1})." -f
            $versionStatus.InstalledVersion,
            $versionStatus.InstalledBuildId
        )
        Write-Host "This Setup package is $Version build $BuildId."
        Write-Host ""
        Write-Host "Setup will not downgrade automatically."
        Write-Host "Use a newer/freshly downloaded package, or uninstall explicitly."
        Write-Host ""
        Write-Host "  [1] Cancel (recommended)"
        Write-Host "  [2] Uninstall WR FreeMouse"
        Write-Host ""

        $choice = Read-Choice -Prompt "Choose" -Default "1"

        switch ($choice) {
            "2" { Uninstall-WRFreeMouse }
            default { Write-Host "Cancelled." }
        }
    }
    elseif ($debugInstalled) {
        Write-Host "Status: WR FreeMouse $Version build $BuildId is current, with optional debug tools."
        Write-Host ""
        Write-Host "  [1] Repair / reinstall"
        Write-Host "  [2] Start observation-only debug session"
        Write-Host "  [3] Remove debug tools from the local installation"
        Write-Host "  [4] Uninstall WR FreeMouse"
        Write-Host ""

        $choice = Read-Choice -Prompt "Choose" -Default "1"

        switch ($choice) {
            "1" { Install-WRFreeMouse -IncludeDebug $true -Repair $true }
            "2" { Start-DebugSession }
            "3" { Remove-DebugTools }
            "4" { Uninstall-WRFreeMouse }
            default { Write-Host "Cancelled." }
        }
    }
    else {
        Write-Host "Status: WR FreeMouse $Version build $BuildId is current, without debug tools."
        Write-Host ""
        Write-Host "  [1] Repair / reinstall"
        Write-Host "  [2] Add optional debug tools"
        Write-Host "  [3] Uninstall WR FreeMouse"
        Write-Host ""

        $choice = Read-Choice -Prompt "Choose" -Default "1"

        switch ($choice) {
            "1" { Install-WRFreeMouse -IncludeDebug $false -Repair $true }
            "2" { Add-DebugTools }
            "3" { Uninstall-WRFreeMouse }
            default { Write-Host "Cancelled." }
        }
    }
}
catch {
    Write-Host ""
    Write-Host "SETUP STOPPED"
    Write-Host "-------------"
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "No further changes will be made."
}
finally {
    if (-not $script:SkipFinalPause) {
        Write-Host ""
        Write-Host "Press Enter to close Setup."
        [void](Read-Host)
    }
}
