param(
    [Parameter(Position = 0)]
    [ValidateSet("up", "list", "down")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Argument
)

$ErrorActionPreference = "Stop"


# ============================================================
# CONFIG
# ============================================================

$Namespace = "stands"

$Registry = "http://localhost:5002"
$ImageRepository = "creatio-stand"

$Login = "Supervisor"
$Password = "Supervisor"

$PostgresHost = "localhost"
$PostgresPort = 5432
$PostgresUser = "postgres"
$PostgresPassword = "postgres"

$TraefikLocalPort = 8080

$JenkinsBaseUrl = "http://localhost:8081"
$JenkinsMultibranchJob = "creatio-multibranch"

$JenkinsStartTimeoutMinutes = 3
$JenkinsBuildTimeoutMinutes = 25

$ArtifactTimeoutMinutes = 5
$DeployTimeoutMinutes = 12


# ============================================================
# OUTPUT
# ============================================================

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    # stderr.
    # Человек видит прогресс,
    # но stdout остаётся чистым JSON.
    [Console]::Error.WriteLine("[stand] $Message")
}


function Write-Json {
    param(
        [Parameter(Mandatory = $true)]
        $Object
    )

    $json = ConvertTo-Json `
        -InputObject $Object `
        -Depth 10 `
        -Compress

    Write-Output $json
}


function Fail-Json {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Stage = "stand",

        [string]$Branch = "",

        [string]$BuildUrl = "",

        [string]$Details = ""
    )

    $result = [ordered]@{
        status  = "error"
        stage   = $Stage
        message = $Message
    }

    if ($Branch) {
        $result.branch = $Branch
    }

    if ($BuildUrl) {
        $result.buildUrl = $BuildUrl
    }

    if ($Details) {
        $result.details = $Details
    }

    Write-Json $result

    exit 1
}


# ============================================================
# GIT
# ============================================================

function Get-RepoRoot {

    $result = git rev-parse --show-toplevel 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Fail-Json `
            -Message "Current directory is not inside a Git repository." `
            -Stage "git"
    }

    return $result.Trim()
}


function Get-CurrentBranch {

    $result = git branch --show-current 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Fail-Json `
            -Message "Unable to determine current Git branch." `
            -Stage "git"
    }

    return $result.Trim()
}


function Get-CurrentSha {

    $result = git rev-parse HEAD 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Fail-Json `
            -Message "Unable to determine current Git commit." `
            -Stage "git"
    }

    return $result.Trim()
}


function Get-ShortSha {

    $result = git rev-parse --short=8 HEAD 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        Fail-Json `
            -Message "Unable to determine current Git commit." `
            -Stage "git"
    }

    return $result.Trim()
}


function Get-RemoteSha {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    $result = git ls-remote `
        origin `
        "refs/heads/$Branch" `
        2>$null

    if ($LASTEXITCODE -ne 0 -or -not $result) {
        return $null
    }

    $parts = $result -split '\s+'

    if ($parts.Count -eq 0) {
        return $null
    }

    return $parts[0].Trim()
}


function Assert-CleanWorkingTree {

    $result = git status --porcelain 2>$null

    if ($LASTEXITCODE -ne 0) {
        Fail-Json `
            -Message "Unable to read Git status." `
            -Stage "git"
    }

    if ($result) {
        Fail-Json `
            -Message "Working tree contains uncommitted changes. Commit them before stand up." `
            -Stage "git"
    }
}


