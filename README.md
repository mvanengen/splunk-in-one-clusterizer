# Splunk-in-One Shell Solution

## Summary
A script paired with a collection of Docker Compose files providing a quick, functional Splunk cluster setup. This solution includes containers for the search head and indexer, a master forwarder, a cluster master and a license master, and a deployment server. It functions as a "drop-in" solution for system administrators to deploy a fresh, scalable Splunk environment capable of receiving and indexing data.

## Usage
This tool offers two modes of operation based on your deployment goal:

1. **All-in-One Quick Start:** Use this mode for quick testing or development where all roles (Search Head, Indexer, etc.) run on the same host. The script builds and manages all necessary containers using the provided `cluster.yml` template to define roles locally. This is the fastest way to get a functional cluster running. Beware, running an entire Splunk cluster on one machine can become resource intensive!
2. **Distributed Cluster Integration:** Use this mode when building parts of a larger cluster. You specify external IPs and ports for members (suhc as search heads or indexers, or a license Master) via the `--cluster-config` flag pointing to a custom `cluster.yml`. This allows your containerized service to communicate with peers running elsewhere on your network.

The script manages sequential startup, graceful shutdown (`--down`), and requires a license file for building a persistent environment.

## Usage Rights
This project adheres to the GNU GPL V3 license, which ensures that users have the freedom to run, study, share, and modify this software. Any derivatives of this project must be released under the same license.