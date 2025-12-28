# Self-hosted Kubernetes Cluster

Welcome to my opinionated self-hosted declarative Kubernetes cluster. The primary goal was to simply deploy a Kubernetes cluster with some easy bootstrapping mechanisms based off of the [onedr0p template](https://github.com/onedr0p/cluster-template).

## ✨ Features

### Key Components
- **Talos Linux**: Immutable, API-managed container OS for enhanced security and simplicity.
- **Flux CD**: Declarative GitOps tool for automated, version-controlled deployments.
- **Cilium**: Advanced container networking with built-in security features.
- **Envoy Gateway**: API gateway managing internal and external traffic routing.
- **cert-manager**: Automated provisioning and renewal of TLS certificates.
- **External Secrets Operator + 1Password**: Secure management of application secrets via 1Password integration.
- **Spegel**: Distributed image caching to optimize container pulls across nodes.
- **Reloader**: Automatic pod restarts when ConfigMaps or Secrets change.
- **external-dns**: Dynamic DNS record management for Cloudflare.
- **cloudflared**: Secure tunneling for external access to applications.

**Other features include:**

- Dev env managed w/ [mise](https://mise.jdx.dev/)
- Workflow automation w/ [GitHub Actions](https://github.com/features/actions)
- Dependency automation w/ [Renovate](https://www.mend.io/renovate)
- Flux `HelmRelease` and `Kustomization` diffs w/ [flux-local](https://github.com/allenporter/flux-local)

### Automation Tools
- **mise**: Tool version manager for consistent development environments.
- **GitHub Actions**: CI/CD automation for workflows and validations.
- **Renovate**: Automated dependency updates to keep components current.
- **flux-local**: Local testing and diffing of Flux manifests.

## 🏗️ Cluster Architecture

This cluster runs on Talos Linux, an immutable OS managed via API for security and reliability. GitOps is implemented with Flux CD, enabling declarative and version-controlled deployments. Networking is handled by Cilium for efficient container communication, with Envoy Gateway providing ingress for both internal and external access. DNS management includes internal k8s_gateway and external-dns integration with Cloudflare. Certificates are automated via cert-manager, and secrets are securely managed through External Secrets Operator with 1Password. Utilities like Spegel provide distributed image caching, while Reloader ensures automatic pod updates on config changes.

## 🖥️ Cluster Nodes

- **Nodes**: 3 high-availability control plane nodes running Talos Linux.
- **Storage**: NVMe SSD with ephemeral volumes (50-95GB) and Longhorn-managed data volumes (up to 900GB ext4).
- **Networking**: Static IPs with virtual IP for load balancing.

## 🔧 Development & Automation

The development environment uses mise for reproducible tooling. Automation includes GitHub Actions for CI/CD workflows, Renovate for dependency management, and flux-local for local validation of Flux configurations.

## 🤝 Thanks

Big shout out to all the contributors, sponsors and everyone else who has helped on this project.
