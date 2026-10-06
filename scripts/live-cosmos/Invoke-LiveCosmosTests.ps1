param(
  [Parameter(Mandatory)]
  [string]$SourceDirectory,

  [Parameter(Mandatory)]
  [string]$TempDirectory
)

$ErrorActionPreference = 'Stop'
$commonScript = Join-Path $PSScriptRoot 'LiveCosmos.Common.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
  throw "Required live Cosmos helper is missing: $commonScript"
}
. $commonScript
az account show --output none
if ($LASTEXITCODE -ne 0) {
  throw 'The WIF service connection could not establish an Azure CLI session.'
}
if ($env:AZURE_TOKEN_CREDENTIALS -cne 'AzureCliCredential') {
  throw 'AZURE_TOKEN_CREDENTIALS must remain AzureCliCredential.'
}
if ([string]::IsNullOrWhiteSpace($env:AZURE_CONFIG_DIR)) {
  throw 'AzureCLI must provide an isolated AZURE_CONFIG_DIR.'
}

$argumentManifest = Join-Path $TempDirectory `
  'live-cosmos-maven-arguments.json'
if (-not (Test-Path -LiteralPath $argumentManifest -PathType Leaf)) {
  throw 'The validated Maven argument manifest is missing.'
}
$manifestValue = Get-Content -LiteralPath `
  $argumentManifest -Raw | ConvertFrom-Json -NoEnumerate
if ($manifestValue -isnot [System.Array]) {
  throw 'The Maven argument manifest must decode to a JSON array.'
}
$liveMavenArguments = @($manifestValue)
$expectedMavenArguments = @(
  Get-LiveCosmosMavenArguments `
    -Endpoint $env:COSMOS_ENDPOINT -TempDirectory $TempDirectory)
if (-not (Test-ExactStringArray `
    -Actual $liveMavenArguments `
    -Expected $expectedMavenArguments)) {
  throw 'The Maven argument manifest does not exactly match the expected ordered live test arguments.'
}
$providerDependencyClasspathFile = Join-Path `
  $TempDirectory 'live-cosmos-test-classpath.txt'

foreach ($name in @(
    'COSMOS_KEY',
    'AZURE_CLIENT_SECRET',
    'AZURE_CLIENT_CERTIFICATE_PATH',
    'AZURE_CLIENT_CERTIFICATE_PASSWORD')) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if (-not [string]::IsNullOrWhiteSpace($value)) {
    throw "Forbidden credential environment variable '$name' is set."
  }
}

$trustedProjectBase = (Resolve-Path -LiteralPath `
  $SourceDirectory).Path
$currentProjectBase = (Resolve-Path -LiteralPath `
  (Get-Location).Path).Path
if ($currentProjectBase -cne $trustedProjectBase) {
  throw 'Maven must run from the trusted Build.SourcesDirectory checkout.'
}

