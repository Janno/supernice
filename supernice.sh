#!/bin/bash

set -e

# minimum uid to be considered
MIN_UID=1000

# number of samples kept.
MAX_SAMPLES=15

# minimum number of samples required to be 
# eligible for penalties
MIN_SAMPLES=10

# number of samples that need to exceed 
# the SAMPLE_LIMIT to trigger penalties
SAMPLES_OVER_LIMIT=8

# the time distance between samples
# in seconds
SAMPLE_DISTANCE=2

# the amount of cpu time that is
# "too much" per sample (in seconds)
SAMPLE_LIMIT=$(( ${SAMPLE_DISTANCE} / 2))

PID_FILE="/var/run/supernice.pid"


USERS=()
STATS=()
PENALIZED=()

ps_call() {
    ps -e --format=uid,user,time h | \
        awk "{ if (\$1 >= ${MIN_UID} )  print;  }"
}

display() {
    echo -e "UID:\t TIMES"
    for uid in "${USERS[@]}";
    do
        echo -e "${uid}:\t ${STATS[$uid]}"
    done
}

update() {

    users_=()
    tmp=()

    IFS=$'\n'
    for line in `ps_call`;
    do
        IFS=" " read uid user time_ <<< "$line"
        IFS=":" read hours mins secs <<< "$time_"
        set +e
        t=$(( 10#$hours * 360))
        ((t += 10#$mins * 60 ))
        ((t += 10#$secs ))
        set -e
        users_[$user]=$user
        tmp[$user]=$(( ${tmp[${user}]:-0} + $t ))  
    done

    for user in "${users_[@]}";
    do
        if (( !${USERS[$user]:-0} ));
        then
            USERS[$user]=$user
        fi
    done

    for user in "${USERS[@]}";
    do
        stats=( ${STATS[$user]=""} )
        n=$( echo "${STATS[$user]}" | wc -w )

        if (( $n == $MAX_SAMPLES ));
        then 
            STATS[$user]="${tmp[$user]:-0} ${stats[@]:1:${MAX_SAMPLES}}"
        else
            STATS[$user]="${tmp[$user]:-0} ${stats[@]}"
        fi

    done
}

penalize() {
    user=$1

    PENALIZED[$user]=$user

    renice -n 20 -u $user > /dev/null

    ps -u $user --format=pid h | xargs ionice -c idle -p
}


check() {
    PENALIZED=()
    for user in "${USERS[@]}";
    do

        IFS=" " read -ra values <<< "${STATS[$user]}"
        n=$( echo "${values[@]}" | wc -w )

        if (( $n >= $MIN_SAMPLES ));
        then

            oldv=${values[0]}

            m=0

            for v in "${values[@]:1:$MAX_SAMPLES}";
            do
                diff=$(($oldv - $v))

                if (( $diff >= $SAMPLE_LIMIT ));
                then
                    ((m += 1))
                fi

                oldv=$v
            done

            if (( $m >= $SAMPLES_OVER_LIMIT ));
            then
                penalize $user
            fi

        fi

    done
}

loop() {
    while true;
    do
        update
        check
        #display
        sleep $SAMPLE_DISTANCE
    done
}

hup() {
    logger -p user.debug -t "supernice" "currently penalized: ${PENALIZED[@]}"
}

daemonize() {
    if [ -f "$PID_FILE" ];
    then
        old_pid=$(cat "$PID_FILE")
        ps -p $old_pid h > /dev/null && echo "supernice already running with pid $old_pid" > /dev/stderr && exit
    fi

    (
        trap hup SIGHUP
        trap "rm \"$PID_FILE\"; exit" SIGINT SIGTERM 
        loop
    ) &
    jobs -p > "$PID_FILE"
}

stop() {
    set +e
    if [ -f "$PID_FILE" ];
    then
        old_pid=$(cat "$PID_FILE")
        ps -p $old_pid h | grep supernice > /dev/null
        if [ "$?" == "0" ];
        then
            echo -n "killing supernice daemon process with pid $old_pid" > /dev/stderr
            kill $old_pid
            for i in `seq 5`;
            do
                echo -n "." > /dev/stderr
                ps -p $old_pid h | grep supernice > /dev/null 
                test "$?" != "0" && echo " success" > /dev/stderr && exit
                sleep 1
            done
            echo " timeout" > /dev/stderr
            exit 1
        else
            echo "could not find supernice daemon with pid $old_pid" > /dev/stderr
        fi
    else
        echo "no supernice daemon pid file found" > /dev/stderr
    fi
    set -e
}

start() {
    echo "starting supernice daemon" > /dev/stderr
    daemonize
}

status() {
    set +e
    if [ -f "$PID_FILE" ];
    then
        old_pid=$(cat "$PID_FILE")
        echo "sending HUP to supernice daemon with pid $old_pid - check /var/log/syslog for stats" > /dev/stderr
        kill -HUP $old_pid
    fi
    set -e
}

restart() {
    stop
    start
}

${1:-start}
