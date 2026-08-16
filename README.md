# Splunk-in-One Shell Solution

## Summary
A collection of Docker Compose files and scripts providing a quick, functional Splunk cluster setup. This solution includes containers for search head, indexer, master forwarder, cluster master, license master, and deployment server. It functions as a "drop-in" solution for system administrators to deploy a fresh, scalable Splunk environment capable of receiving and indexing data.

## Usage
## Usage
This tool offers two modes of operation based on your deployment goal:

1. **All-in-One Quick Start:** Use this mode for quick testing or development where all roles (Search Head, Indexer, etc.) run on the same host. The script builds and manages all necessary containers using the provided `cluster.yml` template to define roles locally. This is the fastest way to get a functional cluster running.
2. **Distributed Cluster Integration:** Use this mode when building parts of a larger cluster. You specify external IPs and ports for members (like Search Heads or Indexers) via the `--cluster-config` flag pointing to a custom `cluster.yml`. This allows your containerized service to communicate with peers running elsewhere in the network.

The script manages sequential startup, graceful shutdown (`--down`), and requires a license file to build a persistent environment.

## Usage Rights
This project adheres to the GNU GPL V3 license.