function Push-CurrentBranch {

    $branch = Get-CurrentBranch
    $localSha = Get-CurrentSha

    Write-Status "Pushing $branch..."

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {

        git push `
            -u origin `
            "HEAD:refs/heads/$branch" `
            *> $null

        $pushExitCode = $LASTEXITCODE
    }
    finally {

        $ErrorActionPreference = $oldPreference
    }

    if ($pushExitCode -ne 0) {

        Fail-Json `
            -Message "Unable to push branch $branch." `
            -Stage "git" `
            -Branch $branch
    }

    $remoteSha = Get-RemoteSha `
        -Branch $branch

    if (-not $remoteSha) {

        Fail-Json `
            -Message "Branch $branch was pushed but cannot be found on origin." `
            -Stage "git" `
            -Branch $branch
    }

    if ($remoteSha -ne $localSha) {

        Fail-Json `
            -Message "Remote branch does not point to current commit." `
            -Stage "git" `
            -Branch $branch
    }

    Write-Status "Branch is on GitHub."
}


# ============================================================
# NAMES
# ============================================================

function Get-Slug {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    $slug = $Branch.ToLower()

    $slug = $slug -replace '[^a-z0-9]', '-'
    $slug = $slug -replace '-+', '-'
    $slug = $slug.Trim('-')

    if ($slug.Length -gt 30) {
        $slug = $slug.Substring(0, 30).TrimEnd('-')
    }

    return $slug
}


function Get-DbName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Slug
    )

    return "stand_" + ($Slug -replace '-', '_')
}


# ============================================================
# JENKINS
# ============================================================

function Get-JenkinsHeaders {

    $headers = @{}

    if (
        $env:JENKINS_USER -and
        $env:JENKINS_TOKEN
    ) {

        $pair = "$($env:JENKINS_USER):$($env:JENKINS_TOKEN)"

        $bytes = [System.Text.Encoding]::ASCII.GetBytes(
            $pair
        )

        $encoded = [Convert]::ToBase64String(
            $bytes
        )

        $headers["Authorization"] = "Basic $encoded"
    }

    return $headers
}


function Invoke-JenkinsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [switch]$AllowFailure
    )

    try {

        return Invoke-RestMethod `
            -Uri $Uri `
            -Headers (Get-JenkinsHeaders) `
            -Method Get `
            -TimeoutSec 10
    }
    catch {

        if ($AllowFailure) {
            return $null
        }

        Fail-Json `
            -Message "Unable to read Jenkins API. If Jenkins requires authentication, set JENKINS_USER and JENKINS_TOKEN." `
            -Stage "ci"
    }
}


function Get-JenkinsBranchJob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    $uri = "$JenkinsBaseUrl/job/$JenkinsMultibranchJob/api/json?tree=jobs[name,displayName,url,color,lastBuild[number,url,building,result,timestamp]]"

    $parent = Invoke-JenkinsJson `
        -Uri $uri

    if (-not $parent.jobs) {
        return $null
    }

    foreach ($job in $parent.jobs) {

        $name = [string]$job.name
        $displayName = [string]$job.displayName

        $decodedName = $name

        try {
            $decodedName = [Uri]::UnescapeDataString(
                $name
            )
        }
        catch {
        }

        if (
            $name -eq $Branch -or
            $displayName -eq $Branch -or
            $decodedName -eq $Branch
        ) {
            return $job
        }
    }

    return $null
}


function Get-JenkinsLastBuildNumber {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    $job = Get-JenkinsBranchJob `
        -Branch $Branch

    if (-not $job) {
        return $null
    }

    if (-not $job.lastBuild) {
        return $null
    }

    return [int]$job.lastBuild.number
}


function Wait-JenkinsCi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch,

        [int]$PreviousBuildNumber = 0,

        [bool]$ExpectNewBuild = $true
    )

    Write-Status "Waiting for Jenkins CI..."

    $startDeadline = (Get-Date).AddMinutes(
        $JenkinsStartTimeoutMinutes
    )

    $build = $null

    while ((Get-Date) -lt $startDeadline) {

        $job = Get-JenkinsBranchJob `
            -Branch $Branch

        if ($job -and $job.lastBuild) {

            $candidate = $job.lastBuild

            if ($ExpectNewBuild) {

                if (
                    [int]$candidate.number -gt
                    $PreviousBuildNumber
                ) {

                    $build = $candidate
                    break
                }
            }
            else {

                $build = $candidate
                break
            }
        }

        Start-Sleep -Seconds 5
    }


    if (-not $build) {

        Fail-Json `
            -Message "Jenkins did not start a build for $Branch. Check GitHub webhook / Cloudflare tunnel." `
            -Stage "ci" `
            -Branch $Branch
    }


    Write-Status "Jenkins build #$($build.number) started."

    $deadline = (Get-Date).AddMinutes(
        $JenkinsBuildTimeoutMinutes
    )


    while ((Get-Date) -lt $deadline) {

        $job = Get-JenkinsBranchJob `
            -Branch $Branch

        if (
            -not $job -or
            -not $job.lastBuild
        ) {

            Start-Sleep -Seconds 5
            continue
        }


        $current = $job.lastBuild

        if (
            [int]$current.number -lt
            [int]$build.number
        ) {

            Start-Sleep -Seconds 5
            continue
        }


        if ($current.building) {

            Start-Sleep -Seconds 5
            continue
        }


        $result = [string]$current.result
        $buildUrl = [string]$current.url


        if ($result -eq "SUCCESS") {

            Write-Status "Jenkins CI succeeded."

            return $current
        }


        Fail-Json `
            -Message "Jenkins CI finished with status $result." `
            -Stage "ci" `
            -Branch $Branch `
            -BuildUrl $buildUrl
    }


    Fail-Json `
        -Message "Jenkins CI did not finish before timeout." `
        -Stage "ci" `
        -Branch $Branch
}


# ============================================================
# DOCKER / DB / REDIS
# ============================================================

function Find-ComposeContainer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Service
    )

    $result = docker ps -q `
        --filter "label=com.docker.compose.project=day1-stand" `
        --filter "label=com.docker.compose.service=$Service" `
        2>$null |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($result)) {
        return $null
    }

    return ([string]$result).Trim()
}


