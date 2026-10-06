param(
  [string]$RepositoryRoot = (
    Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-True {
  param(
    [Parameter(Mandatory)]
    [bool]$Condition,

    [Parameter(Mandatory)]
    [string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory)]
    [string]$Value,

    [Parameter(Mandatory)]
    [string]$Expected,

    [Parameter(Mandatory)]
    [string]$Message
  )
  if (-not $Value.Contains($Expected, [StringComparison]::Ordinal)) {
    throw "$Message Expected '$Expected'."
  }
}

function ConvertTo-ProcessArgument {
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string]$Value
  )
  process {
    if ($Value -match '[\s"]') {
      return '"' + $Value.Replace('"', '\"') + '"'
    }
    return $Value
  }
}

function Stop-OwnedProcessTree {
  param([Diagnostics.Process]$Process)
  if ($null -eq $Process) {
    return
  }
  try {
    if (-not $Process.HasExited) {
      $Process.Kill($true)
      [void]$Process.WaitForExit(10000)
    }
  } catch [InvalidOperationException] {
    # The owned process exited between the state check and termination.
  }
}

function Invoke-CheckedProcess {
  param(
    [Parameter(Mandatory)]
    [string]$FilePath,

    [Parameter(Mandatory)]
    [string[]]$ArgumentList,

    [Parameter(Mandatory)]
    [string]$WorkingDirectory,

    [Parameter(Mandatory)]
    [Collections.Generic.Dictionary[string, string]]$Environment,

    [int]$ExpectedExitCode = 0,

    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 180
  )
  $stdout = Join-Path $script:TestRoot ([Guid]::NewGuid().ToString() + '.out')
  $stderr = Join-Path $script:TestRoot ([Guid]::NewGuid().ToString() + '.err')
  $processArguments = @($ArgumentList | ConvertTo-ProcessArgument)
  $process = $null
  try {
    $process = Start-Process -FilePath $FilePath `
      -ArgumentList $processArguments `
      -WorkingDirectory $WorkingDirectory `
      -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr `
      -Environment $Environment `
      -NoNewWindow -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      Stop-OwnedProcessTree $process
      $output = (
        (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) +
        (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))
      throw "Process '$FilePath' timed out after $TimeoutSeconds second(s).`n$output"
    }
    $output = (
      (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) +
      (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))
    if ($process.ExitCode -ne $ExpectedExitCode) {
      throw "Process '$FilePath' exited $($process.ExitCode), expected $ExpectedExitCode.`n$output"
    }
    return $output
  } finally {
    Stop-OwnedProcessTree $process
    if ($null -ne $process) {
      $process.Dispose()
    }
    Remove-Item -LiteralPath $stdout, $stderr -Force `
      -ErrorAction SilentlyContinue
  }
}

function New-TestEnvironment {
  $environment =
    [Collections.Generic.Dictionary[string, string]]::new(
      [StringComparer]::Ordinal)
  foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
    $environment[[string]$entry.Key] = [string]$entry.Value
  }
  foreach ($name in @(
      'JAVA_TOOL_OPTIONS',
      '_JAVA_OPTIONS',
      'JDK_JAVA_OPTIONS',
      'MAVEN_OPTS',
      'MAVEN_DEBUG_OPTS',
      'MAVEN_ARGS',
      'COSMOS_KEY',
      'AZURE_CLIENT_SECRET',
      'AZURE_CLIENT_CERTIFICATE_PATH',
      'AZURE_CLIENT_CERTIFICATE_PASSWORD')) {
    $environment[$name] = ''
  }
  foreach ($name in @($environment.Keys)) {
    if ($name.StartsWith('LIVE_COSMOS_', [StringComparison]::Ordinal)) {
      $environment[$name] = ''
    }
  }
  return ,$environment
}

function Assert-ProcessExited {
  param(
    [Parameter(Mandatory)]
    [int]$Id,

    [Parameter(Mandatory)]
    [string]$Message
  )
  $deadline = (Get-Date).AddSeconds(10)
  do {
    if ($null -eq (Get-Process -Id $Id -ErrorAction SilentlyContinue)) {
      return
    }
    Start-Sleep -Milliseconds 50
  } while ((Get-Date) -lt $deadline)
  throw $Message
}

function Write-ExecutableFile {
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [string]$Content
  )
  Set-Content -LiteralPath $Path -Value $Content -Encoding utf8NoBOM
  & chmod +x $Path
  if ($LASTEXITCODE -ne 0) {
    throw "Could not make fixture executable: $Path"
  }
}

function Get-LiveTask {
  param(
    [Parameter(Mandatory)]
    [string]$Yaml,

    [Parameter(Mandatory)]
    [string]$DisplayName,

    [string]$NextTask
  )
  $displayMarker = "                  displayName: $DisplayName"
  $displayIndex = $Yaml.IndexOf(
    $displayMarker, [StringComparison]::Ordinal)
  if ($displayIndex -lt 0) {
    throw "Could not find YAML task '$DisplayName'."
  }
  $taskIndex = $Yaml.LastIndexOf(
    '                - task:', $displayIndex,
    [StringComparison]::Ordinal)
  $nextIndex = if ([string]::IsNullOrWhiteSpace($NextTask)) {
    $Yaml.Length
  } else {
    $Yaml.IndexOf(
      "                - task: $NextTask", $displayIndex,
      [StringComparison]::Ordinal)
  }
  if ($taskIndex -lt 0 -or $nextIndex -lt 0) {
    throw "Could not isolate YAML task '$DisplayName'."
  }
  return $Yaml.Substring($taskIndex, $nextIndex - $taskIndex)
}

function Invoke-LiveScript {
  param(
    [Parameter(Mandatory)]
    [string]$ScriptPath,

    [Parameter(Mandatory)]
    [string]$SourceDirectory,

    [Parameter(Mandatory)]
    [string]$TempDirectory,

    [Parameter(Mandatory)]
    [Collections.Generic.Dictionary[string, string]]$Environment,

    [int]$ExpectedExitCode = 0
  )
  return Invoke-CheckedProcess -FilePath 'pwsh' -ArgumentList @(
      '-NoLogo',
      '-NoProfile',
      '-File',
      $ScriptPath,
      '-SourceDirectory',
      $SourceDirectory,
      '-TempDirectory',
      $TempDirectory
    ) -WorkingDirectory $SourceDirectory -Environment $Environment `
    -ExpectedExitCode $ExpectedExitCode
}

