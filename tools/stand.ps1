param(
    [Parameter(Position = 0)]
    [ValidateSet("up", "list", "down")]
    [string]$Command = "up",

    [Parameter(Position = 1)]
    [string]$Branch
)


# ============================================================
# Configuration
# ============================================================

$Namespace = "stands"

$JenkinsBaseUrl = "http://localhost:8081"
$JenkinsMultibranchJob = "creatio-multibranch"
$JenkinsDeployJob = "creatio-stand-deploy"

$JenkinsStartTimeoutMinutes = 5
$JenkinsBuildTimeoutMinutes = 30
$JenkinsDeployStartTimeoutMinutes = 5
$JenkinsDeployTimeoutMinutes = 20

$DeploymentTimeoutMinutes = 5
$SmokeTimeoutMinutes = 5

$TraefikLocalPort = 8080

$Login = "Supervisor"
$Password = "Supervisor"

$PostgresHost = "localhost"
$PostgresPort = 5432
$PostgresUser = "postgres"
$PostgresPassword = "postgres"


$RepoRoot = Split-Path -Parent $PSScriptRoot


# ============================================================
# Output
# ============================================================

function Write-Status {
    param(
        [string]$Message
    )

    [Console]::Error.WriteLine("[stand] $Message")
}


function Write-Json {
    param(
        [object]$Value
    )

    $json = ConvertTo-Json `
        -InputObject $Value `
        -Depth 10 `
        -Compress

    [Console]::Out.WriteLine($json)
}


function Fail-Json {
    param(
        [string]$Stage,
        [string]$Message,
        [string]$BranchName = "",
        [string]$BuildUrl = "",
        [string]$Details = ""
    )

    $result = [ordered]@{
        status  = "error"
        stage   = $Stage
        message = $Message
    }

    if ($BranchName) {
        $result.branch = $BranchName
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
# Native commands
# ============================================================

function Invoke-Native {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )

    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = (($output | Out-String).Trim())
    }
}


# ============================================================
# Git
# ============================================================

function Get-GitBranch {

    $result = Invoke-Native `
        -Executable "git" `
        -Arguments @(
            "-C",
            $RepoRoot,
            "branch",
            "--show-current"
        )

    if ($result.ExitCode -ne 0 -or !$result.Output) {
        throw "Unable to determine current Git branch."
    }

    return $result.Output.Trim()
}


function Get-GitSha {

    $result = Invoke-Native `
        -Executable "git" `
        -Arguments @(
            "-C",
            $RepoRoot,
            "rev-parse",
            "HEAD"
        )

    if ($result.ExitCode -ne 0) {
        throw "Unable to determine Git commit."
    }

    return $result.Output.Trim()
}


function Get-GitShortSha {

    $result = Invoke-Native `
        -Executable "git" `
        -Arguments @(
            "-C",
            $RepoRoot,
            "rev-parse",
            "--short=8",
            "HEAD"
        )

    if ($result.ExitCode -ne 0) {
        throw "Unable to determine short Git commit."
    }

    return $result.Output.Trim()
}


function Assert-CleanWorkingTree {

    $result = Invoke-Native `
        -Executable "git" `
        -Arguments @(
            "-C",
            $RepoRoot,
            "status",
            "--porcelain"
        )

    if ($result.ExitCode -ne 0) {
        throw "Unable to read Git status."
    }

    if ($result.Output) {
        throw "Working tree contains uncommitted changes. Commit them before stand up."
    }
}


function Get-RemoteSha {
    param(
        [string]$BranchName
    )

    $result = Invoke-Native `
        -Executable "git" `
        -Arguments @(
            "-C",
            $RepoRoot,
            "ls-remote",
            "origin",
            "refs/heads/$BranchName"
        )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    if (!$result.Output) {
        return $null
    }

    return (($result.Output -split "\s+")[0]).Trim()
}


function Push-Branch {
    param(
        [string]$BranchName
    )

    Write-Status "Pushing $BranchName..."

    $result = Invoke-Native `
        -Executable "git" `
        -Arguments @(
            "-C",
            $RepoRoot,
            "push",
            "-u",
            "origin",
            "HEAD:$BranchName"
        )

    if ($result.ExitCode -ne 0) {
        throw "git push failed: $($result.Output)"
    }

    Write-Status "Branch is on GitHub."
}


# ============================================================
# Slug
# ============================================================

function Get-Slug {
    param(
        [string]$BranchName
    )

    $slug = $BranchName.ToLowerInvariant()

    $slug = $slug -replace '[^a-z0-9-]+', '-'
    $slug = $slug -replace '-+', '-'
    $slug = $slug.Trim('-')

    return $slug
}


# ============================================================
# Jenkins
# ============================================================

function Get-JenkinsHeaders {

    if (
        [string]::IsNullOrWhiteSpace($env:JENKINS_USER) -or
        [string]::IsNullOrWhiteSpace($env:JENKINS_TOKEN)
    ) {
        throw "JENKINS_USER or JENKINS_TOKEN is missing."
    }

    $pair = "$($env:JENKINS_USER):$($env:JENKINS_TOKEN)"

    $bytes = [Text.Encoding]::UTF8.GetBytes($pair)

    $encoded = [Convert]::ToBase64String($bytes)

    return @{
        Authorization = "Basic $encoded"
    }
}


function Invoke-JenkinsJson {
    param(
        [string]$Url
    )

    try {

        return Invoke-RestMethod `
            -Uri $Url `
            -Method Get `
            -Headers (Get-JenkinsHeaders)

    }
    catch {

        throw "Unable to read Jenkins API. If Jenkins requires authentication, check JENKINS_USER and JENKINS_TOKEN. $($_.Exception.Message)"
    }
}


