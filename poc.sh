#!/bin/bash
IFS=","
##############################################################
# UPDATE TO MATCH THE ENVIRONMENT
##############################################################

OCP_RELEASE_PATH=ocp
OCP_SUBRELEASE=4.3.0

RHCOS_RELEASE=4.3
RHCOS_IMAGE_BASE=4.3.0-x86_64

WEBROOT=/var/www/html
CLUSTER_NAME=ocp

NFS=true
NFSROOT=/exports
NFS_DEV=vdb
NFS_PROVISIONER=true

OCP_REGISTRY_STORAGE_TYPE=nfs

DOMAINNAME=example.com

LB=true

#IPs NODES
BOOTSTRAP=192.168.150.30
MASTERS=192.168.150.30,192.168.150.31,192.168.150.32
WORKERS=192.168.150.40,192.168.150.41,192.168.150.42

AIRGAP_REG='bastion.ocp.example.com'
AIRGAP_REPO='ocp4/openshift4'
AIRGAP_SECRET_JSON='pull-secret.json'
AIRGAP_BIND_IP=192.168.150.10
RHEL_PULLSECRET='redhat-registry-pullsecret.json'


usage() {
    echo -e "Usage: $0 [ clean | check_dns | install | prep_registry | mirror ] "
    echo -e "\t\t(extras) [ get_images | prep_installer | prep_images | prep_nfs | prep_http | pre_lb ]"
}

get_images() {
    cd ~/
    test -d images || mkdir images ; cd images 
    
    test -f images/rhcos-${RHCOS_IMAGE_BASE}-installer-initramfs.img || curl -J -L -O https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${RHCOS_RELEASE}/latest/rhcos-${RHCOS_IMAGE_BASE}-installer-initramfs.img
    test -f images/rhcos-${RHCOS_IMAGE_BASE}-installer-kernel ||curl -J -L -O https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${RHCOS_RELEASE}/latest/rhcos-${RHCOS_IMAGE_BASE}-installer-kernel
    test -f images/rhcos-${RHCOS_IMAGE_BASE}-metal.raw.gz || curl -J -L -O https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${RHCOS_RELEASE}/latest/rhcos-${RHCOS_IMAGE_BASE}-metal.raw.gz
    test -f images/rhcos-${RHCOS_IMAGE_BASE}-installer.iso || curl -J -L -O https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${RHCOS_RELEASE}/latest/rhcos-${RHCOS_IMAGE_BASE}-installer.iso

    test -f images/openshift-client-linux-${OCP_SUBRELEASE}.tar.gz  || curl -J -L -O https://mirror.openshift.com/pub/openshift-v4/clients/${OCP_RELEASE_PATH}/${OCP_SUBRELEASE}/openshift-client-linux-${OCP_SUBRELEASE}.tar.gz 
    test -f images/openshift-install-linux-${OCP_SUBRELEASE}.tar.gz || curl -J -L -O https://mirror.openshift.com/pub/openshift-v4/clients/${OCP_RELEASE_PATH}/${OCP_SUBRELEASE}/openshift-install-linux-${OCP_SUBRELEASE}.tar.gz

    cd ..
    tree images
}

prep_http() {
    if [[ $(rpm -qa httpd | wc -l) -ge 1 ]] ;
    then
    sed -i -e 's/Listen 80/Listen 8080/g' /etc/httpd/conf/httpd.conf
    firewall-cmd --permanent --add-port=8080/tcp -q
    firewall-cmd --reload -q
    systemctl enable --now httpd
    echo -e "\e[1;32m HTTP - HTTP Server Configuration: DONE \e[0m"
    else
    install_tools
    prep_http
    fi
}