function Invoke-SourceScript {
  param(
    [Parameter(Mandatory)]
    [string]$ScriptPath,

    [Parameter(Mandatory)]
    [string]$SourceDirectory,

    [Parameter(Mandatory)]
    [Collections.Generic.Dictionary[string, string]]$Environment,

    [int]$ExpectedExitCode = 0
  )
  return Invoke-CheckedProcess -FilePath 'pwsh' -ArgumentList @(
      '-NoLogo',
      '-NoProfile',
      '-File',
      $ScriptPath,
      '-SourceDirectory',
      $SourceDirectory
    ) -WorkingDirectory $SourceDirectory -Environment $Environment `
    -ExpectedExitCode $ExpectedExitCode
}

function Assert-ProviderOutputs {
  foreach ($relativePath in @(
      'multiclouddb-api/target/classes',
      'multiclouddb-provider-cosmos/target/classes',
      'multiclouddb-provider-dynamo/target/classes',
      'multiclouddb-provider-spanner/target/classes')) {
    $path = Join-Path $RepositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
      throw @"
Required compiled reactor output is missing: $relativePath
Run 'mvn -B -pl multiclouddb-conformance -am test-compile -DskipTests'
before this harness (the CI build job already does so).
"@
    }
  }
}

function New-LiveFixture {
  $fixtureRoot = Join-Path $script:TestRoot 'fixture with spaces'
  Copy-Item -LiteralPath (
    Join-Path $PSScriptRoot 'fixtures/live-cosmos-project') `
    -Destination $fixtureRoot -Recurse
  Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts') `
    -Destination $fixtureRoot -Recurse

  foreach ($module in @(
      'multiclouddb-api',
      'multiclouddb-provider-cosmos',
      'multiclouddb-provider-dynamo',
      'multiclouddb-provider-spanner')) {
    $source = Join-Path $RepositoryRoot "$module/target/classes"
    $destination = Join-Path $fixtureRoot "$module/target/classes"
    New-Item -ItemType Directory -Path (
      Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse
  }
  return $fixtureRoot
}

function New-FixtureTools {
  param(
    [Parameter(Mandatory)]
    [string]$FixtureRoot,

    [Parameter(Mandatory)]
    [string]$RealMaven
  )
  $bin = Join-Path $FixtureRoot 'fixture tools'
  New-Item -ItemType Directory -Path $bin -Force | Out-Null
  Write-ExecutableFile -Path (Join-Path $bin 'az') -Content @'
#!/bin/sh
set -eu
test "$1" = "account"
test "$2" = "show"
exit 0
'@
  Write-ExecutableFile -Path (Join-Path $bin 'mvn') -Content @'
#!/bin/sh
set -eu
goal=$1
shift
{
  printf 'BEGIN %s\n' "$goal"
  printf '%s\n' "$@"
  printf 'END\n'
} >> "$LIVE_COSMOS_MAVEN_CALL_LOG"

if [ "${LIVE_COSMOS_TARGET_GOAL:-}" = "$goal" ]; then
  if [ "${LIVE_COSMOS_SUPPRESS_STREAM:-}" != "true" ]; then
    printf 'LIVE_STREAM_STDOUT goal=%s\n' "$goal"
    printf 'Picked up JAVA_TOOL_OPTIONS: FILTERED_FIXTURE_VALUE\n'
    printf 'LIVE_STREAM_STDERR goal=%s\n' "$goal" >&2
  fi
  case "${LIVE_COSMOS_TARGET_MODE:-exit}" in
    delay)
      sleep 300 &
      fixture_child=$!
      printf '%s\n' "$fixture_child" > "$LIVE_COSMOS_FIXTURE_PID"
      wait "$fixture_child"
      ;;
    exit) exit "${LIVE_COSMOS_TARGET_EXIT:-37}" ;;
    profile-fallback)
      printf '%s\n' '[INFO]  - live-cosmos (source: fixture:multiclouddb-conformance:1)'
      exit 0
      ;;
    *) exit 98 ;;
  esac
fi

case "$goal" in
  help:active-profiles|help:effective-pom|verify)
    exec "$LIVE_COSMOS_REAL_MAVEN" "$goal" "$@" --no-transfer-progress
    ;;
  process-test-classes)
    dependency_output=
    for argument in "$@"; do
      case "$argument" in
        -Dmdep.outputFile=*) dependency_output=${argument#-Dmdep.outputFile=} ;;
      esac
    done
    test -n "$dependency_output"
    "$LIVE_COSMOS_REAL_MAVEN" "$goal" "$@" --no-transfer-progress
    dependency_classpath="$PWD/multiclouddb-api/target/classes:$PWD/multiclouddb-provider-cosmos/target/classes:$PWD/multiclouddb-provider-dynamo/target/classes:$PWD/multiclouddb-provider-spanner/target/classes:$(cat "$dependency_output")"
    if [ -n "${LIVE_COSMOS_DEPENDENCY_CLASSPATH_PREPEND:-}" ]; then
      dependency_classpath="$LIVE_COSMOS_DEPENDENCY_CLASSPATH_PREPEND:$dependency_classpath"
    fi
    printf '%s\n' "$dependency_classpath" > "$dependency_output"
    descriptor="$PWD/multiclouddb-conformance/target/test-classes/META-INF/services/com.multiclouddb.spi.MulticloudDbProviderAdapter"
    rm -f "$descriptor"
    if [ -n "${LIVE_COSMOS_TEST_DESCRIPTOR_FIXTURE:-}" ]; then
      mkdir -p "$(dirname "$descriptor")"
      cp "$LIVE_COSMOS_TEST_DESCRIPTOR_FIXTURE" "$descriptor"
    fi
    if [ "${LIVE_COSMOS_SKIP_CLASSPATH_FILE:-}" = "true" ]; then
      rm -f "$dependency_output"
    fi
    ;;
  *) exit 97 ;;
esac
'@
  return $bin
}