function Get-JenkinsBranchJob {
    param(
        [string]$BranchName
    )

    $url = "$JenkinsBaseUrl/job/$JenkinsMultibranchJob/api/json?depth=1"

    $data = Invoke-JenkinsJson $url


    foreach ($job in @($data.jobs)) {

        $name = [string]$job.name
        $displayName = [string]$job.displayName

        try {
            $decodedName = [Uri]::UnescapeDataString($name)
        }
        catch {
            $decodedName = $name
        }


        if (
            $name -eq $BranchName -or
            $displayName -eq $BranchName -or
            $decodedName -eq $BranchName
        ) {
            return $job
        }
    }


    return $null
}


function Get-JenkinsLastBuildNumber {
    param(
        [string]$BranchName
    )

    $job = Get-JenkinsBranchJob $BranchName

    if ($null -eq $job) {
        return 0
    }

    if ($null -eq $job.lastBuild) {
        return 0
    }

    return [int]$job.lastBuild.number
}


function Wait-JenkinsCi {
    param(
        [string]$BranchName,
        [int]$PreviousBuildNumber,
        [bool]$ExpectNewBuild
    )


    Write-Status "Waiting for Jenkins CI..."


    $startDeadline = (Get-Date).AddMinutes(
        $JenkinsStartTimeoutMinutes
    )

    $build = $null


    while ((Get-Date) -lt $startDeadline) {

        $job = Get-JenkinsBranchJob $BranchName


        if ($null -ne $job -and $null -ne $job.lastBuild) {

            $number = [int]$job.lastBuild.number


            if ($ExpectNewBuild) {

                if ($number -gt $PreviousBuildNumber) {
                    $build = $job.lastBuild
                    break
                }

            }
            else {

                $build = $job.lastBuild
                break
            }
        }


        Start-Sleep -Seconds 3
    }


    if ($null -eq $build) {
        throw "Jenkins did not start CI for branch $BranchName."
    }


    $buildNumber = [int]$build.number
    $buildUrl = [string]$build.url


    Write-Status "Jenkins CI build #$buildNumber started."


    $deadline = (Get-Date).AddMinutes(
        $JenkinsBuildTimeoutMinutes
    )


    while ((Get-Date) -lt $deadline) {

        $data = Invoke-JenkinsJson (
            "$($buildUrl)api/json?depth=1"
        )


        if (!$data.building) {

            return [pscustomobject]@{
                Number = [int]$data.number
                Result = [string]$data.result
                Url    = [string]$data.url
            }
        }


        Start-Sleep -Seconds 5
    }


    throw "Jenkins CI build #$buildNumber timed out."
}


