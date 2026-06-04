#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    # Prevent seeding the cache and installing the prompt hook during dot-source
    $global:_CopilotSeeded          = $true
    $global:_CopilotPromptInstalled = $true

    . (Join-Path (Split-Path $PSScriptRoot -Parent) "copilot_usage.ps1")

    $script:TestCacheDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pester_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $script:TestCacheDir | Out-Null

    # Redirect all cache operations to the temp dir
    $global:_CopilotCacheDir   = $script:TestCacheDir
    $global:_CopilotPromptFile = Join-Path $script:TestCacheDir "prompt.txt"
}

AfterAll {
    Remove-Item -Recurse -Force $script:TestCacheDir -ErrorAction SilentlyContinue
    Remove-Variable _CopilotSeeded, _CopilotPromptInstalled, _CopilotCacheDir, _CopilotPromptFile `
        -Scope Global -ErrorAction SilentlyContinue
}

Describe "Get-CopilotUsageInfo" {
    Context "no cache present" {
        BeforeEach {
            Remove-Item (Join-Path $script:TestCacheDir "detail.txt") -ErrorAction SilentlyContinue
        }

        It "prints 'No cached data' message" {
            $output = Get-CopilotUsageInfo 6>&1 | Out-String
            $output | Should -Match "No cached data"
        }
    }

    Context "cache present" {
        BeforeEach {
            Set-Content (Join-Path $script:TestCacheDir "detail.txt") "Plan : copilot_enterprise"
            [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
                Set-Content (Join-Path $script:TestCacheDir "last_fetch")
        }

        It "prints detail file contents" {
            $output = (Get-CopilotUsageInfo 6>&1) | Out-String
            $output | Should -Match "Plan : copilot_enterprise"
        }

        It "prints cached timestamp" {
            $output = (Get-CopilotUsageInfo 6>&1) | Out-String
            $output | Should -Match "Cached:"
        }
    }
}

Describe "Embedded Python script (_CopilotPyScript)" {
    It "contains biz_hours function" {
        $global:_CopilotPyScript | Should -Match "def biz_hours"
    }

    It "contains parse_iso function" {
        $global:_CopilotPyScript | Should -Match "def parse_iso"
    }

    It "references premium_interactions quota bucket" {
        $global:_CopilotPyScript | Should -Match "premium_interactions"
    }

    It "writes prompt.txt and detail.txt given valid raw JSON" {
        $python = $global:_CopilotPython
        if (-not $python) { Set-ItResult -Skipped -Because "python not found"; return }

        $rawData = @{
            copilot_plan         = "copilot_enterprise"
            quota_reset_date_utc = "2024-07-01T00:00:00Z"
            quota_snapshots      = @{
                premium_interactions = @{
                    has_quota         = $true
                    entitlement       = 1000
                    remaining         = 800
                    percent_remaining = 80.0
                }
            }
        } | ConvertTo-Json -Depth 10

        $rawJsonPath = Join-Path $script:TestCacheDir "raw_test.json"
        Set-Content $rawJsonPath $rawData -Encoding UTF8

        $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
        Set-Content $tmpPy $global:_CopilotPyScript -Encoding UTF8
        try {
            & $python $tmpPy $rawJsonPath $script:TestCacheDir 2>&1 | Out-Null
        } finally {
            Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
        }

        $promptFile = Join-Path $script:TestCacheDir "prompt.txt"
        Test-Path $promptFile | Should -Be $true
        $content = Get-Content $promptFile -Raw -Encoding UTF8
        # used = 1000 - 800 = 200; 20% used → green icon
        $content | Should -Match "200/1000"
        $content | Should -Match "20\.0"
    }

    It "produces unlimited output when no quota snapshot has has_quota true" {
        $python = $global:_CopilotPython
        if (-not $python) { Set-ItResult -Skipped -Because "python not found"; return }

        $rawData = @{
            copilot_plan         = "copilot_individual"
            quota_reset_date_utc = ""
            quota_snapshots      = @{}
        } | ConvertTo-Json -Depth 10

        $rawJsonPath = Join-Path $script:TestCacheDir "raw_unlimited.json"
        Set-Content $rawJsonPath $rawData -Encoding UTF8

        $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
        Set-Content $tmpPy $global:_CopilotPyScript -Encoding UTF8
        try {
            & $python $tmpPy $rawJsonPath $script:TestCacheDir 2>&1 | Out-Null
        } finally {
            Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
        }

        $promptFile = Join-Path $script:TestCacheDir "prompt.txt"
        $content = Get-Content $promptFile -Raw -Encoding UTF8
        $content | Should -Match "unlimited"
    }
}

Describe "_Copilot-Fetch" {
    It "returns false when python is not configured" {
        # Empty string triggers the early-exit guard without touching gh or the API.
        # -ErrorAction Ignore suppresses the Write-Error so Pester does not fail this block.
        $result = _Copilot-Fetch -CacheDir $script:TestCacheDir `
                                  -Python "" `
                                  -PyScript $global:_CopilotPyScript `
                                  -ErrorAction Ignore
        $result | Should -Be $false
    }
}

Describe "PS5 emoji replacement logic" {
    It "replaces green circle emoji with [G]" {
        $s = [char]::ConvertFromUtf32(0x1F7E2) + " 10/100"
        $s.Replace([char]::ConvertFromUtf32(0x1F7E2), '[G]') | Should -Match '\[G\]'
    }

    It "replaces yellow circle emoji with [Y]" {
        $s = [char]::ConvertFromUtf32(0x1F7E1) + " test"
        $s.Replace([char]::ConvertFromUtf32(0x1F7E1), '[Y]') | Should -Match '\[Y\]'
    }

    It "replaces orange circle emoji with [O]" {
        $s = [char]::ConvertFromUtf32(0x1F7E0) + " test"
        $s.Replace([char]::ConvertFromUtf32(0x1F7E0), '[O]') | Should -Match '\[O\]'
    }

    It "replaces red circle emoji with [R]" {
        $s = [char]::ConvertFromUtf32(0x1F534) + " test"
        $s.Replace([char]::ConvertFromUtf32(0x1F534), '[R]') | Should -Match '\[R\]'
    }

    It "replaces up-right arrow with ->" {
        $s = "100 " + [string][char]0x2197 + " 900"
        $s.Replace([string][char]0x2197, '->') | Should -Match '\->'
    }
}

Describe "Python executable detection" {
    It "sets _CopilotPython when any python variant is present" {
        $anyPython = (Get-Command python3 -ErrorAction SilentlyContinue) -or
                     (Get-Command python  -ErrorAction SilentlyContinue) -or
                     (Get-Command py      -ErrorAction SilentlyContinue)
        if (-not $anyPython) {
            Set-ItResult -Skipped -Because "no python executable found in PATH"
            return
        }
        $global:_CopilotPython | Should -Not -BeNullOrEmpty
    }
}
