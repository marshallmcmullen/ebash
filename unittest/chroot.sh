#!/usr/bin/env bash

# Global settings
CHROOT=${TEST_DIR_OUTPUT}/chroot

file_setup()
{
    efreshdir ${CHROOT}
    mkchroot ${CHROOT} precise oxygen bdr-jenkins amd64
}

file_teardown()
{
    chroot_kill
    chroot_unmount
    eunmount_recursive ${CHROOT}
    rm -rf ${CHROOT}
}

check_mounts()
{
    $(declare_args count)

    # Verify chroot paths not mounted
    for path in ${CHROOT_MOUNTS[@]}; do
        [[ ${count} -eq 0 ]] && assert_false emounted ${CHROOT}${path} || assert_true emounted ${CHROOT}${path}
        assert_eq ${count} $(emount_count ${CHROOT}${path})
    done
}

ETEST_chroot_create()
{
    # Chroot created via setup routine so nothing to do
    :
}


ETEST_chroot_readlink()
{
    local real=$(chroot_readlink /var/run)
    assert_eq "${CHROOT}/run" "${real}"
}

ETEST_chroot_create_mount()
{
    check_mounts 0

    # Mount a few times and verify counts go up
    local nmounts=10
    for (( i=0; i<${nmounts}; ++i )); do
        chroot_mount
        check_mounts $((i+1))
    done

    # Unmount and verify counts go down
    for (( i=${nmounts}; i>0; --i )); do
        chroot_unmount
        check_mounts $((i-1))
    done

    check_mounts 0
}

# Ensure if we have multiple chroot_mounts going on that we can successfully
# unmount them properly using a single call to eunmount_recursive.
ETEST_chroot_create_mount_unmount_recursive()
{
    check_mounts 0

    # Mount a few times and verify counts go up
    local nmounts=10
    for (( i=0; i<${nmounts}; ++i )); do
        chroot_mount
        check_mounts $((i+1))
    done

    # One eunmount_recursive should clean everything up.
    eunmount_recursive ${CHROOT}
    check_mounts 0
}

# A problem that we've had repeatedly is after using chroot_mount, our root
# system gets honked up.  This seems to be related to shared/private mounts.
# Here we create a file on the root system in /dev/shm, which will go away if
# that problem occurs.  This seems to occur only on systems that mount /dev as
# shared initially (e.g. those running systemd)
ETEST_chroot_slash_dev_shared_mounts()
{
    TESTFILE=/dev/shm/${FUNCNAME}_$$

    touch ${TESTFILE}
    [[ -f ${TESTFILE} ]] || die "Unable to create ${TESTFILE}"
    trap_add "rm ${TESTFILE}"

    # Force /dev to be mounted "shared" so that the following code can test
    # whether it actually works that way.  This is the default on systemd
    # boxes, but not others
    mount --make-shared /dev

    mkdir dev

    ebindmount /dev dev
    ebindmount /dev dev

    # So now, while we've done a pair of bind mounts, the file should be missing
    [[ -f ${TESTFILE} ]] || die "File is missing"
}

ETEST_chroot_kill()
{
    chroot_mount

    etestmsg "Starting some chroot processes"
    chroot_cmd "cat&            echo \$! >> /tmp/pids"
    chroot_cmd "sleep infinity& echo \$! >> /tmp/pids"
    local pids=()
    array_init pids "$(cat ${CHROOT}/tmp/pids)"
    etestmsg "$(lval pids)"

    etestmsg "Killing cat"
    chroot_kill "cat"
    eretry -T=5s process_not_running ${pids[0]}
    process_running ${pids[1]}

    etestmsg "Killing everything..."
    chroot_kill
    eretry -T=5s process_not_running ${pids[0]}
    eretry -T=5s process_not_running ${pids[1]}

    # Exit CHROOT
    chroot_exit
}

ETEST_chroot_install()
{
    chroot_mount

    chroot_install "bashutils-sfdev-precise-1.0.1>=5"
    chroot_uninstall "bashutils-sfdev-precise-1.0.1"

    # Empty
    chroot_install
    chroot_uninstall

    # Done
    chroot_exit
}

#-----------------------------------------------------------------------------
# CHROOT DAEMON TESTS
#-----------------------------------------------------------------------------