function Find-DeployBuild {
    param(
        [int]$UpstreamBuild,
        [string]$BranchName
    )


    $jobUrl = "$JenkinsBaseUrl/job/$JenkinsDeployJob/api/json?depth=1"

    $job = Invoke-JenkinsJson $jobUrl


    $builds = @(
        $job.builds |
        Sort-Object number -Descending |
        Select-Object -First 20
    )


    $expectedProject = "$JenkinsMultibranchJob/$BranchName"


    foreach ($buildRef in $builds) {

        if (!$buildRef.url) {
            continue
        }


        try {

            $build = Invoke-JenkinsJson (
                "$($buildRef.url)api/json?depth=2"
            )

        }
        catch {

            continue
        }


        foreach ($action in @($build.actions)) {

            foreach ($cause in @($action.causes)) {

                if ($null -eq $cause.upstreamBuild) {
                    continue
                }


                $project = [string]$cause.upstreamProject


                try {
                    $decodedProject = [Uri]::UnescapeDataString(
                        $project
                    )
                }
                catch {
                    $decodedProject = $project
                }


                if (
                    [int]$cause.upstreamBuild -eq $UpstreamBuild -and
                    (
                        $decodedProject -eq $expectedProject -or
                        $decodedProject.EndsWith("/$BranchName")
                    )
                ) {

                    return [pscustomobject]@{
                        Number   = [int]$build.number
                        Url      = [string]$build.url
                        Building = [bool]$build.building
                        Result   = [string]$build.result
                    }
                }
            }
        }
    }


    return $null
}


function Wait-JenkinsDeploy {
    param(
        [int]$UpstreamBuild,
        [string]$BranchName
    )


    Write-Status "Waiting for $JenkinsDeployJob..."


    $startDeadline = (Get-Date).AddMinutes(
        $JenkinsDeployStartTimeoutMinutes
    )


    $deploy = $null


    while ((Get-Date) -lt $startDeadline) {

        $deploy = Find-DeployBuild `
            -UpstreamBuild $UpstreamBuild `
            -BranchName $BranchName


        if ($null -ne $deploy) {
            break
        }


        Start-Sleep -Seconds 3
    }


    if ($null -eq $deploy) {

        throw "$JenkinsDeployJob was not started by CI build #$UpstreamBuild."
    }


    Write-Status "Deploy build #$($deploy.Number) started."


    $deadline = (Get-Date).AddMinutes(
        $JenkinsDeployTimeoutMinutes
    )


    while ((Get-Date) -lt $deadline) {

        $data = Invoke-JenkinsJson (
            "$($deploy.Url)api/json?depth=1"
        )


        if (!$data.building) {

            return [pscustomobject]@{
                Number = [int]$data.number
                Result = [string]$data.result
                Url    = [string]$data.url
            }
        }


        Start-Sleep -Seconds 5
    }


    throw "Deploy build #$($deploy.Number) timed out."
}


# ============================================================
# Kubernetes
# ============================================================

function Wait-Deployment {
    param(
        [string]$ReleaseName,
        [string]$ImageTag
    )


    Write-Status "Checking Kubernetes deployment..."


    $deadline = (Get-Date).AddMinutes(
        $DeploymentTimeoutMinutes
    )


    while ((Get-Date) -lt $deadline) {

        $result = Invoke-Native `
            -Executable "kubectl" `
            -Arguments @(
                "get",
                "deployment",
                $ReleaseName,
                "-n",
                $Namespace,
                "-o",
                "json"
            )


        if ($result.ExitCode -eq 0 -and $result.Output) {

            try {

                $deployment = $result.Output |
                    ConvertFrom-Json


                $desired = [int]$deployment.spec.replicas

                $ready = 0

                if ($null -ne $deployment.status.readyReplicas) {
                    $ready = [int]$deployment.status.readyReplicas
                }


                $available = 0

                if ($null -ne $deployment.status.availableReplicas) {
                    $available = [int]$deployment.status.availableReplicas
                }


                $container = @(
                    $deployment.spec.template.spec.containers |
                    Where-Object {
                        $_.name -eq "creatio"
                    }
                ) | Select-Object -First 1


                if ($null -eq $container) {
                    $container = @(
                        $deployment.spec.template.spec.containers
                    ) | Select-Object -First 1
                }


                $imageOk = $false

                if ($null -ne $container) {

                    $image = [string]$container.image

                    if ($image.EndsWith(":$ImageTag")) {
                        $imageOk = $true
                    }
                }


                if (
                    $desired -gt 0 -and
                    $ready -ge $desired -and
                    $available -ge $desired -and
                    $imageOk
                ) {

                    Write-Status "Kubernetes deployment is Ready."

                    return
                }

            }
            catch {
                # deployment is still changing
            }
        }


        Start-Sleep -Seconds 5
    }


    throw "Kubernetes deployment $ReleaseName did not become Ready."
}