prep_nfs() {
    if [ ${NFS} = true ] ; then
        if [[ $(rpm -qa nfs-utils rpcbind | wc -l) -ge 2 ]] ; 
        then
            systemctl enable --now rpcbind
            systemctl enable --now nfs-server
            firewall-cmd --permanent --add-service=mountd -q
            firewall-cmd --permanent --add-service=nfs -q
            firewall-cmd --permanent --add-service=rpc-bind -q
            firewall-cmd --reload -q

            test -d ${NFSROOT} || mkdir -p ${NFSROOT}

            if [ ${NFS_DEV} != false ] ; then
                if [ !  -b /dev/mapper/OCP-nfs ]
                then
                    pvcreate /dev/${NFS_DEV} 
                    vgcreate OCP /dev/${NFS_DEV}
                    lvcreate -l 100%FREE -n nfs OCP
                    mkfs.xfs -q /dev/mapper/OCP-nfs
                    #mount /dev/mapper/OCP-nfs ${NFSROOT}
                    if ! grep -qw "/dev/mapper/OCP-nfs" /etc/fstab;
                    then 
                        echo "/dev/mapper/OCP-nfs   ${NFSROOT}  xfs defaults    0 0" >> /etc/fstab;
                        mount -a
                    fi
                fi
            fi
            test -d ${NFSROOT}/pv-infra-registry || mkdir ${NFSROOT}/pv-infra-registry
            if [ ${NFS_PROVISIONER} = true ] ; then
                test -d ${NFSROOT}/pv-user-pvs || mkdir ${NFSROOT}/pv-user-pvs
            fi
            cp -rf /etc/exports /etc/exports.$(date "+%Y-%m-%d-%T")
            > /etc/exports
            for NODE in ${MASTERS}; do 
                echo "${NFSROOT}/pv-infra-registry $NODE(rw,sync,no_root_squash)" >> /etc/exports
                echo "${NFSROOT}/pv-user-pvs $NODE(rw,sync,no_root_squash)" >> /etc/exports
            done
            for NODE in ${WORKERS}; do 
                echo "${NFSROOT}/pv-infra-registry $NODE(rw,sync,no_root_squash)" >> /etc/exports
                echo "${NFSROOT}/pv-user-pvs $NODE(rw,sync,no_root_squash)" >> /etc/exports
            done
            exportfs -a
            echo -e "\e[1;32m NFS - NFS Server Configuration: DONE \e[0m"
        else
            install_tools
            prep_nfs
        fi
    fi
}

install_tools() {
    #RHEL8
    if grep -q -i "release 8" /etc/redhat-release; then   
    dnf -y install podman httpd haproxy bind-utils net-tools nfs-utils rpcbind wget tree
    echo -e "\e[1;32m Packages - Dependencies installed\e[0m"
    fi

    #RHEL7
    if grep -q -i "release 7" /etc/redhat-release; then
    #subscription-manager repos --enable rhel-7-server-extras-rpms
    yum -y install podman httpd haproxy bind-utils net-tools nfs-utils rpcbind wget tree || echo "Please - Enable rhel7-server-extras-rpms repo" && echo -e "\e[1;32m Packages - Dependencies installed\e[0m"
    fi
}

mirror () {
    cd ~/
    echo "Mirroring from Quay into Local Registry"
    LOCAL_REGISTRY="${AIRGAP_REG}:5000"
    LOCAL_REPOSITORY="${AIRGAP_REPO}"
    PRODUCT_REPO='openshift-release-dev'
    LOCAL_SECRET_JSON="${AIRGAP_SECRET_JSON}"
    RELEASE_NAME="ocp-release"
    OCP_RELEASE="${RHCOS_IMAGE_BASE}"

    podman login --authfile mirror-registry-pullsecret.json "${AIRGAP_REG}:5000"
    jq -s '{"auths": ( .[0].auths + .[1].auths ) }' mirror-registry-pullsecret.json ${RHEL_PULLSECRET} > ${AIRGAP_SECRET_JSON}   

    oc adm -a ${LOCAL_SECRET_JSON} release mirror \
        --from=quay.io/${PRODUCT_REPO}/${RELEASE_NAME}:${OCP_RELEASE} \
        --to=${LOCAL_REGISTRY}/${LOCAL_REPOSITORY} \
        --to-release-image=${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}

    echo "Retrieving 'openshift-install' from local container repository"
    oc adm release extract -a ${AIRGAP_SECRET_JSON} --command=openshift-install "${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}"
    mv openshift-install bin/openshift-install
    echo "Retrieving 'openshift-install' Version"
    openshift-install version
}

install() {
    cd ~/
    echo "Creating and populating installation folder"
    mkdir ${CLUSTER_NAME}
    cp install-config.yaml ${CLUSTER_NAME}
    echo "Generating ignition files"
    openshift-install create ignition-configs --dir=${CLUSTER_NAME}
    prep_ign
}

prep_installer () {
    cd ~/
    echo "Uncompressing installer and client binaries"
    mkdir ~/bin/
    tar -xzf ./images/openshift-client-linux-${OCP_SUBRELEASE}.tar.gz  -C ~/bin 
    tar -xaf ./images/openshift-install-linux-${OCP_SUBRELEASE}.tar.gz -C ~/bin 
}

