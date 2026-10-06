$mavenOutputSuppressionPattern =
  '^(?:NOTE:\s*)?Picked up (?:JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS):'
function Write-FilteredMavenOutput {
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [AllowNull()]
    [object]$InputObject
  )
  process {
    if ("$InputObject" -notmatch
        $mavenOutputSuppressionPattern) {
      Write-Host $InputObject
    }
  }
}

$forbiddenJvmPropertyPattern =
  '(?i)(?<![A-Za-z0-9_.])(?:-D)?(?:cosmos\.(?:key|endpoint)|COSMOS_(?:KEY|ENDPOINT)|jdk\.(?:tls|certpath)\.disabledAlgorithms|java\.security\.properties|surefire\.systemPropertiesFile|azure\.client\.(?:secret|certificate\.(?:path|password))|AZURE_CLIENT_SECRET|AZURE_CLIENT_CERTIFICATE_(?:PATH|PASSWORD)|AZURE_TOKEN_CREDENTIALS)(?:\s*=|\s|$)'
$forbiddenJvmArgumentIndirectionPattern =
  '(?i)@\{[^}\r\n]+\}|(?:^|\s)["'']?@(?!\{)[^\s"'']+'
$forbiddenJvmExecutableOptionPattern =
  '(?i)(?:^|\s)["'']?(?:-javaagent:|-agentlib:|-agentpath:|-Xrun[^\s"'']*|-Xbootclasspath/a:|--(?:class-path|module-path|upgrade-module-path|patch-module)(?:=|\s+)|-(?:cp|classpath|p)(?:=|\s+)|-Djava\.system\.class\.loader(?:=|\s)|-XX:(?:OnError|OnOutOfMemoryError)=)'
$forbiddenNestedJvmConfigPattern =
  "$forbiddenJvmPropertyPattern|$forbiddenJvmArgumentIndirectionPattern|$forbiddenJvmExecutableOptionPattern|(?:^|\s)[""']?(?-i:--(?:file|settings|global-settings|toolchains|global-toolchains)(?:\s+|=)\S|-(?:s|t)(?:\s+|=)?\S|-(?:gs|gt)(?:\s+|=)\S|-f(?!(?:ae|f|n|npr|npu|nsu)(?:\s|$))(?:\s+|=|\S))|(?:^|\s)[""']?-Dmaven\.(?:multiModuleProjectDirectory|projectBasedir|ext\.class\.path)(?:\s*=|\s|$)"
$forbiddenMavenRepositoryRedirectPattern =
  '(?i)(?:^|\s)["'']?(?:-D\s*|--define(?:=|\s+))["'']?maven\.repo\.local(?:\s*=|\s|$)'
$forbiddenMavenConfigPattern =
  "$forbiddenNestedJvmConfigPattern|$forbiddenMavenRepositoryRedirectPattern"
$forbiddenSurefireExecutionPropertyPattern =
  '(?im)(?:^|\s)["'']?(?:-D\s*|--define(?:=|\s+))["'']?(?:argLine|jvm|maven\.surefire\.debug)(?:\s*=|\s|$)'
function Test-ForbiddenMavenConfiguration {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  if ($Value -match $forbiddenMavenConfigPattern `
      -or $Value -match $forbiddenSurefireExecutionPropertyPattern) { return $true }
  return $false
}