# ============================================================
# Traefik port-forward
# ============================================================

function Test-TcpPort {
    param(
        [int]$Port
    )

    $client = New-Object System.Net.Sockets.TcpClient

    try {

        $result = $client.BeginConnect(
            "127.0.0.1",
            $Port,
            $null,
            $null
        )

        $success = $result.AsyncWaitHandle.WaitOne(
            300
        )

        if (!$success) {
            return $false
        }

        $client.EndConnect($result)

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

    if (Test-TcpPort $TraefikLocalPort) {

        Write-Status "Traefik port-forward is already available."

        return
    }


    Write-Status "Starting Traefik port-forward..."


    $kubectl = Get-Command kubectl `
        -ErrorAction SilentlyContinue


    if ($null -eq $kubectl) {
        throw "kubectl was not found."
    }


    $stdout = Join-Path `
        $env:TEMP `
        "stand-traefik-out.log"

    $stderr = Join-Path `
        $env:TEMP `
        "stand-traefik-error.log"


    Start-Process `
        -FilePath $kubectl.Source `
        -ArgumentList @(
            "port-forward",
            "-n",
            "traefik",
            "svc/traefik",
            "$TraefikLocalPort`:80"
        ) `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -WindowStyle Hidden | Out-Null


    $deadline = (Get-Date).AddSeconds(20)


    while ((Get-Date) -lt $deadline) {

        if (Test-TcpPort $TraefikLocalPort) {

            Write-Status "Traefik port-forward is ready."

            return
        }


        Start-Sleep -Seconds 1
    }


    $details = ""

    if (Test-Path $stderr) {
        $details = Get-Content $stderr -Raw
    }


    throw "Unable to start Traefik port-forward. $details"
}


# ============================================================
# Bruno smoke
# ============================================================

function Invoke-SmokeOnce {
    param(
        [string]$Url
    )


    $bru = Get-Command bru `
        -ErrorAction SilentlyContinue


    if ($null -eq $bru) {
        throw "Bruno CLI (bru) was not found."
    }


    $smokeDir = Join-Path `
        $RepoRoot `
        "smoke"


    Push-Location $smokeDir

    try {

        $output = & bru run `
            --env stand `
            -r `
            --env-var "baseUrl=$Url" `
            2>&1


        $exitCode = $LASTEXITCODE


        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = (($output | Out-String).Trim())
        }

    }
    finally {

        Pop-Location
    }
}


function Wait-Smoke {
    param(
        [string]$Url
    )


    Write-Status "Running stand smoke tests..."


    $deadline = (Get-Date).AddMinutes(
        $SmokeTimeoutMinutes
    )

    $lastOutput = ""


    while ((Get-Date) -lt $deadline) {

        $result = Invoke-SmokeOnce $Url

        $lastOutput = $result.Output


        if ($result.ExitCode -eq 0) {

            Write-Status "Smoke tests passed."

            return
        }


        Write-Status "Smoke is not green yet. Retrying..."

        Start-Sleep -Seconds 10
    }


    throw "Smoke tests failed. $lastOutput"
}


# ============================================================
# Helm
# ============================================================

function Get-HelmValues {
    param(
        [string]$ReleaseName
    )


    $result = Invoke-Native `
        -Executable "helm" `
        -Arguments @(
            "get",
            "values",
            $ReleaseName,
            "-n",
            $Namespace,
            "-o",
            "json"
        )


    if ($result.ExitCode -ne 0) {
        return $null
    }


    if (!$result.Output) {
        return $null
    }


    try {
        return $result.Output | ConvertFrom-Json
    }
    catch {
        return $null
    }
}


# ============================================================
# UP
# ============================================================

