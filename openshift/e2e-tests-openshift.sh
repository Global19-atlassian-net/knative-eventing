#!/bin/sh 

source $(dirname $0)/../vendor/github.com/knative/test-infra/scripts/e2e-tests.sh
source $(dirname $0)/kubecon-demo.sh

set -x

readonly SERVING_VERSION=v0.3.0
readonly EVENTING_SOURCES_VERSION=v0.3.0

readonly SERVING_BASE=https://github.com/knative/serving/releases/download/${SERVING_VERSION}
readonly ISTIO_CRD_RELEASE=${SERVING_BASE}/istio-crds.yaml
readonly ISTIO_RELEASE=${SERVING_BASE}/istio.yaml
readonly SERVING_RELEASE=${SERVING_BASE}/release.yaml

readonly EVENTING_SOURCES_RELEASE=https://github.com/knative/eventing-sources/releases/download/${EVENTING_SOURCES_VERSION}/release.yaml

readonly K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
readonly API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
readonly INTERNAL_REGISTRY="${INTERNAL_REGISTRY:-"docker-registry.default.svc:5000"}"
readonly USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
readonly OPENSHIFT_REGISTRY="${OPENSHIFT_REGISTRY:-"registry.svc.ci.openshift.org"}"
readonly INSECURE="${INSECURE:-"false"}"
readonly EVENTING_NAMESPACE=knative-eventing
readonly TEST_NAMESPACE=e2etest
readonly TEST_FUNCTION_NAMESPACE=e2etestfn3

env

function install_istio(){
  header "Installing Istio"
  # Grant the necessary privileges to the service accounts Istio will use:
  oc adm policy add-scc-to-user anyuid -z istio-ingress-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z default -n istio-system
  oc adm policy add-scc-to-user anyuid -z prometheus -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-egressgateway-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-citadel-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-ingressgateway-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-cleanup-old-ca-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-mixer-post-install-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-mixer-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-pilot-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z istio-sidecar-injector-service-account -n istio-system
  oc adm policy add-scc-to-user anyuid -z cluster-local-gateway-service-account -n istio-system
  oc adm policy add-cluster-role-to-user cluster-admin -z istio-galley-service-account -n istio-system
  
  # Deploy the latest Istio release
  oc apply -f $ISTIO_CRD_RELEASE
  oc apply -f $ISTIO_RELEASE

  # Ensure the istio-sidecar-injector pod runs as privileged
  oc get cm istio-sidecar-injector -n istio-system -o yaml | sed -e 's/securityContext:/securityContext:\\n      privileged: true/' | oc replace -f -
  # Monitor the Istio components until all the components are up and running
  wait_until_pods_running istio-system || return 1
  header "Istio Installed successfully"
}

function install_knative_serving(){
  header "Installing Knative Serving"

  # Grant the necessary privileges to the service accounts Knative will use:
  oc adm policy add-scc-to-user anyuid -z build-controller -n knative-build
  oc adm policy add-scc-to-user anyuid -z controller -n knative-serving
  oc adm policy add-scc-to-user anyuid -z autoscaler -n knative-serving
  oc adm policy add-cluster-role-to-user cluster-admin -z build-controller -n knative-build
  oc adm policy add-cluster-role-to-user cluster-admin -z controller -n knative-serving

  curl -L ${SERVING_RELEASE} | sed '/nodePort/d' | oc apply -f -
  
  oc -n ${SERVING_NAMESPACE} get cm config-controller -oyaml | \
  sed "s/\(^ *registriesSkippingTagResolving.*$\)/\1,image-registry.openshift-image-registry.svc:5000/" | oc apply -f -

  echo ">> Patching knative-ingressgateway"
  oc patch hpa -n istio-system knative-ingressgateway --patch '{"spec": {"maxReplicas": 1}}'

  wait_until_pods_running knative-build || return 1
  wait_until_pods_running knative-serving || return 1
  wait_until_service_has_external_ip istio-system knative-ingressgateway || fail_test "Ingress has no external IP"
  header "Knative Installed successfully"
}

function install_knative_eventing_sources(){
  header "Installing Knative Eventing Sources"
  oc apply -f ${EVENTING_SOURCES_RELEASE}
  wait_until_pods_running knative-sources || return 1
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  # Create knative-eventing namespace, needed for imagestreams
  oc create namespace $EVENTING_NAMESPACE

  # Grant the necessary privileges to the service accounts Knative will use:
  oc annotate clusterrolebinding.rbac cluster-admin 'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite
  oc annotate clusterrolebinding.rbac cluster-admins 'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite

  oc adm policy add-scc-to-user anyuid -z eventing-controller -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z in-memory-channel-dispatcher -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z in-memory-channel-controller -n $EVENTING_NAMESPACE

  resolve_resources config/ $EVENTING_NAMESPACE eventing-resolved.yaml
  oc apply -f eventing-resolved.yaml

  oc adm policy add-cluster-role-to-user cluster-admin -z eventing-controller -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z in-memory-channel-dispatcher -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z in-memory-channel-controller -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z default -n knative-sources

  echo ">>> Setting SSL_CERT_FILE for Knative Eventing Controller"
  oc set env -n $EVENTING_NAMESPACE deployment/eventing-controller SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt

  wait_until_pods_running $EVENTING_NAMESPACE
}

function install_in_memory_channel_provisioner(){
  header "Standing up In-Memory ClusterChannelProvisioner"
  resolve_resources config/provisioners/in-memory-channel/ $EVENTING_NAMESPACE channel-resolved.yaml
  oc apply -f channel-resolved.yaml
}