ETEST_chroot_daemon_start_stop()
{
    local pidfile="${FUNCNAME}.pid"
    local sleep_daemon
    
    daemon_init sleep_daemon     \
        chroot="${CHROOT}"       \
        name="Infinity"          \
        cmdline="sleep infinity" \
        logfile="logfile.log"    \
        pidfile="${pidfile}"

    etestmsg "Starting chroot daemon"
    daemon_start sleep_daemon

    # Wait for process to be running
    eretry -r=30 -d=1 daemon_running sleep_daemon
    assert [[ -s ${pidfile} ]]
    assert process_running $(cat ${pidfile})
    assert daemon_running sleep_daemon
    assert daemon_status  sleep_daemon
    etestmsg "Started successfully"
    
    # Now stop it and verify proper shutdown
    etestmsg "Stopping chroot daemon"
    local pid=$(cat ${pidfile})
    daemon_stop sleep_daemon
    eretry -r=30 -d=1 daemon_not_running sleep_daemon
    eretry -r=30 -d=1 process_not_running "${pid}"
    assert_false daemon_running sleep_daemon
    assert_false daemon_status -q sleep_daemon
    assert_not_exists pidfile
    etestmsg "Stopped successfully"
}

# Test that verifies additional bindmounts can be specified to chroot daemons
ETEST_chroot_daemon_bindmount()
{
    etestmsg "Creating temporary directories"
    local tmpdir1=$(mktemp -d /tmp/${FUNCNAME}1-XXXXXXXX)
    local tmpdir2=$(mktemp -d /tmp/${FUNCNAME}2-XXXXXXXX)
    trap_add "rm -rf ${tmpdir1} ${tmpdir2}"
    touch ${tmpdir1}/{1,2,3,4,5} ${tmpdir2}/{1,2,3,4,5}

    etestmsg "Initializating daemon"
    local pidfile="${FUNCNAME}.pid"
    local sleep_daemon
    daemon_init sleep_daemon                        \
        chroot="${CHROOT}"                          \
        chroot_bindmounts="${tmpdir1} ${tmpdir2}"   \
        name="Infinity"                             \
        cmdline="sleep infinity"                    \
        logfile="logfile.log"                       \
        pidfile="${pidfile}"

    etestmsg "Starting chroot daemon"
    daemon_start sleep_daemon
    eretry -T=30s daemon_running sleep_daemon

    # Verify mounts are mounted
    etestmsg "Verifying mounts were mounted"
    assert_true emounted ${CHROOT}/${tmpdir1}
    assert_true emounted ${CHROOT}/${tmpdir2}

    # Stop the daemon
    etestmsg "Stopping daemon"
    daemon_stop sleep_daemon
 
    # Verify mounts are NOT mounted
    etestmsg "Verifying mounts were unmounted"
    einfo "${CHROOT}${tmpdir1}"
    assert_false emounted ${CHROOT}/${tmpdir1}
    einfo "${CHROOT}${tmpdir1}"
    assert_false emounted ${CHROOT}/${tmpdir2}
}

ETEST_chroot_daemon_bindmount_file()
{
    etestmsg "Creating temporary directories"
    local tmpdir1=$(mktemp -d /tmp/${FUNCNAME}1-XXXXXXXX)
    local tmpdir2=$(mktemp -d /tmp/${FUNCNAME}2-XXXXXXXX)
    trap_add "rm -rf ${tmpdir1} ${tmpdir2}"
    touch ${tmpdir1}/{1,2,3,4,5} ${tmpdir2}/{1,2,3,4,5}
    local bindmounts=( $(find ${tmpdir1} ${tmpdir2} -type f) )
    touch ${tmpdir1}/XXX

    etestmsg "Initializating daemon $(lval bindmounts)"
    local pidfile="${FUNCNAME}.pid"
    local sleep_daemon
    daemon_init sleep_daemon                 \
        chroot="${CHROOT}"                   \
        chroot_bindmounts="${bindmounts[*]} ${tmpdir1}/XXX:${tmpdir1}/YYY" \
        name="Infinity"                      \
        cmdline="sleep infinity"             \
        logfile="logfile.log"                \
        pidfile="${pidfile}"

    etestmsg "Starting chroot daemon"
    daemon_start sleep_daemon
    eretry -T=30s daemon_running sleep_daemon

    # Verify mounts are mounted
    etestmsg "Verifying mounts were mounted"
    for mnt in "${bindmounts[@]} ${tmpdir1}/YYY"; do
        assert_true emounted ${CHROOT}/${mnt}
    done

    # Stop the daemon
    etestmsg "Stopping daemon"
    daemon_stop sleep_daemon
 
    # Verify mounts are NOT mounted
    etestmsg "Verifying mounts were unmounted"
     for mnt in "${bindmounts[@]} ${tmpdir1}/YYY"; do
        assert_false emounted ${CHROOT}/${mnt}
    done
}
