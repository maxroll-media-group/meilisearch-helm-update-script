#!/bin/bash

check_pod_and_container_status() {
    local release_label=$1
    local namespace=$2
    echo "Checking pod and container status for release: $release_label in namespace: $namespace..."
    while true; do
        pod_status=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/instance=${release_label}" -o jsonpath="{.items[0].status.phase}")
        container_ready=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/instance=${release_label}" -o jsonpath="{.items[0].status.containerStatuses[0].ready}")

        if [ "$pod_status" == "Running" ] && [ "$container_ready" == "true" ]; then
            echo "Pod is running and container is ready."
            break
        else
            echo "Waiting for pod to be Running and container to be ready. Current status: Pod - $pod_status, Container Ready - $container_ready"
            sleep 10
        fi
    done
}

# check if kubectl, jq and yq are installed
if ! command -v kubectl &> /dev/null; then
    echo "kubectl could not be found, please install it and try again."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq could not be found, please install it and try again."
    exit 1
fi

if ! command -v yq &> /dev/null; then
    echo "yq could not be found, please install it and try again."
    exit 1
fi

# Check if the minimum number of arguments are passed
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 helm_release namespace master_key [new_version]"
    exit 1
fi

helm_release=$1
namespace=$2
master_key=$3
new_version=${4:-""}

echo "Starting the script with inputs:"
echo "Helm Release: $helm_release"
echo "Namespace: $namespace"
echo "Master Key: [hidden]"
if [ -n "$new_version" ]; then
    echo "New Version: $new_version"
else
    echo "New Version: Not specified, assuming latest version"
fi

# Fetch the image tag from the chart's values
echo "Fetching the image tag..."
if [ -n "$new_version" ]; then
    latest_image_tag=$(helm show values meilisearch/meilisearch --version "$new_version" --jsonpath="{.image.tag}")
else
    latest_image_tag=$(helm show values meilisearch/meilisearch --jsonpath="{.image.tag}")
fi
if [ -z "$latest_image_tag" ]; then
    echo "Failed to fetch the image tag"
    exit 1
fi
echo "Image tag: $latest_image_tag"

# Get current Helm values and update the image tag
echo "Retrieving current Helm values..."
current_values_file="current_values.yaml"
helm get values "$helm_release" -n "$namespace" -o yaml > "$current_values_file"
if [ ! -f "$current_values_file" ]; then
    echo "Failed to get current Helm values"
    exit 1
fi

echo "Updating the image tag in current Helm values..."
yq e ".image.tag = \"$latest_image_tag\"" -i "$current_values_file"

# Get the mount path
echo "Retrieving mount path..."
mount_path=$(helm get values -n "$namespace" "$helm_release" -o json | jq -r '.persistence.volume.mountPath')
if [ -z "$mount_path" ]; then
    echo "Failed to get the mount path"
    exit 1
fi
echo "Mount path retrieved: $mount_path"

# Get the first pod of the statefulset
echo "Creating a new dump..."
task_id=$(kubectl exec -n "$namespace" "${helm_release}-0" -- curl -s -H "Authorization: Bearer $master_key" -XPOST http://localhost:7700/dumps | jq -r '.taskUid')
if [ -z "$task_id" ]; then
    echo "Failed to get the task ID"
    exit 1
fi
echo "Task ID obtained: $task_id"

# Poll for dump status
echo "Polling for dump status..."
dump_status=$(kubectl exec -n "$namespace" "${helm_release}-0" -- curl -s -H "Authorization: Bearer $master_key" http://localhost:7700/tasks/"$task_id" | jq -r '.status')
while [ "$dump_status" != "succeeded" ]; do
    echo "Waiting for dump to succeed... Current status: $dump_status"
    sleep 5
    dump_status=$(kubectl exec -n "$namespace" "${helm_release}-0" -- curl -s -H "Authorization: Bearer $master_key" http://localhost:7700/tasks/"$task_id" | jq -r '.status')
done
echo "Dump creation succeeded."

# Backup the data
echo "Creating backup of the data..."
# create a backup directory with todays date
backup_dir="$mount_path/$(date +%Y-%m-%d)_backup_data.ms"

kubectl exec -n "$namespace" "${helm_release}-0" -- mv "$mount_path/data.ms" "$backup_dir"

# Check if the backup directory exists
echo "Checking if backup was successful..."
if ! kubectl exec -n "$namespace" "${helm_release}-0" -- test -d "$backup_dir"; then
    echo "Backup directory does not exist, aborting."
    exit 1
fi
echo "Backup successful."

# Fetch the latest dump file
echo "Fetching the latest dump file..."
path_to_latest_dump=$(kubectl exec -n "$namespace" "${helm_release}-0" -- ls -t "$mount_path/dumps" | head -n 1)
echo "Path to latest dump: $path_to_latest_dump"

# Update the Helm chart with the modified values file
echo "Upgrading the Helm chart with modified values..."
if [ -n "$new_version" ]; then
    helm upgrade -n "$namespace" -f "$current_values_file" --version "$new_version" -i "$helm_release" meilisearch/meilisearch
else
    helm upgrade -n "$namespace" -f "$current_values_file" -i "$helm_release" meilisearch/meilisearch
fi
echo "Helm chart upgraded."


# Patch the pod with the exec command
echo "Patching the pod to import the latest dump..."
kubectl patch statefulset "${helm_release}" -n "$namespace" --type='json' -p "[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/command\", \"value\": [\"meilisearch\"]}, {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/args\", \"value\": [\"--import-dump\", \"$mount_path/dumps/$path_to_latest_dump\"]}]"
echo "Pod patched. Waiting 5 seconds before checking pod status..."
sleep 5

# Wait for pod to be running
check_pod_and_container_status "$helm_release" "$namespace"

# Remove the patched cmd and args
echo "Removing patched command and arguments from the pod..."
kubectl patch statefulset "${helm_release}" -n "$namespace" --type='json' -p "[{\"op\": \"remove\", \"path\": \"/spec/template/spec/containers/0/command\"}, {\"op\": \"remove\", \"path\": \"/spec/template/spec/containers/0/args\"}]"
echo "Patch removed. Pod should restart with original settings."

# Final check for pod restart
echo "Final check for pod status after patch removal..."
check_pod_and_container_status "$helm_release" "$namespace"

# check if current_values.yaml still exists, if so, delete it
if [ -f "$current_values_file" ]; then
    echo "Deleting current_values.yaml..."
    rm "$current_values_file"
fi

# delete the temporary backup directory
echo "Deleting temporary backup directory if it exists..."
kubectl exec -n "$namespace" "${helm_release}-0" -- rm -rf "${backup_dir}"

# check if the delete was successful
if kubectl exec -n "$namespace" "${helm_release}-0" -- test -d "$backup_dir"; then
    echo "Failed to delete temporary backup directory, please delete it manually."
    exit 1
fi


echo "Script completed successfully."