function Get-DbContainer {

    $container = Find-ComposeContainer `
        -Service "db"

    if (-not $container) {

        Fail-Json `
            -Message "PostgreSQL container was not found." `
            -Stage "database"
    }

    return $container
}


function Get-RedisContainer {

    $container = Find-ComposeContainer `
        -Service "redis"

    if (-not $container) {

        Fail-Json `
            -Message "Redis container was not found." `
            -Stage "redis"
    }

    return $container
}


function Test-DatabaseExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database
    )

    $container = Find-ComposeContainer `
        -Service "db"

    if (-not $container) {
        return $false
    }


    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {

        docker exec `
            $container `
            pg_isready `
            -U postgres `
            *> $null

        $readyExit = $LASTEXITCODE
    }
    finally {

        $ErrorActionPreference = $oldPreference
    }


    if ($readyExit -ne 0) {
        return $false
    }


    $sql = "SELECT 1 FROM pg_database WHERE datname='$Database';"

    $result = docker exec `
        $container `
        psql `
        -U postgres `
        -d postgres `
        -tAc $sql `
        2>$null


    if ($LASTEXITCODE -ne 0) {
        return $false
    }


    if ($null -eq $result) {
        return $false
    }


    $text = ($result | Out-String).Trim()


    return ($text -eq "1")
}


# ============================================================
# REGISTRY
# ============================================================

function Test-ImageExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    try {

        $headers = @{
            Accept = "application/vnd.docker.distribution.manifest.v2+json"
        }

        $null = Invoke-WebRequest `
            -Uri "$Registry/v2/$ImageRepository/manifests/$Tag" `
            -Method Head `
            -Headers $headers `
            -UseBasicParsing `
            -TimeoutSec 5

        return $true
    }
    catch {

        return $false
    }
}


# ============================================================
# BUILD ARTIFACTS
# ============================================================

function Wait-ForBuildArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sha
    )

    Write-Status "Checking image and DB snapshot..."

    $snapshot = "creatio_snap_$Sha"

    $deadline = (Get-Date).AddMinutes(
        $ArtifactTimeoutMinutes
    )


    while ((Get-Date) -lt $deadline) {

        $snapshotReady = Test-DatabaseExists `
            -Database $snapshot

        $imageReady = Test-ImageExists `
            -Tag $Sha


        if (
            $snapshotReady -and
            $imageReady
        ) {

            Write-Status "Build artifacts are ready."

            return
        }


        Start-Sleep -Seconds 5
    }


    Fail-Json `
        -Message "CI succeeded but image or database snapshot for $Sha was not found." `
        -Stage "artifacts"
}


# ============================================================
# HELM
# ============================================================

