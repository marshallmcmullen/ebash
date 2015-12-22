#!/usr/bin/env bash

OUTPUT=${TEST_DIR_OUTPUT}/ticks

# Fake EPROGRESS function body to use in some of the tests which
# don't want the real do_eprogress
FAKE_DO_EPROGRESS='
{
    trap "exit 0" ${DIE_SIGNALS[@]}

    local tick=0
    rm -f ${OUTPUT}

    while true; do
        echo "${tick}" >> ${OUTPUT}
        (( tick++ )) || true
        sleep 0.10   || true
    done
}
'

wait_for_eprogress()
{
    while true; do
        [[ -s ${OUTPUT} ]] && return 0
        sleep .1
    done
}

wait_for_ticks()
{
    $(declare_args expected)

    while true; do
        local actual=$(tail -1 ${OUTPUT} || true)
        [[ ${actual} -ge ${expected} ]] && return 0
        
        echo "Ticks: ${actual}/${expected}"
        sleep .1
    done
}

ETEST_eprogress_ticks()
{
    override_function do_eprogress "${FAKE_DO_EPROGRESS}"

    eprogress "Waiting 1 second"
    wait_for_ticks 9
    eprogress_kill
}

ETEST_eprogress_ticks_reuse()
{
    override_function do_eprogress "${FAKE_DO_EPROGRESS}"

    eprogress "Waiting for Ubuntu to stop sucking"
    wait_for_ticks 5
    eprogress_kill
    
    eprogress "Waiting for Gentoo to replace Ubuntu"
    wait_for_ticks 5
    eprogress_kill
}

# Verify EPROGRESS_TICKER can be used to forcibly enable/disable ticker
ETEST_eprogress_ticker_off()
{
    (
        exec &> >(tee ${OUTPUT})

        COLUMNS=28
        EFUNCS_COLOR=0
        EDEBUG=0
        ETRACE=0
        EINTERACTIVE=0
        eprogress "Waiting"
        eprogress_kill

    )

    wait_for_eprogress
    assert_eq ">> Waiting.[ ok ]" "$(cat ${OUTPUT})"
}

ETEST_eprogress_ticker_on()
{
    (
        exec &> >(tee ${OUTPUT})

        COLUMNS=28
        EFUNCS_COLOR=0
        EDEBUG=0
        ETRACE=0
        EINTERACTIVE=1
        eprogress "Waiting"
        eprogress_kill

    )

    wait_for_eprogress

    # The ticker may actuall run for slightly longer than we requested due to
    # how sleep works. Change instances of 00:00:0[1-9] to 00:00:01 in the output
    # for easier validation.
    sed -i "s|:01\]|:00\]|g" ${OUTPUT}
    assert_eq ">> Waiting [00:00:00]  ^H/^H-^H\^H|^H/^H-^H\^H|^H \$"$'\n'"^[M^[[22C[ ok ]\$" "$(cat -evt ${OUTPUT})"
}

ETEST_eprogress_inside_eretry()
{
    override_function do_eprogress "${FAKE_DO_EPROGRESS}"

    etestmsg "Starting eprogress"
    eprogress "Waiting for eretry"
    $(tryrc eretry -T=5s false)
    eprogress_kill
    assert [[ $(tail -1 ${OUTPUT} || true) -ge 5 ]]
}

ETEST_eprogress_kill_before_eprogress()
{
    eprogress_kill
}

ETEST_eprogress_killall()
{
    eprogress "Processing" &> /dev/null
    eprogress "More Stuff" &> /dev/null

    local pids=( "${__BU_EPROGRESS_PIDS[@]}" )
    assert_eq 2 $(array_size pids)
   
    local pid=
    for pid in "${pids[@]}"; do
        assert process_running ${pid}
    done

    # Kill all eprogress pids and verify they exit
    eprogress_kill -a
    for pid in "${pids[@]}"; do
        eretry -T=5s process_not_running ${pid}
    done
}

ETEST_eprogress_killall_empty()
{
    eprogress_kill -a
}