function Invoke-StandUp {

    try {

        Assert-CleanWorkingTree

        $branchName = Get-GitBranch
        $fullSha = Get-GitSha
        $shortSha = Get-GitShortSha

        $slug = Get-Slug $branchName
        $release = "stand-$slug"


        Write-Status "Branch: $branchName"
        Write-Status "Commit: $shortSha"


        $remoteBefore = Get-RemoteSha $branchName

        $previousBuild = Get-JenkinsLastBuildNumber `
            $branchName


        Push-Branch $branchName


        $expectNewBuild = (
            $remoteBefore -ne $fullSha
        )


        $ci = Wait-JenkinsCi `
            -BranchName $branchName `
            -PreviousBuildNumber $previousBuild `
            -ExpectNewBuild $expectNewBuild


        if ($ci.Result -ne "SUCCESS") {

            Fail-Json `
                -Stage "ci" `
                -Message "Jenkins CI finished with status $($ci.Result)." `
                -BranchName $branchName `
                -BuildUrl $ci.Url
        }


        Write-Status "Jenkins CI succeeded."


        $deploy = Wait-JenkinsDeploy `
            -UpstreamBuild $ci.Number `
            -BranchName $branchName


        if ($deploy.Result -ne "SUCCESS") {

            Fail-Json `
                -Stage "deploy" `
                -Message "$JenkinsDeployJob finished with status $($deploy.Result)." `
                -BranchName $branchName `
                -BuildUrl $deploy.Url `
                -Details "Image tag: $shortSha"
        }


        Write-Status "Stand deploy succeeded."


        Wait-Deployment `
            -ReleaseName $release `
            -ImageTag $shortSha


        Ensure-TraefikPortForward


        $url = "http://$slug.localtest.me`:$TraefikLocalPort"


        Wait-Smoke $url


        $values = Get-HelmValues $release


        $redisDb = $null
        $databaseName = "stand_$($slug -replace '-', '_')"
        $ttlHours = 24


        if ($null -ne $values) {

            if (
                $null -ne $values.redis -and
                $null -ne $values.redis.database
            ) {
                $redisDb = [int]$values.redis.database
            }


            if (
                $null -ne $values.database -and
                $values.database.name
            ) {
                $databaseName = [string]$values.database.name
            }


            if ($values.ttlHours) {
                $ttlHours = [int]$values.ttlHours
            }
        }


        $expiresAt = (
            Get-Date
        ).ToUniversalTime().AddHours(
            $ttlHours
        ).ToString("o")


        $dbConnection = (
            "Server=$PostgresHost;" +
            "Port=$PostgresPort;" +
            "Database=$databaseName;" +
            "User Id=$PostgresUser;" +
            "Password=$PostgresPassword;"
        )


        $result = [ordered]@{
            status    = "ok"
            branch    = $branchName
            slug      = $slug
            url       = $url
            login     = $Login
            password  = $Password
            db        = $dbConnection
            redisDb   = $redisDb
            imageTag  = $shortSha
            logs      = "kubectl logs -n $Namespace -l app=$release -f"
            expiresAt = $expiresAt
            down      = "stand down $branchName"
        }


        Write-Json $result

    }
    catch {

        Fail-Json `
            -Stage "stand-up" `
            -Message $_.Exception.Message
    }
}


# ============================================================
# LIST
# ============================================================

function Invoke-StandList {

    $result = Invoke-Native `
        -Executable "kubectl" `
        -Arguments @(
            "get",
            "deployment",
            "-n",
            $Namespace,
            "-o",
            "json"
        )


    if ($result.ExitCode -ne 0) {

        Fail-Json `
            -Stage "list" `
            -Message $result.Output
    }


    try {

        $data = $result.Output |
            ConvertFrom-Json

    }
    catch {

        Fail-Json `
            -Stage "list" `
            -Message "Unable to parse Kubernetes response."
    }


    $stands = @()


    foreach ($deployment in @($data.items)) {

        $name = [string]$deployment.metadata.name


        if (!$name.StartsWith("stand-")) {
            continue
        }


        $values = Get-HelmValues $name


        $branchName = $null
        $hostName = $null
        $databaseName = $null
        $redisDb = $null
        $imageTag = $null
        $ttlHours = 24


        if ($null -ne $values) {

            $branchName = [string]$values.branch

            if ($values.route) {
                $hostName = [string]$values.route.host
            }

            if ($values.database) {
                $databaseName = [string]$values.database.name
            }

            if ($values.redis) {
                $redisDb = $values.redis.database
            }

            if ($values.image) {
                $imageTag = [string]$values.image.tag
            }

            if ($values.ttlHours) {
                $ttlHours = [int]$values.ttlHours
            }
        }


        $desired = [int]$deployment.spec.replicas

        $ready = 0

        if ($deployment.status.readyReplicas) {
            $ready = [int]$deployment.status.readyReplicas
        }


        $status = "not-ready"

        if (
            $desired -gt 0 -and
            $ready -ge $desired
        ) {
            $status = "ready"
        }


        $createdAt = [DateTimeOffset]::Parse(
            [string]$deployment.metadata.creationTimestamp
        )


        $expiresAt = $createdAt.AddHours(
            $ttlHours
        ).UtcDateTime.ToString("o")


        $url = $null

        if ($hostName) {
            $url = "http://$hostName`:$TraefikLocalPort"
        }


        $stands += [pscustomobject]@{
            branch    = $branchName
            release   = $name
            status    = $status
            url       = $url
            database  = $databaseName
            redisDb   = $redisDb
            imageTag  = $imageTag
            expiresAt = $expiresAt
        }
    }


    Write-Json @($stands)
}


# ============================================================
# DOWN
# ============================================================

function Find-DockerContainer {
    param(
        [string]$Pattern
    )


    $result = Invoke-Native `
        -Executable "docker" `
        -Arguments @(
            "ps",
            "--format",
            "{{.ID}}|{{.Names}}|{{.Image}}"
        )


    if ($result.ExitCode -ne 0) {
        return $null
    }


    foreach ($line in (
        $result.Output -split "`r?`n"
    )) {

        if ($line -match $Pattern) {

            return (
                $line -split "\|"
            )[0]
        }
    }


    return $null
}


function Invoke-StandDown {

    try {

        $branchName = $Branch


        if ([string]::IsNullOrWhiteSpace($branchName)) {

            $branchName = Get-GitBranch
        }


        $slug = Get-Slug $branchName

        $release = "stand-$slug"


        Write-Status "Removing stand $release..."


        $values = Get-HelmValues $release


        $databaseName = "stand_$($slug -replace '-', '_')"

        $redisDb = $null


        if ($null -ne $values) {

            if (
                $values.database -and
                $values.database.name
            ) {
                $databaseName = [string]$values.database.name
            }


            if (
                $values.redis -and
                $null -ne $values.redis.database
            ) {
                $redisDb = [int]$values.redis.database
            }
        }


        $helm = Invoke-Native `
            -Executable "helm" `
            -Arguments @(
                "uninstall",
                $release,
                "-n",
                $Namespace
            )


        if (
            $helm.ExitCode -ne 0 -and
            $helm.Output -notmatch "not found"
        ) {

            throw "helm uninstall failed: $($helm.Output)"
        }


        $postgres = Find-DockerContainer `
            "postgres"


        if ($postgres) {

            Invoke-Native `
                -Executable "docker" `
                -Arguments @(
                    "exec",
                    $postgres,
                    "psql",
                    "-U",
                    $PostgresUser,
                    "-d",
                    "postgres",
                    "-c",
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$databaseName' AND pid <> pg_backend_pid();"
                ) | Out-Null


            Invoke-Native `
                -Executable "docker" `
                -Arguments @(
                    "exec",
                    $postgres,
                    "dropdb",
                    "-U",
                    $PostgresUser,
                    "--if-exists",
                    $databaseName
                ) | Out-Null
        }


        if ($null -ne $redisDb) {

            $redis = Find-DockerContainer `
                "redis"


            if ($redis) {

                Invoke-Native `
                    -Executable "docker" `
                    -Arguments @(
                        "exec",
                        $redis,
                        "redis-cli",
                        "-n",
                        "$redisDb",
                        "FLUSHDB"
                    ) | Out-Null
            }
        }


        Write-Json ([ordered]@{
            status   = "ok"
            branch   = $branchName
            release  = $release
            database = $databaseName
            redisDb  = $redisDb
        })

    }
    catch {

        Fail-Json `
            -Stage "down" `
            -Message $_.Exception.Message `
            -BranchName $Branch
    }
}


# ============================================================
# Command
# ============================================================

switch ($Command) {

    "up" {
        Invoke-StandUp
    }

    "list" {
        Invoke-StandList
    }

    "down" {
        Invoke-StandDown
    }
}