function Get-ReleaseValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Release
    )

    $tempFile = [System.IO.Path]::GetTempFileName()

    try {

        & cmd.exe /d /c `
            "helm get values `"$Release`" -n `"$Namespace`" -o json 1>`"$tempFile`" 2>nul"

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            return $null
        }


        $raw = Get-Content `
            -Path $tempFile `
            -Raw `
            -ErrorAction SilentlyContinue


        if (-not $raw) {
            return $null
        }


        try {
            return ($raw | ConvertFrom-Json)
        }
        catch {
            return $null
        }
    }
    finally {

        Remove-Item `
            $tempFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
}


function Test-ReleaseExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Release
    )

    & cmd.exe /d /c `
        "helm status `"$Release`" -n `"$Namespace`" 1>nul 2>nul"

    return ($LASTEXITCODE -eq 0)
}


# ============================================================
# KUBERNETES
# ============================================================

function Wait-ForDeployment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Release,

        [Parameter(Mandatory = $true)]
        [string]$Sha,

        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    Write-Status "Waiting for Kubernetes deployment..."

    $deadline = (Get-Date).AddMinutes(
        $DeployTimeoutMinutes
    )


    while ((Get-Date) -lt $deadline) {

        $values = Get-ReleaseValues `
            -Release $Release


        if ($null -ne $values) {

            $tag = $null

            if ($values.image) {
                $tag = [string]$values.image.tag
            }


            if ($tag -eq $Sha) {

                $available = kubectl get deployment `
                    $Release `
                    -n $Namespace `
                    -o jsonpath='{.status.availableReplicas}' `
                    2>$null


                if (
                    $LASTEXITCODE -eq 0 -and
                    $available -and
                    [int]$available -ge 1
                ) {

                    Write-Status "Kubernetes deployment is ready."

                    return
                }
            }
        }


        Start-Sleep -Seconds 5
    }


    Fail-Json `
        -Message "Stand did not become Ready before timeout." `
        -Stage "deploy" `
        -Branch $Branch
}


function Get-ExpiresAt {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Release,

        [Parameter(Mandatory = $true)]
        [int]$TtlHours
    )

    $created = kubectl get deployment `
        $Release `
        -n $Namespace `
        -o jsonpath='{.metadata.creationTimestamp}' `
        2>$null


    if (
        $LASTEXITCODE -ne 0 -or
        -not $created
    ) {

        return $null
    }


    try {

        $date = [DateTimeOffset]::Parse(
            $created.Trim()
        )


        return $date.AddHours(
            $TtlHours
        ).ToUniversalTime().ToString(
            "yyyy-MM-ddTHH:mm:ssZ"
        )
    }
    catch {

        return $null
    }
}


# ============================================================
# TRAEFIK
# ============================================================

function Test-LocalPort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $client = New-Object `
        System.Net.Sockets.TcpClient


    try {

        $async = $client.BeginConnect(
            "127.0.0.1",
            $Port,
            $null,
            $null
        )


        $connected = $async.AsyncWaitHandle.WaitOne(
            500
        )


        if (-not $connected) {
            return $false
        }


        $client.EndConnect(
            $async
        )


        return $true
    }
    catch {

        return $false
    }
    finally {

        $client.Close()
    }
}


function Ensure-TraefikPortForward {

    if (Test-LocalPort -Port $TraefikLocalPort) {
        return
    }


    Write-Status "Starting Traefik port-forward..."


    $kubectl = Get-Command kubectl `
        -ErrorAction SilentlyContinue


    if (-not $kubectl) {

        Fail-Json `
            -Message "kubectl was not found." `
            -Stage "deploy"
    }


    $stdout = Join-Path `
        $env:TEMP `
        "stand-traefik.out.log"

    $stderr = Join-Path `
        $env:TEMP `
        "stand-traefik.err.log"


    Start-Process `
        -FilePath $kubectl.Source `
        -ArgumentList @(
            "port-forward",
            "-n",
            "traefik",
            "svc/traefik",
            "${TraefikLocalPort}:80"
        ) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr |
        Out-Null


    $deadline = (Get-Date).AddSeconds(15)


    while ((Get-Date) -lt $deadline) {

        if (Test-LocalPort -Port $TraefikLocalPort) {

            Write-Status "Traefik port-forward is ready."

            return
        }


        Start-Sleep -Seconds 1
    }


    Fail-Json `
        -Message "Unable to start Traefik port-forward." `
        -Stage "deploy"
}


# ============================================================
# BRUNO
# ============================================================

