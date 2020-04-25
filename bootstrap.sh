#!/bin/bash

GITDIR='/opt/git/github/k8s-cluster-deployment'
WORKFOLDER='/opt/k8s_bootstrap'

if [ ! -d "$WORKFOLDER" ]
then
	mkdir -p "$WORKFOLDER"
fi

cd ${WORKFOLDER} ||\
echo "echo 'Can't change directory to bootstrap workfolder, exiting.'; kill -9 $$" | bash

#Generate management ssh key
if [ ! -d ""${WORKFOLDER}"/ssh" ]
then
	mkdir -p "$WORKFOLDER"/ssh
	ssh-keygen -b 2048 -t rsa -f $WORKFOLDER/ssh/k8s-management -q -N ""
fi

#The cfssl and cfssljson command line utilities will be used to provision a PKI Infrastructure and generate TLS certificates.
if [ ! -f /usr/local/bin/cfssl ];
then
	wget -q --timestamping \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/linux/cfssl \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/linux/cfssljson
	chmod +x cfssl cfssljson
	mv cfssl cfssljson /usr/local/bin/\
	&& echo "cfssl successfully installed"
else
	echo "cfssl already installed"
fi

#Setup DNS/SSH over cluster nodes
for NODE in $(awk -F ' ' '!/master/ {print $2}' "${GITDIR}"/config/k8s_nodes);
do
	if [ ! "$(grep "${NODE}" /etc/hosts )" ];
	then
		ADDNODE=$(grep "${NODE}" "${GITDIR}"/config/k8s_nodes)
		echo "${ADDNODE}" >> /etc/hosts
	fi
	ssh-copy-id -o StrictHostKeyChecking=no -i ${WORKFOLDER}/ssh/k8s-management.pub "${NODE}" > /dev/null 2>&1\
	&& scp "${GITDIR}"/config/k8s_nodes "${GITDIR}"/scripts/setup-dns.sh ${NODE}:/tmp > /dev/null 2>&1\
	&& ssh ${NODE} "bash /tmp/setup-dns.sh"
done

#Get kubectl
if [ ! -f "/usr/local/bin/kubectl" ]
then
	echo "Attempting to get kubectl."
	wget -q https://storage.googleapis.com/kubernetes-release/release/v1.15.3/bin/linux/amd64/kubectl
	chmod +x kubectl
	sudo mv kubectl /usr/local/bin/\
	&& echo "Ok"
else
	echo "Kubectl already installed"
fi

###Certs time!
#Certificate Authority
CERTS_DIR="$WORKFOLDER/certs"
cp -r ${GITDIR}/certs ${CERTS_DIR}

cd ${CERTS_DIR}/CA\
&& cfssl gencert -initca ca-csr.json | cfssljson -bare ca

#Admin client certs
cd ${CERTS_DIR}/admin\
&& cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin

#Kubelet client certificates
cd ${CERTS_DIR}/kubelet\
&& for NODE in $(awk -F ' ' '!/master/ {print $2}' "$GITDIR"/config/k8s_nodes);
do
	cat > ${CERTS_DIR}/kubelet/${NODE}-csr.json <<EOF
{
  "CN": "system:node:${NODE}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "RU",
      "L": "Moscow",
      "O": "system:nodes",
      "OU": "Kubernetes",
      "ST": "Moscow"
    }
  ]
}
EOF

NODE_IPADDR=$(awk -F ' ' '/'$NODE'/ {print $1}' "$GITDIR"/config/k8s_nodes)
cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -hostname=${NODE},${NODE_IPADDR} \
  -profile=kubernetes \
  ${NODE}-csr.json | cfssljson -bare ${NODE}
done