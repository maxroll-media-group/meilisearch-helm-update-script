# Meilisearch Update Script
------------------------------

## Why was this made?

This was made because I found it very tedius to update meilisearch it I didn't want to risk making simple mistakes.
So I made this script which may not be perfect but it gets the job done with minimal downtime.
Also it was made because it's not very convinient to update meilisearch when it's deployed in Kubernetes.

## Assumptions

This script assumes you have the following cli tools installed:

* kubectl (connected to the cluster that contains the meilisearch instance)
* Helm 3
* jq
* yq

It also assumes you installed Meilisearch using Helm and you are upgrading from a version newer than 1.0.0

## how to use


Update to the latest release:

```
$ bash patch_meilisearch.sh <helm release name> <namespace> <master key>
```

You can also specify a specific version:

```
$ bash patch_meilisearch.sh <helm release name> <namespace> <master key> <helm release version>
```