function New-FixtureArchive {
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [Collections.IDictionary]$Entries
  )
  Add-Type -AssemblyName System.IO.Compression
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $stream = [IO.File]::Open(
    $Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite)
  try {
    $archive = [IO.Compression.ZipArchive]::new(
      $stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
      foreach ($entryName in $Entries.Keys) {
        $entry = $archive.CreateEntry([string]$entryName)
        $entryStream = $entry.Open()
        try {
          $value = $Entries[$entryName]
          $bytes = if ($value -is [byte[]]) {
            $value
          } else {
            [Text.Encoding]::UTF8.GetBytes([string]$value)
          }
          $entryStream.Write($bytes, 0, $bytes.Length)
        } finally {
          $entryStream.Dispose()
        }
      }
    } finally {
      $archive.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Invoke-ProviderMetadataFailureCase {
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$Expected,

    [Parameter(Mandatory)]
    [string]$FixtureRoot,

    [Parameter(Mandatory)]
    [string]$FixtureTemp,

    [Parameter(Mandatory)]
    [string]$RunnerScript,

    [Parameter(Mandatory)]
    [Collections.Generic.Dictionary[string, string]]$BaseEnvironment,

    [string]$ClasspathPrepend,

    [string]$DescriptorFixture,

    [Collections.IDictionary]$AdditionalEnvironment
  )
  $environment =
    [Collections.Generic.Dictionary[string, string]]::new(
      $BaseEnvironment, [StringComparer]::Ordinal)
  $callLog = Join-Path $script:TestRoot "provider-$Name.calls"
  Set-Content -LiteralPath $callLog -Value '' -Encoding utf8NoBOM
  $environment['LIVE_COSMOS_MAVEN_CALL_LOG'] = $callLog
  if (-not [string]::IsNullOrWhiteSpace($ClasspathPrepend)) {
    $environment['LIVE_COSMOS_DEPENDENCY_CLASSPATH_PREPEND'] =
      $ClasspathPrepend
  }
  if (-not [string]::IsNullOrWhiteSpace($DescriptorFixture)) {
    $environment['LIVE_COSMOS_TEST_DESCRIPTOR_FIXTURE'] =
      $DescriptorFixture
  }
  if ($null -ne $AdditionalEnvironment) {
    foreach ($key in $AdditionalEnvironment.Keys) {
      $environment[[string]$key] = [string]$AdditionalEnvironment[$key]
    }
  }

  $output = Invoke-LiveScript -ScriptPath $RunnerScript `
    -SourceDirectory $FixtureRoot -TempDirectory $FixtureTemp `
    -Environment $environment -ExpectedExitCode 1
  if (-not $output.Contains($Expected, [StringComparison]::Ordinal)) {
    throw @"
Provider metadata case '$Name' did not fail closed with '$Expected'.
$output
"@
  }
  $calls = Get-Content -LiteralPath $callLog -Raw
  Assert-Contains $calls 'BEGIN process-test-classes' `
    "Provider metadata case '$Name' did not reach classpath preparation."
  Assert-True (-not $calls.Contains('BEGIN verify')) `
    "Provider metadata case '$Name' reached live test execution."
  Write-Host "PASS provider metadata $Name rejected before verify."
}

function Invoke-StreamingFailureCase {
  param(
    [Parameter(Mandatory)]
    [ValidateSet('profiles', 'effective-pom', 'compile', 'verify')]
    [string]$Phase,

    [Parameter(Mandatory)]
    [ValidateSet('delay', 'exit')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$FixtureRoot,

    [Parameter(Mandatory)]
    [string]$FixtureTemp,

    [Parameter(Mandatory)]
    [string]$PreflightScript,

    [Parameter(Mandatory)]
    [string]$RunnerScript,

    [Parameter(Mandatory)]
    [Collections.Generic.Dictionary[string, string]]$BaseEnvironment,

    [ValidateRange(1, 60)]
    [int]$ObservationTimeoutSeconds = 60,

    [switch]$SuppressFixtureStream,

    [string]$CaseSuffix,

    [switch]$Quiet
  )
  $goalByPhase = @{
    profiles = 'help:active-profiles'
    'effective-pom' = 'help:effective-pom'
    compile = 'process-test-classes'
    verify = 'verify'
  }
  $errorByPhase = @{
    profiles = 'Maven could not activate the live-cosmos profile'
    'effective-pom' = 'Maven could not produce the activated live-cosmos effective POM'
    compile = 'classpath preparation failed with Maven exit code'
    verify = 'Live Cosmos DB tests failed with Maven exit code'
  }
  $environment =
    [Collections.Generic.Dictionary[string, string]]::new(
      $BaseEnvironment, [StringComparer]::Ordinal)
  $caseName = "$Phase-$Mode$CaseSuffix"
  $pidFile = Join-Path $script:TestRoot "$caseName.pid"
  $stdout = Join-Path $script:TestRoot "$caseName.out"
  $stderr = Join-Path $script:TestRoot "$caseName.err"
  foreach ($path in @($pidFile, $stdout, $stderr)) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
  $environment['LIVE_COSMOS_TARGET_GOAL'] = $goalByPhase[$Phase]
  $environment['LIVE_COSMOS_TARGET_MODE'] = $Mode
  $environment['LIVE_COSMOS_TARGET_EXIT'] = '37'
  $environment['LIVE_COSMOS_FIXTURE_PID'] = $pidFile
  if ($SuppressFixtureStream) {
    $environment['LIVE_COSMOS_SUPPRESS_STREAM'] = 'true'
  }

  if ($Phase -in @('compile', 'verify')) {
    $preflightEnvironment =
      [Collections.Generic.Dictionary[string, string]]::new(
        $environment, [StringComparer]::Ordinal)
    $preflightEnvironment['LIVE_COSMOS_TARGET_GOAL'] = 'none'
    Invoke-LiveScript -ScriptPath $PreflightScript `
      -SourceDirectory $FixtureRoot -TempDirectory $FixtureTemp `
      -Environment $preflightEnvironment | Out-Null
  }

  $scriptPath = if ($Phase -in @('profiles', 'effective-pom')) {
    $PreflightScript
  } else {
    $RunnerScript
  }
  $arguments = @(
    '-NoLogo',
    '-NoProfile',
    '-File',
    $scriptPath,
    '-SourceDirectory',
    $FixtureRoot,
    '-TempDirectory',
    $FixtureTemp
  )
  $processArguments = @($arguments | ConvertTo-ProcessArgument)
  $process = $null
  $fixturePid = $null
  $output = ''
  try {
    $process = Start-Process -FilePath 'pwsh' `
      -ArgumentList $processArguments `
      -WorkingDirectory $FixtureRoot `
      -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr `
      -Environment $environment `
      -NoNewWindow -PassThru

    if ($Mode -eq 'delay') {
      $deadline = (Get-Date).AddSeconds($ObservationTimeoutSeconds)
      $observedWhileRunning = $false
      do {
        $output = (
          (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) +
          (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))
        if ($output -match 'LIVE_STREAM_STDOUT' `
            -and $output -match 'LIVE_STREAM_STDERR' `
            -and -not $process.HasExited) {
          $observedWhileRunning = $true
          break
        }
        Start-Sleep -Milliseconds 50
      } while ((Get-Date) -lt $deadline -and -not $process.HasExited)
      if (-not $observedWhileRunning) {
        throw "$caseName did not stream stdout and stderr before completion.`n$output"
      }

      $deadline = (Get-Date).AddSeconds(10)
      while (-not (Test-Path -LiteralPath $pidFile -PathType Leaf) `
          -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
      }
      Assert-True (Test-Path -LiteralPath $pidFile -PathType Leaf) `
        "$caseName did not publish its fixture-owned process ID."
      $fixturePid = [int](Get-Content -LiteralPath $pidFile -Raw)
      Stop-Process -Id $fixturePid -Force -ErrorAction Stop
    }

    if (-not $process.WaitForExit(30000)) {
      throw "$caseName did not terminate within 30 seconds.`n$output"
    }
    $output = (
      (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) +
      (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))
    Assert-Contains $output 'LIVE_STREAM_STDOUT' `
      "$caseName did not retain streamed stdout."
    Assert-Contains $output 'LIVE_STREAM_STDERR' `
      "$caseName did not retain streamed stderr."
    Assert-True (-not $output.Contains('FILTERED_FIXTURE_VALUE')) `
      "$caseName leaked filtered option output."
    Assert-True ($process.ExitCode -ne 0) "$caseName unexpectedly succeeded."
    Assert-Contains $output $errorByPhase[$Phase] `
      "$caseName did not fail with its phase-specific error."
    if ($Mode -eq 'exit' -and $Phase -in @('compile', 'verify')) {
      Assert-Contains $output 'exit code 37' `
        "$caseName did not preserve the native Maven exit code."
    }
    if (-not $Quiet) {
      Write-Host "PASS streaming $caseName preserved diagnostics and failure."
    }
  } finally {
    if ($null -eq $fixturePid `
        -and (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
      $fixturePid = [int](Get-Content -LiteralPath $pidFile -Raw)
    }
    if ($null -ne $fixturePid) {
      Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue
    }
    Stop-OwnedProcessTree $process
    if ($null -ne $process) {
      $process.Dispose()
    }
  }
}

$script:TestRoot = Join-Path ([Environment]::GetFolderPath(
    [Environment+SpecialFolder]::UserProfile)) (
  'multiclouddb live cosmos regression ' + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

try {
  $RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
  $pipelinePath = Join-Path $RepositoryRoot 'azure-pipelines-live-cosmos.yml'
  $preflightPath = Join-Path $RepositoryRoot `
    'scripts/live-cosmos/Invoke-LiveCosmosPreflight.ps1'
  $runnerPath = Join-Path $RepositoryRoot `
    'scripts/live-cosmos/Invoke-LiveCosmosTests.ps1'
  $cleanupPath = Join-Path $RepositoryRoot `
    'scripts/live-cosmos/Remove-LiveCosmosTestResults.ps1'
  $resultPath = Join-Path $RepositoryRoot `
    'scripts/live-cosmos/Test-LiveCosmosResults.ps1'
  $commonPath = Join-Path $RepositoryRoot `
    'scripts/live-cosmos/LiveCosmos.Common.ps1'
  foreach ($path in @(
      $pipelinePath,
      $preflightPath,
      $runnerPath,
      $cleanupPath,
      $resultPath,
      $commonPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
      "Required repository file is missing: $path"
  }

  $originalJavaToolOptions =
    [Environment]::GetEnvironmentVariable(
      'JAVA_TOOL_OPTIONS', 'Process')
  $originalFixtureMode =
    [Environment]::GetEnvironmentVariable(
      'LIVE_COSMOS_TARGET_MODE', 'Process')
  try {
    [Environment]::SetEnvironmentVariable(
      'JAVA_TOOL_OPTIONS', '-Dfixture.inherited=true', 'Process')
    [Environment]::SetEnvironmentVariable(
      'LIVE_COSMOS_TARGET_MODE', 'delay', 'Process')
    $isolationEnvironment = New-TestEnvironment
    $environmentProbe = Join-Path $script:TestRoot 'environment-probe.ps1'
    Set-Content -LiteralPath $environmentProbe -Encoding utf8NoBOM -Value @'
Write-Output "$env:JAVA_TOOL_OPTIONS|$env:LIVE_COSMOS_TARGET_MODE"
'@
    $isolationOutput = Invoke-CheckedProcess -FilePath 'pwsh' `
      -ArgumentList @('-NoLogo', '-NoProfile', '-File', $environmentProbe) `
      -WorkingDirectory $RepositoryRoot `
      -Environment $isolationEnvironment
    Assert-True ($isolationOutput.Trim() -ceq '|') `
      'Child fixture environment inherited cleared control variables.'
    Write-Host 'PASS child fixture environment cleared inherited controls.'
  } finally {
    [Environment]::SetEnvironmentVariable(
      'JAVA_TOOL_OPTIONS', $originalJavaToolOptions, 'Process')
    [Environment]::SetEnvironmentVariable(
      'LIVE_COSMOS_TARGET_MODE', $originalFixtureMode, 'Process')
  }

  $timeoutPid = Join-Path $script:TestRoot 'timeout-child.pid'
  $timeoutFixture = Join-Path $script:TestRoot 'timeout-fixture.sh'
  Write-ExecutableFile -Path $timeoutFixture -Content @'
#!/bin/sh
set -eu
sleep 300 &
child=$!
printf '%s\n' "$child" > "$LIVE_COSMOS_TIMEOUT_PID"
wait "$child"
'@
  $timeoutEnvironment = New-TestEnvironment
  $timeoutEnvironment['LIVE_COSMOS_TIMEOUT_PID'] = $timeoutPid
  $timeoutFailed = $false
  try {
    Invoke-CheckedProcess -FilePath $timeoutFixture `
      -ArgumentList @('fixture') -WorkingDirectory $RepositoryRoot `
      -Environment $timeoutEnvironment -TimeoutSeconds 1 | Out-Null
  } catch {
    $timeoutFailed = $true
    if (-not "$_".Contains(
        'timed out after 1 second(s)', [StringComparison]::Ordinal)) {
      throw "Bounded process timeout did not retain its diagnostic.`n$_"
    }
  }
  Assert-True $timeoutFailed `
    'Bounded process fixture unexpectedly completed.'
  Assert-True (Test-Path -LiteralPath $timeoutPid -PathType Leaf) `
    'Bounded process fixture did not publish its owned child PID.'
  Assert-ProcessExited `
    -Id ([int](Get-Content -LiteralPath $timeoutPid -Raw)) `
    -Message 'Bounded process timeout left its owned child running.'
  Write-Host 'PASS bounded process timeout terminated its owned tree.'

  $yaml = Get-Content -LiteralPath $pipelinePath -Raw
  $preflightTask = Get-LiveTask -Yaml $yaml `
    -DisplayName 'Preflight live Cosmos DB configuration' `
    -NextTask 'AzureCLI@2'
  $cleanupTask = Get-LiveTask -Yaml $yaml `
    -DisplayName 'Remove stale test results' `
    -NextTask 'JavaToolInstaller@0'
  $runnerTask = Get-LiveTask -Yaml $yaml `
    -DisplayName 'Run live Cosmos DB tests with WIF' `
    -NextTask 'PublishTestResults@2'
  $resultTask = Get-LiveTask -Yaml $yaml `
    -DisplayName 'Verify live Cosmos DB results'
  foreach ($expected in @(
      'condition: always()',
      'targetType: filePath',
      'filePath: $(Build.SourcesDirectory)/scripts/live-cosmos/Remove-LiveCosmosTestResults.ps1',
      '-SourceDirectory "$(Build.SourcesDirectory)"',
      'pwsh: true')) {
    Assert-Contains $cleanupTask $expected 'Cleanup YAML wiring changed.'
  }
  foreach ($expected in @(
      'targetType: filePath',
      'pwsh: true',
      'filePath: $(Build.SourcesDirectory)/scripts/live-cosmos/Invoke-LiveCosmosPreflight.ps1',
      '-SourceDirectory "$(Build.SourcesDirectory)"',
      '-TempDirectory "$(Agent.TempDirectory)"',
      'workingDirectory: $(Build.SourcesDirectory)')) {
    Assert-Contains $preflightTask $expected 'Preflight YAML wiring changed.'
  }
  foreach ($expected in @(
      'azureSubscription: multiclouddb-cosmos-live-ci',
      'scriptType: pscore',
      'scriptLocation: scriptPath',
      'cwd: $(Build.SourcesDirectory)',
      'visibleAzLogin: false',
      'useGlobalConfig: false',
      'addSpnToEnvironment: false',
      'scriptPath: $(Build.SourcesDirectory)/scripts/live-cosmos/Invoke-LiveCosmosTests.ps1',
      '-SourceDirectory "$(Build.SourcesDirectory)"',
      '-TempDirectory "$(Agent.TempDirectory)"',
      'AZURE_TOKEN_CREDENTIALS: AzureCliCredential')) {
    Assert-Contains $runnerTask $expected 'Authenticated YAML wiring changed.'
  }
  foreach ($expected in @(
      'condition: succeededOrFailed()',
      'targetType: filePath',
      'filePath: $(Build.SourcesDirectory)/scripts/live-cosmos/Test-LiveCosmosResults.ps1',
      '-SourceDirectory "$(Build.SourcesDirectory)"',
      'pwsh: true')) {
    Assert-Contains $resultTask $expected 'Result YAML wiring changed.'
  }
  foreach ($task in @($cleanupTask, $preflightTask, $runnerTask, $resultTask)) {
    Assert-True (-not $task.Contains('script: |') `
        -and -not $task.Contains('inlineScript: |')) `
      'Live Cosmos task body must not remain inline.'
  }

  $parseErrors = $null
  foreach ($path in @(
      $preflightPath,
      $runnerPath,
      $cleanupPath,
      $resultPath,
      $commonPath,
      $PSCommandPath)) {
    [Management.Automation.Language.Parser]::ParseFile(
      $path, [ref]$null, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) `
      "PowerShell parser errors in $path`: $parseErrors"
  }

  . $commonPath
  Assert-True (Test-ForbiddenMavenConfiguration `
      '-DargLine=-javaagent:/tmp/agent.jar') `
    'Shared helper accepted a Surefire execution override.'
  Assert-True (Test-ForbiddenMavenConfiguration `
      '--define maven.repo.local=/tmp/repository') `
    'Shared helper accepted a Maven repository redirect.'
  Assert-True (-not (Test-ForbiddenMavenConfiguration `
      '-B -T1 -Xmx512m -DtrustStore=/tmp/trusted.jks')) `
    'Shared helper rejected benign process options.'
  Assert-True (
    '-Dmaven.repo.local=/tmp/repository' -notmatch
      $forbiddenNestedJvmConfigPattern) `
    'maven.repo.local must remain a Maven-process guard, not a nested fork rule.'

  $missingHelperDirectory = Join-Path $script:TestRoot 'missing helper'
  New-Item -ItemType Directory -Path $missingHelperDirectory -Force | Out-Null
  $missingHelperEnvironment = New-TestEnvironment
  $missingHelperEnvironment['COSMOS_ENDPOINT'] =
    'https://fixture.documents.azure.com:443/'
  foreach ($entryPoint in @($preflightPath, $runnerPath)) {
    $missingHelperEntryPoint = Join-Path $missingHelperDirectory `
      (Split-Path -Leaf $entryPoint)
    Copy-Item -LiteralPath $entryPoint `
      -Destination $missingHelperEntryPoint -Force
    $missingHelperOutput = Invoke-CheckedProcess -FilePath 'pwsh' `
      -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-File',
        $missingHelperEntryPoint,
        '-SourceDirectory',
        $RepositoryRoot,
        '-TempDirectory',
        $script:TestRoot
      ) -WorkingDirectory $RepositoryRoot `
      -Environment $missingHelperEnvironment -ExpectedExitCode 1
    Assert-Contains $missingHelperOutput `
      'Required live Cosmos helper is missing' `
      "Missing shared helper did not fail closed for $entryPoint."
  }

  $realRepositoryTemp = Join-Path $script:TestRoot 'real repository temp'
  New-Item -ItemType Directory -Path $realRepositoryTemp -Force | Out-Null
  $realEnvironment = New-TestEnvironment
  $realEnvironment['COSMOS_ENDPOINT'] =
    'https://fixture.documents.azure.com:443/'
  $realOutput = Invoke-LiveScript -ScriptPath $preflightPath `
    -SourceDirectory $RepositoryRoot -TempDirectory $realRepositoryTemp `
    -Environment $realEnvironment -ExpectedExitCode 1
  Assert-Contains $realOutput `
    'The live-cosmos profile must be declared exactly once' `
    'The current repository did not reject the missing module-local profile.'
  Assert-True (-not (Test-Path -LiteralPath (
        Join-Path $realRepositoryTemp 'live-cosmos-maven-arguments.json'))) `
    'Missing-profile preflight produced an authentication manifest.'

  Assert-ProviderOutputs
  $fixtureRoot = New-LiveFixture
  $fixtureTemp = Join-Path $script:TestRoot 'fixture temp with spaces'
  New-Item -ItemType Directory -Path $fixtureTemp -Force | Out-Null
  $realMaven = (Get-Command mvn -CommandType Application).Source
  $fixtureBin = New-FixtureTools -FixtureRoot $fixtureRoot `
    -RealMaven $realMaven
  $environment = New-TestEnvironment
  $environment['PATH'] =
    "$fixtureBin$([IO.Path]::PathSeparator)$($environment['PATH'])"
  $environment['COSMOS_ENDPOINT'] =
    'https://fixture.documents.azure.com:443/'
  $environment['AZURE_TOKEN_CREDENTIALS'] = 'AzureCliCredential'
  $environment['AZURE_CONFIG_DIR'] = Join-Path $script:TestRoot 'azure config'
  $environment['LIVE_COSMOS_REAL_MAVEN'] = $realMaven
  $environment['LIVE_COSMOS_MAVEN_CALL_LOG'] =
    Join-Path $script:TestRoot 'maven-calls.log'
  $environment['LIVE_COSMOS_FIXTURE_PID'] =
    Join-Path $script:TestRoot 'fixture.pid'

  $fixturePreflight = Join-Path $fixtureRoot `
    'scripts/live-cosmos/Invoke-LiveCosmosPreflight.ps1'
  $fixtureRunner = Join-Path $fixtureRoot `
    'scripts/live-cosmos/Invoke-LiveCosmosTests.ps1'
  $fixtureCleanup = Join-Path $fixtureRoot `
    'scripts/live-cosmos/Remove-LiveCosmosTestResults.ps1'
  $fixtureResult = Join-Path $fixtureRoot `
    'scripts/live-cosmos/Test-LiveCosmosResults.ps1'
  $fixtureReportDirectory = Join-Path $fixtureRoot `
    'multiclouddb-conformance/target/surefire-reports'
  $fixtureReport = Join-Path $fixtureReportDirectory `
    'TEST-com.multiclouddb.conformance.LiveCosmosEntraAuthenticationTest.xml'
  New-Item -ItemType Directory -Path $fixtureReportDirectory `
    -Force | Out-Null
  Set-Content -LiteralPath $fixtureReport -Value 'STALE_REPORT' `
    -Encoding utf8NoBOM
  Invoke-SourceScript -ScriptPath $fixtureCleanup `
    -SourceDirectory $fixtureRoot -Environment $environment | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $fixtureReportDirectory)) `
    'Cleanup entry point retained the stale report directory.'

  $sentinelSource = Join-Path $fixtureRoot `
    'multiclouddb-conformance/src/test/java/com/multiclouddb/conformance/LiveCosmosEntraAuthenticationTest.java'
  $sentinelBaseline = Get-Content -LiteralPath $sentinelSource -Raw
  $providerSelection =
    '            .provider(com.multiclouddb.api.ProviderId.COSMOS)'
  $configDeclaration =
    '    com.multiclouddb.api.MulticloudDbClientConfig config ='
  foreach ($sourceCase in @(
      @{
        Name = 'cosmos-then-dynamo'
        Expected = 'exactly one provider invocation'
        Source = $sentinelBaseline.Replace(
          $providerSelection,
          "$providerSelection`n            .provider(com.multiclouddb.api.ProviderId.DYNAMO)")
      },
      @{
        Name = 'dynamo-then-cosmos'
        Expected = 'exactly one provider invocation'
        Source = $sentinelBaseline.Replace(
          $providerSelection,
          "            .provider(com.multiclouddb.api.ProviderId.DYNAMO)`n$providerSelection")
      },
      @{
        Name = 'duplicate-cosmos'
        Expected = 'exactly one provider invocation'
        Source = $sentinelBaseline.Replace(
          $providerSelection, "$providerSelection`n$providerSelection")
      },
      @{
        Name = 'system-property-mutation'
        Expected = 'no System property mutation'
        Source = $sentinelBaseline.Replace(
          $configDeclaration,
          "    java.lang.System.setProperty(`"cosmos.endpoint`", `"https://shadow.documents.azure.com:443/`");`n$configDeclaration")
      },
      @{
        Name = 'security-policy-mutation'
        Expected = 'no java.security.Security runtime policy'
        Source = $sentinelBaseline.Replace(
          $configDeclaration,
          "    java.security.Security.setProperty(`"jdk.tls.disabledAlgorithms`", `"`");`n$configDeclaration")
      })) {
    [IO.File]::WriteAllText(
      $sentinelSource, $sourceCase.Source,
      [Text.UTF8Encoding]::new($false))
    $sourceOutput = Invoke-LiveScript -ScriptPath $fixturePreflight `
      -SourceDirectory $fixtureRoot -TempDirectory $fixtureTemp `
      -Environment $environment -ExpectedExitCode 1
    Assert-Contains $sourceOutput $sourceCase.Expected `
      "Source contract case '$($sourceCase.Name)' was not rejected."
    Assert-True (-not (Test-Path -LiteralPath (
          Join-Path $fixtureTemp 'live-cosmos-maven-arguments.json'))) `
      "Source contract case '$($sourceCase.Name)' produced an authentication manifest."
    Write-Host "PASS source contract $($sourceCase.Name) rejected before auth manifest."
  }
  $decoySource = $sentinelBaseline.Replace(
    $configDeclaration,
    "    String decoy = `"System.setProperty Security.setProperty .provider(com.multiclouddb.api.ProviderId.DYNAMO)`";`n    // System.clearProperty and duplicate .provider(...) are decoys.`n$configDeclaration")
  [IO.File]::WriteAllText(
    $sentinelSource, $decoySource,
    [Text.UTF8Encoding]::new($false))
  Invoke-LiveScript -ScriptPath $fixturePreflight `
    -SourceDirectory $fixtureRoot -TempDirectory $fixtureTemp `
    -Environment $environment | Out-Null
  [IO.File]::WriteAllText(
    $sentinelSource, $sentinelBaseline,
    [Text.UTF8Encoding]::new($false))
  $mavenConfigDirectory = Join-Path $fixtureRoot '.mvn'
  New-Item -ItemType Directory -Path $mavenConfigDirectory `
    -Force | Out-Null
  foreach ($configCase in @(
      @{
        Name = 'maven-config-argline'
        File = 'maven.config'
        Value = '-DargLine=-javaagent:/tmp/fixture-agent.jar'
      },
      @{
        Name = 'jvm-config-agent'
        File = 'jvm.config'
        Value = '-javaagent:/tmp/fixture-agent.jar'
      })) {
    $configPath = Join-Path $mavenConfigDirectory $configCase.File
    Set-Content -LiteralPath $configPath -Value $configCase.Value `
      -Encoding utf8NoBOM
    $configOutput = Invoke-LiveScript -ScriptPath $fixturePreflight `
      -SourceDirectory $fixtureRoot -TempDirectory $fixtureTemp `
      -Environment $environment -ExpectedExitCode 1
    Assert-Contains $configOutput 'contains forbidden' `
      "Preflight accepted $($configCase.Name)."
    Remove-Item -LiteralPath $configPath -Force
  }
  $forbiddenEnvironment =
    [Collections.Generic.Dictionary[string, string]]::new(
      $environment, [StringComparer]::Ordinal)
  $forbiddenEnvironment['MAVEN_ARGS'] =
    '--define maven.repo.local=/tmp/fixture-repository'
  $environmentOutput = Invoke-LiveScript `
    -ScriptPath $fixturePreflight -SourceDirectory $fixtureRoot `
    -TempDirectory $fixtureTemp -Environment $forbiddenEnvironment `
    -ExpectedExitCode 1
  Assert-Contains $environmentOutput `
    "Environment variable 'MAVEN_ARGS' contains forbidden" `
    'Preflight accepted a Maven repository redirect from the environment.'
  [IO.File]::WriteAllText(
    $environment['LIVE_COSMOS_MAVEN_CALL_LOG'], '',
    [Text.UTF8Encoding]::new($false))

  foreach ($staleName in @(
      'live-cosmos-effective-pom.xml',
      'live-cosmos-maven-arguments.json',
      'live-cosmos-test-classpath.txt')) {
    Set-Content -LiteralPath (Join-Path $fixtureTemp $staleName) `
      -Value 'STALE_FIXTURE_VALUE' -Encoding utf8NoBOM
  }
  $preflightOutput = Invoke-LiveScript -ScriptPath $fixturePreflight `
    -SourceDirectory $fixtureRoot -TempDirectory $fixtureTemp `
    -Environment $environment
  Assert-True (-not $preflightOutput.Contains(
      '##vso[task.logissue type=error]')) `
    'Positive preflight emitted an Azure DevOps configuration error.'
  Assert-True (Test-Path -LiteralPath (
      Join-Path $fixtureTemp 'live-cosmos-maven-arguments.json') `
      -PathType Leaf) `
    'Positive preflight did not write the validated argument manifest.'
  Assert-True (-not (Test-Path -LiteralPath (
        Join-Path $fixtureTemp 'live-cosmos-test-classpath.txt'))) `
    'Positive preflight retained a stale dependency classpath artifact.'
  Assert-True (-not ((
        Get-Content -LiteralPath (
          Join-Path $fixtureTemp 'live-cosmos-effective-pom.xml') -Raw
      ).Contains('STALE_FIXTURE_VALUE'))) `
    'Positive preflight retained stale effective-POM content.'
  $postAuthEnvironment =
    [Collections.Generic.Dictionary[string, string]]::new(
      $environment, [StringComparer]::Ordinal)
  $postAuthEnvironment['MAVEN_ARGS'] =
    '-Dmaven.surefire.debug=-agentlib:jdwp=transport=dt_socket'
  $postAuthEnvironmentOutput = Invoke-LiveScript `
    -ScriptPath $fixtureRunner -SourceDirectory $fixtureRoot `
    -TempDirectory $fixtureTemp -Environment $postAuthEnvironment `
    -ExpectedExitCode 1
  Assert-Contains $postAuthEnvironmentOutput `
    "Environment variable 'MAVEN_ARGS' contains forbidden" `
    'Authenticated runner did not recheck environment injection.'
  $postAuthConfig = Join-Path $mavenConfigDirectory 'maven.config'
  Set-Content -LiteralPath $postAuthConfig `
    -Value '--define maven.repo.local=/tmp/post-auth-repository' `
    -Encoding utf8NoBOM
  try {
    $postAuthConfigOutput = Invoke-LiveScript `
      -ScriptPath $fixtureRunner -SourceDirectory $fixtureRoot `
      -TempDirectory $fixtureTemp -Environment $environment `
      -ExpectedExitCode 1
    Assert-Contains $postAuthConfigOutput 'contains forbidden' `
      'Authenticated runner did not recheck .mvn configuration.'
  } finally {
    Remove-Item -LiteralPath $postAuthConfig -Force
  }
  $runnerOutput = Invoke-LiveScript -ScriptPath $fixtureRunner `
    -SourceDirectory $fixtureRoot -TempDirectory $fixtureTemp `
    -Environment $environment
  Assert-Contains $runnerOutput `
    'Validated production provider descriptors and class origins' `
    'Positive authenticated runner did not validate provider metadata.'
  Assert-True (Test-Path -LiteralPath $fixtureReport -PathType Leaf) `
    'Positive runner did not produce the dedicated JUnit report.'
  [xml]$result = Get-Content -LiteralPath $fixtureReport -Raw
  $cases = @($result.SelectNodes(
    "//testcase[@classname='com.multiclouddb.conformance.LiveCosmosEntraAuthenticationTest']"))
  Assert-True ($cases.Count -eq 1) `
    'Positive runner did not execute exactly one live sentinel fixture case.'
  Assert-True (@($cases[0].SelectNodes('./failure | ./error | ./skipped')).Count -eq 0) `
    'Positive runner fixture case was not a clean pass.'
  $resultOutput = Invoke-SourceScript -ScriptPath $fixtureResult `
    -SourceDirectory $fixtureRoot -Environment $environment
  Assert-Contains $resultOutput `
    'total=1 passed=1 failed=0 skipped=0' `
    'Result entry point did not accept the exact passing sentinel.'

  $passingReport = [IO.File]::ReadAllBytes($fixtureReport)
  Remove-Item -LiteralPath $fixtureReport -Force
  try {
    $missingReportOutput = Invoke-SourceScript `
      -ScriptPath $fixtureResult -SourceDirectory $fixtureRoot `
      -Environment $environment -ExpectedExitCode 1
    Assert-Contains $missingReportOutput `
      'dedicated LiveCosmosEntraAuthenticationTest report was not produced' `
      'Result entry point accepted a missing report.'
  } finally {
    New-Item -ItemType Directory -Path $fixtureReportDirectory `
      -Force | Out-Null
    [IO.File]::WriteAllBytes($fixtureReport, $passingReport)
  }
  foreach ($reportCase in @(
      @{
        Name = 'failed'
        Body = '<failure message="fixture failure"/>'
      },
      @{
        Name = 'skipped'
        Body = '<skipped message="fixture skip"/>'
      },
      @{
        Name = 'wrong-method'
        Body = ''
        Method = 'differentMethod'
      })) {
    $method = if ($reportCase.ContainsKey('Method')) {
      $reportCase.Method
    } else {
      'entraAuthenticationPerformsCreateReadDelete'
    }
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite tests="1">
  <testcase classname="com.multiclouddb.conformance.LiveCosmosEntraAuthenticationTest" name="$method">$($reportCase.Body)</testcase>
</testsuite>
"@
    [IO.File]::WriteAllText(
      $fixtureReport, $xml, [Text.UTF8Encoding]::new($false))
    $invalidResultOutput = Invoke-SourceScript `
      -ScriptPath $fixtureResult -SourceDirectory $fixtureRoot `
      -Environment $environment -ExpectedExitCode 1
    Assert-Contains $invalidResultOutput `
      'must have at least one passing case and no failed or skipped cases' `
      "Result entry point accepted the $($reportCase.Name) report."
  }
  [IO.File]::WriteAllBytes($fixtureReport, $passingReport)

  $callLines = Get-Content -LiteralPath `
    $environment['LIVE_COSMOS_MAVEN_CALL_LOG']
  $calls = @()
  for ($index = 0; $index -lt $callLines.Count;) {
    Assert-True $callLines[$index].StartsWith('BEGIN ') `
      'Malformed Maven call log.'
    $goal = $callLines[$index].Substring(6)
    $index++
    $arguments = [Collections.Generic.List[string]]::new()
    while ($callLines[$index] -cne 'END') {
      $arguments.Add($callLines[$index])
      $index++
    }
    $index++
    $calls += [pscustomobject]@{
      Goal = $goal
      Arguments = @($arguments)
    }
  }
  Assert-True (($calls | ForEach-Object Goal) -join ',' -ceq
      'help:active-profiles,help:effective-pom,process-test-classes,verify') `
    'Maven invocation order changed.'
  $sharedArguments = $calls[0].Arguments
  Assert-True ($sharedArguments.Count -eq 12) `
    'The validated Maven manifest no longer has exactly 12 arguments.'
  Assert-True (
    [string]::Join([char]0, $calls[1].Arguments) -ceq
      [string]::Join([char]0, $sharedArguments)) `
    'Effective-POM arguments differ from active-profile arguments.'
  Assert-True ($calls[2].Arguments[0] -ceq
      'org.apache.maven.plugins:maven-dependency-plugin:3.7.0:build-classpath') `
    'The pinned dependency classpath goal changed.'
  Assert-True (
    [string]::Join([char]0, $calls[2].Arguments[1..12]) -ceq
      [string]::Join([char]0, $sharedArguments)) `
    'Classpath-preparation arguments differ from the validated manifest.'
  Assert-True (
    [string]::Join([char]0, $calls[3].Arguments) -ceq
      [string]::Join([char]0, $sharedArguments)) `
    'Verify arguments differ from the validated manifest.'

  $argumentManifest = Join-Path $fixtureTemp `
    'live-cosmos-maven-arguments.json'
  $savedManifest = [IO.File]::ReadAllBytes($argumentManifest)
  Remove-Item -LiteralPath $argumentManifest -Force
  try {
    $missingManifestOutput = Invoke-LiveScript `
      -ScriptPath $fixtureRunner -SourceDirectory $fixtureRoot `
      -TempDirectory $fixtureTemp -Environment $environment `
      -ExpectedExitCode 1
    Assert-Contains $missingManifestOutput `
      'validated Maven argument manifest is missing' `
      'Authenticated runner accepted a missing argument manifest.'
  } finally {
    [IO.File]::WriteAllBytes($argumentManifest, $savedManifest)
  }

  Invoke-ProviderMetadataFailureCase -Name 'missing-classpath-artifact' `
    -Expected 'dependency classpath' `
    -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
    -RunnerScript $fixtureRunner -BaseEnvironment $environment `
    -AdditionalEnvironment @{
      LIVE_COSMOS_SKIP_CLASSPATH_FILE = 'true'
    }

  $providerFixtures = Join-Path $script:TestRoot 'provider fixtures'
  $cosmosClassResource =
    'com/multiclouddb/provider/cosmos/CosmosProviderAdapter.class'
  $earlierShadow = Join-Path $providerFixtures 'earlier shadow'
  $earlierShadowClass = Join-Path $earlierShadow $cosmosClassResource
  New-Item -ItemType Directory -Path (
    Split-Path -Parent $earlierShadowClass) -Force | Out-Null
  [IO.File]::WriteAllBytes($earlierShadowClass, [byte[]]@(0))
  Invoke-ProviderMetadataFailureCase -Name 'earlier-shadow' `
    -Expected 'CosmosProviderAdapter' `
    -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
    -RunnerScript $fixtureRunner -BaseEnvironment $environment `
    -ClasspathPrepend $earlierShadow

  $multiReleaseArchive = Join-Path $providerFixtures `
    'multi-release-shadow.jar'
  New-FixtureArchive -Path $multiReleaseArchive -Entries ([ordered]@{
      'META-INF/MANIFEST.MF' =
        "Manifest-Version: 1.0`r`nMulti-Release: true`r`n`r`n"
      "META-INF/versions/17/$cosmosClassResource" = [byte[]]@(0)
    })
  Invoke-ProviderMetadataFailureCase -Name 'multi-release-shadow' `
    -Expected 'Multi-release' `
    -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
    -RunnerScript $fixtureRunner -BaseEnvironment $environment `
    -ClasspathPrepend $multiReleaseArchive

  foreach ($manifestCase in @(
      @{
        Name = 'manifest-classpath-lf'
        Text = "Manifest-Version: 1.0`nClass-Path: hidden.jar`n`n"
      },
      @{
        Name = 'manifest-classpath-crlf'
        Text = "Manifest-Version: 1.0`r`nCLASS-PATH: hidden.jar`r`n`r`n"
      },
      @{
        Name = 'manifest-classpath-cr-continuation'
        Text = "Manifest-Version: 1.0`rclAsS-pAtH: hidden-`r jar`r`r"
      })) {
    $archivePath = Join-Path $providerFixtures `
      "$($manifestCase.Name).jar"
    New-FixtureArchive -Path $archivePath -Entries ([ordered]@{
        'META-INF/MANIFEST.MF' = $manifestCase.Text
      })
    Invoke-ProviderMetadataFailureCase -Name $manifestCase.Name `
      -Expected 'Class-Path' `
      -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
      -RunnerScript $fixtureRunner -BaseEnvironment $environment `
      -ClasspathPrepend $archivePath
  }

  foreach ($descriptorCase in @(
      @{ Name = 'descriptor-lf'; Text = "fixture.GeneratedProvider`n" },
      @{ Name = 'descriptor-crlf'; Text = "fixture.GeneratedProvider`r`n" },
      @{ Name = 'descriptor-cr'; Text = "fixture.GeneratedProvider`r" },
      @{ Name = 'descriptor-malformed'; Text = "not a valid class name`n" },
      @{
        Name = 'descriptor-duplicate'
        Text = (
          "com.multiclouddb.provider.cosmos.CosmosProviderAdapter`n" +
          "com.multiclouddb.provider.cosmos.CosmosProviderAdapter`n")
      })) {
    $descriptorPath = Join-Path $providerFixtures `
      "$($descriptorCase.Name).txt"
    [IO.File]::WriteAllText(
      $descriptorPath, $descriptorCase.Text,
      [Text.UTF8Encoding]::new($false))
    $expected = if ($descriptorCase.Name -eq 'descriptor-malformed') {
      'not a valid class name'
    } elseif ($descriptorCase.Name -eq 'descriptor-duplicate') {
      'CosmosProviderAdapter'
    } else {
      'fixture.GeneratedProvider'
    }
    Invoke-ProviderMetadataFailureCase -Name $descriptorCase.Name `
      -Expected $expected -FixtureRoot $fixtureRoot `
      -FixtureTemp $fixtureTemp -RunnerScript $fixtureRunner `
      -BaseEnvironment $environment -DescriptorFixture $descriptorPath
  }

  Invoke-ProviderMetadataFailureCase -Name 'missing-dependency' `
    -Expected 'Required provider probe' `
    -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
    -RunnerScript $fixtureRunner -BaseEnvironment $environment `
    -ClasspathPrepend (Join-Path $providerFixtures 'missing.jar')

  $cosmosOutput = Join-Path $fixtureRoot `
    'multiclouddb-provider-cosmos/target/classes'
  $savedCosmosOutput = "$cosmosOutput.saved"
  Move-Item -LiteralPath $cosmosOutput -Destination $savedCosmosOutput
  try {
    Invoke-ProviderMetadataFailureCase -Name 'missing-provider-output' `
      -Expected 'Required provider probe' `
      -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
      -RunnerScript $fixtureRunner -BaseEnvironment $environment
  } finally {
    Move-Item -LiteralPath $savedCosmosOutput -Destination $cosmosOutput
  }

  foreach ($mode in @('delay', 'exit')) {
    foreach ($phase in @('profiles', 'effective-pom', 'compile', 'verify')) {
      Invoke-StreamingFailureCase -Phase $phase -Mode $mode `
        -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
        -PreflightScript $fixturePreflight -RunnerScript $fixtureRunner `
        -BaseEnvironment $environment
    }
  }

  foreach ($phaseCount in @(
      @{ Phase = 'profiles'; Repetitions = 20 },
      @{ Phase = 'effective-pom'; Repetitions = 10 })) {
    foreach ($iteration in 1..$phaseCount.Repetitions) {
      Invoke-StreamingFailureCase -Phase $phaseCount.Phase -Mode exit `
        -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
        -PreflightScript $fixturePreflight -RunnerScript $fixtureRunner `
        -BaseEnvironment $environment `
        -CaseSuffix "-rapid-$iteration" -Quiet
    }
    Write-Host (
      "PASS rapid exit $($phaseCount.Phase) repeated $($phaseCount.Repetitions) times.")
  }

  $streamCleanupFailed = $false
  try {
    Invoke-StreamingFailureCase -Phase profiles -Mode delay `
      -FixtureRoot $fixtureRoot -FixtureTemp $fixtureTemp `
      -PreflightScript $fixturePreflight -RunnerScript $fixtureRunner `
      -BaseEnvironment $environment -ObservationTimeoutSeconds 1 `
      -SuppressFixtureStream -CaseSuffix '-cleanup' -Quiet
  } catch {
    $streamCleanupFailed = $true
    Assert-Contains "$_" `
      'profiles-delay-cleanup did not stream stdout and stderr' `
      'Controlled streaming assertion did not retain its diagnostic.'
  }
  Assert-True $streamCleanupFailed `
    'Controlled streaming assertion fixture unexpectedly succeeded.'
  $streamCleanupPid = Join-Path $script:TestRoot `
    'profiles-delay-cleanup.pid'
  Assert-True (Test-Path -LiteralPath $streamCleanupPid -PathType Leaf) `
    'Controlled streaming assertion did not publish its owned child PID.'
  Assert-ProcessExited `
    -Id ([int](Get-Content -LiteralPath $streamCleanupPid -Raw)) `
    -Message 'Streaming assertion failure left its owned child running.'
  Write-Host 'PASS streaming assertion cleanup terminated owned processes.'

  $profileFallbackEnvironment =
    [Collections.Generic.Dictionary[string, string]]::new(
      $environment, [StringComparer]::Ordinal)
  $profileFallbackEnvironment['LIVE_COSMOS_TARGET_GOAL'] =
    'help:active-profiles'
  $profileFallbackEnvironment['LIVE_COSMOS_TARGET_MODE'] =
    'profile-fallback'
  $profileFallbackOutput = Invoke-LiveScript `
    -ScriptPath $fixturePreflight -SourceDirectory $fixtureRoot `
    -TempDirectory $fixtureTemp -Environment $profileFallbackEnvironment
  Assert-True (Test-Path -LiteralPath (
      Join-Path $fixtureTemp 'live-cosmos-maven-arguments.json') `
      -PathType Leaf) `
    'Streamed active-profile metadata fallback did not validate the manifest.'
  Assert-True (-not $profileFallbackOutput.Contains(
      'FILTERED_FIXTURE_VALUE')) `
    'Profile fallback leaked filtered option output.'

  Write-Host 'Live Cosmos no-auth regression harness passed.'
} finally {
  if (Test-Path -LiteralPath $script:TestRoot) {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force `
      -ErrorAction Stop
  }
}