prep_images () {
    cd ~/
    prep_http
    echo "Copying RHCOS OS Images to ${WEBROOT}"
    cp -f ./images/rhcos-${RHCOS_IMAGE_BASE}-metal.raw.gz ${WEBROOT}

    echo "Copying RHCOS Boot Images to ${WEBROOT}"
    cp ./images/rhcos-${RHCOS_IMAGE_BASE}-installer-initramfs.img ${WEBROOT}
    cp ./images/rhcos-${RHCOS_IMAGE_BASE}-installer-kernel ${WEBROOT}
    tree ${WEBROOT}
}

prep_ign () {
    cd ~/
    prep_http
    echo "Installing Ignition files into web path"
    cp -f ${CLUSTER_NAME}/*.ign ${WEBROOT}
    tree ${WEBROOT}
    echo "Assuming VMs boot process in progress"
    openshift-install wait-for bootstrap-complete --dir=${CLUSTER_NAME} --log-level debug
    echo "Enable cluster credentials: 'export KUBECONFIG=${CLUSTER_NAME}/auth/kubeconfig'"
    export KUBECONFIG=${CLUSTER_NAME}/auth/kubeconfig
    echo "Assuming VMs boot process in progress"
    openshift-install wait-for install-complete --dir=${CLUSTER_NAME} --log-level debug
}

create_config(){
 echo install-config
}

prep_loadbalancer(){
    sed -i '0,/NODE/s//MASTER/' test.sh
}

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


prep_registry (){
    cd ~/
    fqdn=$(dig +short ${AIRGAP_REG})
    if [ ! -z ${fqdn} ]
    then
    test -d /opt/registry/ || mkdir -p /opt/registry/{auth,certs,data}
    test -f /opt/registry/certs/domain.crt || openssl req -newkey rsa:4096 -nodes -sha256 -keyout /opt/registry/certs/domain.key -x509 -days 365 -subj "/CN=${AIRGAP_REG}" -out /opt/registry/certs/domain.crt
    cp -rf /opt/registry/certs/domain.crt /etc/pki/ca-trust/source/anchors/
    update-ca-trust
    if [ ! -f /opt/registry/auth/htpasswd ]
    then
    echo "Please enter admin user password"
    htpasswd -Bc /opt/registry/auth/htpasswd admin
    fi


    test -f /etc/systemd/system/mirror-registry.service || cat > /etc/systemd/system/mirror-registry.service << EOF
[Unit]
Description=Mirror registry (mirror-registry)
After=network.target

[Service]
Type=simple
TimeoutStartSec=5m

ExecStartPre=-/usr/bin/podman rm "mirror-registry"
ExecStartPre=/usr/bin/podman pull quay.io/redhat-emea-ssa-team/registry:2
ExecStart=/usr/bin/podman run --name mirror-registry --net host \
  -v /opt/registry/data:/var/lib/registry:z \
  -v /opt/registry/auth:/auth:z \
  -e "REGISTRY_AUTH=htpasswd" \
  -e "REGISTRY_HTTP_ADDR=${AIRGAP_BIND_IP}:5000" \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=registry-realm" \
  -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" \
  -v /opt/registry/certs:/certs:z \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
  quay.io/redhat-emea-ssa-team/registry:2

ExecReload=-/usr/bin/podman stop "mirror-registry"
ExecReload=-/usr/bin/podman rm "mirror-registry"
ExecStop=-/usr/bin/podman stop "mirror-registry"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload -q
    systemctl enable --now mirror-registry -q
    firewall-cmd --permanent --add-port=5000/tcp -q
    firewall-cmd --permanent --add-port=5000/udp -q
    firewall-cmd --reload -q
    echo -e "\e[1;32m Registry - Container Registry Configuration: DONE \e[0m"
else
    echo -e "$AIRGAP_REG \e[1;31m FAIL - DNS Record not found! \e[0m"
fi
}

prep_discon(){
    install_tools
    prep_http
    prep_nfs
    get_images
    prep_images
    prep_installer
    prep_registry
    mirror
}

key="$1"

case $key in
    prep_nfs)
        prep_nfs
        ;;
    prep_http)
        prep_http
        ;;        
    get_images|images)
        get_images
        ;;
    mirror)
        mirror
        ;;
    clean)
        clean
        ;;
    install)
        install
        ;;
    prep_installer)
        prep_installer
        ;;
    prep_images)
        prep_images
        ;;
    check_dns)
        check_dns
        ;;
    prep_registry)
        prep_registry
        ;;
    disconnected)
        prep_discon
        ;;
    *)
        usage
        ;;
esac

##############################################################
# END OF FILE
##############################################################