function Invoke-Smoke {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    Write-Status "Running Bruno smoke tests..."


    $smokeDir = Join-Path `
        $RepoRoot `
        "smoke"


    if (-not (Test-Path $smokeDir)) {

        Fail-Json `
            -Message "Smoke directory was not found." `
            -Stage "smoke" `
            -Branch $Branch
    }


    $bru = Get-Command bru `
        -ErrorAction SilentlyContinue


    if (-not $bru) {

        Fail-Json `
            -Message "Bruno CLI 'bru' was not found." `
            -Stage "smoke" `
            -Branch $Branch
    }


    $stdoutFile = Join-Path `
        $env:TEMP `
        "stand-smoke-out.txt"

    $stderrFile = Join-Path `
        $env:TEMP `
        "stand-smoke-err.txt"


    Push-Location $smokeDir


    try {

        $process = Start-Process `
            -FilePath $bru.Source `
            -ArgumentList @(
                "run",
                "--env",
                "stand",
                "--env-var",
                "baseUrl=$Url",
                "--env-var",
                "username=$Login",
                "--env-var",
                "password=$Password",
                "--bail"
            ) `
            -Wait `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile


        if ($process.ExitCode -ne 0) {

            $details = ""

            if (Test-Path $stdoutFile) {

                $details = (
                    Get-Content $stdoutFile |
                    Select-Object -Last 15
                ) -join " "
            }


            Fail-Json `
                -Message "Bruno smoke tests failed." `
                -Stage "smoke" `
                -Branch $Branch `
                -Details $details
        }
    }
    finally {

        Pop-Location

        Remove-Item `
            $stdoutFile `
            -Force `
            -ErrorAction SilentlyContinue

        Remove-Item `
            $stderrFile `
            -Force `
            -ErrorAction SilentlyContinue
    }


    Write-Status "Smoke tests passed."
}


# ============================================================
# STAND INFO
# ============================================================

function Get-StandInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    $slug = Get-Slug `
        -Branch $Branch

    $release = "stand-$slug"

    $values = Get-ReleaseValues `
        -Release $release


    if ($null -eq $values) {
        return $null
    }


    $redisDb = $null
    $imageTag = $null
    $ttlHours = 24


    if ($values.redis) {
        $redisDb = $values.redis.database
    }


    if ($values.image) {
        $imageTag = [string]$values.image.tag
    }


    if ($null -ne $values.ttlHours) {
        $ttlHours = [int]$values.ttlHours
    }


    $dbName = Get-DbName `
        -Slug $slug


    $expiresAt = Get-ExpiresAt `
        -Release $release `
        -TtlHours $ttlHours


    $url = "http://${slug}.localtest.me:${TraefikLocalPort}"


    return [ordered]@{
        branch    = $Branch
        slug      = $slug
        url       = $url
        login     = $Login
        password  = $Password
        db        = "Server=$PostgresHost;Port=$PostgresPort;Database=$dbName;User Id=$PostgresUser;Password=$PostgresPassword"
        redisDb   = $redisDb
        imageTag  = $imageTag
        logs      = "kubectl logs -n $Namespace deployment/$release -f"
        expiresAt = $expiresAt
        down      = "stand down $Branch"
    }
}


# ============================================================
# UP
# ============================================================

function Invoke-StandUp {

    $repoRoot = Get-RepoRoot
    $branch = Get-CurrentBranch


    if (
        $branch -eq "master" -or
        $branch -eq "main"
    ) {

        Fail-Json `
            -Message "stand up must be executed from a feature branch." `
            -Stage "git" `
            -Branch $branch
    }


    Assert-CleanWorkingTree


    $fullSha = Get-CurrentSha
    $sha = Get-ShortSha


    Write-Status "Branch: $branch"
    Write-Status "Commit: $sha"


    $remoteBefore = Get-RemoteSha `
        -Branch $branch


    $previousBuildNumber = Get-JenkinsLastBuildNumber `
        -Branch $branch


    if ($null -eq $previousBuildNumber) {
        $previousBuildNumber = 0
    }


    Push-CurrentBranch


    $expectNewBuild = (
        $remoteBefore -ne $fullSha
    )


    Wait-JenkinsCi `
        -Branch $branch `
        -PreviousBuildNumber $previousBuildNumber `
        -ExpectNewBuild $expectNewBuild |
        Out-Null


    Wait-ForBuildArtifacts `
        -Sha $sha


    $slug = Get-Slug `
        -Branch $branch

    $release = "stand-$slug"


    Wait-ForDeployment `
        -Release $release `
        -Sha $sha `
        -Branch $branch


    Ensure-TraefikPortForward


    $url = "http://${slug}.localtest.me:${TraefikLocalPort}"


    Invoke-Smoke `
        -RepoRoot $repoRoot `
        -Url $url `
        -Branch $branch


    $info = Get-StandInfo `
        -Branch $branch


    if ($null -eq $info) {

        Fail-Json `
            -Message "Stand is Ready but Helm values could not be read." `
            -Stage "stand" `
            -Branch $branch
    }


    Write-Json $info
}


# ============================================================
# LIST
# ============================================================

function Get-StandList {

    $raw = helm list `
        -n $Namespace `
        -o json `
        2>$null


    if ($LASTEXITCODE -ne 0) {

        Fail-Json `
            -Message "Unable to read Helm releases." `
            -Stage "helm"
    }


    if (-not $raw) {

        Write-Json @()

        return
    }


    try {

        $releases = (
            $raw -join "`n"
        ) | ConvertFrom-Json
    }
    catch {

        Fail-Json `
            -Message "Unable to parse Helm releases." `
            -Stage "helm"
    }


    $result = @()


    foreach ($release in $releases) {

        if (-not $release.name.StartsWith("stand-")) {
            continue
        }


        $values = Get-ReleaseValues `
            -Release $release.name


        if (-not $values) {
            continue
        }


        $branch = [string]$values.branch


        if (-not $branch) {
            continue
        }


        $info = Get-StandInfo `
            -Branch $branch


        if ($info) {
            $result += $info
        }
    }


    Write-Json $result
}