foreach ($baseVariable in @(
    'MAVEN_PROJECTBASEDIR',
    'MAVEN_BASEDIR')) {
  $configuredProjectBase = [Environment]::GetEnvironmentVariable(
    $baseVariable)
  if (-not [string]::IsNullOrWhiteSpace($configuredProjectBase)) {
    try {
      $resolvedProjectBase = (Resolve-Path -LiteralPath `
        $configuredProjectBase).Path
    } catch {
      throw "$baseVariable does not resolve to the trusted checkout."
    }
    if ($resolvedProjectBase -cne $trustedProjectBase) {
      throw "$baseVariable must resolve to Build.SourcesDirectory."
    }
  }
}

foreach ($name in @(
    'JAVA_TOOL_OPTIONS',
    '_JAVA_OPTIONS',
    'JDK_JAVA_OPTIONS',
    'MAVEN_OPTS',
    'MAVEN_DEBUG_OPTS',
    'MAVEN_ARGS')) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if (-not [string]::IsNullOrWhiteSpace($value) `
      -and (Test-ForbiddenMavenConfiguration $value)) {
    throw "Environment variable '$name' contains forbidden Maven/JVM injection."
  }
}

foreach ($relativeConfigPath in @(
    '.mvn/maven.config',
    '.mvn/jvm.config')) {
  $configPath = Join-Path $trustedProjectBase $relativeConfigPath
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Write-Host "Inspecting Maven configuration file: $relativeConfigPath"
    $configText = Get-Content -LiteralPath $configPath -Raw
    if (Test-ForbiddenMavenConfiguration $configText) {
      throw "Maven configuration file '$relativeConfigPath' contains forbidden project, credential, endpoint, or security-policy injection."
    }
  }
}
$extensionsPath = Join-Path $trustedProjectBase '.mvn/extensions.xml'
if (Test-Path -LiteralPath $extensionsPath) {
  throw "Maven core extension file '.mvn/extensions.xml' is not permitted in the live WIF pipeline."
}

if (Test-Path -LiteralPath `
    $providerDependencyClasspathFile) {
  Remove-Item -LiteralPath `
    $providerDependencyClasspathFile `
    -Force -ErrorAction Stop
}
if (Test-Path -LiteralPath `
    $providerDependencyClasspathFile) {
  throw 'Stale live test dependency classpath could not be removed.'
}
& mvn process-test-classes `
  org.apache.maven.plugins:maven-dependency-plugin:3.7.0:build-classpath `
  @liveMavenArguments 2>&1 |
  Write-FilteredMavenOutput
$compileExitCode = $LASTEXITCODE
if ($compileExitCode -ne 0) {
  throw "Live Cosmos DB test classpath preparation failed with Maven exit code $compileExitCode."
}
if (-not (Test-Path -LiteralPath `
    $providerDependencyClasspathFile -PathType Leaf)) {
  throw 'Maven did not produce the live test dependency classpath.'
}

$candidateProviderClasspathEntries = @(
  (Join-Path $trustedProjectBase `
    'multiclouddb-conformance/target/test-classes')
)
$conformanceMainClasses = Join-Path `
  $trustedProjectBase `
  'multiclouddb-conformance/target/classes'
if (Test-Path -LiteralPath $conformanceMainClasses) {
  $candidateProviderClasspathEntries +=
    $conformanceMainClasses
}
$resolvedDependencyClasspath = (
  Get-Content -LiteralPath `
    $providerDependencyClasspathFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace(
    $resolvedDependencyClasspath)) {
  throw 'Maven produced an empty live test dependency classpath.'
}
$candidateProviderClasspathEntries +=
  $resolvedDependencyClasspath -split `
    [regex]::Escape([IO.Path]::PathSeparator)
$seenProviderClasspathEntries =
  [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
$providerClasspathEntries = @(
  foreach ($classpathEntry in `
      $candidateProviderClasspathEntries) {
    if ([string]::IsNullOrWhiteSpace($classpathEntry)) {
      continue
    }
    if (-not (Test-Path -LiteralPath $classpathEntry)) {
      throw "Required provider probe classpath entry is missing: $classpathEntry"
    }
    $resolvedClasspathEntry = (
      Resolve-Path -LiteralPath $classpathEntry).Path
    if ($seenProviderClasspathEntries.Add(
        $resolvedClasspathEntry)) {
      $resolvedClasspathEntry
    }
  }
)
if ($providerClasspathEntries.Count -eq 0) {
  throw 'The live test provider probe classpath is empty.'
}
$providerServiceResource =
  'META-INF/services/com.multiclouddb.spi.MulticloudDbProviderAdapter'
$approvedProviderModules = [ordered]@{
  'com.multiclouddb.provider.cosmos.CosmosProviderAdapter' =
    'multiclouddb-provider-cosmos'
  'com.multiclouddb.provider.dynamo.DynamoProviderAdapter' =
    'multiclouddb-provider-dynamo'
  'com.multiclouddb.provider.spanner.SpannerProviderAdapter' =
    'multiclouddb-provider-spanner'
}
$approvedProviderOrigins = [ordered]@{}
foreach ($providerClassName in `
    $approvedProviderModules.Keys) {
  $providerClasses = Join-Path $trustedProjectBase `
    "$($approvedProviderModules[$providerClassName])/target/classes"
  if (-not (Test-Path -LiteralPath `
      $providerClasses -PathType Container)) {
    throw "Approved provider output is missing: $providerClasses"
  }
  $approvedProviderOrigins[$providerClassName] = (
    Resolve-Path -LiteralPath $providerClasses).Path
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$providerValidationErrors =
  [Collections.Generic.List[string]]::new()
$providerRegistrationOrigins = @{}
$firstProviderClassOrigins = @{}
foreach ($classpathEntry in $providerClasspathEntries) {
  $descriptorTexts = @()
  $providerClassEntries = @{}
  if (Test-Path -LiteralPath `
      $classpathEntry -PathType Container) {
    $descriptorPath = Join-Path `
      $classpathEntry $providerServiceResource
    if (Test-Path -LiteralPath `
        $descriptorPath -PathType Leaf) {
      try {
        $descriptorTexts +=
          [IO.File]::ReadAllText(
            $descriptorPath,
            [Text.UTF8Encoding]::new($false, $true))
      } catch {
        $providerValidationErrors.Add(
          "Provider descriptor is not valid UTF-8: $descriptorPath")
      }
    }
    foreach ($providerClassName in `
        $approvedProviderOrigins.Keys) {
      $providerClassPath = Join-Path $classpathEntry `
        ($providerClassName.Replace(
          '.', [IO.Path]::DirectorySeparatorChar) +
          '.class')
      if (Test-Path -LiteralPath `
          $providerClassPath -PathType Leaf) {
        $providerClassEntries[$providerClassName] = 1
      }
    }
  } else {
    $archive = $null
    $isMultiReleaseArchive = $false
    try {
      $archive =
        [IO.Compression.ZipFile]::OpenRead(
          $classpathEntry)
      $manifestEntries = @($archive.Entries |
        Where-Object {
          $_.FullName -ieq 'META-INF/MANIFEST.MF'
        })
      if ($manifestEntries.Count -gt 1) {
        $providerValidationErrors.Add(
          "Classpath archive has duplicate manifests: $classpathEntry")
      }
      if ($manifestEntries.Count -eq 1) {
        $manifestStream = $manifestEntries[0].Open()
        try {
          $manifestReader = [IO.StreamReader]::new(
            $manifestStream,
            [Text.UTF8Encoding]::new($false, $true),
            $true)
          try {
            $manifestText =
              $manifestReader.ReadToEnd()
          } finally {
            $manifestReader.Dispose()
          }
          $manifestAttributes = @{}
          $currentManifestAttribute = $null
          foreach ($manifestLine in `
              ($manifestText -split '\r\n|\n|\r')) {
            if ($manifestLine.Length -eq 0) {
              break
            }
            if ($manifestLine.StartsWith(' ')) {
              if ($null -eq
                  $currentManifestAttribute) {
                $providerValidationErrors.Add(
                  "Classpath archive has malformed manifest continuation: $classpathEntry")
                continue
              }
              $manifestAttributes[
                $currentManifestAttribute] +=
                $manifestLine.Substring(1)
              continue
            }
            $manifestSeparator =
              $manifestLine.IndexOf(':')
            if ($manifestSeparator -le 0) {
              $providerValidationErrors.Add(
                "Classpath archive has malformed manifest attribute: $classpathEntry")
              $currentManifestAttribute = $null
              continue
            }
            $manifestName = $manifestLine.Substring(
              0, $manifestSeparator).Trim()
            $manifestValue = $manifestLine.Substring(
              $manifestSeparator + 1).TrimStart()
            if ($manifestAttributes.ContainsKey(
                $manifestName)) {
              $providerValidationErrors.Add(
                "Classpath archive has duplicate manifest attribute '$manifestName': $classpathEntry")
            } else {
              $manifestAttributes[$manifestName] =
                $manifestValue
            }
            $currentManifestAttribute =
              $manifestName
          }
          if ($manifestAttributes.ContainsKey(
              'Class-Path') `
              -and -not [string]::IsNullOrWhiteSpace(
                $manifestAttributes['Class-Path'])) {
            $providerValidationErrors.Add(
              "Classpath archive has unsupported manifest Class-Path entries: $classpathEntry")
          }
          $isMultiReleaseArchive =
            $manifestAttributes.ContainsKey(
              'Multi-Release') `
            -and $manifestAttributes[
              'Multi-Release'].Trim() -ieq 'true'
        } catch {
          $providerValidationErrors.Add(
            "Classpath archive manifest is not valid UTF-8: $classpathEntry")
        } finally {
          $manifestStream.Dispose()
        }
      }
      $serviceEntries = @($archive.Entries |
        Where-Object {
          $_.FullName -ceq $providerServiceResource
        })
      if ($serviceEntries.Count -gt 1) {
        $providerValidationErrors.Add(
          "Classpath archive has duplicate provider descriptors: $classpathEntry")
      }
      foreach ($serviceEntry in $serviceEntries) {
        $descriptorStream = $serviceEntry.Open()
        try {
          $descriptorReader = [IO.StreamReader]::new(
            $descriptorStream,
            [Text.UTF8Encoding]::new($false, $true),
            $true)
          try {
            $descriptorTexts +=
              $descriptorReader.ReadToEnd()
          } finally {
            $descriptorReader.Dispose()
          }
        } catch {
          $providerValidationErrors.Add(
            "Provider descriptor is not valid UTF-8 in: $classpathEntry")
        } finally {
          $descriptorStream.Dispose()
        }
      }
      foreach ($providerClassName in `
          $approvedProviderOrigins.Keys) {
        $classResource =
          $providerClassName.Replace('.', '/') +
          '.class'
        $baseClassEntries = @($archive.Entries |
          Where-Object {
            $_.FullName -ceq $classResource
          })
        if ($baseClassEntries.Count -gt 1) {
          $providerValidationErrors.Add(
            "Classpath archive has duplicate provider class entries for $providerClassName`: $classpathEntry")
        }
        $versionedClassEntries = @()
        if ($isMultiReleaseArchive) {
          $versionedClassPattern =
            '^META-INF/versions/(?<version>[0-9]+)/' +
            [regex]::Escape($classResource) + '$'
          $versionedClassEntries = @(
            foreach ($archiveEntry in `
                $archive.Entries) {
              $versionedClassMatch =
                [regex]::Match(
                  $archiveEntry.FullName,
                  $versionedClassPattern)
              if ($versionedClassMatch.Success) {
                $version = [int]$versionedClassMatch.Groups['version'].Value
                if ($version -ge 9 -and
                    $version -le 17) {
                  $archiveEntry
                }
              }
            }
          )
          if ($versionedClassEntries.Count -ne 0) {
            $providerValidationErrors.Add(
              "Multi-release archive defines approved provider class '$providerClassName' for Java 17: $classpathEntry")
          }
        }
        if ($baseClassEntries.Count -ne 0 `
            -or $versionedClassEntries.Count -ne 0) {
          $providerClassEntries[$providerClassName] =
            $baseClassEntries.Count +
            $versionedClassEntries.Count
        }
      }
    } catch {
      $providerValidationErrors.Add(
        "Provider classpath entry is not a readable archive: $classpathEntry")
    } finally {
      if ($null -ne $archive) {
        $archive.Dispose()
      }
    }
  }

  foreach ($providerClassName in `
      $providerClassEntries.Keys) {
    if (-not $firstProviderClassOrigins.ContainsKey(
        $providerClassName)) {
      $firstProviderClassOrigins[$providerClassName] =
        $classpathEntry
    }
  }
  foreach ($descriptorText in $descriptorTexts) {
    foreach ($descriptorLine in `
        ($descriptorText -split '\r\n|\n|\r')) {
      $providerName =
        ($descriptorLine -replace '#.*$', '').Trim()
      if ([string]::IsNullOrWhiteSpace($providerName)) {
        continue
      }
      if ($providerName -notmatch
          '^[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*$') {
        $providerValidationErrors.Add(
          "Malformed provider descriptor entry '$providerName' in: $classpathEntry")
        continue
      }
      if (-not $approvedProviderOrigins.Contains(
          $providerName)) {
        $providerValidationErrors.Add(
          "Unsupported provider registration '$providerName' in: $classpathEntry")
        continue
      }
      if ($providerRegistrationOrigins.ContainsKey(
          $providerName)) {
        $providerValidationErrors.Add(
          "Duplicate provider registration '$providerName' in: $classpathEntry")
        continue
      }
      $providerRegistrationOrigins[$providerName] =
        $classpathEntry
    }
  }
}

foreach ($providerClassName in `
    $approvedProviderOrigins.Keys) {
  $approvedOrigin =
    $approvedProviderOrigins[$providerClassName]
  if (-not $providerRegistrationOrigins.ContainsKey(
      $providerClassName)) {
    $providerValidationErrors.Add(
      "Missing approved provider registration '$providerClassName'.")
  } elseif ($providerRegistrationOrigins[
      $providerClassName] -cne $approvedOrigin) {
    $providerValidationErrors.Add(
      "Provider registration '$providerClassName' must originate from: $approvedOrigin")
  }
  if (-not $firstProviderClassOrigins.ContainsKey(
      $providerClassName)) {
    $providerValidationErrors.Add(
      "Missing approved provider class '$providerClassName'.")
  } elseif ($firstProviderClassOrigins[
      $providerClassName] -cne $approvedOrigin) {
    $providerValidationErrors.Add(
      "The first classpath definition of '$providerClassName' must originate from: $approvedOrigin")
  }
}
if ($providerValidationErrors.Count -ne 0) {
  throw @"
The live test classpath provider metadata is invalid:
$($providerValidationErrors -join [Environment]::NewLine)
Only the production Cosmos, Dynamo, and Spanner provider registrations and
classes from their canonical reactor target/classes outputs are permitted.
Test, generated, shadowed, malformed, duplicate, or dependency provider
registrations are unsupported.
"@
}
Write-Host (
  'Validated production provider descriptors and class origins without loading provider classes.')

# This exact future sentinel must perform a real Cosmos data-plane
# operation using DefaultAzureCredential and fail (never skip) if
# endpoint, Azure CLI auth, RBAC, or fixtures are unavailable.
# Splat the preflight-authored data array; never evaluate it as script.
& mvn verify @liveMavenArguments 2>&1 |
  Write-FilteredMavenOutput
$verifyExitCode = $LASTEXITCODE
if ($verifyExitCode -ne 0) {
  throw "Live Cosmos DB tests failed with Maven exit code $verifyExitCode."
}