function create_test_resources() {
  echo ">> Ensuring pods in test namespaces can access test images"
  oc policy add-role-to-group system:image-puller system:serviceaccounts:$TEST_NAMESPACE --namespace=$EVENTING_NAMESPACE
  oc policy add-role-to-group system:image-puller system:serviceaccounts:$TEST_FUNCTION_NAMESPACE --namespace=$EVENTING_NAMESPACE

  echo ">> Creating imagestream tags for all test images"
  tag_test_images test/test_images

  #Grant additional privileges
  oc adm policy add-scc-to-user anyuid -z default -n $TEST_FUNCTION_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_FUNCTION_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z e2e-receive-adapter -n $TEST_FUNCTION_NAMESPACE
  oc adm policy add-scc-to-user privileged -z e2e-receive-adapter -n $TEST_FUNCTION_NAMESPACE
}

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$3
  > $resolved_file_name
  for yaml in $(find $dir -maxdepth 1 -name "*.yaml"); do
    echo "---" >> $resolved_file_name
    #first prefix all test images with "test-", then replace all image names with proper repository
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(test\/\)\(.*\)/\1\2 \3\4test-\5/' $yaml | \
    sed -e 's%github.com/knative/eventing/pkg/controller/eventing/inmemory/controller%'"$INTERNAL_REGISTRY"'\/'"$EVENTING_NAMESPACE"'\/knative-eventing-in-memory-channel-controller%' | \
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$INTERNAL_REGISTRY"'\/'"$EVENTING_NAMESPACE"'\/knative-eventing-\4/' >> $resolved_file_name
  done

  oc policy add-role-to-group system:image-puller system:serviceaccounts:${EVENTING_NAMESPACE} --namespace=${OPENSHIFT_BUILD_NAMESPACE}

  echo ">> Creating imagestream tags for images referenced in yaml files"
  IMAGE_NAMES=$(cat $resolved_file_name | grep -i "image:" | grep "$INTERNAL_REGISTRY" | awk '{print $2}' | awk -F '/' '{print $3}')
  for name in $IMAGE_NAMES; do
    tag_built_image ${name} ${name}
  done
}

function enable_docker_schema2(){
  oc set env -n default dc/docker-registry REGISTRY_MIDDLEWARE_REPOSITORY_OPENSHIFT_ACCEPTSCHEMA2=true
}

function create_test_namespace(){
  oc new-project $TEST_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_NAMESPACE
  oc new-project $TEST_FUNCTION_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_FUNCTION_NAMESPACE
}

function run_e2e_tests(){
  header "Running tests"
  options=""
  (( EMIT_METRICS )) && options="-emitmetrics"
  report_go_test \
    -v -tags=e2e -count=1 -timeout=20m \
    ./test/e2e \
    --tag latest \
    --kubeconfig $KUBECONFIG \
    --dockerrepo ${INTERNAL_REGISTRY}/${EVENTING_NAMESPACE} \
    ${options} || return 1
}

function delete_istio_openshift(){
  echo ">> Bringing down Istio"
  oc delete --ignore-not-found=true -f $ISTIO_RELEASE
  oc delete --ignore-not-found=true -f $ISTIO_CRD_RELEASE
}

function delete_serving_openshift() {
  echo ">> Bringing down Serving"
  oc delete --ignore-not-found=true -f $SERVING_RELEASE
}

function delete_test_namespace(){
  echo ">> Deleting test namespace $TEST_NAMESPACE"
  oc adm policy remove-scc-from-user privileged -z default -n $TEST_NAMESPACE
  oc delete project $TEST_NAMESPACE
  echo ">> Deleting test namespace $TEST_FUNCTION_NAMESPACE"
  oc adm policy remove-scc-from-user privileged -z default -n $TEST_FUNCTION_NAMESPACE
  oc delete project $TEST_FUNCTION_NAMESPACE
}

function delete_knative_eventing_sources(){
  header "Brinding down Knative Eventing Sources"
  oc delete --ignore-not-found=true -f $EVENTING_SOURCES_RELEASE
}

function delete_knative_eventing(){
  header "Bringing down Eventing"
  oc delete --ignore-not-found=true -f eventing-resolved.yaml
}

function delete_in_memory_channel_provisioner(){
  header "Bringing down In-Memory ClusterChannelProvisioner"
  oc delete --ignore-not-found=true -f channel-resolved.yaml
}

function teardown() {
  delete_demo
  delete_test_namespace
  delete_in_memory_channel_provisioner
  delete_knative_eventing
  delete_knative_eventing_sources
  delete_serving_openshift
  delete_istio_openshift
}

function tag_test_images() {
  local dir=$1
  image_dirs="$(find ${dir} -mindepth 1 -maxdepth 1 -type d)"

  for image_dir in ${image_dirs}; do
    name=$(basename ${image_dir})
    tag_built_image knative-eventing-test-${name} ${name}
  done
}

function tag_built_image() {
  local remote_name=$1
  local local_name=$2
  oc tag --insecure=${INSECURE} -n ${EVENTING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:${remote_name} ${local_name}:latest
}

install_istio

enable_docker_schema2

install_knative_serving

install_knative_eventing_sources

install_knative_eventing

install_in_memory_channel_provisioner

create_test_namespace

create_test_resources

failed=0

run_e2e_tests || failed=1

run_demo || failed=1

(( failed )) && dump_cluster_state

teardown

(( failed )) && exit 1

success