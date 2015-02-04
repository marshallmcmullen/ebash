
ecmd_quoting_func()
{
    expect_eq "a"     "$1"
    expect_eq "b c"   "$2"
    expect_eq "d e f" "$3"

    expect_eq 3 $#
}

ETEST_ecmd_quoting()
{
    ecmd ecmd_quoting_func "a" "b c" "d e f"
}

ecmd_dies_on_failure_func()
{
    return 3
}

ETEST_ecmd_dies_on_failure()
{
    EFUNCS_FATAL=0

    output=$(
        (
            ecmd ecmd_dies_on_failure_func
        ) 2>&1
    )

    expect_eq 1 $?
    expect_true 'echo "$output" | grep -q ecmd_dies_on_failure_func'
}
