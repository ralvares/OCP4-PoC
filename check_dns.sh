#!/bin/bash
IFS=","

CLUSTER_NAME=ocp
DOMAINNAME=example.com

BOOTSTRAP=192.168.150.30
MASTERS=192.168.150.30,192.168.150.31,192.168.150.32
WORKERS=192.168.150.40,192.168.150.41,192.168.150.42

check_dns() {
    cd ~/

    echo "DNS - Checking Master nodes"
    echo "================================================="
    for etcd in ${MASTERS}
        do
        check=$(dig +short -x ${etcd})
        if [ ! -z ${check} ]
            then
            fqdn=$(dig +short ${check})
            if [ ! -z ${fqdn} ]
            then
                    echo -e "$etcd \e[1;32m Record found! - $check\e[0m"
            fi
        else
            echo -e "$etcd \e[1;31m FAIL - Record not found! \e[0m"
        fi
    done
    echo "================================================="
    echo ""

    echo "DNS - Checking Worker nodes"
    echo "================================================="
    for worker in ${WORKERS}
        do
        check=$(dig +short -x ${worker})
        if [ ! -z ${check} ]
            then
            fqdn=$(dig +short ${check})
            if [ ! -z ${fqdn} ]
            then
                    echo -e "$worker \e[1;32m Record found! - $check\e[0m"
            fi
        else
            echo -e "$worker \e[1;31m FAIL - Record not found! \e[0m"
        fi
    done
    echo "================================================="
    echo ""


    echo "DNS - Checking etcd SRV entries"
    echo "================================================="
    dig _etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAINNAME} SRV +short | while read line; do
        etcd_host=$(echo $line | awk '{print $4}')
        etcd_port=$(echo $line | awk '{print $1" "$2" "$3}')
        if [ "$etcd_port" == "0 10 2380" ] 
        then
            if [[ "$etcd_host" == *"etcd-"* ]]
            then
                ip=$(dig +short ${etcd_host})
                if [ ! -z ${ip} ]
                then
                    ptr=$(dig +short -x ${ip})
                    if [[ "$ptr" != *"etcd-"* ]]
                    then
                        echo -e "$etcd_host - _etcd-server-ssl._tcp - \e[1;32m PASS\e[0m"
                    else
                        echo -e "$etcd_host \e[1;31m FAIL - PTR Records found! \e[0m"
                    fi
                else
                    echo -e "$etcd_host \e[1;31m FAIL - Please check your ETCD entries! \e[0m"
                fi

            else
                echo -e "$etcd_host \e[1;31m FAIL - Please check your SRV entries! \e[0m"
            fi
        fi
    done
    echo "================================================="
    echo ""

    echo "DNS - Checking API and API-INT entries"
    echo "================================================="
    for api in "api" "api-int"
    do
    ip=$(dig +short ${api}.${CLUSTER_NAME}.${DOMAINNAME})
    if [ ! -z ${ip} ]
        then
        echo -e "$ip - $api       \e[1;32m PASS\e[0m"
    else
        echo -e "$api       \e[1;31m FAIL - Record not found! \e[0m"
    fi
    done
    echo "================================================="
    echo ""


    echo "DNS - Checking Bootstrap nodes"
    echo "================================================="
    for bootstrap in ${BOOTSTRAP}
        do
        check=$(dig +short -x ${bootstrap})
        if [ ! -z ${check} ]
            then
            fqdn=$(dig +short ${check})
            if [ ! -z ${fqdn} ]
            then
            echo -e "$bootstrap \e[1;32m Record found! - $check\e[0m"
            fi
        else
            echo -e "$bootstrap \e[1;31m FAIL - Record not found! \e[0m"
        fi
    done
    echo "================================================="
    echo ""

}

check_dns