# ============================================================
# DOWN
# ============================================================

function Invoke-StandDown {

    $branch = $Argument


    if (-not $branch) {
        $branch = Get-CurrentBranch
    }


    $slug = Get-Slug `
        -Branch $branch

    $release = "stand-$slug"

    $dbName = Get-DbName `
        -Slug $slug


    $redisDb = $null


    $values = Get-ReleaseValues `
        -Release $release


    if (
        $values -and
        $values.redis
    ) {

        $redisDb = $values.redis.database
    }


    Write-Status "Deleting $release..."


    if (Test-ReleaseExists -Release $release) {

        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"

        try {

            helm uninstall `
                $release `
                -n $Namespace `
                *> $null

            $helmExit = $LASTEXITCODE
        }
        finally {

            $ErrorActionPreference = $oldPreference
        }


        if ($helmExit -ne 0) {

            Fail-Json `
                -Message "Unable to uninstall Helm release." `
                -Stage "down" `
                -Branch $branch
        }
    }


    $dbContainer = Get-DbContainer


    $terminateSql = @"
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '$dbName'
  AND pid <> pg_backend_pid();
"@


    docker exec `
        $dbContainer `
        psql `
        -U postgres `
        -d postgres `
        -c $terminateSql `
        *> $null


    $dropSql = "DROP DATABASE IF EXISTS $dbName;"


    docker exec `
        $dbContainer `
        psql `
        -U postgres `
        -d postgres `
        -c $dropSql `
        *> $null


    if ($LASTEXITCODE -ne 0) {

        Fail-Json `
            -Message "Unable to remove stand database." `
            -Stage "down" `
            -Branch $branch
    }


    if ($null -ne $redisDb) {

        $redisContainer = Get-RedisContainer


        docker exec `
            $redisContainer `
            redis-cli `
            -n $redisDb `
            FLUSHDB `
            *> $null


        if ($LASTEXITCODE -ne 0) {

            Fail-Json `
                -Message "Unable to flush Redis DB." `
                -Stage "down" `
                -Branch $branch
        }
    }


    Write-Json ([ordered]@{
        status = "deleted"
        branch = $branch
        slug   = $slug
    })
}


# ============================================================
# ENTRY
# ============================================================

if (-not $Command) {

    Fail-Json `
        -Message "Usage: stand <up|list|down> [branch]"
}


switch ($Command) {

    "up" {
        Invoke-StandUp
    }

    "list" {
        Get-StandList
    }

    "down" {
        Invoke-StandDown
    }
}