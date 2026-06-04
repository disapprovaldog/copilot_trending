#!/usr/bin/env bats
# Requires bats-core >= 1.7 and zsh

setup() {
    CACHE_DIR="$(mktemp -d)"
    # IMPORTANT: source the script first, then override _COPILOT_CACHE_DIR.
    # The script sets _COPILOT_CACHE_DIR at the top level, overwriting any
    # pre-source export.
    SCRIPT="$(dirname "$BATS_TEST_FILENAME")/../copilot_usage.zsh"
}

teardown() {
    rm -rf "$CACHE_DIR"
}

@test "script sources without error" {
    run zsh -c "
        source '$SCRIPT' && echo ok
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}

@test "copilot_usage_info with no cache returns error and message" {
    run zsh -c "
        source '$SCRIPT'
        _COPILOT_CACHE_DIR='$CACHE_DIR'
        copilot_usage_info
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"No cached data"* ]]
}

@test "copilot_usage_info prints detail.txt contents" {
    printf 'Plan : copilot_enterprise\n' > "$CACHE_DIR/detail.txt"
    date +%s > "$CACHE_DIR/last_fetch"

    run zsh -c "
        source '$SCRIPT'
        _COPILOT_CACHE_DIR='$CACHE_DIR'
        copilot_usage_info
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Plan : copilot_enterprise"* ]]
}

@test "copilot_usage_info appends cached timestamp" {
    printf 'Plan : copilot_enterprise\n' > "$CACHE_DIR/detail.txt"
    date +%s > "$CACHE_DIR/last_fetch"

    run zsh -c "
        source '$SCRIPT'
        _COPILOT_CACHE_DIR='$CACHE_DIR'
        copilot_usage_info
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cached:"* ]]
}

@test "copilot_usage_update calls fetch and prints fetching message" {
    printf '🟢 10/100 (10.0%%%%)\n' > "$CACHE_DIR/prompt.txt"

    run zsh -c "
        source '$SCRIPT'
        _COPILOT_CACHE_DIR='$CACHE_DIR'
        _copilot_usage_fetch() { return 0 }
        copilot_usage_update
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Fetching"* ]]
}

@test "copilot_usage_update unescapes double-percent from prompt.txt" {
    # The zsh version stores percent as '%%' to escape zsh prompt expansion.
    # copilot_usage_update must convert '%%' → '%' before printing.
    printf '🟢 10/100 (10.0%%%%)\n' > "$CACHE_DIR/prompt.txt"

    run zsh -c "
        source '$SCRIPT'
        _COPILOT_CACHE_DIR='$CACHE_DIR'
        _copilot_usage_fetch() { return 0 }
        copilot_usage_update
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"%%"* ]]
    [[ "$output" == *"10.0%"* ]]
}

@test "_copilot_usage_precmd skips fetch when cache is fresh" {
    date +%s > "$CACHE_DIR/last_fetch"

    run zsh -c "
        source '$SCRIPT'
        _COPILOT_CACHE_DIR='$CACHE_DIR'
        _COPILOT_REFRESH_SECS=300
        FETCH_CALLED=0
        _copilot_usage_fetch() { FETCH_CALLED=1 }
        _copilot_usage_precmd
        echo fetch_called=\$FETCH_CALLED
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"fetch_called=0"* ]]
}

@test "_copilot_usage_precmd runs without error when cache is stale" {
    # Verifies the stale-cache path executes without crashing.
    # The background job uses ( fn & ) which doesn't inherit overridden
    # functions in non-interactive zsh, so we just test error-free execution.
    echo "0" > "$CACHE_DIR/last_fetch"

    run zsh -c "
        source '$SCRIPT'
        _COPILOT_CACHE_DIR='$CACHE_DIR'
        _COPILOT_REFRESH_SECS=300
        _copilot_usage_precmd
        echo precmd_ran
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"precmd_ran"* ]]
}

@test "copilot_usage_update is a no-op when fetch fails" {
    run zsh -c "
        source '$SCRIPT'
        _COPILOT_CACHE_DIR='$CACHE_DIR'
        _copilot_usage_fetch() { return 1 }
        copilot_usage_update
        echo done
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Fetching"* ]]
    [[ "$output" == *"done"* ]]
}
